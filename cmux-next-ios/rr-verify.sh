#!/bin/bash
# The fix's verdict: 20 repeats of the flaky test, then the whole loopback and https_relay files, then the unit test.
set -euo pipefail
N=20 LOG=info bash cmux-next-ios/rr-repeat.sh
cd cmux-next-ios/rust
cargo test -p cmux-mobile-link --test loopback 2>&1 | grep -E "^test |test result|panicked" 
cargo test -p cmux-mobile-link --test https_relay 2>&1 | grep -E "^test |test result|panicked"
cargo test -p cmux-mobile-link --lib reliable_link_takes_no_input_lane 2>&1 | grep -E "^test |test result|panicked"
