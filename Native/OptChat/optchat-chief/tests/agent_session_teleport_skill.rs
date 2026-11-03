//! Every Chief can move an agent chat to another machine when asked ("move that Codex session
//! to cmux-mini-7", "teleport this chat to the cloud"): the shipped `agent-session-teleport`
//! skill gives it the move, the cloud route, the target's sign-in and the resume check.

use optchat_chief::skills;

#[test]
fn the_teleport_skill_ships_to_every_chief_with_the_move_it_runs() {
    let dir = tempfile::tempdir().unwrap();
    let shared = skills::shared_dir(&dir.path().join("default"));
    let written = skills::install_builtin(&shared).unwrap();
    assert!(
        written.contains(&"agent-session-teleport".to_owned()),
        "{written:?}"
    );

    let loaded = skills::load(&shared, &skills::chief_dir(&dir.path().join("default")));
    let skill = loaded
        .iter()
        .find(|s| s.name == "agent-session-teleport")
        .expect("agent-session-teleport loads");
    for word in [
        "Claude Code",
        "Codex",
        "OpenCode",
        "pi",
        "teleport",
        "another machine",
    ] {
        assert!(
            skill.description.contains(word),
            "{word}: {}",
            skill.description
        );
    }
    let text = std::fs::read_to_string(&skill.path).unwrap();
    for needle in [
        "acpmux session move CHAT --machine NAME --dry-run",
        "--interrupt",
        "--from mini-3 --machine cloud-vm",
        "--machine local",
        "cmux cloud move",
        "escalate_auth",
        "acpmux last HOST/ID",
    ] {
        assert!(text.contains(needle), "skill lacks {needle}");
    }
    // A sign-in never travels: the skill forbids copying any agent's credentials.
    assert!(text.contains("Never copy"));
}
