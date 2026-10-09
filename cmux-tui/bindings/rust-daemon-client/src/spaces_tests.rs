//! Spaces read from `list-personal` and the membership rule
//! (plans/cmux-next/data-model.md 3.2; cmux-next `RoomMembership`).

use crate::spaces::{DEFAULT_SPACE, Spaces, WorkspaceRef};
use serde_json::json;

fn ws(session: &str, key: &str) -> WorkspaceRef {
    WorkspaceRef { session: session.into(), key: key.into() }
}

fn personal() -> serde_json::Value {
    json!({
        "personal_revision": 7,
        "sessions": [],
        "profiles": [
            {"id": "prof_b", "name": "Work", "color": "red", "icon": "🔥", "theme": null, "index": 1,
             "browser_profile_id": null, "default_session_id": "remote", "defaults": {"cwd": "/w"},
             "follows": ["remote"]},
            {"id": "default", "name": "Default", "color": null, "icon": null, "theme": "Nord", "index": 0,
             "browser_profile_id": null, "default_session_id": null, "defaults": null,
             "follows": ["home"]},
            {"id": "prof_c", "name": "", "color": null, "icon": null, "theme": null, "index": 2,
             "browser_profile_id": "bp", "default_session_id": null, "defaults": null,
             "follows": ["home", "remote"], "future_field": 1}
        ],
        "pins": [
            {"session_id": "home", "workspace_key": "w1", "profile": "prof_b"},
            {"session_id": "remote", "workspace_key": "r9", "profile": "gone"}
        ],
        "groups": [], "workspaces": [], "terminals": [], "browser_profiles": []
    })
}

#[test]
fn reads_spaces_in_index_order_with_their_fields() {
    let spaces = Spaces::from_personal(&personal()).unwrap();
    assert_eq!(spaces.revision, 7);
    let ids: Vec<&str> = spaces.spaces.iter().map(|s| s.id.as_str()).collect();
    assert_eq!(ids, ["default", "prof_b", "prof_c"]);
    let work = spaces.space("prof_b").unwrap();
    assert_eq!(work.name, "Work");
    assert_eq!(work.color.as_deref(), Some("red"));
    assert_eq!(work.icon.as_deref(), Some("🔥"));
    assert_eq!(work.default_session_id.as_deref(), Some("remote"));
    assert_eq!(work.defaults, Some(json!({"cwd": "/w"})));
    assert_eq!(work.follows, ["remote"]);
    assert_eq!(spaces.space("default").unwrap().theme.as_deref(), Some("Nord"));
    assert_eq!(spaces.space("prof_c").unwrap().browser_profile_id.as_deref(), Some("bp"));
    assert_eq!(spaces.position("prof_c"), Some(2));
    assert!(spaces.space("nope").is_none());
}

#[test]
fn a_pinned_workspace_is_only_in_its_space() {
    let spaces = Spaces::from_personal(&personal()).unwrap();
    assert_eq!(spaces.spaces_of(&ws("home", "w1")), ["prof_b"]);
    assert!(spaces.contains(&ws("home", "w1"), "prof_b"));
    assert!(!spaces.contains(&ws("home", "w1"), "default"));
    // A pin to a space that is gone still decides (cmux-next keeps it).
    assert_eq!(spaces.spaces_of(&ws("remote", "r9")), ["gone"]);
}

#[test]
fn an_unpinned_workspace_is_in_every_space_that_follows_its_session() {
    let spaces = Spaces::from_personal(&personal()).unwrap();
    assert_eq!(spaces.spaces_of(&ws("home", "w2")), ["default", "prof_c"]);
    assert_eq!(spaces.spaces_of(&ws("remote", "r1")), ["prof_b", "prof_c"]);
}

#[test]
fn a_workspace_in_no_space_shows_in_default() {
    let spaces = Spaces::from_personal(&personal()).unwrap();
    assert_eq!(spaces.spaces_of(&ws("cloud", "c1")), [DEFAULT_SPACE]);
    assert!(spaces.contains(&ws("cloud", "c1"), DEFAULT_SPACE));
}

#[test]
fn delete_closes_only_what_no_other_space_shows_and_never_for_default() {
    let spaces = Spaces::from_personal(&personal()).unwrap();
    assert!(spaces.closes(&ws("home", "w1"), "prof_b"));
    assert!(!spaces.closes(&ws("remote", "r1"), "prof_b"), "prof_c also shows it");
    assert!(!spaces.closes(&ws("home", "w2"), "prof_b"), "not in that space");
    assert!(!spaces.closes(&ws("cloud", "c1"), DEFAULT_SPACE), "default is never deleted");
}

#[test]
fn pin_and_remove_space_edit_the_copy_as_the_daemon_will() {
    let mut spaces = Spaces::from_personal(&personal()).unwrap();
    spaces.pin(ws("home", "w2"), "prof_b");
    assert_eq!(spaces.spaces_of(&ws("home", "w2")), ["prof_b"]);
    spaces.remove_space("prof_b", Some("prof_c"));
    assert_eq!(spaces.spaces_of(&ws("home", "w1")), ["prof_c"], "pins move");
    assert!(spaces.space("prof_b").is_none());
    assert_eq!(spaces.spaces_of(&ws("remote", "r1")), ["prof_c"], "no longer followed by prof_b");
    spaces.remove_space("prof_c", None);
    assert_eq!(
        spaces.spaces_of(&ws("home", "w1")),
        [DEFAULT_SPACE],
        "pins dropped: back to followers"
    );
    assert_eq!(spaces.spaces_of(&ws("remote", "r1")), [DEFAULT_SPACE]);
}

#[test]
fn following_all_puts_every_session_in_default() {
    let spaces = Spaces::following_all(&["home".to_string(), "remote".to_string()]);
    assert_eq!(spaces.spaces.len(), 1);
    assert_eq!(spaces.spaces[0].id, DEFAULT_SPACE);
    assert_eq!(spaces.spaces_of(&ws("remote", "x")), [DEFAULT_SPACE]);
}

#[test]
fn malformed_personal_state_is_an_error() {
    assert!(Spaces::from_personal(&json!({"profiles": "no"})).is_err());
    assert!(Spaces::from_personal(&json!({"profiles": [{"name": "no id"}]})).is_err());
    assert!(
        Spaces::from_personal(&json!({"profiles": [], "pins": [{"session_id": "s"}]})).is_err()
    );
    // An older daemon without pins: none.
    let spaces = Spaces::from_personal(&json!({"personal_revision": 1, "profiles": []})).unwrap();
    assert!(spaces.spaces.is_empty());
}
