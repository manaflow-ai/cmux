#!/usr/bin/env bash
# chief-agents on a Cloud Chief turn machine: the Mac Chief's subagent tools (optchat-chief spawn, tell, peers,
# control, chiefs) on the person's Mac, through the Mac gate. The Mac Chief host must be running there.
#
#   chief-agents peers
#   chief-agents spawn "Title: short title\nGroup: topic\n\nthe whole task"
#   chief-agents tell aN "message"
#   chief-agents control status|interrupt|priority|cap ...
set -euo pipefail
tool="${1:-}"
case "$tool" in
  peers|spawn|tell|control|chiefs) shift ;;
  *) echo "usage: chief-agents peers | spawn \"task\" | tell aN \"message\" | control ACTION ... | chiefs" >&2; exit 2 ;;
esac
mac health >/dev/null || exit 125
# shellcheck disable=SC2016 # expanded on the Mac
exec mac --timeout "${CHIEF_AGENTS_TIMEOUT:-180}" -- /bin/zsh -c '
home=$HOME/.cmux/chief/default
bin=$(ps -axo command= | grep -E "optchat-chief host .*--mux-home [^ ]*/\.cmux/chief/default( |$)" | grep -v grep | head -1 | awk "{print \$1}")
[[ -x $bin ]] || bin="/Applications/cmux NIGHTLY.app/Contents/Resources/bin/optchat-chief"
[[ -x $bin ]] || { echo "chief-agents: no Mac Chief host is running" >&2; exit 127; }
tool=$1; shift
exec "$bin" "$tool" --mux-home "$home" "$@"' chief-agents "$tool" "$@"
