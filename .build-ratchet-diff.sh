#!/bin/bash
set -o pipefail
exec 2>&1
OUT="${FAST_CHECKS_OUT:-/tmp}"
BASE=c2c25943920908967b6db0b232e874d0e1d1e083
ROOT=$(pwd)
PKGS="-p acpmux -p acpmux-standalone -p cmux-agent-cli-render -p cmux-remote -p cmux-terminal-client -p cmux-tui -p cmux-tui-core"
FLAGS=$(python3 scripts/cmux-next/rust_panic_ratchet.py --flags)
(cd cmux-tui && cargo clippy --locked $PKGS --lib --bins --message-format=json -- $FLAGS > "$OUT/head.jsonl") || true
git fetch -q --depth 1 origin "$BASE" && git worktree add -q /tmp/basetree "$BASE" || { echo NO_BASE_TREE; exit 1; }
(cd /tmp/basetree/cmux-tui && cargo clippy --locked $PKGS --lib --bins --message-format=json -- $FLAGS > "$OUT/base.jsonl") || true
python3 .build-ratchet-diff.py "$OUT/head.jsonl" "$OUT/base.jsonl" "$ROOT" /tmp/basetree | tee "$OUT/diff.txt"
