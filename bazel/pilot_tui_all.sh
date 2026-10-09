#!/usr/bin/env bash
# Run every Rust scenario for the cmux-tui binaries (both [[bin]] targets).
set -uo pipefail
cd /work/bazel-pilot
L="//cmux-tui/crates/cmux-tui:cmux_tui_bin //cmux-tui/crates/cmux-tui:cmux_tui_hook_bin"
bash src/bazel/pilot_measure_rust.sh "$L" cmux-tui both
bash src/bazel/pilot_measure_rust_cache.sh "$L" cmux-tui
bash src/bazel/pilot_incr.sh "$L"
