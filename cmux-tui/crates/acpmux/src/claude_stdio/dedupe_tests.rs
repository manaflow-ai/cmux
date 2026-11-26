//! Harness magic `dedupe` (`dedupe.rs`, `dedupe_shell.rs`).

use super::dedupe::{Call, Dedupe, enabled_in, env_off, stub};
use super::dedupe_shell::{inputs, words};
use super::*;
use std::path::PathBuf;
use std::time::{Duration, Instant};

fn read(path: &Path, offset: Option<u64>, limit: Option<u64>) -> Value {
    let mut args = json!({"file_path": path.to_str().unwrap()});
    if let Some(o) = offset {
        args.set("offset", json!(o));
    }
    if let Some(l) = limit {
        args.set("limit", json!(l));
    }
    json!({"tool_name": "Read", "tool_input": args, "cwd": "/"})
}

fn bash(cwd: &Path, command: &str) -> Value {
    json!({"tool_name": "Bash", "tool_input": {"command": command, "description": "x"},
        "cwd": cwd.to_str().unwrap()})
}

/// Runs one call through `d`: the stub, or `None` after its result `text` was recorded.
fn call(
    d: &Dedupe,
    id: &str,
    agent: &str,
    input: &Value,
    text: &str,
    now: Instant,
) -> Option<String> {
    let c = Call::of(input).expect("a call dedupe knows");
    let fp = c.fingerprint().expect("a fingerprint");
    let stub = d.decide(id, agent, c, fp, now);
    if stub.is_none() {
        d.result(id, false, text);
    }
    stub
}

fn file(dir: &Path, name: &str, body: &str) -> PathBuf {
    let p = dir.join(name);
    std::fs::write(&p, body).unwrap();
    p
}

#[test]
fn a_second_read_of_an_unchanged_file_is_stubbed_once() {
    let dir = tempfile::tempdir().unwrap();
    let f = file(dir.path(), "a.txt", &"line\n".repeat(400));
    let d = Dedupe::default();
    let now = Instant::now();
    let body = "x".repeat(4000);
    assert_eq!(call(&d, "1", "", &read(&f, None, None), &body, now), None);
    let s = call(&d, "2", "", &read(&f, None, None), &body, now).expect("stubbed");
    assert!(
        s.starts_with("[dedupe] unchanged since your Read 1 call ago; it is still in your context"),
        "{s}"
    );
    // Asked again: it runs (the escape hatch), and that result can be stubbed from.
    assert_eq!(call(&d, "3", "", &read(&f, None, None), &body, now), None);
    assert!(call(&d, "4", "", &read(&f, None, None), &body, now).is_some());
    let c = d.turn_ended();
    assert_eq!(c.reads_stubbed, 2);
    assert_eq!(c.calls_stubbed, 0);
    assert!(c.est_tokens_saved > 1500, "{c:?}");
    assert_eq!(d.turn_ended().reads_stubbed, 0, "taken per turn");
}

#[test]
fn a_covered_range_is_stubbed_and_a_wider_one_runs() {
    let dir = tempfile::tempdir().unwrap();
    let f = file(dir.path(), "a.txt", "a\nb\nc\n");
    let d = Dedupe::default();
    let now = Instant::now();
    assert_eq!(call(&d, "1", "", &read(&f, Some(10), Some(100)), "body", now), None);
    assert!(call(&d, "2", "", &read(&f, Some(20), Some(50)), "body", now).is_some());
    assert_eq!(call(&d, "3", "", &read(&f, Some(1), Some(100)), "body", now), None);
    assert_eq!(call(&d, "4", "", &read(&f, None, None), "body", now), None, "2000 lines > 100");
}

#[test]
fn a_changed_file_runs_again() {
    let dir = tempfile::tempdir().unwrap();
    let f = file(dir.path(), "a.txt", "one\n");
    let d = Dedupe::default();
    let now = Instant::now();
    assert_eq!(call(&d, "1", "", &read(&f, None, None), "one", now), None);
    std::fs::write(&f, "two\n").unwrap();
    assert_eq!(call(&d, "2", "", &read(&f, None, None), "two", now), None);
    assert!(call(&d, "3", "", &read(&f, None, None), "two", now).is_some());
}

