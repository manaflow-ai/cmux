# cmux fish integration - auto-generated, do not modify
if test "$CMUX_SHELL_INTEGRATION" != "0" -a -n "$CMUX_SHELL_INTEGRATION_DIR"
    set -l _cmux_fish "$CMUX_SHELL_INTEGRATION_DIR/cmux-fish-integration.fish"
    test -r "$_cmux_fish"; and source "$_cmux_fish"
    set -e _cmux_fish
end
