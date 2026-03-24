#!/usr/bin/env bash
# cmux-session-namer.sh — Initialize tab/workspace naming on new Claude Code session
#
# Invoked by the cmux claude wrapper as a SessionStart hook.
# - Clears tab-naming cache so first Stop triggers a fresh AI summary
# - Registers this surface as the workspace "owner" (first session wins)
# - Sets project basename as initial workspace name
#
# Environment: CMUX_WORKSPACE_ID, CMUX_SURFACE_ID (set by cmux shell integration)
# Stdin: JSON with session_id, cwd, etc.

set -e

INPUT=$(cat)

[ "$CMUX_TAB_NAMER_DISABLED" = "1" ] && exit 0
[ -z "$CMUX_WORKSPACE_ID" ] && exit 0
[ -z "$CMUX_SURFACE_ID" ] && exit 0
command -v cmux &>/dev/null || exit 0

# Clear this tab's cache so first Stop triggers a fresh AI summary
rm -f "/tmp/cmux-tab-cache-${CMUX_SURFACE_ID}" 2>/dev/null

# Register as workspace owner if no owner exists yet (first session wins).
# The workspace owner's AI summary controls the workspace name.
WS_OWNER_FILE="/tmp/cmux-ws-owner-${CMUX_WORKSPACE_ID}"
if [ ! -f "$WS_OWNER_FILE" ]; then
  echo "$CMUX_SURFACE_ID" > "$WS_OWNER_FILE"
fi

# Set project basename as initial workspace name (overridden by AI summary after first response)
CWD=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null || true)
if [ -n "$CWD" ]; then
  BASENAME=$(basename "$CWD")
  cmux rename-workspace --workspace "$CMUX_WORKSPACE_ID" "$BASENAME" 2>/dev/null || true
fi
