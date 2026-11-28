//! Harness magic `pathRules` (`path_rules.rs`).

use super::path_rules::{self, Counters, PathRules, covers, find_root, load, parse};
use super::*;
use std::path::PathBuf;

fn repo(rules: &[(&str, &str)]) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    std::fs::create_dir(dir.path().join(".git")).unwrap();
    let rules_dir = dir.path().join(path_rules::RULES_DIR);
    std::fs::create_dir_all(&rules_dir).unwrap();
    for (name, text) in rules {
        std::fs::write(rules_dir.join(name), text).unwrap();
    }
    dir
}

fn touch(file: &std::path::Path, agent: Option<&str>) -> Value {
    let mut input = json!({
        "hook_event_name": "PostToolUse",
        "tool_name": "Read",
        "tool_input": {"file_path": file.to_str().unwrap()},
        "cwd": "/",
    });
    if let Some(a) = agent {
        input.set("agent_id", json!(a));
    }
    input
}

const RUST: &str =
    "---\npaths: [\"cmux-tui/**/*.rs\", 'docs/acpmux/*.md']\n---\nNew logic is Rust.\n";

#[test]
fn front_matter_forms_all_name_paths() {
    let inline = parse("a", RUST).unwrap();
    assert_eq!(inline.paths.len(), 2);
    assert_eq!(inline.body, "New logic is Rust.");
    let one = parse("b", "---\npaths: web/**\n---\nbody").unwrap();
    assert!(covers(&one, "web/src/app.tsx"));
    let commas = parse("c", "---\ntitle: x\npaths: a/*.rs, ./b/**\n---\nbody").unwrap();
    assert!(covers(&commas, "a/x.rs") && covers(&commas, "b/y/z"));
    let block =
        parse("d", "---\npaths:\n  - \"a/**\"\n  - b/*.md\ndescription: y\n---\r\nbody").unwrap();
    assert_eq!(block.paths.len(), 2);
    assert!(covers(&block, "b/x.md") && !covers(&block, "c/x.md"));
}

#[test]
fn a_file_with_no_paths_front_matter_or_body_is_no_path_rule() {
    assert!(parse("a", "No front matter.").is_none());
    assert!(parse("a", "---\ntitle: x\n---\nbody").is_none());
    assert!(parse("a", "---\npaths: a/**\n---\n  \n").is_none());
    assert!(parse("a", "---\npaths: a/**\nbody, never closed").is_none());
}

#[test]
fn one_star_stays_in_its_folder_two_cross() {
    let rule = parse("a", "---\npaths: [docs/*.md, src/**]\n---\nbody").unwrap();
    assert!(covers(&rule, "docs/a.md"));
    assert!(!covers(&rule, "docs/deep/a.md"));
    assert!(covers(&rule, "src/a/b/c.rs"));
    assert!(!covers(&rule, "other/src/a.rs"));
}

#[test]
fn the_root_is_the_nearest_folder_with_rules_and_stops_at_a_repo() {
    let r = repo(&[("rust.md", RUST)]);
    let file = r.path().join("cmux-tui/crates/x.rs");
    let (root, rel) = find_root(&file).unwrap();
    assert_eq!(root, r.path());
    assert_eq!(rel, "cmux-tui/crates/x.rs");
    // A repo with no rules of its own, inside a folder that has some, stops at its `.git`.
    let inner = r.path().join("vendor/other");
    std::fs::create_dir_all(inner.join(".git")).unwrap();
    assert!(find_root(&inner.join("src/a.rs")).is_none());
}

#[test]
fn load_skips_other_files_oversized_and_malformed_rules() {
    let big = format!("---\npaths: a/**\n---\n{}", "x".repeat(20 * 1024));
    let r = repo(&[
        ("b.md", RUST),
        ("a.md", "---\npaths: a/**\n---\nA."),
        ("notes.txt", "---\npaths: a/**\n---\nnot md"),
        ("big.md", &big),
        ("none.md", "just text"),
    ]);
    let ids: Vec<String> = load(r.path()).into_iter().map(|r| r.id).collect();
    assert_eq!(ids, ["a", "b"]);
}

