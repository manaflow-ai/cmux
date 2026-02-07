# cmuxterm ZDOTDIR wrapper — restore ZDOTDIR, source user's .zshrc, then load integration

# Restore original ZDOTDIR so user configs and subsequent shells work normally
if [ -n "$CMUX_ORIGINAL_ZDOTDIR" ]; then
    ZDOTDIR="$CMUX_ORIGINAL_ZDOTDIR"
else
    ZDOTDIR="$HOME"
fi

# Source user's .zshrc
[ -f "$ZDOTDIR/.zshrc" ] && source "$ZDOTDIR/.zshrc"

# Load cmux shell integration (unless disabled)
if [ "$CMUX_SHELL_INTEGRATION" != "0" ]; then
    source "${CMUX_SHELL_INTEGRATION_DIR}/cmux-zsh-integration.zsh"
fi
