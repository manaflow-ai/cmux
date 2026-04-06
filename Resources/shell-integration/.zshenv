# vim:ft=zsh
#
# cmux ZDOTDIR bootstrap for zsh.
#
# GhosttyKit sets ZDOTDIR to this integration directory so zsh loads this file
# first.  We keep ZDOTDIR pointing here through the full startup sequence
# (.zshenv → .zprofile → .zshrc → .zlogin) so that our wrapper files control
# the loading order.  Each wrapper sources the user's real file, and .zshrc
# loads cmux/Ghostty shell integration AFTER the user's .zshrc — ensuring
# tools like Kiro CLI or Amazon Q that reset precmd_functions in .zprofile
# cannot clobber cmux's hooks.
#
# The user's original ZDOTDIR is preserved in _CMUX_ORIG_ZDOTDIR and restored
# in .zshrc after integration loading completes.

# Save the user's original ZDOTDIR so wrappers can find user files.
if [[ -n "${GHOSTTY_ZSH_ZDOTDIR+X}" ]]; then
    builtin export _CMUX_ORIG_ZDOTDIR="$GHOSTTY_ZSH_ZDOTDIR"
    builtin unset GHOSTTY_ZSH_ZDOTDIR
elif [[ -n "${CMUX_ZSH_ZDOTDIR+X}" ]]; then
    builtin export _CMUX_ORIG_ZDOTDIR="$CMUX_ZSH_ZDOTDIR"
    builtin unset CMUX_ZSH_ZDOTDIR
else
    builtin export _CMUX_ORIG_ZDOTDIR="${HOME}"
fi

# Source the user's .zshenv (runs for all shells, interactive or not).
builtin typeset _cmux_file="${_CMUX_ORIG_ZDOTDIR}/.zshenv"
[[ ! -r "$_cmux_file" ]] || builtin source -- "$_cmux_file"
builtin unset _cmux_file
