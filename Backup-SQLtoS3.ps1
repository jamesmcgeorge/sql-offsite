Param (
        [string]$BackupFileLocation,
        [string]$LocalPath,
        [string]$NetworkUser,
        [string]$NetworkUserPassword,
        [string]$AWSAccessKey,
        [string]$AWSSecretKey,
        [string]$CompressedFileName,
        [string]$AWSBucketName
      )

function Prepare-SQLFilesForBackup
{
    [CmdletBinding()]
    Param
    (
        # The location of the SQL backup files
        [Parameter(Mandatory=$true,Position=0)]
        $BackupFileLocation,
        # The path on the local machine used for preparing the files
        [Parameter(Mandatory=$true,Position=1)]
        $LocalPath,
        # Credentials to access the backup file location
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential = [System.Management.Automation.PSCredential]::Empty,
        # Whether or not to compress the backup files
        [switch]
        $Compress,
        [string]$CompressedFileName
    )
    $now = Get-Date
    $month = $now.Month
    $day = $now.Day
    if($month -lt 10) {
        $month = "0" + $month
    }
    if($day -lt 10) {
        $day = "0" + $day
    }

    $timestamp = "" + $month + $day + $now.Year
    $7zip = "C:\Program Files\7-Zip\7z.exe"
    $hasCred = $Credential -ne [System.Management.Automation.PSCredential]::Empty
    # First test if we can reach the path
    if($hasCred) {
        try {
            New-PSDrive -Name M -PSProvider FileSystem -Root $BackupFileLocation -Credential $Credential | Out-Null
        } catch {
            Write-Host -ForegroundColor Red "Credentials invalid, cannot access $BackupFileLocation with $($Credential.UserName)"
        }
    } else {
        if(!(Test-Path -Path $BackupFileLocation)) {
            Write-Host -ForegroundColor Red "Credentials invalid, cannot access $BackupFileLocation without credentials"
            return 2;
        }
    }
    if (!(Test-Path "$LocalPath\$CompressedFileName-$timestamp.7z")) {
        Write-Host Path and credentials valid, transferring files
        # Now get the list of files with todays timestamp
        
        $files = Get-ChildItem -Path M:\ -Recurse | where {$_.LastWriteTime.Date -eq $now.Date}
    
        foreach($file in $files) {

            Write-Host Transferring M:\$($file.Name) to $LocalPath\$($file.Name)
            Copy-Item -Path $($file.FullName.Replace($BackupFileLocation,"M:")) -Destination "$LocalPath\$($file.Name)" -Force

        }

        if($Compress) {
            Write-Host Compressing SQL Backup Files
        
            Start-Process -FilePath $7zip -ArgumentList "a -mx=1 -mmt=8 $LocalPath\$CompressedFileName-$timestamp.7z $LocalPath\*" -Wait



        }
    } else {
        Write-Host Backup already prepared
    }
    Write-Host Operation Complete
    return "$CompressedFileName-$timestamp.7z"
}

function Update-S3Backup
{
    [CmdletBinding()]
    Param
    (
        # Param1 help description
        [Parameter(Mandatory=$true,Position=0)]
        $BackupFilePath,
        $BackupFileName,
        $AWSAccessKey,
        $AWSSecretKey,
        $AWSBucketName
    )

    Import-Module AWSPowerShell

    Set-AWSCredential -AccessKey $AWSAccessKey -SecretKey $AWSSecretKey -StoreAs default

    $file = Get-Item -Path "$BackupFilePath\$BackupFileName"
    
    Write-S3Object -BucketName $AWSBucketName -File $file.FullName -Key $file.Name -CannedACLName bucket-owner-full-control

    $bucketFiles = Get-S3Object -BucketName $AWSBucketName

    $now = Get-Date
    $uploadSuccess = $false
    foreach($bFile in $bucketFiles) {
        
        if($bFile.LastModified -lt $now.AddDays(-3)) {
            Write-Host Removing old backup $bFile.Key
            #Write-Host $bFile.Key
        }
        if ($bFile.Key -eq $file.Name) {
            Write-Host Found new uploaded file, success is real
            $uploadSuccess = $true
        }
    }
    if($uploadSuccess) {
        Remove-Item -Path $BackupFilePath -Recurse -Force
    }
}

$secpasswd = ConvertTo-SecureString $NetworkUserPassword -AsPlainText -Force
$mycreds = New-Object System.Management.Automation.PSCredential ($NetworkUser, $secpasswd)

$fileName = Prepare-SQLFilesForBackup -BackupFileLocation $BackupFileLocation -LocalPath $LocalPath -Credential $mycreds -Compress -CompressedFileName $CompressedFileName

Write-Host Backup file name: $fileName

if($fileName -ne 1 -and $fileName -ne 2) {
    Update-S3Backup -BackupFilePath $LocalPath -BackupFileName $fileName -AWSAccesskey $AWSAccessKey -AWSSecretKey $AWSSecretKey -AWSBucketName $AWSBucketName
}
