#!/usr/bin/env bash
# cmux notify handler for Codex AfterAgent events.
#
# Codex's legacy notify mechanism appends a JSON payload as the last argument:
#   {"type":"agent-turn-complete","thread-id":"...","last-assistant-message":"..."}
#
# This script extracts the summary and forwards it to cmux.

PAYLOAD="${1:-}"
MSG=""
if [[ -n "$PAYLOAD" ]]; then
    MSG=$(printf '%s' "$PAYLOAD" | jq -r '."last-assistant-message" // empty' 2>/dev/null | head -c 160)
fi
[[ -z "$MSG" ]] && MSG="Turn complete"

cmux notify --title Codex --body "$MSG" 2>/dev/null || true
cmux set-status codex Idle --icon pause.circle.fill --color '#8E8E93' 2>/dev/null || true
