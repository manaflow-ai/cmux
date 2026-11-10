#!/usr/bin/env bash
set -u
cd cmux-tui
echo "=== HEAD: integration tests that drive the app retry"
cargo test -q -p cmux-tui --test app_refusal_note --test app_wait_progress 2>&1 | grep -E "test result|FAILED|panicked|^error" | head
F="carrier::fault::tests::the_probe_accounts_are_the_provisioners_accounts cli::agent_start::tests::w3h_resume_reads_the_session_id_kept_on_the_terminal_after_the_session_ended cli::command::tests::transport_path_coverage_tests::every_safe_transport_operation_has_a_noun_first_path cli::wire::agent_roster::tests::empty_roster_has_zero_counts cli::wire::agent_roster::tests::json_shape_has_agents_with_age_title_and_folder_and_counts"
echo "=== BASE (this PR's files at base): the 5 lib reds"
for f in app.rs app/run.rs app/wait.rs cloud_start_chat.rs; do cp "../.gates-base/$f" "crates/cmux-tui/src/cli/$f"; done
python3 - <<'PY'
p='crates/cmux-tui/src/cli/app/tests.rs'; s=open(p).read()
a=s.index('/// An app whose daemon connection takes 5 s'); b=s.index('/// A person\'s `cmux machine new`')
open(p,'w').write(s[:a]+s[b:])
p='crates/cmux-tui/src/cli/cloud_start_chat/tests.rs'; s=open(p).read()
a=s.index('/// Unanswered reads are asked again, with backoff'); b=s.index('/// A read refused because the machine stopped')
s=s[:a]+s[b:]
a=s.index('/// `cloud start-session`\'s own split'); b=s.index('#[test]\nfn a_failure_carries_the_steps_it_ran')
open(p,'w').write(s[:a]+s[b:])
PY
cargo test -q -p cmux-tui --lib -- --exact $F 2>&1 | grep -E "test result|FAILED" | head
git checkout -- crates
