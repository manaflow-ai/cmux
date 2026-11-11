#!/usr/bin/env bash
out="${FAST_CHECKS_OUT:-/tmp}"
./scripts/lint-ios-package-conventions.sh > "$out/ioslint.log" 2>&1; echo "IOSLINT rc=$?" > "$out/summary.txt"
python3 tests/test_cmux_next_tour.py > "$out/tour.log" 2>&1; echo "TOUR rc=$?" >> "$out/summary.txt"
python3 tests/test_ci_change_areas.py > "$out/ca.log" 2>&1; echo "CA rc=$?" >> "$out/summary.txt"
scripts/ci/guards-local.sh --no-stamp --keep-going --jobs "$(getconf _NPROCESSORS_ONLN)" --results "$out/head.json" > "$out/guards.log" 2>&1
rc=$?
grep -E "^\s*FAIL |steps passed" "$out/guards.log" >> "$out/summary.txt"
echo "=== SUMMARY"; cat "$out/summary.txt"; grep -E "^ERROR" "$out/ioslint.log" | head; grep -B2 -A12 "^FAIL:" "$out/tour.log" "$out/ca.log" | head -40
exit $rc
