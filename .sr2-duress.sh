set -u
exec > >(tee -a "${FAST_CHECKS_OUT:-/tmp}/duress3.log") 2>&1
cd cmux-tui
cargo clippy -q -p acpmux --lib -- -W clippy::indexing_slicing 2>&1 | grep -A3 -E 'steer_batch.rs|steer_end.rs' | head -20
echo "== clippy steer hits above (none = clean)"
pass=0; fail=0
for i in $(seq 1 20); do if cargo test -q -p acpmux --lib steer > /tmp/s.log 2>&1; then pass=$((pass+1)); else fail=$((fail+1)); grep -E 'panicked|FAILED' /tmp/s.log | head -5; fi; done
grep -E 'test result' /tmp/s.log | tail -1
echo "Duress: acpmux --lib steer tests (steer_batch, steer_end) x20 at 94f3e5af: pass=$pass fail=$fail"
