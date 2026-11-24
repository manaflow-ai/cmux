set -u
cd cmux-tui
run() { echo "=== $1"; cargo test --locked -q -p acpmux --lib -- turn_cap 2>&1 | grep -E "^test result|FAILED|panicked" | head -5; }
git fetch -q --depth=50 origin feat-cmux-next 2>&1 | tail -1
H=$(git rev-parse HEAD)
run branch
git checkout -q FETCH_HEAD -- crates/acpmux/src/hub/inbox.rs crates/acpmux/src/hub/inbox_tests.rs; run inbox-reverted; git checkout -q $H -- crates/acpmux
git checkout -q FETCH_HEAD -- crates/acpmux/src/hub/transcript.rs; run transcript-reverted; git checkout -q $H -- crates/acpmux
git checkout -q FETCH_HEAD -- crates/acpmux/src/hub/hosts/journal.rs crates/acpmux/src/hub/hosts_tests.rs; run journal-reverted; git checkout -q $H -- crates/acpmux
sed -i 's/^\(\s*\)self.seed_prompt_stops(/\1if false { self.seed_prompt_stops(/; ' crates/acpmux/src/hub/log_load.rs; git diff --stat; 
git checkout -q $H -- crates/acpmux
git checkout -q FETCH_HEAD -- crates/acpmux; run base
