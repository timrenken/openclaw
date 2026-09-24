# deploy-fork.ps1 - Deploy our fork build of OpenClaw to the global npm install.
#
# Doctrine (2026-09-23): "The best agent harness is the one that we fork and make our own."
#   - Source of truth: D:\projects\openclaw  (fork of github.com/openclaw/openclaw)
#   - Installs come ONLY from our built artifact (docker-e2e-package tarball).
#   - NEVER run `openclaw update` / `npm update -g openclaw` / `npm i -g openclaw` - those
#     replace our build with stock npm. update.channel=extended-stable + checkOnStart=false
#     + OPENCLAW_NO_AUTO_UPDATE=1 block automatic/background swaps; this script is the
#     sanctioned deploy path.
#
# OWNER-RUN ONLY. This stops and restarts the "OpenClaw Gateway" scheduled task (kills
# agent sessions; Discord unclean-handoff cooldown doctrine applies). Do NOT invoke from
# an agent session - run it from a host shell.

param(
  [string]$Tarball = "",
  [switch]$SkipConfirm,
  [int]$CooldownSeconds = 0
)

$ErrorActionPreference = "Stop"
$ForkRoot   = "D:\projects\openclaw"
$NpmRoot    = "C:\Users\Tim\AppData\Roaming\npm"
$Installed  = Join-Path $NpmRoot "node_modules\openclaw"
$TaskName   = "OpenClaw Gateway"
$MarkerName = ".fork-deploy.json"
$DistMarker = "PreparedModelRuntimePublicationQueue"

function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }

# --- 1. Locate tarball -----------------------------------------------------------
if (-not $Tarball) {
  $Tarball = Get-ChildItem (Join-Path $ForkRoot ".artifacts\docker-e2e-package\openclaw-*.tgz") -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $Tarball -or -not (Test-Path $Tarball)) {
  throw "No fork tarball found (got: '$Tarball'). Build one first: node scripts/package-openclaw-for-docker.mjs"
}
Step "Tarball: $Tarball"

# --- 2. Preflight: prove the tarball is OUR fork build, not stock npm ------------
$members = tar -tf $Tarball | Where-Object { $_ -match '^package/dist/prepared-model-runtime-[^/]+\.mjs$' }
if (-not $members) { throw "PREFLIGHT FAILED: no prepared-model-runtime dist files in tarball - is this an openclaw package?" }
$hits = 0
foreach ($m in $members) {
  $hits += (tar -xOf $Tarball $m 2>$null | Select-String -SimpleMatch $DistMarker -ErrorAction SilentlyContinue | Measure-Object).Count
}
if ($hits -lt 1) { throw "PREFLIGHT FAILED: tarball lacks fork dist marker '$DistMarker' - refusing to deploy (that would install stock)." }
Step "Preflight OK: fork dist marker present ($hits hits)"

# --- 3. Confirm --------------------------------------------------------------------
if (-not $SkipConfirm) {
  Write-Host "This STOPS '$TaskName', swaps the global npm package, then STARTS it again."
  Write-Host "Current install: $Installed"
  if ($CooldownSeconds -gt 0) { Write-Host "Cooldown between stop and start: $CooldownSeconds s (Discord handoff doctrine: 5-10 min recommended)." }
  $ans = Read-Host "Proceed? (y/N)"
  if ($ans -notmatch '^y') { Write-Host "Aborted - nothing changed."; exit 1 }
}

# --- 4. Stop gateway (task + reap orphans) --------------------------------------------
Step "Stopping scheduled task: $TaskName"
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

# The task 'stop' does NOT reliably kill the gateway process tree on this box
# (task reads stopped while the gateway still serves the port). Reap orphans
# explicitly: kill node processes running from the installed tree, then wait
# for the port to free. (gateway-restart-verify doctrine; verified 2026-09-24)
$deadline = (Get-Date).AddSeconds(45)
do {
  $listeners = Get-NetTCPConnection -LocalPort 18789 -State Listen -ErrorAction SilentlyContinue
  $tree = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*$Installed*" }
  if ($listeners) {
    $listeners | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
  }
  if ($tree) {
    $tree | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Write-Host "  reaped $($tree.Count) orphaned gateway process(es)"
  }
  if (-not $listeners -and -not $tree) { break }
  Start-Sleep -Milliseconds 800
} while ((Get-Date) -lt $deadline)
$still = Get-NetTCPConnection -LocalPort 18789 -State Listen -ErrorAction SilentlyContinue
if ($still) { throw "Gateway still listening on 18789 after reaping (PID $($still.OwningProcess)) - aborting, nothing changed." }
Step "Gateway stopped (port 18789 free)"
if ($CooldownSeconds -gt 0) {
  Write-Host "Cooldown $CooldownSeconds s (Discord sockets settle)..."
  Start-Sleep -Seconds $CooldownSeconds
}

