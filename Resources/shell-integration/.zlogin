# cmuxterm ZDOTDIR wrapper — sources user's .zlogin
_cmux_real_zdotdir="${CMUX_ORIGINAL_ZDOTDIR:-$HOME}"
[ -f "$_cmux_real_zdotdir/.zlogin" ] && source "$_cmux_real_zdotdir/.zlogin"
unset _cmux_real_zdotdir
