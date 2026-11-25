//! Slash skills (Lawrence 2026-11-07: "i want to be able to invoke / skills
//! from chief and have chief skills, like i want all the emil skills in
//! chief"): `/name` at the start of a person's message makes the turn read
//! that skill's SKILL.md; the composer lists the Chief's skills, the person's
//! Claude Code skills and their plugins' skills; every `emil-*` skill joins
//! the shared Chief skills by default. The brain test sets the process env
//! (`CLAUDE_CONFIG_DIR`), so it is the only test here that reads it.

mod common;

use std::path::Path;

use common::*;
use optchat_chief::slash_skills::{
    self, Source, catalog, claude_skill_patterns, glob, invocation_line, invoked,
    link_claude_skills,
};
use serde_json::json;

fn skill(dir: &Path, folder: &str, name: &str, description: &str) {
    std::fs::create_dir_all(dir.join(folder)).unwrap();
    std::fs::write(
        dir.join(folder).join("SKILL.md"),
        format!("---\nname: {name}\ndescription: {description}\n---\n\nSteps.\n"),
    )
    .unwrap();
}

#[test]
fn slash_skills_a_person_command_makes_the_turn_read_the_skill() {
    let claude = tempfile::tempdir().unwrap();
    skill(
        &claude.path().join("skills"),
        "emil-prototype",
        "emil-prototype",
        "Explore several versions behind a live picker.",
    );
    // SAFETY: the only test of this binary that reads the env.
    unsafe { std::env::set_var("CLAUDE_CONFIG_DIR", claude.path()) };

    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "/emil-prototype make the import sheet better");
    h.settle();
    h.say("user_local", "/tmp/build.log is broken");
    h.settle();
    h.say("user_local", "/nobody-has-this skill");
    h.settle();

    let users: Vec<String> = h
        .log()
        .into_iter()
        .filter(|(kind, _)| kind == "user")
        .map(|(_, text)| text)
        .collect();
    let invoked = users
        .iter()
        .find(|t| t.contains("/emil-prototype make"))
        .unwrap_or_else(|| panic!("{users:?}"));
    let path = claude.path().join("skills/emil-prototype/SKILL.md");
    assert!(
        invoked.contains("[skill /emil-prototype]")
            && invoked.contains(&path.display().to_string()),
        "{invoked}"
    );
    // A path and a name nobody has stay plain messages.
    for words in ["/tmp/build.log", "/nobody-has-this"] {
        let t = users.iter().find(|t| t.contains(words)).unwrap();
        assert!(!t.contains("[skill "), "{t}");
    }
}

#[test]
fn slash_skills_catalog_lists_chief_then_claude_then_plugin_skills_once() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("chief").join("default");
    let claude = dir.path().join("claude");
    skill(
        &dir.path().join("chief/skills"),
        "cmux-views",
        "cmux-views",
        "Chief's own.",
    );
    skill(
        &home.join("skills"),
        "emil-color",
        "emil-color",
        "The Chief's copy.",
    );
    skill(
        &claude.join("skills"),
        "emil-color",
        "emil-color",
        "The person's copy.",
    );
    skill(
        &claude.join("skills"),
        "emil-typography",
        "emil-typography",
        "Type.",
    );
    std::fs::create_dir_all(claude.join("skills/no-skill-md")).unwrap();
    let plugin = dir.path().join("cache/vercel/0.50.0");
    skill(&plugin.join("skills"), "ai-sdk", "ai-sdk", "The AI SDK.");
    std::fs::create_dir_all(claude.join("plugins")).unwrap();
    std::fs::write(
        claude.join("plugins/installed_plugins.json"),
        json!({"version": 2, "plugins": {"vercel@claude-plugins-official": [
            {"scope": "user", "installPath": plugin},
            {"scope": "project", "installPath": plugin}
        ]}})
        .to_string(),
    )
    .unwrap();

    let got: Vec<(String, Source, String)> = catalog(&home, &claude)
        .into_iter()
        .map(|s| (s.skill.name, s.source, s.skill.description))
        .collect();
    assert_eq!(
        got,
        vec![
            ("cmux-views".into(), Source::Chief, "Chief's own.".into()),
            (
                "emil-color".into(),
                Source::Chief,
                "The Chief's copy.".into()
            ),
            ("emil-typography".into(), Source::Claude, "Type.".into()),
            ("vercel:ai-sdk".into(), Source::Plugin, "The AI SDK.".into()),
        ]
    );
    let skills = catalog(&home, &claude);
    let line = invocation_line("/vercel:ai-sdk", &skills).unwrap();
    assert!(line.contains("[skill /vercel:ai-sdk]"), "{line}");
    assert!(line.contains("no other words"), "{line}");
    assert_eq!(
        slash_skills::with_invocation("hello /emil-color", &skills),
        "hello /emil-color"
    );
}

#[test]
fn slash_skills_command_is_a_name_at_the_start() {
    assert_eq!(invoked("/emil-prototype"), Some(("emil-prototype", "")));
    assert_eq!(
        invoked("  /emil-prototype  the sheet \n now"),
        Some(("emil-prototype", "the sheet \n now"))
    );
    assert_eq!(invoked("/vercel:ai-sdk go"), Some(("vercel:ai-sdk", "go")));
    assert_eq!(invoked("/"), None);
    assert_eq!(invoked("/ x"), None);
    assert_eq!(invoked("/tmp/x"), None);
    assert_eq!(invoked("say /emil-color"), None);
    assert_eq!(invoked("/-flag"), None);
}

#[test]
fn slash_skills_every_emil_skill_joins_the_shared_chief_skills_by_default() {
    let dir = tempfile::tempdir().unwrap();
    let claude = dir.path().join("claude");
    let shared = dir.path().join("chief/skills");
    for name in ["emil-prototype", "emil-color", "grilling"] {
        skill(&claude.join("skills"), name, name, "d");
    }
    // A real folder of the same name is the person's or cmux's: it stays.
    skill(&shared, "emil-color", "emil-color", "mine");

    let defaults = claude_skill_patterns(None);
    assert_eq!(defaults, vec!["emil-*".to_owned()]);
    assert_eq!(
        link_claude_skills(&shared, &claude, &defaults),
        vec!["emil-prototype".to_owned()]
    );
    assert_eq!(
        std::fs::read_link(shared.join("emil-prototype")).unwrap(),
        claude.join("skills/emil-prototype")
    );
    assert!(!shared.join("grilling").exists());
    assert!(std::fs::read_link(shared.join("emil-color")).is_err());
    let names: Vec<String> = optchat_chief::skills::load(&shared, &dir.path().join("none"))
        .into_iter()
        .map(|s| s.name)
        .collect();
    assert_eq!(names, vec!["emil-color", "emil-prototype"]);

    // `[]` in cmux.json links none, and the old link goes.
    let none = claude_skill_patterns(Some(&json!({"chief.claudeSkills": []})));
    assert!(none.is_empty());
    link_claude_skills(&shared, &claude, &none);
    assert!(std::fs::symlink_metadata(shared.join("emil-prototype")).is_err());
    assert!(shared.join("emil-color/SKILL.md").is_file());

    assert!(glob("emil-*", "emil-ui-polish"));
    assert!(!glob("emil-*", "grilling"));
    assert!(glob("*", "x"));
}
