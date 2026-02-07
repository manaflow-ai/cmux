# cmuxterm ZDOTDIR wrapper — sources user's .zlogin
_cmux_wrapper_zdotdir="${ZDOTDIR:-}"
_cmux_real_zdotdir="${CMUX_ORIGINAL_ZDOTDIR:-$HOME}"
if [ -f "$_cmux_real_zdotdir/.zlogin" ]; then
    ZDOTDIR="$_cmux_real_zdotdir"
    source "$_cmux_real_zdotdir/.zlogin"
fi

# Restore whatever ZDOTDIR was for the current shell.
if [ -n "$_cmux_wrapper_zdotdir" ]; then
    ZDOTDIR="$_cmux_wrapper_zdotdir"
else
    unset ZDOTDIR
fi

unset _cmux_real_zdotdir _cmux_wrapper_zdotdir
