# cmux Surface Status: launch-only Codex attribution.
# Official cmux persistent hooks remain enabled and own all lifecycle state.
function codex() {
  local launcher="$HOME/.local/libexec/cmux-surface-status/codex-presence-launcher.py"
  if [[ ! -x "$launcher" ]]; then
    print -u2 'codex: Surface Status launch helper is missing or not executable'
    return 127
  fi
  command "$launcher" "$@"
}
