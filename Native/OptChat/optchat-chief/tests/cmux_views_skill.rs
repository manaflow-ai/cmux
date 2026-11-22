//! The Chief's cmux-views skill teaches the local customize app path for
//! live sidebar and Session Info views.

use optchat_chief::skills;

#[test]
fn the_cmux_views_skill_ships_to_every_chief() {
    let dir = tempfile::tempdir().unwrap();
    let shared = skills::shared_dir(&dir.path().join("default"));
    let written = skills::install_builtin(&shared).unwrap();
    assert!(written.contains(&"cmux-views".to_owned()), "{written:?}");

    let loaded = skills::load(&shared, &skills::chief_dir(&dir.path().join("default")));
    let skill = loaded
        .iter()
        .find(|s| s.name == "cmux-views")
        .expect("cmux-views loads");
    for needle in [
        "local/customize",
        "cmux.section/1",
        "cmux.session.info.section/1",
        "__cmuxAppExports",
        "cmux apps place 'local/customize#cmux.section/1' --region bottom",
        "apps-logs",
    ] {
        let text = std::fs::read_to_string(&skill.path).unwrap();
        assert!(text.contains(needle), "skill lacks {needle}");
    }
}
