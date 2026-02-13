# cmux terminfo overlay

cmux ships Ghostty's `xterm-ghostty` terminfo entry, but the embedded
renderer in cmux has differed from Ghostty's app renderer in how it treats
the "bright" SGR 90-97/100-107 sequences.

This overlay patches the terminfo capabilities so that `tput setaf 8` (and
similar "bright" colors) uses 256-color indexed sequences (`38;5;<n>m` /
`48;5;<n>m`) rather than SGR 90-97/100-107. This avoids relying on bright SGR
handling and fixes zsh-autosuggestions (default `fg=8`) visibility issues in
cmux.

The build phase `Copy Ghostty Resources` overlays this directory onto the app
bundle's `Contents/Resources/terminfo` after copying Ghostty's resources.

