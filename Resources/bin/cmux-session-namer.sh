#!/usr/bin/env bash
# cmux-session-namer.sh — Initialize tab/workspace naming on new Claude Code session
#
# Invoked by the cmux claude wrapper as a SessionStart hook (both new and resume).
#
# New session:    clear cache for fresh AI summary, set project basename
# Resume session: scan entire transcript for custom-title and sync it immediately,
#                 write marker file so AI summary is suppressed (fixes the bug where
#                 /rename early in a long transcript was invisible to tail-500 checks)
#
# Environment: CMUX_WORKSPACE_ID, CMUX_SURFACE_ID (set by cmux shell integration)
# Stdin: JSON with session_id, cwd, transcript_path, etc.

set -e

INPUT=$(cat)

[ "$CMUX_TAB_NAMER_DISABLED" = "1" ] && exit 0
[ -z "$CMUX_WORKSPACE_ID" ] && exit 0
[ -z "$CMUX_SURFACE_ID" ] && exit 0
command -v cmux &>/dev/null || exit 0

# Register as workspace owner if no owner exists yet (first session wins).
# The workspace owner's AI summary / custom-title controls the workspace name.
WS_OWNER_FILE="/tmp/cmux-ws-owner-${CMUX_WORKSPACE_ID}"
# Use noclobber for atomic owner claim — shell's O_EXCL equivalent.
# Two concurrent SessionStart hooks both seeing a missing file: only one
# write succeeds; the other gets EEXIST and silently skips.
( set -o noclobber
  printf '%s\n' "$CMUX_SURFACE_ID" > "$WS_OWNER_FILE"
) 2>/dev/null || true

# Check entire transcript for an existing custom-title (handles resumed sessions
# where /rename was issued earlier in a long transcript, beyond tail-500 reach)
CUSTOM_MARKER="/tmp/cmux-custom-title-${CMUX_SURFACE_ID}"
TRANSCRIPT=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('transcript_path',''))" 2>/dev/null || true)

if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  TITLE=$(grep '"type":"custom-title"' "$TRANSCRIPT" 2>/dev/null | tail -1 | python3 -c "
import sys,json
try:
    print(json.loads(sys.stdin.readline()).get('customTitle',''))
except: pass
" 2>/dev/null)

  if [ -n "$TITLE" ]; then
    # Resumed session with custom-title: sync immediately and suppress AI summary
    echo "$TITLE" > "$CUSTOM_MARKER"
    cmux rename-tab --workspace "$CMUX_WORKSPACE_ID" --surface "$CMUX_SURFACE_ID" "$TITLE" 2>/dev/null || true
    WS_OWNER=$(cat "$WS_OWNER_FILE" 2>/dev/null || true)
    if [ "$WS_OWNER" = "$CMUX_SURFACE_ID" ]; then
      cmux rename-workspace --workspace "$CMUX_WORKSPACE_ID" "$TITLE" 2>/dev/null || true
    fi
    exit 0
  fi
fi

# No custom-title: clear marker and cache so the first Stop triggers a fresh AI summary
rm -f "$CUSTOM_MARKER" 2>/dev/null
rm -f "/tmp/cmux-tab-cache-${CMUX_SURFACE_ID}" 2>/dev/null

# Set project basename as initial workspace name — only if this tab owns the workspace.
# Non-owner sessions must not overwrite an already-established workspace name.
WS_OWNER=$(cat "$WS_OWNER_FILE" 2>/dev/null || true)
if [ "$WS_OWNER" = "$CMUX_SURFACE_ID" ]; then
  CWD=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null || true)
  if [ -n "$CWD" ]; then
    BASENAME=$(basename "$CWD")
    cmux rename-workspace --workspace "$CMUX_WORKSPACE_ID" "$BASENAME" 2>/dev/null || true
  fi
fi
