#!/usr/bin/env bash
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later

# Build and run the host-only tests in the current public Browser slice. This
# intentionally needs neither a Chromium checkout nor gtest.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$ROOT/overlay/chrome/browser/cmux_term"
TMP_OUT="$(mktemp -d)"
trap 'rm -rf "$TMP_OUT"' EXIT

CXX="${CXX:-c++}"
CXXFLAGS=(
  -std=c++17
  -Wall
  -Wextra
  -Werror
  -Wno-comment
  -pthread
  -I "$ROOT/overlay"
)

"$CXX" "${CXXFLAGS[@]}" \
  "$TEST_DIR/cmux_tui_protocol.cc" \
  "$TEST_DIR/cmux_tui_protocol_test.cc" \
  -o "$TMP_OUT/cmux_tui_protocol_test"

"$TMP_OUT/cmux_tui_protocol_test"
echo "PASS cmux_tui_protocol_test.cc"
