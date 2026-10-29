//! Every Chief can build the person a custom pane (issue 26579,
//! plans/cmux-next/custom-panes-DESIGN.md section 4): the shipped
//! `cmux-custom-pane` skill is installed for every Chief with the steps and
//! the page's rules, and the Chief's prompt says when to read it.

use optchat_chief::prompt::{Tools, chief_system_text};
use optchat_chief::skills;

#[test]
fn the_custom_pane_skill_ships_with_the_flow_it_needs() {
    let dir = tempfile::tempdir().unwrap();
    let shared = skills::shared_dir(&dir.path().join("default"));
    let written = skills::install_builtin(&shared).unwrap();
    assert!(
        written.contains(&"cmux-custom-pane".to_owned()),
        "{written:?}"
    );

    let loaded = skills::load(&shared, &skills::chief_dir(&dir.path().join("default")));
    let skill = loaded
        .iter()
        .find(|s| s.name == "cmux-custom-pane")
        .expect("cmux-custom-pane loads");
    for word in ["pane", "dashboard", "cmux.call", "App Store"] {
        assert!(
            skill.description.contains(word),
            "{word}: {}",
            skill.description
        );
    }
    let text = std::fs::read_to_string(&skill.path).unwrap();
    for needed in [
        "cmux --json raw command",
        r#""cmd":"apps-list""#,
        "local_dir",
        r#""cmux.pane/1": { "web": "web/index.html""#,
        r#""runtime": { "web": { "root": "web/" } }"#,
        "cmux app store --app local/",
        "cmux app open local/",
        r#""cmd":"apps-logs""#,
        "terminal:execute",
        "scope.missing",
        "gesture.required",
        "Submit for Review",
        "\"repository\"",
    ] {
        assert!(text.contains(needed), "skill lacks {needed}");
    }
}

#[test]
fn the_chief_prompt_says_when_to_read_the_custom_pane_skill() {
    let cli = Tools::Cli("/opt/chief".into());
    for (name, text) in [
        ("mcp", chief_system_text(None, &Tools::Mcp, false, false)),
        ("cli", chief_system_text(None, &cli, true, true)),
    ] {
        let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
        assert!(
            flat.contains("`cmux-custom-pane` skill"),
            "{name}: no pointer"
        );
    }
}
