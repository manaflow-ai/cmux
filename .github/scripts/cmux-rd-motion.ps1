# Keep the hosted Windows desktop changing so the live proof exercises the
# host's changed-frame path instead of measuring an intentionally idle screen.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedToolWindow
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.Location = New-Object System.Drawing.Point(80, 80)
$form.Size = New-Object System.Drawing.Size(640, 360)
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.Text = 'cmux-rd live proof'

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 200
$script:colorIndex = 0
$colors = @(
    [System.Drawing.Color]::FromArgb(32, 96, 160)
    [System.Drawing.Color]::FromArgb(192, 80, 48)
)
$timer.Add_Tick({
    $form.BackColor = $colors[$script:colorIndex % $colors.Count]
    $script:colorIndex++
})
$timer.Start()

try {
    [System.Windows.Forms.Application]::Run($form)
} finally {
    $timer.Dispose()
    $form.Dispose()
}
