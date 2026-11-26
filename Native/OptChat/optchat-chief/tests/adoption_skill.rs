//! Every Chief knows how to help the person adopt more of cmux (Lawrence
//! 2026-10-22: "chief needs to know how to help user adopt more of cmux ...
//! our iOS app ... set up cmux daemon on other computers, set up the
//! tailscale flow"): the shipped `cmux-adoption` skill is installed for
//! every Chief, and the Chief's prompt says when to read it.

use optchat_chief::prompt::{Tools, chief_system_text};
use optchat_chief::skills;

#[test]
fn the_adoption_skill_ships_to_every_chief_with_the_commands_it_needs() {
    let dir = std::env::temp_dir().join(format!("optchat-adoption-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let shared = skills::shared_dir(&dir.join("default"));
    let written = skills::install_builtin(&shared).unwrap();
    assert!(written.contains(&"cmux-adoption".to_owned()), "{written:?}");

    let loaded = skills::load(&shared, &skills::chief_dir(&dir.join("default")));
    let skill = loaded
        .iter()
        .find(|s| s.name == "cmux-adoption")
        .expect("cmux-adoption loads");
    for word in ["iPhone", "another computer", "Tailscale"] {
        assert!(
            skill.description.contains(word),
            "{word}: {}",
            skill.description
        );
    }
    let text = std::fs::read_to_string(&skill.path).unwrap();
    for command in [
        "cmux setup tailnet",
        "cmux cloud open-mobile-pairing",
        "cmux setup machine",
        "cmux host list --json",
        "cmux host dial",
        "cmux acp host ticket new",
        "cmux acp host candidates --json",
    ] {
        assert!(text.contains(command), "skill lacks {command}");
    }
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_chief_prompt_says_when_to_read_the_adoption_skill() {
    let cli = Tools::Cli("/opt/chief".into());
    for (name, text) in [
        ("mcp", chief_system_text(None, &Tools::Mcp, false, false)),
        ("cli", chief_system_text(None, &cli, true, true)),
    ] {
        let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
        assert!(flat.contains("`cmux-adoption` skill"), "{name}: no pointer");
        assert!(flat.contains("iPhone"), "{name}: no iPhone");
    }
}
