//! A Claude Code subagent's Bash command carries the hook's mark line first
//! (`bg_hook::subagent_mark`); its tool card shows the command as written.

use super::*;

#[test]
fn caller_identity_a_marked_bash_call_is_titled_as_written() {
    let mark = "export ACPMUX_CALLER_SUBAGENT=general-purpose:a0a68e7af3df5967e\n";
    let input = json!({"command": format!("{mark}./scripts/tell beta hi")});
    assert_eq!(tool_title("Bash", &input), "./scripts/tell beta hi");
    let plain = json!({"command": "export X=1\nls"});
    assert_eq!(tool_title("Bash", &plain), "export X=1", "only the hook's own mark is passed over");
}

#[test]
fn pleasant_tool_labels_preserve_input_and_tool_identity() {
    let command = "timeout 30 acpmux session inbox 123";
    for (name, input, expected) in [
        ("Bash", json!({"command": command, "description": " Read the inbox "}), "Read the inbox"),
        ("Bash", json!({"command": command, "description": "  "}), command),
        ("Read", json!({"file_path": "/src/foo.ts"}), "Read foo.ts"),
        ("Edit", json!({"file_path": "/src/foo.ts"}), "Edit foo.ts"),
        ("Grep", json!({"pattern": "TODO"}), "Search for TODO"),
        ("mcp__repo__search", json!({"description": "Find follow-ups"}), "mcp__repo__search"),
    ] {
        let call = tool_call_fields(name, &input);
        assert_eq!(call["title"], expected);
        assert_eq!(call["rawInput"], input);
        assert_eq!(call["_meta"]["claude"]["tool"], name);
    }
    // The permission prompt still names the action awaiting approval.
    assert_eq!(
        tool_title("Bash", &json!({"command": command, "description": "Read the inbox"})),
        command
    );
}
