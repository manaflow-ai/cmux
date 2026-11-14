use super::*;

fn skill(root: &Path, dir: &str, text: &str) {
    std::fs::create_dir_all(root.join(dir)).unwrap();
    std::fs::write(root.join(dir).join("SKILL.md"), text).unwrap();
}

#[test]
fn families_get_their_own_guidance() {
    let on = Switches::default();
    // Claude Code: the rules a cut skill listing would hide, then the skill for the rest.
    let claude = first_turn_text(Family::Claude, &on, &[]).unwrap();
    assert!(claude.contains("cmux:cmux-chat") && claude.contains("first reads"), "{claude}");
    for rule in [
        "TaskCreate",
        "TaskUpdate",
        "TodoWrite",
        "background",
        "HOST/NAME",
        "recap",
        "acpmux_wrap_up",
    ] {
        assert!(claude.contains(rule), "{rule} missing: {claude}");
    }
    assert!(claude.len() < AGENT_GUIDANCE.len(), "stays under Codex's: {} bytes", claude.len());
    let codex = first_turn_text(Family::Codex, &on, &[]).unwrap();
    for tool in [
        "update_plan",
        "cmux.subsessions_start_session",
        "cmux.sessions_offer_session",
        "cmux.sessions_suggest_tasks",
        "recap",
        "inline code",
    ] {
        assert!(codex.contains(tool), "{tool} missing: {codex}");
    }
    assert!(codex.contains("skip this when they are not"), "{codex}");
}

#[test]
fn switches_turn_off_per_family_and_default_on() {
    assert_eq!(Switches::from_settings_text(None), Switches::default());
    assert_eq!(Switches::from_settings_text(Some("not json")), Switches::default());
    let sw = Switches::from_settings_text(Some(
        r#"{"agents": {"guidance": {"codex": false}}, "agents.guidance.userSkills": false}"#,
    ));
    assert!(sw.claude && !sw.codex && sw.other && !sw.user_skills);
    assert_eq!(first_turn_text(Family::Codex, &sw, &[]), None);
    assert!(first_turn_text(Family::Other, &sw, &[]).is_some());
}

#[test]
fn user_skills_are_read_validated_and_indexed_for_codex_only() {
    let root = tempfile::tempdir().unwrap();
    skill(
        root.path(),
        "deploy",
        "---\nname: deploy\ndescription: \"Ship the app to staging.\"\n---\n\nSteps.",
    );
    skill(root.path(), "bad", "---\nname: Bad Name\ndescription: x\n---\n");
    skill(root.path(), "nofront", "just text");
    std::fs::create_dir_all(root.path().join("empty")).unwrap();
    let skills = user_skills(root.path());
    assert_eq!(skills.len(), 1, "{skills:?}");
    assert_eq!(skills[0].description, "Ship the app to staging.");

    let on = Switches::default();
    let codex = first_turn_text(Family::Codex, &on, &skills).unwrap();
    assert!(codex.contains("- deploy: Ship the app to staging. ("), "{codex}");
    assert!(codex.contains("deploy/SKILL.md"), "{codex}");
    let claude = first_turn_text(Family::Claude, &on, &skills).unwrap();
    assert!(!claude.contains("Ship the app"), "Claude gets them as a plugin: {claude}");
    let off = Switches { codex: false, ..on };
    let only_index = first_turn_text(Family::Codex, &off, &skills).unwrap();
    assert!(only_index.starts_with("The person's own skills"), "{only_index}");
}

