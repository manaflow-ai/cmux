//! The chat's own start tools: their list, argv and params.

use super::*;

#[test]
fn a_sessions_chat_lists_the_start_tools_once() {
    let all = super::super::tools();
    let names: Vec<&str> = crate::mcp_hint::names(&all).collect();
    for tool in TOOLS {
        assert_eq!(names.iter().filter(|n| *n == tool).count(), 1, "{tool}: {names:?}");
    }
    for tool in tools() {
        assert_eq!(tool["inputSchema"]["type"], "object", "{tool}");
    }
}

#[test]
fn new_runs_acpmux_new_detached_in_the_sessions_own_policy() {
    let (name, argv, prompt) = new_argv(&json!({
        "prompt": "run the suite",
        "machine": "cosmic-gray",
        "harness": "claude/opus",
        "folder": "~/src/app",
        "name": "Suite run",
    }))
    .unwrap();
    assert_eq!(name, "suite-run");
    assert_eq!(prompt, "run the suite");
    assert_eq!(
        argv,
        [
            "--json",
            "new",
            "--detach",
            "--name",
            "suite-run",
            "--model",
            "claude/opus",
            "--machine",
            "cosmic-gray",
            "--cwd",
            "~/src/app",
            "--prompt-file",
            "-"
        ]
    );
    // The session's CLI decides the policy, as from its shell: no forced `ask`, unlike a guest.
    assert!(!argv.iter().any(|w| w == "--policy" || w == "--require-asking"));
}

#[test]
fn new_refuses_no_prompt_and_a_word_that_reads_as_a_flag() {
    assert!(new_argv(&json!({})).is_err());
    assert!(new_argv(&json!({"prompt": "  "})).is_err());
    for key in ["machine", "harness", "folder", "name"] {
        let err = new_argv(&json!({"prompt": "x", key: "--policy=bypass"})).unwrap_err();
        assert!(err.contains(key), "{err}");
    }
    let (name, argv, _) = new_argv(&json!({"prompt": "x"})).unwrap();
    assert!(name.starts_with("chat-"), "{name}");
    assert!(!argv.iter().any(|w| w == "--machine"));
}

#[test]
fn fork_sends_what_acpmux_session_fork_sends() {
    let p = fork_params(
        "cosmic-gray/01abc",
        &json!({"chat": "cosmic-gray/coord", "name": "coord-alt", "folder": "/tmp/x", "harness": "codex"}),
    );
    assert_eq!(
        p,
        json!({
            "sessionId": "cosmic-gray/01abc",
            "mcpServers": [],
            "_meta": {"acpmux": {"name": "coord-alt", "harness": "codex"}},
            "cwd": "/tmp/x",
        })
    );
    assert_eq!(
        fork_params("x", &json!({"chat": "x"})),
        json!({"sessionId": "x", "mcpServers": [], "_meta": {"acpmux": {}}})
    );
}

#[test]
fn machine_start_resumes_a_named_machine_or_makes_a_new_one() {
    assert_eq!(
        machine_start_argv(&json!({"machine": "dev-box", "size": "large"})).unwrap(),
        ["vm", "resume", "dev-box", "--json"]
    );
    assert_eq!(
        machine_start_argv(&json!({"name": "ci", "size": "large", "repo": "o/r@main"})).unwrap(),
        ["vm", "new", "--name", "ci", "--size", "large", "--repo", "o/r@main", "--json"]
    );
    assert_eq!(machine_start_argv(&json!({})).unwrap(), ["vm", "new", "--json"]);
    assert!(machine_start_argv(&json!({"machine": "-rf"})).is_err());
}