# --- 5. Rollback insurance (rename same-volume = instant) ----------------------------
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = "$Installed.npm-backup-$stamp"
if (Test-Path $Installed) {
  Step "Backing up current install -> $backup"
  Rename-Item -Path $Installed -NewName (Split-Path $backup -Leaf)
}

# --- 6. Install fork tarball ------------------------------------------------------------
# Stale bin shims (openclaw / openclaw.cmd / openclaw.ps1) in $NpmRoot block npm's
# reify with EEXIST when a prior install aborted (observed 2026-09-24). Remove them
# here; npm recreates the shims on install.
foreach ($shim in @('openclaw', 'openclaw.cmd', 'openclaw.ps1')) {
  $sp = Join-Path $NpmRoot $shim
  if (Test-Path $sp) { Remove-Item $sp -Force; Write-Host "  removed stale bin shim: $sp" }
}
Step "npm install -g $Tarball"
npm install -g $Tarball
if ($LASTEXITCODE -ne 0) {
  Write-Host "npm install FAILED (exit $LASTEXITCODE)." -ForegroundColor Red
  Write-Host "Rollback: rename '$backup' back to 'openclaw', then Start-ScheduledTask '$TaskName'." -ForegroundColor Yellow
  exit 1
}

# --- 7. Post-install verification --------------------------------------------------------
Step "Verifying installed build"
$ver = & (Join-Path $NpmRoot "openclaw.cmd") --version 2>$null
if ($LASTEXITCODE -ne 0) { $ver = "unknown" }
$distFiles = Get-ChildItem (Join-Path $Installed "dist\prepared-model-runtime-*.mjs") -ErrorAction SilentlyContinue
$hits2 = ($distFiles | Select-String -SimpleMatch $DistMarker -ErrorAction SilentlyContinue | Measure-Object).Count
if ($hits2 -lt 1) {
  Write-Host "POST-INSTALL VERIFY FAILED: dist marker '$DistMarker' missing in installed tree." -ForegroundColor Red
  Write-Host "Rollback: rename '$backup' back to 'openclaw', then Start-ScheduledTask '$TaskName'." -ForegroundColor Yellow
  exit 1
}
Write-Host "  openclaw --version -> $ver"
Write-Host "  dist marker '$DistMarker' -> $hits2 hits (OK)"

# --- 8. Write fork provenance marker ------------------------------------------------------
$commit = git -C $ForkRoot rev-parse HEAD 2>$null
if ($LASTEXITCODE -ne 0) { $commit = "unknown" }
$dirty = (git -C $ForkRoot status --porcelain 2>$null | Measure-Object).Count
$marker = [ordered]@{
  forkRepo    = "git@github.com:timrenken/openclaw.git"
  upstream    = "git@github.com:openclaw/openclaw.git"
  commit      = $commit
  dirty       = if ($dirty -gt 0) { "yes" } else { "no" }
  distMarker  = $DistMarker
  tarball     = $Tarball
  installedAt = (Get-Date).ToString("o")
} | ConvertTo-Json
$markerPath = Join-Path $Installed $MarkerName
Set-Content -Path $markerPath -Value $marker -Encoding UTF8
Step "Fork marker written: $markerPath"

# --- 9. Start gateway ----------------------------------------------------------------------
Step "Starting scheduled task: $TaskName"
Start-ScheduledTask -TaskName $TaskName
Write-Host "Started. Post-boot checks (give the gateway a minute):" -ForegroundColor Green
Write-Host "  openclaw status                          # gateway up, Discord 7/7"
Write-Host "  Get-Content $markerPath                  # proves fork provenance"
Write-Host "  logs grep 'prepared model runtime owner was not published' -> expect none"
Write-Host "DONE. Rollback reference: rename '$backup' back to 'openclaw', then Start-ScheduledTask '$TaskName'." -ForegroundColor Green