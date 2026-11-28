//! Every Chief can say what changed from build to build and what is worth
//! trying (Leo 2026-10-20: "I feel like Chief is a really good way of like
//! being able to highlight, say, version to version, what's nice, what's
//! changed, what's worth trying out"): the shipped `whats-new` skill reads
//! the signed release notes the What's New page shows, and the Chief's
//! prompt says when to read it.

use optchat_chief::prompt::{Tools, chief_system_text};
use optchat_chief::skills;

#[test]
fn the_whats_new_skill_ships_to_every_chief_with_the_notes_it_reads() {
    let dir = tempfile::tempdir().unwrap();
    let shared = skills::shared_dir(&dir.path().join("default"));
    let written = skills::install_builtin(&shared).unwrap();
    assert!(written.contains(&"whats-new".to_owned()), "{written:?}");

    let loaded = skills::load(&shared, &skills::chief_dir(&dir.path().join("default")));
    let skill = loaded
        .iter()
        .find(|s| s.name == "whats-new")
        .expect("whats-new loads");
    for word in ["what's new", "worth trying", "release notes"] {
        assert!(
            skill.description.contains(word),
            "{word}: {}",
            skill.description
        );
    }
    let text = std::fs::read_to_string(&skill.path).unwrap();
    for needle in [
        "cmux version --json",
        "cmux settings check-for-updates --json",
        "notes/index.json",
        "whatsNew.entries",
        "tryIt",
        "cmux action run updates.whatsNew",
    ] {
        assert!(text.contains(needle), "skill lacks {needle}");
    }
}

#[test]
fn the_chief_prompt_says_when_to_read_the_whats_new_skill() {
    let cli = Tools::Cli("/opt/chief".into());
    for (name, text) in [
        ("mcp", chief_system_text(None, &Tools::Mcp, false, false)),
        ("cli", chief_system_text(None, &cli, true, true)),
    ] {
        let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
        assert!(flat.contains("`whats-new` skill"), "{name}: no pointer");
    }
}
