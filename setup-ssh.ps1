#Requires -RunAsAdministrator
# ============================================================
# One-Click OpenSSH Server Setup for Hermes Remote Installation
# Run this as Administrator on Windows 10/11
# ============================================================

$ErrorActionPreference = "SilentlyContinue"
$host.UI.RawUI.WindowTitle = "Hermes Remote - SSH Setup"

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Hermes Remote Agent - SSH Setup" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# --- Step 1: Check if OpenSSH is already running ---
$existing = Get-NetTCPConnection -LocalPort 22 -ErrorAction SilentlyContinue | Where-Object State -eq Listen
if ($existing) {
    Write-Host "[OK] SSH already running on port 22" -ForegroundColor Green
    goto :SHOWINFO
}

# --- Step 2: Install OpenSSH ---
Write-Host "[1/5] Installing OpenSSH Server..." -ForegroundColor Yellow

# Try built-in Windows capability first
$cap = Get-WindowsCapability -Online | Where-Object Name -like "OpenSSH.Server*"
if ($cap.State -ne "Installed") {
    Write-Host "  Installing Windows OpenSSH feature..."
    Add-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0" | Out-Null
}

# Check if sshd.exe actually works (some old Win10 builds have broken binaries)
$testResult = & "C:\Windows\System32\OpenSSH\sshd.exe" -? 2>&1 | Out-String
if ($LASTEXITCODE -eq 0 -or $testResult -match "usage") {
    Write-Host "  Using built-in Windows OpenSSH" -ForegroundColor Green
    $sshPath = "C:\Windows\System32\OpenSSH"
} else {
    Write-Host "  Built-in OpenSSH not working, installing via Chocolatey..." -ForegroundColor Yellow
    # Install Chocolatey if needed
    if (!(Get-Command choco -ErrorAction SilentlyContinue)) {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
    }
    choco install openssh -y --no-progress | Out-Null
    $sshPath = "C:\Program Files\OpenSSH-Win64"
}

# --- Step 3: Generate host keys ---
Write-Host "[2/5] Generating SSH host keys..." -ForegroundColor Yellow
& "$sshPath\ssh-keygen.exe" -A 2>&1 | Out-Null

# --- Step 4: Ensure sshd_config is correct ---
Write-Host "[3/5] Configuring sshd..." -ForegroundColor Yellow
$configDir = "C:\ProgramData\ssh"
if (!(Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }

# Ensure password authentication is enabled
$configFile = "$configDir\sshd_config"
if (!(Test-Path $configFile)) {
    Copy-Item "$sshPath\sshd_config_default" $configFile -Force
}
$config = Get-Content $configFile
$changed = $false
if ($config -match "^#?(PasswordAuthentication)\s+(yes|no)") {
    $line = $matches[0]
    if ($line -match "^#" -or $line -match "no$") {
        $config = $config -replace [regex]::Escape($line), "PasswordAuthentication yes"
        $changed = $true
    }
} else {
    $config += "`nPasswordAuthentication yes"
    $changed = $true
}
if ($changed) { $config | Out-File $configFile -Encoding ascii -Force }

# --- Step 5: Install and start the service ---
Write-Host "[4/5] Installing & starting SSH service..." -ForegroundColor Yellow
& "$sshPath\install-sshd.ps1" 2>&1 | Out-Null
Set-Service -Name sshd -StartupType "Automatic"
Start-Service sshd -ErrorAction SilentlyContinue

# If service won't start, run directly
$svc = Get-Service sshd
$retry = 0
while ($svc.Status -ne "Running" -and $retry -lt 3) {
    Start-Sleep 2
    Start-Service sshd -ErrorAction SilentlyContinue
    $svc = Get-Service sshd
    $retry++
}

if ($svc.Status -ne "Running") {
    Write-Host "  Service won't start, launching directly..." -ForegroundColor Yellow
    # Kill any existing sshd
    Get-Process -Name "sshd" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep 1
    Start-Process -FilePath "$sshPath\sshd.exe" -WindowStyle Hidden
    Start-Sleep 3
}

# --- Step 6: Firewall ---
Write-Host "[5/5] Configuring firewall..." -ForegroundColor Yellow
if (!(Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}

# --- Verify ---
Start-Sleep 2
$listening = Get-NetTCPConnection -LocalPort 22 -ErrorAction SilentlyContinue | Where-Object State -eq Listen
if ($listening) {
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host "  SSH Server is RUNNING!" -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Red
    Write-Host "  SSH Server FAILED to start" -ForegroundColor Red
    Write-Host "==========================================" -ForegroundColor Red
    exit 1
}

# --- Show connection info ---
:SHOWINFO
$username = [Environment]::UserName
$computerName = [Environment]::MachineName
$ips = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" -and $_.IPAddress -notlike "169.254.*" }

Write-Host ""
Write-Host "------------- CONNECTION INFO -------------" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Username : $username" -ForegroundColor White
Write-Host "  IP Addr   :" -ForegroundColor White -NoNewline
foreach ($ip in $ips) {
    Write-Host " $($ip.IPAddress)" -ForegroundColor Yellow
    Write-Host "             " -NoNewline
}
Write-Host ""
Write-Host "  Port      : 22" -ForegroundColor White
Write-Host "  Password  : (your Windows login password)" -ForegroundColor White
Write-Host ""
Write-Host "Send this info to the technician:" -ForegroundColor Cyan
Write-Host "  IP: $($ips[0].IPAddress)" -ForegroundColor Green
Write-Host "  User: $username" -ForegroundColor Green
Write-Host ""
Write-Host "--------------------------------------------" -ForegroundColor Cyan
Write-Host ""
Write-Host "Press any key to close..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