#[test]
fn a_rule_is_said_once_per_context_and_again_after_a_reset() {
    let r = repo(&[("rust.md", RUST), ("docs.md", "---\npaths: docs/**\n---\nDocs rule.")]);
    let rules = PathRules::default();
    let file = r.path().join("cmux-tui/src/lib.rs");
    let said = rules.context_for(&touch(&file, None)).unwrap();
    assert!(said.contains("New logic is Rust."), "{said}");
    assert!(said.contains(".agents/rules/rust.md") && said.contains("cmux-tui/src/lib.rs"));
    assert!(!said.contains("Docs rule."));
    // The same context, another covered file: nothing new.
    assert!(rules.context_for(&touch(&r.path().join("cmux-tui/a.rs"), None)).is_none());
    // A subagent's context is its own.
    assert!(rules.context_for(&touch(&file, Some("agent-1"))).is_some());
    assert!(rules.context_for(&touch(&file, Some("agent-1"))).is_none());
    // A file no rule covers says nothing.
    assert!(rules.context_for(&touch(&r.path().join("README.md"), None)).is_none());
    let counts = rules.turn_ended();
    assert_eq!(counts.fired, 2);
    assert!(counts.said_chars > 0);
    assert_eq!(rules.turn_ended(), Counters::default());
    // A compaction or `/clear` drops it from the context.
    rules.reset();
    assert!(rules.context_for(&touch(&file, None)).is_some());
}

#[test]
fn a_relative_path_resolves_from_the_hooks_cwd_and_notebooks_count() {
    let r = repo(&[("nb.md", "---\npaths: \"**/*.ipynb\"\n---\nNotebook rule.")]);
    let rules = PathRules::default();
    let input = json!({
        "hook_event_name": "PostToolUse",
        "tool_name": "NotebookEdit",
        "tool_input": {"notebook_path": "analysis/a.ipynb"},
        "cwd": r.path().to_str().unwrap(),
    });
    assert!(rules.context_for(&input).unwrap().contains("Notebook rule."));
}

#[test]
fn rules_past_the_cap_wait_for_the_next_touch() {
    let long = format!("---\npaths: a/**\n---\n{}", "y".repeat(path_rules::MAX_SAY - 200));
    let r = repo(&[("1.md", &long), ("2.md", &long)]);
    let rules = PathRules::default();
    let file = r.path().join("a/x");
    let first = rules.context_for(&touch(&file, None)).unwrap();
    assert!(first.contains("rules/1.md") && !first.contains("rules/2.md"));
    assert_eq!(rules.turn_ended().deferred, 1);
    let second = rules.context_for(&touch(&file, None)).unwrap();
    assert!(second.contains("rules/2.md"));
}

#[test]
fn the_hook_answers_additional_context_only_after_a_call() {
    let r = repo(&[("rust.md", RUST)]);
    let rules = PathRules::default();
    let file = r.path().join("cmux-tui/a.rs");
    let mut pre = touch(&file, None);
    pre.set("hook_event_name", json!("PreToolUse"));
    assert_eq!(path_rules::output(&rules, &pre), json!({}));
    let out = path_rules::output(&rules, &touch(&file, None));
    assert_eq!(out["hookSpecificOutput"]["hookEventName"], "PostToolUse");
    assert!(out["hookSpecificOutput"]["additionalContext"].as_str().unwrap().contains("Rust"));
    // No repo rules, no tool path: nothing, and no error.
    let none = PathRules::default();
    let bare = json!({"hook_event_name": "PostToolUse", "tool_input": {}, "cwd": "/"});
    assert_eq!(path_rules::output(&none, &bare), json!({}));
    let elsewhere = tempfile::tempdir().unwrap();
    std::fs::create_dir(elsewhere.path().join(".git")).unwrap();
    let outside = touch(&PathBuf::from(elsewhere.path()).join("a.rs"), None);
    assert_eq!(path_rules::output(&none, &outside), json!({}));
}

#[test]
fn initialize_registers_the_hook_after_tool_calls_while_on() {
    let request = outbound::initialize_request(false);
    let registered = request["hooks"]["PostToolUse"]
        .as_array()
        .into_iter()
        .flatten()
        .any(|e| e["hookCallbackIds"] == json!([path_rules::PATH_RULES_CALLBACK]));
    assert_eq!(registered, path_rules::enabled());
}

#[test]
fn the_turns_counts_name_the_feature() {
    let c = Counters { fired: 2, said_chars: 90, deferred: 1 };
    assert_eq!(c.to_json(), json!({"fired": 2, "saidChars": 90, "deferred": 1}));
    assert_eq!(path_rules::FEATURE, "pathRules");
    assert!(crate::hub::harness_magic::FEATURES.iter().any(|f| f.name == path_rules::FEATURE));
}
