//! The Chief's `watch` never polls GitHub itself (the user, 2026-11-19: "glaeda-gh wait
//! pr|run|comment is in everyone's agent rules, runs off webhooks so it spends no quota
//! ... are we using this properly too?"). It was not: watch w43 re-ran `gh api
//! .../actions/runs/N` for hours, and only a `gh pr view` merge wait was rewritten. With
//! glaeda-gh on the host, `watch::route` turns every GitHub wait it recognises (a run's
//! status, a PR's checks or merge, a comment) into one `glaeda-gh wait run|pr|comment`,
//! and a file or pid sleep loop into `glaeda-gh wait file|pid`; a GitHub poll it cannot
//! say as one wait (a loop, several targets, no repository) is refused with the command
//! to use instead.

use optchat_chief::watch::{Route, route};

/// The rewritten command and `until`, or a panic naming what came back.
fn rewritten(command: &str, until: Option<&str>) -> (String, Option<String>) {
    match route(command, until, 3600) {
        Route::Rewrite { command, until } => (command, until),
        other => panic!("{command:?} with until {until:?} was not rewritten: {other:?}"),
    }
}

fn refused(command: &str, until: Option<&str>) -> String {
    match route(command, until, 3600) {
        Route::Refuse(why) => why,
        other => panic!("{command:?} with until {until:?} was not refused: {other:?}"),
    }
}

fn matches(until: &Option<String>, line: &str) -> bool {
    regex::Regex::new(until.as_deref().expect("an until"))
        .unwrap()
        .is_match(line)
}

#[test]
fn a_run_status_poll_waits_through_glaeda_then_reads_once() {
    // Watch w45 (2026-11-19): this exact read, re-run every 15 s.
    let read = "gh api repos/manaflow-ai/cmux/actions/runs/44637914493 --jq '\"\\(.status) \\(.conclusion)\"'";
    let (command, until) = rewritten(read, Some("completed"));
    assert!(
        command.starts_with("glaeda-gh wait run manaflow-ai/cmux/44637914493 --timeout 3600"),
        "{command}"
    );
    // The Chief's own read runs once, after the run ended, and its line still matches.
    assert!(command.contains(read), "{command}");
    assert!(matches(&until, "completed success"));
    assert!(!matches(&until, "in_progress "));
    // A run that ended without the expected line still ends the watch (no 15 s re-poll).
    assert!(
        command.contains("watch: the GitHub wait ended"),
        "{command}"
    );
    assert!(matches(
        &until,
        "watch: the GitHub wait ended (glaeda-gh exit 1)"
    ));

    let view =
        "gh run view 44645431812 -R manaflow-ai/cmux --json status,conclusion -q .conclusion";
    let (command, _) = rewritten(view, Some("success|failure"));
    assert!(
        command.starts_with("glaeda-gh wait run manaflow-ai/cmux/44645431812 "),
        "{command}"
    );
    // A job list of one run (a1233's poll of the nightly's publish job) waits on that run.
    let jobs = "gh api 'repos/manaflow-ai/cmux/actions/runs/44464326281/jobs?per_page=100' -q '[.jobs[]|select(.name==\"publish\")|.status]|join(\" \")'";
    let (command, _) = rewritten(jobs, Some("completed"));
    assert!(
        command.starts_with("glaeda-gh wait run manaflow-ai/cmux/44464326281 "),
        "{command}"
    );
    let url = "gh run view https://github.com/manaflow-ai/cmux/actions/runs/7 --json conclusion";
    let (command, _) = rewritten(url, Some("success"));
    assert!(
        command.starts_with("glaeda-gh wait run manaflow-ai/cmux/7 "),
        "{command}"
    );
}

#[test]
fn gh_run_watch_and_checks_watch_become_one_glaeda_wait() {
    let (command, until) = rewritten(
        "gh run watch 44655157417 --repo manaflow-ai/cmux --exit-status",
        None,
    );
    assert_eq!(
        command,
        "glaeda-gh wait run manaflow-ai/cmux/44655157417 --timeout 3600"
    );
    assert_eq!(until, None);
    let (command, until) = rewritten("gh pr checks 46978 -R manaflow-ai/cmux --watch", None);
    assert_eq!(
        command,
        "glaeda-gh wait pr manaflow-ai/cmux#46978 --until done --timeout 3600"
    );
    assert_eq!(until, None);
}

#[test]
fn a_pr_checks_or_merge_poll_waits_on_the_pr() {
    let read = "gh pr view 46978 -R manaflow-ai/cmux --json statusCheckRollup,mergeStateStatus -q .mergeStateStatus";
    let (command, until) = rewritten(read, Some("CLEAN|UNSTABLE"));
    assert!(
        command.starts_with("glaeda-gh wait pr manaflow-ai/cmux#46978 --until done --timeout 3600"),
        "{command}"
    );
    assert!(command.contains(read), "{command}");
    assert!(matches(&until, "CLEAN"));
    let api = "gh api repos/manaflow-ai/cmux/pulls/47261 --jq .merged";
    let (command, _) = rewritten(api, Some("true|MERGED|closed"));
    assert!(
        command.starts_with("glaeda-gh wait pr manaflow-ai/cmux#47261 --until merged "),
        "{command}"
    );
    // The original merge rewrite is unchanged.
    let (command, until) = rewritten(
        "gh pr view 30082 -R manaflow-ai/cmux --json state -q .state",
        Some("MERGED"),
    );
    assert_eq!(
        command,
        "glaeda-gh wait pr manaflow-ai/cmux#30082 --until merged --timeout 3600 >/dev/null && echo MERGED"
    );
    assert_eq!(until.as_deref(), Some("MERGED"));
}

