//! Harness magic `dedupe` (`dedupe.rs`, `dedupe_shell.rs`).

use super::dedupe::{
    Call, Dedupe, attached, attached_fingerprint, enabled_in, env_off, prefetch_stub, stub,
};
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

fn grep(cwd: &Path, args: Value) -> Value {
    json!({"tool_name": "Grep", "tool_input": args, "cwd": cwd.to_str().unwrap()})
}

fn glob(cwd: &Path, pattern: &str) -> Value {
    json!({"tool_name": "Glob", "tool_input": {"pattern": pattern}, "cwd": cwd.to_str().unwrap()})
}

/// A tree like a checkout: a `.git`, a `.gitignore`d `target/`, a hidden dir, a source file.
fn tree() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path();
    for d in [".git/objects/ab", ".git/refs", "target", ".hidden", "src"] {
        std::fs::create_dir_all(p.join(d)).unwrap();
    }
    file(p, ".gitignore", "target/\n");
    file(p, ".git/HEAD", "ref: refs/heads/main\n");
    file(p, ".git/objects/ab/cdef", "object");
    file(p, "target/out.rs", "needle\n");
    file(p, ".hidden/h.rs", "needle\n");
    file(p, "src/main.rs", "fn main() {} // needle\n");
    dir
}

#[test]
fn a_repeated_grep_is_stubbed_until_a_searched_file_or_directory_moves() {
    let t = tree();
    let p = t.path();
    let d = Dedupe::default();
    let now = Instant::now();
    let g = grep(p, json!({"pattern": "needle", "output_mode": "files_with_matches"}));
    let body = "Found 2 files\n.hidden/h.rs\nsrc/main.rs\n".repeat(50);
    assert_eq!(call(&d, "1", "", &g, &body, now), None);
    let s = call(&d, "2", "", &g, &body, now).expect("stubbed");
    assert!(s.starts_with("[dedupe] the same Grep ran 1 call ago"), "{s}");
    // Kept across turns: the fingerprint covers the tree, not the turn.
    let c = d.turn_ended();
    assert_eq!((c.searches_stubbed, c.reads_stubbed, c.calls_stubbed), (1, 0, 0));
    assert!(c.to_json()["searchesStubbed"] == 1);
    assert_eq!(call(&d, "3", "", &g, &body, now), None, "once per result");
    assert!(call(&d, "4", "", &g, &body, now).is_some());
    // What Grep does not see moves: still the same answer.
    file(p, "target/out.rs", "needle needle\n");
    file(p, ".git/objects/ab/cdef", "changed");
    assert_eq!(call(&d, "5", "", &g, &body, now), None);
    assert!(call(&d, "6", "", &g, &body, now).is_some(), "ignored and .git changes keep it");
    // A searched file's content moves: it runs.
    file(p, "src/main.rs", "fn main() {}\n");
    assert_eq!(call(&d, "7", "", &g, &body, now), None);
    assert!(call(&d, "8", "", &g, &body, now).is_some());
    // A new file in a nested directory: it runs.
    file(&p.join("src"), "lib.rs", "needle\n");
    assert_eq!(call(&d, "9", "", &g, &body, now), None);
    // A different input is a different call.
    let other = grep(p, json!({"pattern": "needle", "output_mode": "content"}));
    assert_eq!(call(&d, "10", "", &other, &body, now), None);
    // The .gitignore itself moves: it runs.
    assert!(call(&d, "11", "", &g, &body, now).is_some());
    file(p, ".gitignore", "");
    assert_eq!(call(&d, "12", "", &g, &body, now), None);
}

#[test]
fn a_repeated_glob_runs_again_when_an_ignored_file_or_a_modification_time_moves() {
    let t = tree();
    let p = t.path();
    let d = Dedupe::default();
    let now = Instant::now();
    let g = glob(p, "**/*.rs");
    let body = "src/main.rs\n.hidden/h.rs\ntarget/out.rs";
    assert_eq!(call(&d, "1", "", &g, body, now), None);
    assert!(call(&d, "2", "", &g, body, now).is_some());
    // Glob lists gitignored files: a rewrite there (a new mtime, so a new order) runs it.
    file(p, "target/out.rs", "needle!\n");
    assert_eq!(call(&d, "3", "", &g, body, now), None);
    assert!(call(&d, "4", "", &g, body, now).is_some());
    // An object file `**/*.rs` cannot match: rewriting it in place keeps the stub.
    file(p, ".git/objects/ab/cdef", "freshened");
    assert_eq!(call(&d, "5", "", &g, body, now), None);
    assert!(call(&d, "6", "", &g, body, now).is_some());
    // A catch-all pattern can match it: the same rewrite runs it.
    let all = glob(p, "**/*");
    assert_eq!(call(&d, "7", "", &all, body, now), None);
    file(p, ".git/objects/ab/cdef", "freshened again");
    assert_eq!(call(&d, "8", "", &all, body, now), None);
    // A compaction forgets it.
    assert_eq!(call(&d, "9", "", &g, body, now), None);
    d.reset();
    assert_eq!(call(&d, "10", "", &g, body, now), None);
}

