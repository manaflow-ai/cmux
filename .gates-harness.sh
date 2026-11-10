#!/usr/bin/env bash
# gates harness: the same slow-path tests at the PR head (after) and on base code (before).
set -u
cd cmux-tui
T="cli::app::tests::a_daemon_that_comes_back_after_5_s_is_waited_for cli::cloud_start_chat::tests::a_machine_that_answers_after_30_s_of_unanswered_reads_gets_its_reply_read cli::cloud_start_chat::tests::unanswered_reads_are_asked_again_until_the_deadline cli::cloud_start_chat::tests::the_start_sessions_own_stages_are_its_parts"
echo "=== AFTER: the whole cmux-tui crate (lib and integration tests)"
s=$(date +%s); cargo test -q -p cmux-tui 2>&1 | grep -E "^test result|FAILED|panicked|failed|error\[" | head -80; echo "after suites exit=${PIPESTATUS[0]} $(( $(date +%s)-s ))s"
echo "=== AFTER: slow-path tests, timed"
PHASE=AFTER
for t in $T; do s=$(date +%s%N); out=$(cargo test -q -p cmux-tui --lib -- --exact $t 2>&1); r=$?; echo "$PHASE $t: $([ $r = 0 ] && echo PASS || echo FAIL) in $(( ($(date +%s%N)-s)/1000000 )) ms (includes cargo start)"; [ $r = 0 ] || echo "$out" | grep -E "panicked|assert|left|right" | head -4; done
echo "=== BEFORE: base code, same slow-path tests"
for f in app.rs app/run.rs app/wait.rs cloud_start_chat.rs; do cp "../.gates-base/$f" "crates/cmux-tui/src/cli/$f"; done
python3 - <<'PY'
import re
p='crates/cmux-tui/src/cli/app/tests.rs'; s=open(p).read()
a=s.index('/// A refusal that says nothing ran and never passes'); b=s.index('/// A person\'s `cmux machine new`')
open(p,'w').write(s[:a]+s[b:])
p='crates/cmux-tui/src/cli/cloud_start_chat/tests.rs'; s=open(p).read()
a=s.index('/// The pauses between unanswered reads grow'); b=s.index('/// A read refused because the machine stopped')
open(p,'w').write(s[:a]+s[b:])
PY
cargo test -q -p cmux-tui --lib --no-run 2>&1 | grep -E "^error" | head
PHASE=BEFORE
for t in $T; do s=$(date +%s%N); out=$(cargo test -q -p cmux-tui --lib -- --exact $t 2>&1); r=$?; echo "$PHASE $t: $([ $r = 0 ] && echo PASS || echo FAIL) in $(( ($(date +%s%N)-s)/1000000 )) ms (includes cargo start)"; [ $r = 0 ] || echo "$out" | grep -E "panicked|assert|left|right" | head -4; done
git checkout -- crates
