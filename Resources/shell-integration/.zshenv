# cmuxterm ZDOTDIR wrapper — sources user's .zshenv
#
# zsh resolves startup files relative to $ZDOTDIR. We point $ZDOTDIR at this
# wrapper directory so zsh loads our wrappers, but we must preserve the user's
# semantics when sourcing their real files. In particular, many setups rely on
# $ZDOTDIR inside early startup files, so source with ZDOTDIR temporarily
# restored to the original value.
_cmux_wrapper_zdotdir="${ZDOTDIR:-}"
_cmux_real_zdotdir="${CMUX_ORIGINAL_ZDOTDIR:-$HOME}"
if [ -f "$_cmux_real_zdotdir/.zshenv" ]; then
    ZDOTDIR="$_cmux_real_zdotdir"
    source "$_cmux_real_zdotdir/.zshenv"
fi

# For interactive shells, keep the wrapper chain intact so zsh loads our
# .zprofile/.zshrc wrappers next. For non-interactive shells, leave ZDOTDIR
# pointing at the real directory to avoid surprising script semantics.
case $- in
    *i*)
        if [ -n "$_cmux_wrapper_zdotdir" ]; then
            ZDOTDIR="$_cmux_wrapper_zdotdir"
        else
            unset ZDOTDIR
        fi
        ;;
esac

unset _cmux_real_zdotdir _cmux_wrapper_zdotdir
