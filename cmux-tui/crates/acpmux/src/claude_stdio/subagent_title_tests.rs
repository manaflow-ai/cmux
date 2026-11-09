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
