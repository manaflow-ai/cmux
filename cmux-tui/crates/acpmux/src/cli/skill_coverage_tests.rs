//! The agents skill (`cmux:agents`) names every visible top-level command, so an agent learns a tool exists
//! from the guide it loads: `chats search` indexed every chat on the device for weeks while
//! agents scanned transcripts by hand because the guide never said so (ask-a490bf8aa5).

use super::command::Cli;
use clap::CommandFactory;

#[test]
fn agents_skill_names_every_top_level_command() {
    let skill = include_str!("../../skills/agents/SKILL.md");
    let cli = Cli::command();
    let missing: Vec<&str> = cli
        .get_subcommands()
        .filter(|command| !command.is_hide_set() && command.get_name() != "help")
        .map(|command| command.get_name())
        .filter(|name| {
            !skill.contains(&format!("cmux agent {name} "))
                && !skill.contains(&format!("acpmux {name} "))
                && !skill.contains(&format!("`{name}`"))
        })
        .collect();
    assert!(
        missing.is_empty(),
        "the agents skill (skills/agents/SKILL.md) never names these commands; add each to \
         \"Find things\" or its one-line list: {missing:?}"
    );
}
