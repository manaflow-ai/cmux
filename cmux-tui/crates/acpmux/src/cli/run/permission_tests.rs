use super::*;

fn refusal(session: &str) -> String {
    let refused =
        crate::client::DaemonError(crate::hub::person::person_required("allowing a permission"));
    format!("{:#}", explain_person_required(refused.into(), session))
}

/// The refusal of a CLI allow names a policy only when that policy covers
/// what the agent asks next. Codex sends every command, its reads too, as
/// `execute`, which approve-reads and approve-edits still ask about, so the
/// tool prompt after the next start waited again (ergo-walk2, 2026-10-25).
#[test]
fn the_allow_refusal_names_no_policy_that_still_asks_for_shell_commands() {
    let text = refusal("my-linux/api-work");
    assert!(!text.contains("--policy approve-edits"), "{text}");
    assert!(!text.contains("--policy approve-reads"), "{text}");
    assert!(text.contains("--policy approve-all"), "{text}");
    assert!(text.contains("shell command"), "{text}");
    assert!(text.contains("in the cmux app"), "{text}");
    assert!(text.contains("`acpmux deny my-linux/api-work`"), "{text}");
    assert!(!text.contains("acpmux session allow"), "{text}");
}
