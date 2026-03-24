#!/usr/bin/env bash
# cmux-rename-namer.sh — Apply pending AI labels + sync /rename custom title to cmux tab
#
# Invoked by the cmux claude wrapper as a UserPromptSubmit hook.
#
# Phase 1: Apply pending AI label from previous Stop (moved here from the Stop hook
#          so the tab name updates the moment the user sends their next message,
#          rather than waiting for Claude's full response to complete).
#
# Phase 2: Sync /rename custom title to tab and workspace (owner only).
#          Writes a marker file so the custom title persists even in long transcripts
#          where tail-500 would miss an early /rename entry.
#
# Environment: CMUX_WORKSPACE_ID, CMUX_SURFACE_ID (set by cmux shell integration)
# Stdin: JSON with session_id, transcript_path, etc.

set -e

INPUT=$(cat)

[ "$CMUX_TAB_NAMER_DISABLED" = "1" ] && exit 0
[ -z "$CMUX_WORKSPACE_ID" ] && exit 0
[ -z "$CMUX_SURFACE_ID" ] && exit 0
command -v cmux &>/dev/null || exit 0

# ============================================================
# PHASE 1: Apply pending AI label from previous Stop (fast path)
# Tab name updates on next user prompt, not on next Claude response.
# ============================================================
TAB_PENDING="/tmp/cmux-tab-pending-${CMUX_SURFACE_ID}"
TAB_CACHE="/tmp/cmux-tab-cache-${CMUX_SURFACE_ID}"
if [ -f "$TAB_PENDING" ]; then
  LABEL=$(head -1 "$TAB_PENDING" 2>/dev/null)
  P_LINE_COUNT=$(sed -n '2p' "$TAB_PENDING" 2>/dev/null)
  P_HAS_CUSTOM=$(sed -n '3p' "$TAB_PENDING" 2>/dev/null)
  rm -f "$TAB_PENDING" 2>/dev/null

  if [ -n "$LABEL" ]; then
    # Update tab cache
    printf '%s\n%s\n' "${P_LINE_COUNT:-0}" "$LABEL" > "$TAB_CACHE" 2>/dev/null

    # Rename this tab
    cmux rename-tab --workspace "$CMUX_WORKSPACE_ID" --surface "$CMUX_SURFACE_ID" "$LABEL" 2>/dev/null || true

    # Rename workspace only if: (a) no custom-title, AND (b) this tab is the workspace owner
    WS_OWNER_FILE="/tmp/cmux-ws-owner-${CMUX_WORKSPACE_ID}"
    WS_OWNER=$(cat "$WS_OWNER_FILE" 2>/dev/null || true)
    if [ "${P_HAS_CUSTOM:-0}" -eq 0 ] 2>/dev/null && [ "$WS_OWNER" = "$CMUX_SURFACE_ID" ]; then
      cmux rename-workspace --workspace "$CMUX_WORKSPACE_ID" "$LABEL" 2>/dev/null || true
    fi
  fi
fi

# ============================================================
# PHASE 2: Sync /rename custom title
# ============================================================

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

# Write marker file — ensures custom-title suppresses AI summary even in very long
# transcripts where the /rename entry falls outside the tail-500 window
echo "$TITLE" > "/tmp/cmux-custom-title-${CMUX_SURFACE_ID}" 2>/dev/null

# Always rename this tab
cmux rename-tab --workspace "$CMUX_WORKSPACE_ID" --surface "$CMUX_SURFACE_ID" "$TITLE" 2>/dev/null || true

# Only rename workspace if this tab is the owner (first session)
WS_OWNER=$(cat "/tmp/cmux-ws-owner-${CMUX_WORKSPACE_ID}" 2>/dev/null || true)
if [ "$WS_OWNER" = "$CMUX_SURFACE_ID" ]; then
  cmux rename-workspace --workspace "$CMUX_WORKSPACE_ID" "$TITLE" 2>/dev/null || true
fi
