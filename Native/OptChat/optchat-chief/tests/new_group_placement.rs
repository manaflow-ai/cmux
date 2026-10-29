//! A personal group a Chief subagent's workspace joins is made where `workspaces.newPlacement`
//! says a new workspace goes: first under `top` (the default, with no settings file either),
//! last under `bottom`. Before, the group was always made last, so the workspace the Chief
//! made landed at the very end of the sidebar.

use optchat_chief::workspaces::new_group_index;
use std::path::Path;

fn home_with(settings: Option<&str>) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    if let Some(text) = settings {
        let config = dir.path().join(".config/cmux");
        std::fs::create_dir_all(&config).unwrap();
        std::fs::write(config.join("cmux-next.json"), text).unwrap();
    }
    dir
}

#[test]
fn no_settings_file_puts_a_new_group_first() {
    let home = home_with(None);
    assert_eq!(new_group_index(home.path()), Some(0));
}

#[test]
fn a_settings_file_without_the_key_puts_a_new_group_first() {
    let home = home_with(Some(r#"{"workspaces": {"autoName": true}}"#));
    assert_eq!(new_group_index(home.path()), Some(0));
}

#[test]
fn top_puts_a_new_group_first() {
    let home = home_with(Some(r#"{"workspaces": {"newPlacement": "top"}}"#));
    assert_eq!(new_group_index(home.path()), Some(0));
}

#[test]
fn an_unknown_value_gets_the_default_top() {
    let home = home_with(Some(r#"{"workspaces": {"newPlacement": "sideways"}}"#));
    assert_eq!(new_group_index(home.path()), Some(0));
}

#[test]
fn bottom_keeps_the_daemon_place_last() {
    let home = home_with(Some(r#"{"workspaces": {"newPlacement": "bottom"}}"#));
    assert_eq!(new_group_index(home.path()), None);
}

#[test]
fn after_current_keeps_the_daemon_place_last() {
    let home = home_with(Some(r#"{"workspaces": {"newPlacement": "afterCurrent"}}"#));
    assert_eq!(new_group_index(home.path()), None);
}

#[test]
fn a_missing_home_reads_as_the_default() {
    assert_eq!(
        new_group_index(Path::new("/nonexistent/cmux-home-for-test")),
        Some(0)
    );
}
