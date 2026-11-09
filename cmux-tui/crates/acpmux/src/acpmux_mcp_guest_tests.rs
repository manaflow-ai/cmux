//! The acpmux MCP server's guest mode: its tools and the `new` and `machines` calls.

use super::*;

fn names(tools: &Value) -> Vec<String> {
    crate::mcp_hint::names(tools).map(str::to_owned).collect()
}

#[test]
fn a_guest_gets_the_tools_that_need_no_session_and_new_and_machines() {
    assert_eq!(
        names(&tools(&tools_with_artifacts(false))),
        ["send", "ls", "last", "info", "search", "send_status", "machines", "new"]
    );
    let signed_in = names(&tools(&tools_with_artifacts(true)));
    for artifact in artifacts::TOOLS {
        assert!(signed_in.iter().any(|n| n == artifact), "{artifact}: {signed_in:?}");
    }
    for session_bound in
        ["inbox_read", "bg_start", "goal_set", "wrap_up", "watch_add", "machine_info"]
    {
        assert!(!signed_in.iter().any(|n| n == session_bound), "{session_bound}");
    }
}

#[test]
fn every_guest_tool_has_a_schema_and_the_steer_names_new() {
    for tool in tools(&tools_with_artifacts(true)).as_array().unwrap() {
        assert!(tool["inputSchema"]["type"] == "object", "{tool}");
        assert!(!tool["description"].as_str().unwrap_or_default().is_empty(), "{tool}");
    }
    assert!(STEER.contains("new starts a session"));
    assert!(STEER.len() < 2048, "Claude Code may cut instructions past 2048 characters");
}

#[test]
fn new_runs_acpmux_new_detached_with_the_apps_origin() {
    let (name, argv, prompt) = new_argv(
        "claude-desktop",
        &json!({"prompt": "fix the flaky test", "harness": "codex", "machine": "auto", "folder": "~/src/app", "name": "Flaky test fix"}),
    )
    .unwrap();
    assert_eq!(name, "flaky-test-fix");
    assert_eq!(prompt, "fix the flaky test");
    assert_eq!(
        argv,
        [
            "--json",
            "new",
            "--detach",
            "--name",
            "flaky-test-fix",
            "--model",
            "codex",
            "--machine",
            "auto",
            "--cwd",
            "~/src/app",
            "--policy",
            "ask",
            "--tag",
            "origin=claude-desktop",
            "--prompt-file",
            "-",
        ]
    );
    let (name, argv, prompt) =
        new_argv("codex", &json!({"prompt": "-rf look", "showInCmux": true})).unwrap();
    assert!(name.starts_with("codex-"), "{name}");
    let group = argv.iter().position(|a| a == "--group").unwrap();
    assert_eq!(argv[group + 1], "Codex desktop and CLI");
    // The prompt goes on stdin, never into argv, so one that looks like a flag stays the prompt.
    assert_eq!(prompt, "-rf look");
    assert!(!argv.iter().any(|a| a == "-rf look"), "{argv:?}");
}

/// Review F1 (#39320): a guest is not the person, so every session it starts asks before each
/// change, Claude and Codex alike, on this machine, a paired machine or a Cloud machine.
#[test]
fn every_session_a_guest_starts_asks_before_it_acts() {
    let policy = |argv: &[String]| {
        let at = argv.iter().position(|a| a == "--policy").expect("a --policy");
        argv[at + 1].clone()
    };
    let harnesses = [None, Some("claude"), Some("claude/opus"), Some("codex"), Some("codex/gpt-5.5")];
    let machines = [None, Some("local"), Some("auto"), Some("mac-mini"), Some("cloud-1")];
    for harness in harnesses {
        for machine in machines {
            let mut args = json!({"prompt": "run the tests"});
            if let Some(h) = harness {
                args["harness"] = json!(h);
            }
            if let Some(m) = machine {
                args["machine"] = json!(m);
            }
            let (_, argv, _) = new_argv("claude-code", &args).unwrap();
            assert_eq!(policy(&argv), "ask", "{harness:?} on {machine:?}: {argv:?}");
            assert!(!argv.iter().any(|a| a == "--mode"), "{argv:?}");
            let model = argv.iter().position(|a| a == "--model").unwrap();
            assert_eq!(argv[model + 1], harness.unwrap_or("claude"));
        }
    }
    // A harness the hub cannot hold to asking is refused, not started.
    for harness in ["opencode", "pi", "gemini/2.5"] {
        let e = new_argv("codex", &json!({"prompt": "x", "harness": harness})).unwrap_err();
        assert!(e.contains("cannot be held to asking"), "{harness}: {e}");
    }
}

#[test]
fn new_refuses_no_prompt_and_a_value_that_is_a_flag() {
    assert_eq!(new_argv("codex", &json!({})).unwrap_err(), "prompt is required");
    assert_eq!(new_argv("codex", &json!({"prompt": "  "})).unwrap_err(), "prompt is required");
    let e = new_argv("codex", &json!({"prompt": "x", "machine": "--force-admit"})).unwrap_err();
    assert!(e.contains("machine may not start with -"), "{e}");
    let e = new_argv("codex", &json!({"prompt": "x", "name": "--reuse"})).unwrap_err();
    assert!(e.contains("name may not start with -"), "{e}");
}

#[test]
fn new_answers_with_the_sessions_link() {
    let record = json!({
        "sessionId": "mac-mini/s-1",
        "name": "flaky-test-fix",
        "peer": "mac-mini",
        "harness": "claude-opus",
        "agentSessionId": "0f1e2d3c-0000-4000-8000-000000000001",
    });
    let result = new_result("flaky test fix", &record);
    let link = result["structuredContent"]["link"].as_str().unwrap();
    assert_eq!(
        link,
        "https://cmux.com/deeplink/agent?harness=claude&session=0f1e2d3c-0000-4000-8000-000000000001&host=mac-mini&name=flaky-test-fix"
    );
    assert!(text_of(&result).contains("Started flaky-test-fix on mac-mini"));
    assert_eq!(result["structuredContent"]["machine"], "mac-mini");

    let starting = new_result("x", &json!({"sessionId": "s-2", "name": "x"}));
    assert!(text_of(&starting).contains("cmux NEXT's chat list"));
    assert!(starting["structuredContent"].get("link").is_none());
}

#[test]
fn machines_reads_one_line_each_this_machine_first() {
    let list = json!({"peers": [
        {"name": "laptop", "connected": true, "link": "connected", "health": {"os": "macos", "liveSessions": 23, "load": [1.0]}, "paths": []},
        {"name": "cloud-1", "connected": false, "link": "down", "health": null},
    ]});
    let rows = machine_rows(&list);
    assert_eq!(
        rows[0],
        json!({"name": "laptop", "connected": true, "link": "connected", "os": "macos", "liveSessions": 23})
    );
    assert_eq!(
        machines_text(&rows),
        "this machine  [local]\nlaptop  [connected]  23 live sessions\ncloud-1  [down]"
    );
    assert_eq!(machines_text(&machine_rows(&json!({"peers": []}))), "this machine  [local]");
}

fn text_of(result: &Value) -> String {
    result["content"][0]["text"].as_str().unwrap_or_default().to_owned()
}
