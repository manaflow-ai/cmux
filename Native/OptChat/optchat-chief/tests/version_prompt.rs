//! Every agent the Chief runs knows how to find out which cmux it talks to
//! (Lawrence 2026-10-20: "make sure chief can detect cmux version and stuff
//! like that"): one command names the CLI, the app behind its socket (full
//! nightly build, channel, bundle, pid), whether the CLI is that app's own,
//! the update state, the bundled helpers and macOS.

use optchat_chief::prompt::{Tools, chief_system_text, subagent_system_text};

#[test]
fn every_agent_prompt_names_the_version_report() {
    let cli = Tools::Cli("/opt/chief".into());
    let prompts = [
        ("chief mcp", chief_system_text(None, &Tools::Mcp, false, false)),
        ("chief cli", chief_system_text(None, &cli, true, true)),
        ("subagent mcp", subagent_system_text(None, &Tools::Mcp)),
        ("subagent cli", subagent_system_text(None, &cli)),
    ];
    for (name, text) in prompts {
        let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
        assert!(flat.contains("`cmux version --json`"), "{name}: no version command");
        assert!(flat.contains("update state"), "{name}: no update state");
        assert!(flat.contains("is not the app's own"), "{name}: no CLI/app skew rule");
    }
}
