# vim:ft=zsh
#
# cmux ZDOTDIR wrapper for .zlogin.
# Sources the user's real .zlogin from _CMUX_ORIG_ZDOTDIR.

builtin typeset _cmux_file="${_CMUX_ORIG_ZDOTDIR-$HOME}/.zlogin"
[[ ! -r "$_cmux_file" ]] || builtin source -- "$_cmux_file"
builtin unset _cmux_file
