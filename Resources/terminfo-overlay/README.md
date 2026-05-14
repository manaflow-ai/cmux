# cmux terminfo overlay

cmux ships patched `xterm-ghostty` and `xterm-256color` terminfo entries so
the embedded renderer keeps the same color behavior even when the reported
`TERM` changes.

These overlays patch the terminfo capabilities so that `tput setaf 8` (and
similar "bright" colors) uses 256-color indexed sequences (`38;5;<n>m` /
`48;5;<n>m`) rather than SGR 90-97/100-107. This avoids relying on bright SGR
handling and fixes zsh-autosuggestions (default `fg=8`) visibility issues in
cmux while preserving Ghostty's truecolor capabilities.

The build phase `Copy Ghostty Resources` overlays this directory onto the app
bundle's `Contents/Resources/terminfo` after copying Ghostty's resources.