#[test]
fn a_compaction_an_idle_gap_or_another_agent_runs_again() {
    let dir = tempfile::tempdir().unwrap();
    let f = file(dir.path(), "a.txt", "one\n");
    let d = Dedupe::default();
    let now = Instant::now();
    assert_eq!(call(&d, "1", "", &read(&f, None, None), "one", now), None);
    d.reset();
    assert_eq!(call(&d, "2", "", &read(&f, None, None), "one", now), None);
    assert_eq!(
        call(&d, "3", "agent-b", &read(&f, None, None), "one", now),
        None,
        "its own context"
    );
    let later = now + Duration::from_secs(301);
    assert_eq!(call(&d, "4", "", &read(&f, None, None), "one", later), None, "idle past 5 minutes");
    assert!(call(&d, "5", "", &read(&f, None, None), "one", later).is_some());
}

#[test]
fn an_error_a_cut_view_or_a_reset_while_running_records_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let f = file(dir.path(), "a.txt", "one\n");
    let d = Dedupe::default();
    let now = Instant::now();
    let c = Call::of(&read(&f, None, None)).unwrap();
    let fp = c.fingerprint().unwrap();
    assert_eq!(d.decide("1", "", c.clone(), fp.clone(), now), None);
    d.result("1", true, "error");
    assert_eq!(d.decide("2", "", c.clone(), fp.clone(), now), None);
    d.result("2", false, "x [Truncated: PARTIAL view of the file]");
    assert_eq!(d.decide("3", "", c.clone(), fp.clone(), now), None);
    d.result("3", false, "File unchanged since last read. ...");
    assert_eq!(d.decide("4", "", c.clone(), fp.clone(), now), None);
    d.reset();
    d.result("4", false, "one");
    assert_eq!(d.decide("5", "", c, fp, now), None);
}

#[test]
fn only_plain_reads_and_absolute_paths_are_known() {
    assert!(
        Call::of(&json!({"tool_name": "Read", "tool_input": {"file_path": "rel.txt"}})).is_none()
    );
    assert!(
        Call::of(&json!({"tool_name": "Read", "tool_input": {"file_path": "/a", "pages": "1-2"}}))
            .is_none()
    );
    assert!(Call::of(&json!({"tool_name": "Edit", "tool_input": {"file_path": "/a"}})).is_none());
    let c = Call::of(&json!({"tool_name": "Read", "tool_input": {"file_path": "/a", "offset": 0}}));
    assert_eq!(c, Some(Call::Read { path: "/a".into(), lines: (1, 2001) }));
}

#[test]
fn a_repeated_read_only_shell_command_is_stubbed_in_its_turn_only() {
    let dir = tempfile::tempdir().unwrap();
    let f = file(dir.path(), "a.txt", "one\ntwo\n");
    let d = Dedupe::default();
    let now = Instant::now();
    let input = bash(dir.path(), "wc -l a.txt");
    assert_eq!(call(&d, "1", "", &input, "2 a.txt", now), None);
    let s = call(&d, "2", "", &input, "2 a.txt", now).expect("stubbed");
    assert!(s.starts_with("[dedupe] `wc -l a.txt` ran 1 call ago"), "{s}");
    assert_eq!(d.turn_ended().calls_stubbed, 1);
    assert_eq!(call(&d, "3", "", &input, "2 a.txt", now), None, "a new turn runs it");
    std::fs::write(&f, "one\n").unwrap();
    assert_eq!(call(&d, "4", "", &input, "1 a.txt", now), None, "its file changed");
}

