#!/usr/bin/env bash
# DIAG ONLY: run answer_latency 5 times with timing marks; exit is the tests'.
cd "$(dirname "$0")/.." || exit 2
fail=0
for i in 1 2 3 4 5; do
  DIAG_ANSWER=1 cargo test --locked -p cmux-mobile-host --test answer_latency -- offer_to_answer_before_and_after --nocapture > "/tmp/al-$i.txt" 2>&1 || fail=1
  echo "=== iter $i"
  grep -E "SUMMARY|test result|panicked" "/tmp/al-$i.txt"
  grep -E "DIAG_NETCHANGE|DIAG_DIAL network-change after|DIAG_ANSWER" "/tmp/al-$i.txt" | tail -70
done
exit $fail
