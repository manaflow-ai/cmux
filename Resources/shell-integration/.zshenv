# cmuxterm ZDOTDIR wrapper — sources user's .zshenv
# NOTE: Do NOT restore ZDOTDIR here. It must stay pointed at our wrapper dir
# so that zsh finds our .zshrc next. Restoration happens in .zshrc.
_cmux_real_zdotdir="${CMUX_ORIGINAL_ZDOTDIR:-$HOME}"
[ -f "$_cmux_real_zdotdir/.zshenv" ] && source "$_cmux_real_zdotdir/.zshenv"
unset _cmux_real_zdotdir
