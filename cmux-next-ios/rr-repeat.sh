#!/bin/bash
# Build once, then run the WireGuard reliable-resume test N times; print the logs of failures.
set -u
cd cmux-next-ios/rust
cargo test -p cmux-mobile-link --test loopback --no-run 2>&1 | tail -3
bin=$(ls -t target/debug/deps/loopback-* | grep -v '\.d$' | head -1)
fails=0
for i in $(seq 1 ${N:-12}); do
  if ! RUST_LOG=${LOG:-cmux_mobile_link=debug} "$bin" --exact ${TEST:-wireguard_reliable_link_resumes_over_a_new_transport} --nocapture > /tmp/rr.$i 2>&1; then
    fails=$((fails+1)); echo "=== FAIL run $i"; [ $fails -le 2 ] && tail -c 30000 /tmp/rr.$i
  else echo "pass run $i"; fi
done
echo "fails=$fails of ${N:-12}"
[ $fails -eq 0 ]
