//! Harness magic `dedupe` for Codex (`codex_dedupe.rs`).

use super::*;
use serde_json::json;
use std::time::Instant;

/// A Codex hook payload as 0.172.0 sends it (captured 2026-11-27), trimmed to what is read.
fn payload(event: &str, turn: &str, cwd: &Path, command: &str, id: &str) -> Value {
    let mut v = json!({
        "session_id": "s", "turn_id": turn, "cwd": cwd, "hook_event_name": event,
        "tool_name": "Bash", "tool_input": {"command": command}, "tool_use_id": id,
    });
    if event == "PostToolUse" {
        v["tool_response"] = json!("out\n");
    }
    v
}

/// One call through the table: the stub, or `None` after it ran and its result was recorded.
fn run(table: &mut Table, turn: &str, cwd: &Path, command: &str, id: &str) -> Option<String> {
    let stub = decide("pre", &payload("PreToolUse", turn, cwd, command, id), table);
    if stub.is_none() {
        decide("post", &payload("PostToolUse", turn, cwd, command, id), table);
    }
    stub
}

fn checkout() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("probe.txt"), "hello\n").unwrap();
    dir
}

#[test]
fn a_repeat_in_the_turn_is_refused_once_with_claudes_stub() {
    let dir = checkout();
    let mut table = Table::default();
    assert_eq!(run(&mut table, "t1", dir.path(), "cat probe.txt", "a"), None);
    let stub = run(&mut table, "t1", dir.path(), "cat probe.txt", "b").expect("a stub");
    assert!(stub.starts_with("[dedupe] `cat probe.txt` ran 1 call ago"), "{stub}");
    assert_eq!(run(&mut table, "t1", dir.path(), "cat probe.txt", "c"), None, "asking again runs");
    assert_eq!(table.stubbed, 1);
}

#[test]
fn another_turn_a_changed_input_or_another_folder_runs() {
    let dir = checkout();
    let other = checkout();
    let mut table = Table::default();
    assert_eq!(run(&mut table, "t1", dir.path(), "cat probe.txt", "a"), None);
    assert_eq!(run(&mut table, "t2", dir.path(), "cat probe.txt", "b"), None, "a new turn");
    assert_eq!(run(&mut table, "t2", other.path(), "cat probe.txt", "c"), None, "another folder");
    std::fs::write(dir.path().join("probe.txt"), "changed, longer\n").unwrap();
    assert_eq!(run(&mut table, "t2", dir.path(), "cat probe.txt", "d"), None, "a changed file");
    assert_eq!(table.stubbed, 0);
}

#[test]
fn only_read_only_commands_are_recorded() {
    let dir = checkout();
    let mut table = Table::default();
    for id in ["a", "b"] {
        assert_eq!(run(&mut table, "t1", dir.path(), "touch probe.txt", id), None);
        assert_eq!(run(&mut table, "t1", dir.path(), "sh -c 'cat probe.txt'", id), None);
    }
    assert!(table.seen.is_empty() && table.pending.is_empty(), "{table:?}");
}

#[test]
fn a_grep_or_glob_call_is_not_taken() {
    let dir = checkout();
    let mut table = Table::default();
    for (tool, input) in
        [("Grep", json!({"pattern": "hello"})), ("Glob", json!({"pattern": "*.txt"}))]
    {
        for (event, id) in [("pre", "a"), ("post", "a"), ("pre", "b")] {
            let mut v = payload(
                if event == "pre" { "PreToolUse" } else { "PostToolUse" },
                "t1",
                dir.path(),
                "",
                id,
            );
            v["tool_name"] = json!(tool);
            v["tool_input"] = input.clone();
            assert_eq!(decide(event, &v, &mut table), None, "{tool}");
        }
    }
    assert!(table.seen.is_empty() && table.pending.is_empty(), "{table:?}");
}

#[test]
fn a_call_with_no_result_or_a_moved_input_is_not_recorded() {
    let dir = checkout();
    let mut table = Table::default();
    // PreToolUse only: Codex never ran it (another hook refused, the person declined).
    decide("pre", &payload("PreToolUse", "t1", dir.path(), "cat probe.txt", "a"), &mut table);
    assert_eq!(run(&mut table, "t1", dir.path(), "wc probe.txt", "b"), None);
    assert!(run(&mut table, "t1", dir.path(), "cat probe.txt", "c").is_none());
    // The file changed while it ran: its output may be either, so it is not recorded.
    decide("pre", &payload("PreToolUse", "t1", dir.path(), "head probe.txt", "d"), &mut table);
    std::fs::write(dir.path().join("probe.txt"), "moved mid-call\n").unwrap();
    decide("post", &payload("PostToolUse", "t1", dir.path(), "head probe.txt", "d"), &mut table);
    assert_eq!(run(&mut table, "t1", dir.path(), "head probe.txt", "e"), None);
}

#[test]
fn compaction_drops_the_table() {
    let dir = checkout();
    let mut table = Table::default();
    assert_eq!(run(&mut table, "t1", dir.path(), "cat probe.txt", "a"), None);
    decide("compact", &json!({"session_id": "s", "turn_id": "t1"}), &mut table);
    assert_eq!(run(&mut table, "t1", dir.path(), "cat probe.txt", "b"), None);
}

