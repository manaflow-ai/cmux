#!/usr/bin/env bash
# cmux-rename-namer.sh — Sync /rename custom title to cmux tab name
#
# Invoked by the cmux claude wrapper as a UserPromptSubmit hook.
# When a user /renames their Claude Code session, this hook syncs the
# custom title to the cmux tab. Workspace name is only updated if this
# tab is the workspace owner (first session).
#
# Environment: CMUX_WORKSPACE_ID, CMUX_SURFACE_ID (set by cmux shell integration)
# Stdin: JSON with session_id, transcript_path, etc.

set -e

INPUT=$(cat)

[ "$CMUX_TAB_NAMER_DISABLED" = "1" ] && exit 0
[ -z "$CMUX_WORKSPACE_ID" ] && exit 0
[ -z "$CMUX_SURFACE_ID" ] && exit 0
command -v cmux &>/dev/null || exit 0

# Extract transcript path
TRANSCRIPT=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('transcript_path',''))" 2>/dev/null || true)
[ -z "$TRANSCRIPT" ] && exit 0
[ -f "$TRANSCRIPT" ] || exit 0

# Fast: grep last custom-title from transcript tail
TITLE=$(tail -500 "$TRANSCRIPT" | grep '"custom-title"' | tail -1 | python3 -c "
import sys,json
try:
    print(json.loads(sys.stdin.readline()).get('customTitle',''))
except: pass
" 2>/dev/null)

[ -z "$TITLE" ] && exit 0

# Always rename this tab
cmux rename-tab --workspace "$CMUX_WORKSPACE_ID" --surface "$CMUX_SURFACE_ID" "$TITLE" 2>/dev/null || true

# Only rename workspace if this tab is the owner (first session)
WS_OWNER=$(cat "/tmp/cmux-ws-owner-${CMUX_WORKSPACE_ID}" 2>/dev/null || true)
if [ "$WS_OWNER" = "$CMUX_SURFACE_ID" ]; then
  cmux rename-workspace --workspace "$CMUX_WORKSPACE_ID" "$TITLE" 2>/dev/null || true
fi
