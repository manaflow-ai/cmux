#!/bin/bash
set -x
OUT=${FAST_CHECKS_OUT:-/tmp/out}; mkdir -p "$OUT"
cd cmux-tui
ACPMUX_PROTOCOL_BLESS=1 cargo test -p acpmux --lib protocol:: > "$OUT/protocol.log" 2>&1
ACPMUX_LIST_STREAM_BLESS=1 cargo test -p acpmux --lib sidebar_mirror > "$OUT/mirror.log" 2>&1
git status --short > "$OUT/git-status-after-bless.txt"
git diff --stat > "$OUT/bless.stat"
cp crates/acpmux/spec/acpmux-protocol.json crates/acpmux/spec/acpmux-abi.surface.json ../Packages/macOS/CmuxNext/Tests/Fixtures/AgentListStream/mirror.bytes ../Packages/macOS/CmuxNext/Tests/Fixtures/AgentListStream/mirror.jsonl "$OUT/"
cargo test -p acpmux --lib every_tool_schema_fits -- --nocapture 2>&1 | grep -E "SCHEMA acpmux TOTAL|over budget|test result" > "$OUT/schema.log"
cargo test -p acpmux --lib > "$OUT/lib.log" 2>&1; echo "lib exit $?" >> "$OUT/lib.log"
cargo test -p acpmux --test hub_integration > "$OUT/hub.log" 2>&1; echo "hub exit $?" >> "$OUT/hub.log"
grep -hE "^test .*FAILED|test result|exit " "$OUT"/*.log
exit 0
