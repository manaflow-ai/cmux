# cmuxterm ZDOTDIR wrapper — sources user's .zprofile
_cmux_real_zdotdir="${CMUX_ORIGINAL_ZDOTDIR:-$HOME}"
[ -f "$_cmux_real_zdotdir/.zprofile" ] && source "$_cmux_real_zdotdir/.zprofile"
unset _cmux_real_zdotdir
