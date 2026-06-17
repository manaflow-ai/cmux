#!/usr/bin/env bash
# cmux-grok-pretool-v1 — PreToolUse bridge for Grok Build inside cmux.
# Installed/maintained by cmux-grok-hooks-ensure.sh (survives cmux app updates).
set -euo pipefail

if printenv CMUX_GROK_HOOKS_DISABLED 2>/dev/null | grep -qx 1; then
  echo '{}'
  exit 0
fi

event_json="$(cat)"
tool_name="$(
  printf '%s' "$event_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('toolName') or d.get('tool_name') or '')
" 2>/dev/null || true
)"

grok_should_skip_feed_blocking() {
  if printenv CMUX_GROK_FEED_SKIP_BLOCKING 2>/dev/null | grep -qx 1; then
    return 0
  fi
  local config="${GROK_HOME:-$HOME/.grok}/config.toml"
  [[ -f "$config" ]] || return 1
  if grep -Eq '^[[:space:]]*permission_mode[[:space:]]*=[[:space:]]*"?always-approve"?[[:space:]]*$' "$config"; then
    return 0
  fi
  if grep -Eq '^[[:space:]]*permission_mode[[:space:]]*=[[:space:]]*"?bypassPermissions"?[[:space:]]*$' "$config"; then
    return 0
  fi
  if grep -Eq '^[[:space:]]*yolo[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$config"; then
    return 0
  fi
  return 1
}

grok_tool_needs_feed_approval() {
  local t
  t="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$t" in
    write|edit|multiedit|bash|notebookedit|apply_patch|shell|write_to_file|replace_file_content|multi_replace_file_content|search_replace)
      return 0
      ;;
  esac
  return 1
}

# Auto-approve / yolo: never block on cmux Feed (avoids 120s PreToolUse stalls).
if grok_should_skip_feed_blocking; then
  echo '{}'
  exit 0
fi

# Read-only / telemetry tools: skip feed subprocess entirely.
if ! grok_tool_needs_feed_approval "$tool_name"; then
  echo '{}'
  exit 0
fi

CMUX_BIN="${CMUX_BIN:-/Applications/cmux.app/Contents/Resources/bin/cmux}"
if [[ ! -x "$CMUX_BIN" ]] && command -v cmux >/dev/null 2>&1; then
  CMUX_BIN="$(command -v cmux)"
fi
SOCK="${CMUX_SOCKET_PATH:-${CMUX_SOCK:-$HOME/.local/state/cmux/cmux.sock}}"

if [[ ! -x "$CMUX_BIN" ]] || [[ ! -S "$SOCK" ]]; then
  echo '{}'
  exit 0
fi

printf '%s' "$event_json" | "$CMUX_BIN" --socket "$SOCK" hooks feed --source grok --event PreToolUse
exit $?