#[test]
fn searches_dedupe_does_not_know_pass_through() {
    let t = tree();
    let p = t.path();
    // An input key Claude Code's Grep does not have, an absolute or parent Glob, a relative cwd.
    assert!(Call::of(&grep(p, json!({"pattern": "x", "follow": true}))).is_none());
    assert!(Call::of(&glob(p, "/etc/**")).is_none());
    assert!(Call::of(&glob(p, "../**/*.rs")).is_none());
    assert!(
        Call::of(&json!({"tool_name": "Glob", "tool_input": {"pattern": "*"}, "cwd": "rel"}))
            .is_none()
    );
    // A Grep of one file stamps the file; a missing path has no fingerprint.
    let one = Call::of(&grep(p, json!({"pattern": "x", "path": "src/main.rs"}))).unwrap();
    assert!(one.fingerprint().is_some());
    let gone = Call::of(&grep(p, json!({"pattern": "x", "path": "nope"}))).unwrap();
    assert!(gone.fingerprint().is_none());
    // A tree past the walk's bound has none either (not built here: 50,000 entries); a Glob
    // rooted at a file has none.
    let at_file = Call::of(&json!({"tool_name": "Glob",
        "tool_input": {"pattern": "*", "path": "src/main.rs"}, "cwd": p.to_str().unwrap()}))
    .unwrap();
    assert!(at_file.fingerprint().is_none());
}

/// The fingerprint's cost on a real tree: `ACPMUX_DEDUPE_BENCH_DIR=/path cargo test -p acpmux --lib
/// dedupe_search_walk_cost -- --ignored --nocapture`.
#[test]
#[ignore]
fn dedupe_search_walk_cost() {
    let Ok(dir) = std::env::var("ACPMUX_DEDUPE_BENCH_DIR") else { return };
    let root = Path::new(&dir);
    for (name, input) in [
        ("Grep", grep(root, json!({"pattern": "needle"}))),
        ("Glob **/*.rs", glob(root, "**/*.rs")),
        ("Glob **/*", glob(root, "**/*")),
    ] {
        let c = Call::of(&input).unwrap();
        let mut times = Vec::new();
        let mut parts = 0;
        for _ in 0..5 {
            let t = Instant::now();
            let fp = c.fingerprint();
            times.push(t.elapsed());
            parts = fp.map_or(0, |f| f.lines().count());
        }
        times.sort();
        eprintln!("{name}: median {:?}, max {:?}, {parts} stamps", times[2], times[4]);
    }
}

/// The block the hub's prefetch attaches for `prompt` in `dir` (`hub/prefetch.rs`).
fn prefetch_block(dir: &Path, prompt: &str) -> Value {
    crate::hub::prefetch::plan(prompt, dir, None, true).expect("a prefetch").block
}

fn seeded(d: &Dedupe, block: &Value, now: Instant) {
    let files =
        attached(block).into_iter().filter_map(|a| attached_fingerprint(&a).map(|f| (a, f)));
    d.seed_prefetch(files.collect(), now);
}

#[test]
fn a_prefetch_block_names_its_files_with_lines_and_blob() {
    let dir = tempfile::tempdir().unwrap();
    let f = file(dir.path(), "a.txt", &"line\n".repeat(30));
    let g = file(dir.path(), "b.rs", &"fn x() {}\n".repeat(400));
    let block = prefetch_block(dir.path(), "read a.txt and b.rs:200");
    let files = attached(&block);
    assert_eq!(files.len(), 2, "{files:?}");
    let a = files.iter().find(|a| a.path == std::fs::canonicalize(&f).unwrap()).unwrap();
    assert_eq!((a.ranges.clone(), a.total_lines), (vec![(1, 30)], 30));
    assert_eq!(a.blob, crate::hub::prefetch::blob_hash(&std::fs::read(&f).unwrap()));
    let b = files.iter().find(|a| a.path == std::fs::canonicalize(&g).unwrap()).unwrap();
    assert_eq!((b.ranges.clone(), b.total_lines), (vec![(120, 280)], 400));
    // The marks are the hub's: the same text from anywhere else is not an attachment.
    let mut unmarked = block.clone();
    unmarked["_meta"]["acpmux"]["prefetch"] = json!(false);
    assert!(attached(&unmarked).is_empty());
    assert!(attached(&json!({"type": "text", "text": block["text"]})).is_empty());
}

