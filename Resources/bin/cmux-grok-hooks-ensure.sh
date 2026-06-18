#!/usr/bin/env bash
# Idempotent repair for Grok Build + cmux PreToolUse integration.
# Safe to run on every SessionStart and after `cmux hooks grok install`.
# cmux-grok-ensure-v1
set -euo pipefail

GROK_HOME="${GROK_HOME:-$HOME/.grok}"
HOOKS_DIR="$GROK_HOME/hooks"
BIN_DIR="$GROK_HOME/bin"
SELF="$BIN_DIR/cmux-grok-hooks-ensure.sh"
SESSION_JSON="$HOOKS_DIR/cmux-session.json"
ENSURE_JSON="$HOOKS_DIR/cmux-grok-ensure.json"
PRETOL="$BIN_DIR/cmux-grok-pretooluse.sh"
MARKER="cmux-grok-pretool-v1"
LOCK_DIR="$GROK_HOME/.locks"
LOCK="$LOCK_DIR/cmux-grok-hooks-ensure.lock"

mkdir -p "$BIN_DIR" "$HOOKS_DIR" "$LOCK_DIR"

if ! mkdir "$LOCK" 2>/dev/null; then
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

_bundled_pretool() {
  local candidates=(
    "/Applications/cmux.app/Contents/Resources/bin/cmux-grok-pretooluse.sh"
  )
  if [[ -n "${CMUX_BUNDLED_CLI_PATH:-}" ]]; then
    candidates+=("$(dirname "$CMUX_BUNDLED_CLI_PATH")/cmux-grok-pretooluse.sh")
  fi
  local c
  for c in "${candidates[@]}"; do
    [[ -n "$c" && -f "$c" ]] || continue
    printf '%s' "$c"
    return 0
  done
  return 1
}

_install_pretool() {
  if bundled="$(_bundled_pretool 2>/dev/null || true)" && [[ -n "$bundled" ]]; then
    if [[ ! -f "$PRETOL" ]] || [[ "$bundled" -nt "$PRETOL" ]]; then
      cp "$bundled" "$PRETOL"
    fi
  elif [[ ! -x "$PRETOL" ]]; then
    echo "cmux-grok-hooks-ensure: missing $PRETOL and no bundled copy" >&2
    return 1
  fi
  chmod +x "$PRETOL"
  chmod +x "$SELF" 2>/dev/null || true
}

_write_ensure_hook_json() {
  local ensure_cmd
  ensure_cmd="$(printf '%s' "$SELF" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')"
  cat >"$ENSURE_JSON" <<EOF
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "command": $ensure_cmd,
            "timeout": 5,
            "type": "command"
          }
        ]
      }
    ]
  }
}
EOF
}

_repair_session_json() {
  [[ -f "$SESSION_JSON" ]] || return 0
  python3 - "$SESSION_JSON" "$PRETOL" "$MARKER" <<'PY'
import json, sys

path, pretool, marker = sys.argv[1:4]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
hooks = data.setdefault("hooks", {})
groups = hooks.get("PreToolUse")
if not isinstance(groups, list):
    groups = []
    hooks["PreToolUse"] = groups

def is_cmux_feed(cmd: str) -> bool:
    return "cmux-grok-hook-v2" in cmd and "hooks feed --source grok --event PreToolUse" in cmd

def is_pretool(cmd: str) -> bool:
    return "cmux-grok-pretooluse.sh" in cmd or marker in cmd

new_groups = []
pretool_group = None
for group in groups:
    if not isinstance(group, dict):
        continue
    hook_list = group.get("hooks")
    if not isinstance(hook_list, list):
        new_groups.append(group)
        continue
    kept = []
    for h in hook_list:
        if not isinstance(h, dict):
            continue
        cmd = h.get("command", "")
        if is_cmux_feed(cmd):
            continue
        if is_pretool(cmd):
            pretool_group = {
                "hooks": [{
                    "type": "command",
                    "command": pretool,
                    "timeout": 120,
                }]
            }
            continue
        kept.append(h)
    if kept:
        new_groups.append({"hooks": kept})

if pretool_group is None:
    pretool_group = {
        "hooks": [{
            "type": "command",
            "command": pretool,
            "timeout": 120,
        }]
    }

hooks["PreToolUse"] = [pretool_group] + new_groups
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

_install_pretool
_write_ensure_hook_json
_repair_session_json

exit 0