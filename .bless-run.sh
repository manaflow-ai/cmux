#!/bin/bash
set -euo pipefail
exec 2>&1
cd cmux-tui
ACPMUX_PROTOCOL_BLESS=1 cargo test -p acpmux --lib protocol_ir_is_current
cp crates/acpmux/spec/acpmux-protocol.json "$FAST_CHECKS_OUT/acpmux-protocol.json"