#[test]
fn a_read_of_an_attached_unchanged_file_is_stubbed_back_to_the_attachment() {
    let dir = tempfile::tempdir().unwrap();
    let f = std::fs::canonicalize(file(dir.path(), "a.txt", &"line\n".repeat(30))).unwrap();
    let d = Dedupe::default();
    let now = Instant::now();
    seeded(&d, &prefetch_block(dir.path(), "read a.txt"), now);
    let s = call(&d, "1", "", &read(&f, None, None), "x", now).expect("stubbed");
    assert_eq!(s, prefetch_stub());
    let n = d.turn_ended();
    assert_eq!((n.reads_stubbed, n.reads_stubbed_prefetched), (1, 1));
    assert!(n.est_tokens_saved > 0, "{n:?}");
    // Once: the model that asks again gets the Read.
    assert_eq!(call(&d, "2", "", &read(&f, None, None), "x", now), None);
    // A subagent's context does not hold the attachment.
    let d = Dedupe::default();
    seeded(&d, &prefetch_block(dir.path(), "read a.txt"), now);
    assert_eq!(call(&d, "3", "sub-1", &read(&f, None, None), "x", now), None);
}

#[test]
fn a_window_covers_reads_inside_it_only() {
    let dir = tempfile::tempdir().unwrap();
    let f = std::fs::canonicalize(file(dir.path(), "b.rs", &"x\n".repeat(400))).unwrap();
    let d = Dedupe::default();
    let now = Instant::now();
    seeded(&d, &prefetch_block(dir.path(), "see b.rs:200"), now);
    // Each Read that runs is entered itself, so the order matters: inside, outside, whole.
    let s = call(&d, "1", "", &read(&f, Some(150), Some(50)), "x", now).expect("inside");
    assert_eq!(s, prefetch_stub());
    assert_eq!(call(&d, "2", "", &read(&f, Some(100), Some(50)), "x", now), None, "outside runs");
    assert_eq!(call(&d, "3", "", &read(&f, None, None), "x", now), None, "the whole file runs");
}

#[test]
fn a_file_changed_since_its_attachment_is_not_entered() {
    let dir = tempfile::tempdir().unwrap();
    let f = std::fs::canonicalize(file(dir.path(), "a.txt", "one\n")).unwrap();
    let d = Dedupe::default();
    let now = Instant::now();
    let block = prefetch_block(dir.path(), "read a.txt");
    std::fs::write(&f, "two\n").unwrap();
    seeded(&d, &block, now);
    assert_eq!(call(&d, "1", "", &read(&f, None, None), "x", now), None);
    // Changed after it was entered: the fingerprint no longer matches.
    let d = Dedupe::default();
    let block = prefetch_block(dir.path(), "read a.txt");
    seeded(&d, &block, now);
    std::fs::write(&f, "three, longer\n").unwrap();
    assert_eq!(call(&d, "2", "", &read(&f, None, None), "x", now), None);
    // A compaction or an idle gap forgets it.
    let d = Dedupe::default();
    seeded(&d, &prefetch_block(dir.path(), "read a.txt"), now);
    d.reset();
    assert_eq!(call(&d, "3", "", &read(&f, None, None), "x", now), None);
    let d = Dedupe::default();
    seeded(&d, &prefetch_block(dir.path(), "read a.txt"), now);
    let later = now + Duration::from_secs(301);
    assert_eq!(call(&d, "4", "", &read(&f, None, None), "x", later), None);
}

#[tokio::test]
async fn the_translator_enters_a_prompts_prefetch_and_stubs_its_read() {
    super::dedupe::ON_FOR_TEST.with(|on| on.set(true));
    let dir = tempfile::tempdir().unwrap();
    let f = std::fs::canonicalize(file(dir.path(), "a.txt", "hello\n")).unwrap();
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let block = prefetch_block(dir.path(), "read a.txt");
    let prompt = Message::request(
        1,
        method::SESSION_PROMPT,
        json!({"sessionId": "acp-1", "prompt": [{"type": "text", "text": "read a.txt"}, block]}),
    );
    let Outbound::Lines(_) = t.outbound(&prompt).await else { panic!("a prompt written") };
    t.inbound(&json!({"type": "control_request", "request_id": "h1", "request": {
        "subtype": "hook_callback", "callback_id": super::dedupe::DEDUPE_CALLBACK,
        "tool_use_id": "u1",
        "input": {"session_id": "s", "cwd": "/", "hook_event_name": "PreToolUse",
            "tool_name": "Read", "tool_use_id": "u1",
            "tool_input": {"file_path": f.to_str().unwrap()}}}}))
        .await;
    let replies = t.take_stdin_replies().await;
    let out = replies[0].pointer("/response/response/hookSpecificOutput").expect("a decision");
    assert_eq!(out["permissionDecision"], "deny");
    assert_eq!(out["permissionDecisionReason"], prefetch_stub());
    assert_eq!(t.dedupe.turn_ended().reads_stubbed_prefetched, 1);
}