#[test]
fn the_table_file_is_per_session_and_survives_between_hooks() {
    let dir = checkout();
    let tables = tempfile::tempdir().unwrap();
    let input = payload("PreToolUse", "t1", dir.path(), "cat probe.txt", "a");
    let path = table_path(tables.path(), &input).unwrap();
    let mut other = input.clone();
    other["session_id"] = json!("s2");
    assert_ne!(Some(path.clone()), table_path(tables.path(), &other));
    assert_eq!(table_path(tables.path(), &json!({"session_id": ""})), None);
    let step = |event: &str, hook: &str, id: &str| {
        let input = payload(hook, "t1", dir.path(), "cat probe.txt", id);
        with_table(&path, |t| decide(event, &input, t)).unwrap()
    };
    assert_eq!(step("pre", "PreToolUse", "a"), None);
    assert_eq!(step("post", "PostToolUse", "a"), None);
    assert!(step("pre", "PreToolUse", "b").is_some(), "the second hook process reads the first's");
    std::fs::write(&path, "not json").unwrap();
    assert_eq!(step("pre", "PreToolUse", "c"), None, "an unreadable table starts empty");
}

#[test]
fn the_launch_hooks_run_this_binary_per_event_and_share_pre_tool_use_with_the_gate() {
    let exe = "/opt/cmux/bin/cmux-tui";
    let prefix = vec!["acp".to_owned()];
    let dedupe = hooks(exe, &prefix, Path::new("/home/u/.acpmux/codex-dedupe"));
    let events: Vec<&str> = dedupe.iter().map(|(e, _, _)| e.as_str()).collect();
    assert_eq!(events, ["PreToolUse", "PostToolUse", "PostCompact", "SessionEnd"]);
    assert_eq!(
        dedupe[0].1,
        "'/opt/cmux/bin/cmux-tui' 'acp' '__codex-dedupe' 'pre' '/home/u/.acpmux/codex-dedupe'"
    );
    assert!(!dedupe[0].1.contains("exit 2"), "a crash lets the call run");
    let gate = crate::codex_repo_gate::hook_command(exe, &prefix);
    let all: Vec<(String, String, u64)> =
        std::iter::once(("PreToolUse".to_owned(), gate.clone(), 90))
            .chain(dedupe.clone())
            .collect();
    let flags = crate::codex_repo_gate::hooks_flags(&all).unwrap();
    assert_eq!(&flags[..2], ["--enable", "hooks"]);
    assert_eq!(flags.len(), 2 + 2 * 5, "four events and one trust table: {flags:?}");
    let mut parsed = toml::Table::new();
    for pair in flags[2..].chunks(2) {
        assert_eq!(pair[0], "-c");
        let one: toml::Table = pair[1].parse().unwrap();
        for (k, v) in one["hooks"].as_table().unwrap() {
            parsed.insert(k.clone(), v.clone());
        }
    }
    let pre = parsed["PreToolUse"].as_array().unwrap();
    assert_eq!(pre.len(), 2, "one PreToolUse setting holds both: a second would replace it");
    assert_eq!(pre[0]["hooks"][0]["command"].as_str(), Some(gate.as_str()), "the gate first");
    assert_eq!(pre[1]["hooks"][0]["command"].as_str(), Some(dedupe[0].1.as_str()));
    // Each trust entry is the hash a lone hook of that command gets (the single-hook builder).
    let state = parsed["state"].as_table().unwrap();
    assert_eq!(state.len(), 5);
    let lone = |event: &str, command: &str, timeout: u64| -> String {
        let [_, state] =
            cmux_tui_hooks::codex_session_flag_hook_settings(event, command, timeout).unwrap();
        let state: toml::Table = state.parse().unwrap();
        let (_, entry) = state["hooks"]["state"].as_table().unwrap().iter().next().unwrap();
        entry["trusted_hash"].as_str().unwrap().to_owned()
    };
    let hash = |key: &str| state[key]["trusted_hash"].as_str().unwrap().to_owned();
    assert_eq!(
        hash("/<session-flags>/config.toml:pre_tool_use:0:0"),
        lone("PreToolUse", &gate, 90)
    );
    assert_eq!(
        hash("/<session-flags>/config.toml:pre_tool_use:1:0"),
        lone("PreToolUse", &dedupe[0].1, HOOK_TIMEOUT_SECS)
    );
    for (event, label, i) in [
        ("PostToolUse", "post_tool_use", 1),
        ("PostCompact", "post_compact", 2),
        ("SessionEnd", "session_end", 3),
    ] {
        let key = format!("/<session-flags>/config.toml:{label}:0:0");
        assert_eq!(hash(&key), lone(event, &dedupe[i].1, dedupe[i].2), "{event}");
    }
}

/// The hook's own work per call (lock, read, decide, write), the part the process spawn adds to.
#[test]
fn a_hook_step_is_well_under_a_millisecond_or_two() {
    let dir = checkout();
    let tables = tempfile::tempdir().unwrap();
    let input = payload("PreToolUse", "t1", dir.path(), "cat probe.txt", "a");
    let path = table_path(tables.path(), &input).unwrap();
    let mut times = Vec::new();
    for i in 0..200 {
        let id = format!("c{i}");
        let pre = payload("PreToolUse", "t1", dir.path(), "cat probe.txt", &id);
        let post = payload("PostToolUse", "t1", dir.path(), "cat probe.txt", &id);
        let start = Instant::now();
        let stub = with_table(&path, |t| decide("pre", &pre, t)).unwrap();
        if stub.is_none() {
            with_table(&path, |t| decide("post", &post, t)).unwrap();
        }
        times.push(start.elapsed());
    }
    times.sort();
    let (median, p90) = (times[times.len() / 2], times[times.len() * 9 / 10]);
    eprintln!("codex dedupe hook step: median {median:?}, p90 {p90:?} (n=200)");
    assert!(median < std::time::Duration::from_millis(50), "{median:?}");
}
