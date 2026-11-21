#!/bin/bash
set -euo pipefail
exec 2>&1
(cd cmux-tui && ACPMUX_PROTOCOL_BLESS=1 cargo test -p acpmux --lib protocol_ir_is_current)
(cd webviews && (bun install --frozen-lockfile >/dev/null 2>&1 || true) && bun run acpmux-protocol:codegen)
git status --short
git diff > "$FAST_CHECKS_OUT/bless.diff"
