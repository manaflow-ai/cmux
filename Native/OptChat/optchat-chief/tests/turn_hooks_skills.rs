//! A Chief turn keeps the user's guard hooks, a short list of the user's
//! skills with the `Skill` tool, and the agent memory server, while its
//! prompt stays small (chief-acpmux-gaps.md: turns ran with every hook off,
//! `Skill` denied and only the `cmux` agent tool server, so the Chief's own
//! Bash skipped the reserved-host guard and the user's ask log).
//!
//! Only what the user names in cmux.json reaches a turn: `chief.turnHooks`
//! (words; a user hook whose command holds one is copied into the turn's
//! project settings) and `chief.turnSkills` (skill folder names under the
//! user's Claude home, linked into the turn folder's `.claude/skills`).
//! Claude Code's bundled skills stay off. One test in this binary: it sets
//! the process env.

use optchat_chief::acpmux::Family;
use optchat_chief::host::{TURN_TOOLS, turn_isolation_args, turn_preset};
use optchat_chief::prompt::Tools;
use optchat_chief::session_dir::{SessionSetup, TURN_DENIED_TOOLS, TURN_TOOL_SERVERS, write};
use serde_json::{Value, json};

#[test]
fn a_chief_turn_keeps_the_named_hooks_skills_and_agent_memory() {
    // The tool list: Skill on, skills and slash commands no longer disabled.
    assert!(TURN_TOOLS.contains(&"Skill"), "{TURN_TOOLS:?}");
    assert!(
        !TURN_DENIED_TOOLS.contains(&"Skill"),
        "{TURN_DENIED_TOOLS:?}"
    );
    let args = turn_isolation_args();
    assert!(
        !args.iter().any(|a| a == "--disable-slash-commands"),
        "{args:?}"
    );
    let tools = args
        .iter()
        .position(|a| a == "--tools")
        .and_then(|k| args.get(k + 1))
        .unwrap();
    assert!(tools.split(',').any(|t| t == "Skill"), "{tools}");
    // The agent memory server is kept next to cmux (it is listed only when
    // cmux.json turns `agents.memory.enabled` on, and waits behind ToolSearch).
    let kept: Vec<&str> = TURN_TOOL_SERVERS.1.split(',').collect();
    assert!(kept.contains(&"cmux"), "{kept:?}");
    assert!(kept.contains(&"cmux-agent-memory"), "{kept:?}");

    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("mux");
    let paths = optchat_chief::paths::Paths::new(&home);
    paths.create().unwrap();
    // Bundled skills stay off: only the named ones are listed.
    let preset = turn_preset(&paths, &home, "claude", Family::Claude, true, "SYS").unwrap();
    assert_eq!(
        preset
            .env
            .get("CLAUDE_CODE_DISABLE_BUNDLED_SKILLS")
            .map(String::as_str),
        Some("1"),
        "{:?}",
        preset.env
    );

    // The user's Claude home: two hooks, one named; two skills, one named.
    let claude_home = dir.path().join("claude-home");
    for skill in ["guard-skill", "other-skill"] {
        std::fs::create_dir_all(claude_home.join("skills").join(skill)).unwrap();
        std::fs::write(
            claude_home.join("skills").join(skill).join("SKILL.md"),
            format!("---\nname: {skill}\ndescription: d\n---\n"),
        )
        .unwrap();
    }
    let guard =
        json!({"type": "command", "command": "bash /h/reserved-host-hook.sh", "timeout": 5});
    let log = json!({"type": "command", "command": "python3 /h/leo-asks hook"});
    std::fs::write(
        claude_home.join("settings.json"),
        json!({"hooks": {
            "PreToolUse": [
                {"matcher": "Bash", "hooks": [guard.clone()]},
                {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash /h/noisy.sh"}]}
            ],
            "UserPromptSubmit": [{"hooks": [log.clone()]}],
            "Stop": [{"hooks": [{"type": "command", "command": "python3 /h/refs-capture hook"}]}]
        }})
        .to_string(),
    )
    .unwrap();
    let config = dir.path().join("cmux.json");
    std::fs::write(
        &config,
        r#"{
  // JSONC, as the app writes it
  "chief": {"turnHooks": ["reserved-host-hook", "leo-asks"], "turnSkills": ["guard-skill", "missing-skill"]},
}"#,
    )
    .unwrap();
    // SAFETY: this test binary runs this one test; nothing else reads the env meanwhile.
    unsafe {
        std::env::set_var("CLAUDE_CONFIG_DIR", &claude_home);
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", &config);
    }
    let setup = SessionSetup {
        exe: "/x/optchat-chief".into(),
        env: Default::default(),
        instructions: None,
        tools: Tools::Mcp,
        user_env: Default::default(),
        profile_tool: false,
        chiefs_tool: false,
    };
    write(&paths, &setup).unwrap();
    let read = |name: &str| -> Value {
        serde_json::from_str(
            &std::fs::read_to_string(paths.session.join(".claude").join(name)).unwrap(),
        )
        .unwrap()
    };
    for name in ["settings.json", "settings.local.json"] {
        let settings = read(name);
        assert_eq!(
            settings["disableAllHooks"],
            json!(false),
            "{name}: {settings}"
        );
        assert_eq!(
            settings["disableBundledSkills"],
            json!(true),
            "{name}: {settings}"
        );
        assert_eq!(
            settings["hooks"],
            json!({
                "PreToolUse": [{"matcher": "Bash", "hooks": [guard]}],
                "UserPromptSubmit": [{"hooks": [log]}]
            }),
            "{name}: only the named hooks"
        );
    }
    let skills = paths.session.join(".claude").join("skills");
    let linked = std::fs::read_link(skills.join("guard-skill")).unwrap();
    assert_eq!(linked, claude_home.join("skills").join("guard-skill"));
    assert!(
        std::fs::symlink_metadata(skills.join("other-skill")).is_err(),
        "an unnamed skill stays out"
    );
    assert!(
        std::fs::symlink_metadata(skills.join("missing-skill")).is_err(),
        "a missing skill gets no link"
    );

    // Nothing named: hooks stay off and the old links go.
    std::fs::write(&config, "{}").unwrap();
    write(&paths, &setup).unwrap();
    let settings = read("settings.json");
    assert_eq!(settings["disableAllHooks"], json!(true), "{settings}");
    assert!(settings.get("hooks").is_none(), "{settings}");
    assert!(
        std::fs::symlink_metadata(skills.join("guard-skill")).is_err(),
        "a skill no longer named loses its link"
    );
    // A real folder there is the user's own and stays.
    std::fs::create_dir_all(skills.join("own")).unwrap();
    write(&paths, &setup).unwrap();
    assert!(skills.join("own").is_dir());
}