#[test]
fn a_comment_poll_waits_for_the_comment() {
    let read = "gh api repos/manaflow-ai/cmux/issues/44204/comments --jq '.[].body'";
    let (command, until) = rewritten(read, Some("landed on feat-cmux-next"));
    assert!(
        command.starts_with(
            "glaeda-gh wait comment manaflow-ai/cmux#44204 --match 'landed on feat-cmux-next' --since 60m --timeout 3600"
        ),
        "{command}"
    );
    assert!(command.contains(read), "{command}");
    assert!(matches(&until, "Fix landed on feat-cmux-next as 66412ed"));
    let (command, _) = rewritten(
        "gh pr view 44204 -R manaflow-ai/cmux --comments",
        Some("it's in"),
    );
    assert!(
        command.starts_with("glaeda-gh wait comment manaflow-ai/cmux#44204 --match 'it'\\''s in' "),
        "{command}"
    );
}

#[test]
fn file_and_pid_checks_and_sleep_loops_wait_through_glaeda() {
    let (command, until) = rewritten(
        "test -s /tmp/a1212/verdict.txt && echo READY",
        Some("READY"),
    );
    assert_eq!(
        command,
        "glaeda-gh wait file /tmp/a1212/verdict.txt --timeout 3600 && echo READY"
    );
    assert_eq!(until.as_deref(), Some("READY"));
    let (command, _) = rewritten("[ -e '/tmp/my dir/done' ] && echo DONE", Some("DONE"));
    assert_eq!(
        command,
        "glaeda-gh wait file '/tmp/my dir/done' --exists --timeout 3600 && echo DONE"
    );
    let (command, _) = rewritten(
        "grep -qE 'EXIT|state=failed' /tmp/a-auto-cc.log && echo FINISHED",
        Some("FINISHED"),
    );
    assert_eq!(
        command,
        "glaeda-gh wait file /tmp/a-auto-cc.log --contains 'EXIT|state=failed' --timeout 3600 && echo FINISHED"
    );
    let (command, _) = rewritten("kill -0 4242 2>/dev/null || echo GONE", Some("GONE"));
    assert_eq!(
        command,
        "glaeda-gh wait pid 4242 --timeout 3600 && echo GONE"
    );
    // A sleep loop inside the command, with or without until.
    let (command, until) = rewritten(
        "until [ -s /tmp/a-cs-run/base.log ]; do sleep 20; done; tail -3 /tmp/a-cs-run/base.log",
        None,
    );
    assert_eq!(
        command,
        "glaeda-gh wait file /tmp/a-cs-run/base.log --timeout 3600; tail -3 /tmp/a-cs-run/base.log"
    );
    assert_eq!(until, None);
    let (command, _) = rewritten(
        "until grep -qE '^TEST_EXIT=|^exit=' /tmp/b.log 2>/dev/null; do sleep 20; done; grep -h TEST_EXIT /tmp/b.log",
        None,
    );
    assert_eq!(
        command,
        "glaeda-gh wait file /tmp/b.log --contains '^TEST_EXIT=|^exit=' --timeout 3600; grep -h TEST_EXIT /tmp/b.log"
    );
    let (command, _) = rewritten("while kill -0 777; do sleep 5; done; echo exited", None);
    assert_eq!(
        command,
        "glaeda-gh wait pid 777 --timeout 3600; echo exited"
    );
}

#[test]
fn a_github_poll_glaeda_cannot_say_as_one_wait_is_refused() {
    // a1230's loop, a1232's loop over two runs, a poll with no repository.
    let why = refused(
        "while true; do r=$(gh api repos/manaflow-ai/cmux/actions/runs/44637914493 --jq .status); case \"$r\" in completed*) break;; esac; sleep 120; done",
        None,
    );
    assert!(why.contains("glaeda-gh wait run"), "{why}");
    let why = refused(
        "for r in 44490344125 44494815020; do gh run view $r -R manaflow-ai/cmux --json status -q .status; done",
        Some("completed"),
    );
    assert!(why.contains("glaeda-gh wait"), "{why}");
    let why = refused("gh run view 5 --json status -q .status", Some("completed"));
    assert!(why.contains("OWNER/REPO"), "{why}");
    let why = refused(
        "gh api 'repos/manaflow-ai/cmux/actions/runs?head_sha=a2e0ede' --jq '.workflow_runs[].status'",
        Some("completed"),
    );
    assert!(why.contains("glaeda-gh wait run"), "{why}");
    let why = refused("gh run watch 1 -R a/b; gh run watch 2 -R a/b", None);
    assert!(why.contains("one watch per"), "{why}");
}

#[test]
fn other_watches_are_left_alone() {
    for (command, until) in [
        (
            "aws sts get-caller-identity && echo SIGNED_IN",
            Some("SIGNED_IN"),
        ),
        // One read with no until runs once: no poll.
        ("gh pr view 1 -R a/b --json state", None),
        // Waiting for a run to start has no glaeda wait: kept.
        (
            "gh run view 1 -R a/b --json status -q .status",
            Some("in_progress"),
        ),
        // A review decision is not a checks wait.
        (
            "gh pr view 1 -R a/b --json reviewDecision -q .reviewDecision",
            Some("APPROVED"),
        ),
        // glaeda's own reads cost nothing.
        (
            "glaeda-gh status pr a/b#1 --field checks.state",
            Some("SUCCESS"),
        ),
        ("glaeda-gh wait run a/b/1", None),
        ("cmux-ci wait 47fcc5ed3f9ff739f211d307", None),
        ("test -s /tmp/x", None),
    ] {
        assert_eq!(route(command, until, 600), Route::Keep, "{command}");
    }
}