#[test]
fn shell_commands_outside_the_list_are_not_known() {
    let cwd = tempfile::tempdir().unwrap();
    file(cwd.path(), "a.txt", "x");
    for bad in [
        "cat a.txt | head",
        "cat a.txt; rm a.txt",
        "cat $HOME/a.txt",
        "cat `x`",
        "cat a.txt > b",
        "rm a.txt",
        "tail -f a.txt",
        "grep -r x .",
        "rg x",
        "ls -R",
        "cat missing.txt",
        "cat",
        "git status",
        "git diff",
        "git log --since=1.day",
        "git log --format=%ar",
        "git push",
        "date",
        "find . -name x",
    ] {
        assert!(inputs(bad, cwd.path()).is_none(), "{bad}");
    }
    for good in
        ["cat a.txt", "head -n 5 a.txt", "grep -n x a.txt", "rg -e x a.txt", "ls -la", "wc a.txt"]
    {
        assert!(inputs(good, cwd.path()).is_some(), "{good}");
    }
    assert_eq!(
        words("git log --format='%h %s' -3").unwrap(),
        ["git", "log", "--format=%h %s", "-3"]
    );
}

#[test]
fn a_git_read_is_stubbed_until_a_ref_moves() {
    let dir = tempfile::tempdir().unwrap();
    let git = |args: &[&str]| {
        let ok = std::process::Command::new("git")
            .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"])
            .args(args)
            .current_dir(dir.path())
            .output()
            .is_ok_and(|o| o.status.success());
        assert!(ok, "git {args:?}");
    };
    git(&["init", "-q", "-b", "main"]);
    git(&["commit", "-q", "--allow-empty", "-m", "one"]);
    let d = Dedupe::default();
    let now = Instant::now();
    let input = bash(dir.path(), "git log --oneline -5");
    assert_eq!(call(&d, "1", "", &input, "abc one", now), None);
    assert!(call(&d, "2", "", &input, "abc one", now).is_some());
    git(&["commit", "-q", "--allow-empty", "-m", "two"]);
    assert_eq!(call(&d, "3", "", &input, "def two", now), None, "HEAD moved");
}

#[test]
fn the_switches() {
    // Off unless the person turns it on.
    assert!(!enabled_in(None));
    assert!(!enabled_in(Some(&json!({}))));
    assert!(!enabled_in(Some(
        &json!({"agents": {"harnessMagic": {"dedupe": {"enabled": false}}}})
    )));
    assert!(enabled_in(Some(&json!({"agents": {"harnessMagic": {"dedupe": {"enabled": true}}}}))));
    for off in ["0", "false", "OFF", "no"] {
        assert!(env_off(Some(off)), "{off}");
    }
    assert!(!env_off(Some("1")) && !env_off(None));
}

#[test]
fn the_stub_is_one_line() {
    let s = stub(&Call::Read { path: "/a".into(), lines: (1, 2) }, 3);
    assert!(!s.contains('\n') && s.contains("3 calls ago"), "{s}");
}

/// Through the translator: the callback's answers and the turn result's counts.
#[tokio::test]
async fn the_translator_stubs_a_repeated_read_and_counts_it() {
    super::dedupe::ON_FOR_TEST.with(|on| on.set(true));
    let dir = tempfile::tempdir().unwrap();
    let f = file(dir.path(), "a.txt", "hello\n");
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let hook = |rid: &str, use_id: &str| {
        json!({"type": "control_request", "request_id": rid, "request": {
            "subtype": "hook_callback", "callback_id": super::dedupe::DEDUPE_CALLBACK,
            "tool_use_id": use_id,
            "input": {"session_id": "s", "cwd": "/", "hook_event_name": "PreToolUse",
                "tool_name": "Read", "tool_use_id": use_id,
                "tool_input": {"file_path": f.to_str().unwrap()}}}})
    };
    let result = |use_id: &str| {
        json!({"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": use_id, "content": "1\thello\n".repeat(50)}]}})
    };
    t.inbound(&hook("h1", "u1")).await;
    let first = t.take_stdin_replies().await;
    assert_eq!(first[0].pointer("/response/response"), Some(&json!({})), "{first:?}");
    t.inbound(&result("u1")).await;
    t.inbound(&hook("h2", "u2")).await;
    let second = t.take_stdin_replies().await;
    let out = second[0].pointer("/response/response/hookSpecificOutput").expect("a decision");
    assert_eq!(out["permissionDecision"], "deny");
    assert!(out["permissionDecisionReason"].as_str().unwrap().starts_with("[dedupe]"));
    assert_eq!(t.dedupe.turn_ended().reads_stubbed, 1);
}
