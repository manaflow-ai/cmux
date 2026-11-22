//! `chief agents spawn` is retired (chwsr5: the Chief fell back to it and
//! its subagent got no workspace and no chat tab); `chief spawn` and
//! `chief tell` are the subagent tools.

use optchat_chief::agents::{SPAWN_RETIRED, USAGE, retired};

fn words(w: &[&str]) -> Vec<String> {
    w.iter().map(|s| s.to_string()).collect()
}

#[test]
fn agents_spawn_refuses_and_names_spawn_and_tell() {
    let refusal = retired(&words(&[
        "agents",
        "spawn",
        "--name",
        "kid",
        "--cwd",
        "/tmp",
        "Reply PONG.",
    ]));
    assert_eq!(refusal, Some(SPAWN_RETIRED));
    assert!(SPAWN_RETIRED.contains("chief spawn") && SPAWN_RETIRED.contains("chief tell"));
}

#[test]
fn the_other_agents_verbs_stay() {
    for verb in ["list", "prompt", "allow", "deny"] {
        assert_eq!(retired(&words(&["agents", verb])), None, "{verb}");
        assert!(USAGE.contains(verb), "{verb}");
    }
    assert!(!USAGE.contains("agents spawn"), "{USAGE}");
}

#[test]
fn the_prompt_names_only_spawn_and_tell() {
    use optchat_chief::prompt::{CMUX_INSTRUCTIONS, Tools, system_text};
    assert!(!CMUX_INSTRUCTIONS.contains("agents spawn"));
    let cli = system_text(None, &Tools::Cli("/x/chief".into()));
    assert!(!cli.contains("agents spawn"), "{cli}");
}
