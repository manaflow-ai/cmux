#!/usr/bin/env bash
# cmux-tab-namer.sh — AI-powered tab & workspace auto-naming for Claude Code
#
# Invoked by the cmux claude wrapper as a Stop hook.
# Generates an AI summary in background → writes to pending file.
# The pending label is applied in cmux-rename-namer.sh (UserPromptSubmit)
# for faster tab name updates (user sees new name on next prompt, not next response).
#
# custom-title detection uses a marker file so long transcripts (e.g. resumed
# sessions with /rename early in history) are handled correctly.
#
# Environment: CMUX_WORKSPACE_ID, CMUX_SURFACE_ID (set by cmux shell integration)
# Stdin: JSON with session_id, transcript_path, cwd, etc.

set -e

INPUT=$(cat)

[ "$CMUX_TAB_NAMER_DISABLED" = "1" ] && exit 0
[ -z "$CMUX_WORKSPACE_ID" ] && exit 0
[ -z "$CMUX_SURFACE_ID" ] && exit 0
command -v cmux &>/dev/null || exit 0

TRANSCRIPT=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('transcript_path',''))" 2>/dev/null || true)
[ -z "$TRANSCRIPT" ] && exit 0
[ -f "$TRANSCRIPT" ] || exit 0

# Per-tab (surface) files — each tab tracks its own label independently
TAB_PENDING="/tmp/cmux-tab-pending-${CMUX_SURFACE_ID}"
TAB_CACHE="/tmp/cmux-tab-cache-${CMUX_SURFACE_ID}"

# ============================================================
# Generate AI summary if needed, spawn background
# ============================================================
LINE_COUNT=$(wc -l < "$TRANSCRIPT" 2>/dev/null | tr -d ' ')
# Skip tiny transcripts (subagent sessions)
[ "$LINE_COUNT" -lt 50 ] 2>/dev/null && exit 0

# Skip if custom-title exists — check marker file first (handles long/resumed transcripts),
# then fall back to tail-500 scan for /rename done in the current session.
CUSTOM_MARKER="/tmp/cmux-custom-title-${CMUX_SURFACE_ID}"
[ -f "$CUSTOM_MARKER" ] && exit 0
HAS_CUSTOM_TITLE=$(tail -500 "$TRANSCRIPT" | grep -c '"custom-title"' 2>/dev/null; true)
[ "${HAS_CUSTOM_TITLE:-0}" -gt 0 ] 2>/dev/null && exit 0

if [ -f "$TAB_CACHE" ]; then
  PREV_COUNT=$(head -1 "$TAB_CACHE" 2>/dev/null || echo 0)
  DIFF=$((LINE_COUNT - PREV_COUNT))
  if [ "$DIFF" -lt 6 ]; then
    exit 0
  fi
fi

# Extract recent conversation context
CONTEXT=$(_TRANSCRIPT="$TRANSCRIPT" python3 -c "
import json, os, subprocess, sys

TRANSCRIPT = os.environ['_TRANSCRIPT']

tail_lines = subprocess.run(
    ['tail', '-300', TRANSCRIPT], capture_output=True, text=True
).stdout.splitlines()

head_lines = subprocess.run(
    ['head', '-100', TRANSCRIPT], capture_output=True, text=True
).stdout.splitlines()

def extract_text(entry):
    msg = entry.get('message', {})
    if isinstance(msg, dict):
        c = msg.get('content', '')
        if isinstance(c, str): return c
        if isinstance(c, list):
            return ' '.join(b.get('text','') for b in c if isinstance(b, dict) and b.get('type') == 'text')
    return ''

first_user = []
for raw in head_lines:
    try:
        e = json.loads(raw)
        if e.get('type') == 'user':
            t = extract_text(e)
            if t.strip():
                first_user.append(f'user: {t[:200]}')
                if len(first_user) >= 2: break
    except: pass

last_msgs = []
for raw in reversed(tail_lines):
    try:
        e = json.loads(raw)
        if e.get('type') in ('user', 'assistant'):
            t = extract_text(e)
            if t.strip():
                last_msgs.append(f'{e[\"type\"]}: {t[:200]}')
                if len(last_msgs) >= 4: break
    except: pass
last_msgs.reverse()

all_msgs = first_user + last_msgs
if all_msgs:
    print('\n'.join(all_msgs))
" 2>/dev/null)

[ -z "$CONTEXT" ] && exit 0

# Build prompt file (per-surface to avoid collisions)
PROMPT_FILE="/tmp/cmux-tab-prompt-${CMUX_SURFACE_ID}"
cat > "$PROMPT_FILE" << PYEOF
Summarize this conversation in 2-5 words, using the SAME language as the conversation. Output ONLY the summary, nothing else.

$CONTEXT
PYEOF

# Spawn background: generate AI label → write to pending file
# (applied on next UserPromptSubmit by cmux-rename-namer.sh for faster tab updates)
(
  set +e
  LABEL=$(perl -e 'alarm 15; exec @ARGV' claude -p --model haiku < "$PROMPT_FILE" 2>/dev/null | head -1 | cut -c1-30)
  rm -f "$PROMPT_FILE" 2>/dev/null
  if [ -n "$LABEL" ]; then
    printf '%s\n%s\n%s\n' "$LABEL" "$LINE_COUNT" "${HAS_CUSTOM_TITLE:-0}" > "$TAB_PENDING"
  fi
) &>/dev/null &
disown

exit 0
