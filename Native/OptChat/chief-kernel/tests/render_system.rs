//! `render_system` renders exactly the system text the Mac host renders today
//! (golden files written from optchat-chief at 847951443eb), so moving the
//! prompt into the kernel changes no byte, and the Cloud Chief can drop its
//! own copy (`chief-brain/prompts.ts`).

use chief_kernel::render_system;
use serde_json::json;

const PERSON: &str = "- Replies: short.\n- Default project is cmux-next.";
const AGENTS: &str = "Extra instructions from AGENTS.md.";
const CHANNELS: &str = "## Channels\n\nYou take part in group conversations.";

fn golden(name: &str) -> String {
    std::fs::read_to_string(format!(
        "{}/tests/golden/{name}.txt",
        env!("CARGO_MANIFEST_DIR")
    ))
    .unwrap()
}

fn record() -> serde_json::Value {
    json!({"display_name": "Codex Chief", "role": "Chief running on Codex", "personality": "",
           "instructions": "Be brief.", "is_default": false})
}

#[test]
fn an_mcp_engine_gets_todays_text() {
    let profile = json!({"person": PERSON}).to_string();
    let tools = json!({"mode": "mcp"}).to_string();
    assert_eq!(
        render_system(&profile, "claude", &tools).unwrap(),
        golden("mcp-plain")
    );
}

#[test]
fn every_part_of_the_profile_lands_in_the_hosts_order() {
    let profile =
        json!({"person": PERSON, "instructions": AGENTS, "channels": CHANNELS, "record": record()})
            .to_string();
    let tools = json!({"mode": "mcp", "profile_tool": true, "chiefs_tool": true}).to_string();
    assert_eq!(
        render_system(&profile, "claude", &tools).unwrap(),
        golden("mcp-everything")
    );
}

#[test]
fn a_cli_engine_names_the_launcher() {
    let profile = json!({"person": PERSON}).to_string();
    let tools = json!({"mode": "cli", "chief": "/h/optchat/bin/chief"}).to_string();
    assert_eq!(
        render_system(&profile, "codex", &tools).unwrap(),
        golden("cli-plain")
    );
    let profile =
        json!({"person": PERSON, "instructions": AGENTS, "channels": CHANNELS, "record": record()})
            .to_string();
    let tools = json!({"mode": "cli", "chief": "/h/optchat/bin/chief", "profile_tool": true, "chiefs_tool": true}).to_string();
    assert_eq!(
        render_system(&profile, "muse", &tools).unwrap(),
        golden("cli-everything")
    );
}

#[test]
fn pi_durable_names_its_tools_as_the_mcp_engines_do() {
    // The Durable Object offers the same short tool names (spawn, send, zoom ...).
    let profile = json!({"person": PERSON}).to_string();
    assert_eq!(
        render_system(&profile, "pi-durable", "{}").unwrap(),
        golden("mcp-plain")
    );
}

#[test]
fn an_empty_profile_and_the_plain_default_record_add_nothing() {
    let profile = json!({"record": {"display_name": "Chief", "is_default": true}}).to_string();
    assert_eq!(
        render_system(&profile, "claude", "{}").unwrap(),
        golden("mcp-no-user")
    );
}

#[test]
fn bad_input_is_an_error_not_a_prompt() {
    assert!(render_system("not json", "claude", "{}").is_err());
    assert!(
        render_system("{}", "claude", r#"{"mode": "cli"}"#).is_err(),
        "cli needs its launcher path"
    );
    assert!(render_system("{}", "no-such-engine", "{}").is_err());
}