/// Codex's index of cmux's own skills: one line per skill under a header naming their
/// shared folder once (each line its own path when they do not share one), nothing at all
/// without skills.
#[test]
fn cmux_skills_are_indexed_with_their_folder() {
    assert_eq!(cmux_skills_text(&[]), None);
    let skill = |name: &str, root: &str| UserSkill {
        name: name.into(),
        description: format!("About {name}."),
        dir: PathBuf::from(root).join(name),
    };
    let root = "/state/agent-tools/abc/skills";
    let text = cmux_skills_text(&[skill("cmux-browser", root), skill("acpmux", root)]).unwrap();
    assert_eq!(
        text,
        "cmux skills, each at /state/agent-tools/abc/skills/<name>/SKILL.md. When one's description matches the task, read its SKILL.md first and follow it:\n- cmux-browser: About cmux-browser.\n- acpmux: About acpmux."
    );
    let mixed = cmux_skills_text(&[skill("a", root), skill("b", "/elsewhere")]).unwrap();
    assert!(mixed.ends_with("- b: About b. (/elsewhere/b/SKILL.md)"), "{mixed}");
}

#[cfg(unix)]
#[test]
fn a_symlinked_skill_md_is_refused() {
    let root = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    let target = outside.path().join("SKILL.md");
    std::fs::write(&target, "---\nname: outside\ndescription: Not in the folder.\n---\n").unwrap();
    std::fs::create_dir_all(root.path().join("outside")).unwrap();
    std::os::unix::fs::symlink(&target, root.path().join("outside/SKILL.md")).unwrap();
    assert!(user_skills(root.path()).is_empty(), "the index must not point outside the folder");
}

#[test]
fn a_long_description_is_cut_in_the_index() {
    let root = tempfile::tempdir().unwrap();
    let long = "word ".repeat(2000);
    skill(root.path(), "long", &format!("---\nname: long\ndescription: {long}\n---\n"));
    let skills = user_skills(root.path());
    assert_eq!(skills[0].description.chars().count(), MAX_DESCRIPTION_CHARS + 1);
    assert!(skills[0].description.ends_with('…'));
    let codex = first_turn_text(Family::Codex, &Switches::default(), &skills).unwrap();
    assert!(codex.len() < AGENT_GUIDANCE.len() + 1000, "{} bytes", codex.len());
}

#[test]
fn the_plugin_copies_at_most_its_byte_budget_and_skill_md_first() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    let md = "---\nname: big\ndescription: Big.\n---\n";
    skill(root.path(), "big", md);
    std::fs::write(root.path().join("big/a-large.bin"), vec![b'x'; 4096]).unwrap();
    std::fs::write(root.path().join("big/b-small.md"), "small").unwrap();
    let skills = user_skills(root.path());
    let budget = (md.len() + "small".len()) as u64;
    let dir = materialize_within(state.path(), &skills, budget).unwrap().unwrap();
    assert!(dir.join("skills/big/SKILL.md").is_file());
    assert!(dir.join("skills/big/b-small.md").is_file());
    assert!(!dir.join("skills/big/a-large.bin").exists(), "over the budget");
}

#[test]
fn user_plugin_copies_regular_files_once_per_content() {
    let root = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    skill(root.path(), "notes", "---\nname: notes\ndescription: Take notes.\n---\n");
    std::fs::create_dir_all(root.path().join("notes/references")).unwrap();
    std::fs::write(root.path().join("notes/references/more.md"), "more").unwrap();
    std::fs::write(root.path().join("notes/.secret"), "hidden").unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink("/etc/hosts", root.path().join("notes/hosts")).unwrap();

    assert_eq!(materialize_user_plugin(state.path(), &[]).unwrap(), None);
    let skills = user_skills(root.path());
    let dir = materialize_user_plugin(state.path(), &skills).unwrap().unwrap();
    assert!(dir.join("skills/notes/SKILL.md").is_file());
    assert_eq!(
        std::fs::read_to_string(dir.join("skills/notes/references/more.md")).unwrap(),
        "more"
    );
    assert!(!dir.join("skills/notes/.secret").exists());
    assert!(!dir.join("skills/notes/hosts").exists());
    let manifest: Value = serde_json::from_str(
        &std::fs::read_to_string(dir.join(".claude-plugin/plugin.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(manifest["name"], USER_PLUGIN_NAME);
    assert_eq!(materialize_user_plugin(state.path(), &skills).unwrap().unwrap(), dir);
}
