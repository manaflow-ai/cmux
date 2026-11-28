//! Harness magic `dirRules` (`dir_rules.rs`).

use super::dir_rules::{DIR_RULES_CALLBACK, MAX_FILE_BYTES, enabled_in, rules_for, touched_path};
use super::*;
use std::collections::HashSet;
use std::path::PathBuf;

/// A repo: root rules loaded by a `CLAUDE.md` link, `pkg/` with a pointer `CLAUDE.md` (the case
/// Claude Code never follows), `web/` importing its own, `pkg/deep/` with rules and no `CLAUDE.md`.
fn repo() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    let r = dir.path();
    std::fs::create_dir_all(r.join(".git")).unwrap();
    std::fs::create_dir_all(r.join("pkg/deep")).unwrap();
    std::fs::create_dir_all(r.join("web")).unwrap();
    std::fs::write(r.join("AGENTS.md"), "root rules\n").unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink("AGENTS.md", r.join("CLAUDE.md")).unwrap();
    #[cfg(not(unix))]
    std::fs::write(r.join("CLAUDE.md"), "@AGENTS.md\n").unwrap();
    std::fs::write(r.join("pkg/AGENTS.md"), "pkg rules\n").unwrap();
    std::fs::write(r.join("pkg/CLAUDE.md"), "Read and follow `AGENTS.md` in this directory.\n")
        .unwrap();
    std::fs::write(r.join("pkg/deep/AGENTS.md"), "deep rules\n").unwrap();
    std::fs::write(r.join("pkg/deep/a.rs"), "fn a() {}\n").unwrap();
    std::fs::write(r.join("web/AGENTS.md"), "web rules\n").unwrap();
    std::fs::write(r.join("web/CLAUDE.md"), "@AGENTS.md\n").unwrap();
    std::fs::write(r.join("web/x.ts"), "x\n").unwrap();
    dir
}

fn texts(rules: &[super::dir_rules::Rule]) -> Vec<String> {
    rules.iter().map(|r| r.text.trim().to_owned()).collect()
}

#[test]
fn the_rules_claude_code_does_not_load_come_outermost_first() {
    let dir = repo();
    let r = dir.path();
    let rules = rules_for(&r.join("pkg/deep/a.rs"), &HashSet::new());
    assert_eq!(texts(&rules), ["pkg rules", "deep rules"]);
    // A directory touched itself (Grep, Glob) counts as under itself.
    assert_eq!(texts(&rules_for(&r.join("pkg"), &HashSet::new())), ["pkg rules"]);
    // Imported or linked by the directory's CLAUDE.md: Claude Code loads it already.
    assert!(rules_for(&r.join("web/x.ts"), &HashSet::new()).is_empty());
    assert!(rules_for(&r.join("README.md"), &HashSet::new()).is_empty());
}

#[test]
fn a_shown_directory_or_a_path_outside_a_repo_shows_nothing() {
    let dir = repo();
    let r = dir.path();
    let seen: HashSet<PathBuf> = [r.join("pkg")].into();
    assert_eq!(texts(&rules_for(&r.join("pkg/deep/a.rs"), &seen)), ["deep rules"]);
    let loose = tempfile::tempdir().unwrap();
    std::fs::write(loose.path().join("AGENTS.md"), "not a repo\n").unwrap();
    assert!(rules_for(&loose.path().join("f"), &HashSet::new()).is_empty());
}

#[test]
fn a_long_file_is_cut_with_its_path() {
    let dir = repo();
    let r = dir.path();
    std::fs::write(r.join("pkg/AGENTS.md"), "é".repeat(MAX_FILE_BYTES)).unwrap();
    let rules = rules_for(&r.join("pkg/x"), &HashSet::new());
    assert!(rules[0].text.len() < MAX_FILE_BYTES + 200, "{}", rules[0].text.len());
    assert!(
        rules[0].text.ends_with(&format!("the rest is in {}]", r.join("pkg/AGENTS.md").display()))
    );
}

#[test]
fn the_touched_path_comes_from_the_tool_input() {
    let input = |args: Value| json!({"cwd": "/repo", "tool_input": args});
    assert_eq!(touched_path(&input(json!({"file_path": "/a/b.rs"}))), Some("/a/b.rs".into()));
    assert_eq!(
        touched_path(&input(json!({"notebook_path": "n.ipynb"}))),
        Some("/repo/n.ipynb".into())
    );
    assert_eq!(
        touched_path(&input(json!({"pattern": "x", "path": "src"}))),
        Some("/repo/src".into())
    );
    assert_eq!(touched_path(&input(json!({"pattern": "x"}))), None);
}

#[test]
fn off_unless_the_setting_says_true_and_registered_only_when_on() {
    assert!(!enabled_in(None));
    assert!(!enabled_in(Some(
        &json!({"agents": {"harnessMagic": {"dirRules": {"enabled": false}}}})
    )));
    assert!(enabled_in(Some(
        &json!({"agents": {"harnessMagic": {"dirRules": {"enabled": true}}}})
    )));
    let registered = |req: &Value| {
        req.pointer("/hooks/PostToolUse").and_then(Value::as_array).is_some_and(|hooks| {
            hooks.iter().any(|h| h["hookCallbackIds"][0] == DIR_RULES_CALLBACK)
        })
    };
    super::dir_rules::ON_FOR_TEST.with(|on| on.set(true));
    assert!(registered(&outbound::initialize_request(false)));
    super::dir_rules::ON_FOR_TEST.with(|on| on.set(false));
}

/// Through the translator: the first touch gets the rules, the second nothing, a subagent its
/// own, a compaction resets, and the turn counts them.
#[tokio::test]
async fn the_translator_shows_a_directory_once_per_context() {
    super::dir_rules::ON_FOR_TEST.with(|on| on.set(true));
    let dir = repo();
    let file = dir.path().join("pkg/deep/a.rs");
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let hook = |rid: &str, agent: Option<&str>| {
        let mut input = json!({"session_id": "s", "cwd": "/", "hook_event_name": "PostToolUse",
            "tool_name": "Read", "tool_use_id": rid,
            "tool_input": {"file_path": file.to_str().unwrap()},
            "tool_response": {"type": "text"}});
        if let Some(a) = agent {
            input.set("agent_id", json!(a));
        }
        json!({"type": "control_request", "request_id": rid, "request": {
            "subtype": "hook_callback", "callback_id": DIR_RULES_CALLBACK, "input": input}})
    };
    let context = |replies: Vec<Value>| {
        replies[0]
            .pointer("/response/response/hookSpecificOutput/additionalContext")
            .and_then(Value::as_str)
            .map(str::to_owned)
    };
    t.inbound(&hook("h1", None)).await;
    let first = context(t.take_stdin_replies().await).expect("the rules");
    assert!(first.contains("pkg rules") && first.contains("deep rules"), "{first}");
    assert!(first.find("pkg rules") < first.find("deep rules"));
    t.inbound(&hook("h2", None)).await;
    assert_eq!(context(t.take_stdin_replies().await), None);
    t.inbound(&hook("h3", Some("sub-1"))).await;
    assert!(context(t.take_stdin_replies().await).is_some(), "a subagent's context is its own");
    let counts = t.dir_rules.turn_ended();
    assert_eq!(counts.files_injected, 4);
    t.dir_rules.reset();
    t.inbound(&hook("h4", None)).await;
    assert!(context(t.take_stdin_replies().await).is_some(), "shown again after a compaction");
    super::dir_rules::ON_FOR_TEST.with(|on| on.set(false));
}
