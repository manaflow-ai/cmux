use super::*;
use serde_json::json;

#[test]
fn tracker_ids_are_bead_ids() {
    for id in ["cx-cus7j", "cx-cus7j.230", "cx-ncc.112.129", "cx-0op.M1a", "agent-tasks-a1"] {
        assert!(is_bead_id(id), "{id}");
    }
    for not in
        ["review", "cx-", "-abc", "cx-abc.", "cx-abc..1", "cx-a_b", "cx abc", "1x-abc", "a/b-c"]
    {
        assert!(!is_bead_id(not), "{not}");
    }
}

#[test]
fn a_sessions_beads_are_its_bead_tags() {
    let tags = json!({"bead:cx-b.2": "1", "archived": "2", "bead:cx-a": "3", "bead:nope": "4"});
    assert_eq!(of_tags(&tags), ["cx-a", "cx-b.2"]);
    assert!(of_tags(&Value::Null).is_empty());
}
