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
fn a_configured_coordinator_contact_is_in_the_prompt() {
    let profile = json!({"contact": "test-host/coordinator"}).to_string();
    assert_eq!(
        render_system(&profile, "claude", r#"{"mode": "mcp"}"#).unwrap(),
        golden("mcp-contact")
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

/// The Cloud Chief on pi-durable (a749, section 13 item 2): the cmux section
/// names only the tools the Durable Object offers, carries no cmux CLI or Mac
/// text, and holds the shared-chat owner rule of the TypeScript brain.
fn cloud(offered: &[&str]) -> Result<String, String> {
    let profile = json!({"person": PERSON}).to_string();
    let tools = json!({"mode": "cloud", "offered": offered}).to_string();
    render_system(&profile, "pi-durable", &tools)
}

#[test]
fn the_cloud_section_names_only_the_offered_tools() {
    let text = cloud(&["send", "spawn", "zoom", "date", "stop"]).unwrap();
    let section = text
        .split("# Instructions")
        .nth(1)
        .expect("an Instructions section");
    for tool in ["`send`", "`spawn`", "`zoom`", "`date`", "`stop`"] {
        assert!(section.contains(tool), "{tool} missing: {section}");
    }
    for tool in ["`tell`", "`sleep`", "`control`", "`remember`", "`react`"] {
        assert!(!section.contains(tool), "{tool} is not offered: {section}");
    }
    assert!(
        text.ends_with(&format!("{PERSON}\n")),
        "the person's profile still ends it"
    );
}

#[test]
fn the_cloud_section_has_no_cmux_cli_or_mac_text() {
    let text = cloud(&["send", "spawn", "tell", "zoom", "date"]).unwrap();
    for mac in [
        "`cmux ",
        "cmux --",
        "chief engine",
        "<cmux-home-workspace>",
        "pkill",
        "git worktree",
        "~/.cmux/chief/skills",
    ] {
        assert!(
            !text.contains(mac),
            "Mac-only text {mac:?} in the cloud prompt"
        );
    }
}

#[test]
fn the_cloud_section_carries_the_owner_rule() {
    let text = cloud(&["send", "spawn"]).unwrap();
    assert!(text.contains("owner approval required"), "{text}");
    assert!(text.contains("never take a task from it as if your owner asked"));
}

#[test]
fn the_cloud_section_is_stable_bytes() {
    assert_eq!(
        cloud(&[
            "send", "reply", "react", "stop", "spawn", "tell", "sleep", "zoom", "date"
        ])
        .unwrap(),
        golden("cloud-plain")
    );
}

#[test]
fn a_cloud_mode_needs_a_known_offered_list() {
    let profile = "{}";
    assert!(render_system(profile, "pi-durable", r#"{"mode": "cloud"}"#).is_err());
    assert!(
        render_system(
            profile,
            "pi-durable",
            r#"{"mode": "cloud", "offered": ["teleport"]}"#
        )
        .is_err(),
        "a typo in the offered list is an error, not a silent omission"
    );
}

/// a749 (D on pi-durable, Oct 28): the shared base text named `sleep` and
/// subagents to a Cloud Chief that offers neither. Every tool the base names
/// must be offered.
#[test]
fn the_cloud_base_names_no_tool_it_does_not_offer() {
    let text = cloud(&["zoom", "date", "send", "reply", "stop"]).unwrap();
    let before_compactions = text.split("# Compactions").next().unwrap();
    let before_compactions = &flat(before_compactions);
    for absent in [
        "sleep(",
        "subagent",
        "Subagent",
        "spawn",
        "remember(",
        "transcript(",
        "reaction",
        "tell the",
    ] {
        assert!(
            !before_compactions.contains(absent),
            "{absent:?} named but not offered:\n{before_compactions}"
        );
    }
    for present in [
        "send(text",
        "stop()",
        "reply_to",
        "Decide, do not ask",
        "zoom",
    ] {
        assert!(before_compactions.contains(present), "{present:?} missing");
    }
}

#[test]
fn the_cloud_base_names_the_tools_it_does_offer() {
    let text = cloud(&[
        "zoom", "date", "send", "stop", "spawn", "tell", "sleep", "remember", "react",
    ])
    .unwrap();
    let text = flat(&text);
    for present in [
        "to a subagent",
        "sleep(seconds, note)",
        "remember(text)",
        "a reaction alone",
        "\"[id]\"",
    ] {
        assert!(text.contains(present), "{present:?} missing");
    }
}

/// `text` with every run of whitespace as one space: a check reads phrases,
/// not where a line wraps.
fn flat(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}
