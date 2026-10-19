//! Every agent the Chief runs shows what it opens in one column right of
//! its chat (Lawrence 2026-10-18: "always default to a split column to the
//! right (so it's left and right and easier to manage)").

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
fn the_rule_appears_once_in_each_prompt() {
    for (name, text) in prompts() {
        assert_eq!(text.matches("- Where to show things:").count(), 1, "{name}");
    }
}
