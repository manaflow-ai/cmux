//! Every agent the Chief runs shows what it opens in one column right of
//! its chat (Lawrence 2026-10-18: "always default to a split column to the
//! right (so it's left and right and easier to manage)"), sorts its
//! workspaces into sidebar groups ("use groups more aggressively so that you
//! can organize and the user feels less overwhelmed") and pushes straight to
//! the feature branch ("we don't want to really use [PRs] at all").

use optchat_chief::prompt::{Tools, chief_system_text, subagent_system_text};

fn prompts() -> Vec<(&'static str, String)> {
    let cli = Tools::Cli("/opt/chief".into());
    vec![
        (
            "chief mcp",
            chief_system_text(None, &Tools::Mcp, false, false),
        ),
        ("chief cli", chief_system_text(None, &cli, true, true)),
        ("subagent mcp", subagent_system_text(None, &Tools::Mcp)),
        ("subagent cli", subagent_system_text(None, &cli)),
    ]
}

#[test]
fn every_agent_prompt_keeps_one_column_right_of_the_chat() {
    for (name, text) in prompts() {
        let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
        assert!(
            flat.contains("your chat on the left and one column"),
            "{name}: no right-column rule"
        );
        assert!(
            flat.contains("split --right --viewport-width 0.5"),
            "{name}: no way to make the column"
        );
        assert!(
            flat.contains("split down or add another column unless the user asks"),
            "{name}: no limit to one column"
        );
    }
}

#[test]
fn every_agent_prompt_groups_workspaces_and_pushes_without_pull_requests() {
    for (name, text) in prompts() {
        let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
        assert!(
            flat.contains("goes into a group named by its topic"),
            "{name}: no group rule"
        );
        assert!(
            flat.contains("cmux workspace group create --name NAME"),
            "{name}: no way to make a group"
        );
        assert!(
            flat.contains("Never close or rename the user's workspaces to group them"),
            "{name}"
        );
        assert!(
            flat.contains("no pull requests unless the user asks"),
            "{name}: no push rule"
        );
        assert!(flat.contains("never force"), "{name}");
    }
}

#[test]
fn each_rule_appears_once_in_each_prompt() {
    for (name, text) in prompts() {
        for rule in ["- Where to show things:", "- Sidebar groups:", "- Git:"] {
            assert_eq!(text.matches(rule).count(), 1, "{name}: {rule}");
        }
    }
}
