# cmuxterm ZDOTDIR wrapper — sources user's .zprofile
_cmux_wrapper_zdotdir="${ZDOTDIR:-}"
_cmux_real_zdotdir="${CMUX_ORIGINAL_ZDOTDIR:-$HOME}"
if [ -f "$_cmux_real_zdotdir/.zprofile" ]; then
    ZDOTDIR="$_cmux_real_zdotdir"
    source "$_cmux_real_zdotdir/.zprofile"
fi

# Restore wrapper ZDOTDIR so zsh continues through our wrapper chain.
if [ -n "$_cmux_wrapper_zdotdir" ]; then
    ZDOTDIR="$_cmux_wrapper_zdotdir"
else
    unset ZDOTDIR
fi

unset _cmux_real_zdotdir _cmux_wrapper_zdotdir
