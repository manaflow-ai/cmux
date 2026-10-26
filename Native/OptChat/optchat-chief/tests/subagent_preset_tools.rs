//! A Claude subagent runs in the folder its task names (a repository), so the
//! subagent folder's project settings, and their deny list, never reach it:
//! a 2026-10-23 subagent was offered Agent, Workflow and AskUserQuestion,
//! about 3.5k prompt tokens of tools it must not use on every request. The
//! preset denies them by argument, wherever the subagent runs, and keeps
//! the user's own settings (subagents do real work).

use optchat_chief::acpmux::Family;
use optchat_chief::host::subagent_preset;

fn preset(family: Family) -> optchat_chief::acpmux::Preset {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("mux");
    let paths = optchat_chief::paths::Paths::new(&home);
    subagent_preset(
        &paths,
        &home,
        "optchat-sub-x".into(),
        "claude",
        family,
        true,
        "SUB",
        &Default::default(),
    )
}

fn denied(args: &[String]) -> Vec<String> {
    let at = args
        .iter()
        .position(|a| a == "--disallowedTools")
        .unwrap_or_else(|| panic!("no --disallowedTools in {args:?}"));
    args[at + 1].split(',').map(str::to_owned).collect()
}

#[test]
fn a_claude_subagent_is_denied_its_own_subagents_and_human_waits_anywhere() {
    let sub = preset(Family::Claude);
    let denied = denied(&sub.args);
    for tool in [
        "Task",
        "Agent",
        "AskUserQuestion",
        "EnterPlanMode",
        "ExitPlanMode",
        "Workflow",
        // The cmux app's 584 menu-action tools (the `cmux action` CLI keeps
        // them): 11.4k of a bare subagent's 36.3k prompt tokens, measured
        // 2026-10-23 on Claude Code 2.1.305.
        "mcp__cmux__app_*",
    ] {
        assert!(denied.iter().any(|d| d == tool), "{tool} not in {denied:?}");
    }
    for kept in ["Bash", "Read", "Edit", "Write", "Skill", "ToolSearch"] {
        assert!(
            !denied.iter().any(|d| d == kept),
            "{kept} denied: {denied:?}"
        );
    }
    // The user's own settings still load: no setting-source limit.
    assert!(
        !sub.args.iter().any(|a| a == "--setting-sources"),
        "{:?}",
        sub.args
    );
}

#[test]
fn a_codex_subagent_gets_no_claude_args() {
    assert!(preset(Family::Codex).args.is_empty());
}
