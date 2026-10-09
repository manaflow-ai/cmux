//! The mirror keeps the session's tab groups: seeded from the snapshot's
//! `extra.state.tab_groups`, then `state_upsert` / `state_delete` changes of
//! `tab_group` (the shapes of resource-operations-v2.json `TabGroupSnapshot`,
//! as cmux-tui-core `state/tab_state_store.rs` writes them).

use crate::fixture::{GROUP_SNAPSHOT, event};
use crate::mirror::{Applied, Mirror, MirrorError};
use cmux::{Document, ResourceChange, SessionEvent};
use serde_json::{Value, json};

const PANE: &str = "pane_00000000000000000000000000000006";
const TAB_A: &str = "tab_0000000000000000000000000000000a";
const TAB_B: &str = "tab_0000000000000000000000000000000b";
const TERMINAL: &str = "term_0000000000000000000000000000000c";
const FIRST: &str = "tgrp_00000000000000000000000000000001";
const SECOND: &str = "tgrp_00000000000000000000000000000002";

fn group(id: &str, name: &str, tabs: &[&str]) -> Value {
    json!({"id": id, "pane_id": PANE, "name": name, "color": "blue", "collapsed": false,
           "tab_ids": tabs, "saved_tab_group_id": null})
}

fn tab(id: &str, index: u32) -> Value {
    json!({"id": id, "pane_id": PANE, "name": null, "index": index, "focused": index == 0,
           "content_kind": "terminal", "content_id": TERMINAL, "extra": {}})
}

/// The recorded snapshot with two tabs of one pane and two groups: FIRST
/// holds the second tab (and a field this SDK does not know), SECOND holds
/// the first tab.
fn seeded() -> Mirror {
    let mut line: Value = serde_json::from_str(GROUP_SNAPSHOT.lines().next().unwrap()).unwrap();
    let snapshot = &mut line["item"]["snapshot"];
    snapshot["tabs"] = json!([tab(TAB_A, 0), tab(TAB_B, 1)]);
    let mut first = group(FIRST, "Later", &[TAB_B]);
    first["future_field"] = json!({"kept": true});
    snapshot["extra"]["state"]["tab_groups"] = json!([first, group(SECOND, "Sooner", &[TAB_A])]);
    let mut mirror = Mirror::default();
    assert_eq!(mirror.apply(event(&line.to_string())), Ok(Applied::Reset));
    mirror
}

fn state_delta(mirror: &Mirror, change: Value) -> SessionEvent {
    let cursor = mirror.cursor.clone().unwrap();
    let mut next = cursor.clone();
    next.revision += 1;
    let kind = change["kind"].as_str().unwrap().to_string();
    SessionEvent::Delta(cmux::SessionDeltaEvent {
        cursor: next.clone(),
        previous_revision: cursor.revision,
        revision: next.revision,
        changes: vec![ResourceChange::Unknown {
            kind,
            raw: Document::from_serializable(&change).unwrap(),
        }],
    })
}

fn upsert(value: Value) -> Value {
    json!({"kind": "state_upsert", "sequence": 0, "resource": "tab_group",
           "id": value["id"].clone(), "value": value})
}

#[test]
fn malformed_tab_group_changes_leave_the_mirror_unchanged() {
    let mut mirror = seeded();
    let before = mirror.clone();
    let mut missing = group(FIRST, "x", &[TAB_B]);
    missing.as_object_mut().unwrap().remove("tab_ids");
    let cases = [
        // The value's id differs from the change id.
        json!({"kind": "state_upsert", "sequence": 0, "resource": "tab_group", "id": SECOND,
               "value": group(FIRST, "x", &[TAB_B])}),
        // A missing required field.
        upsert(missing),
    ];
    for case in cases {
        let error = mirror.apply(state_delta(&mirror, case.clone())).unwrap_err();
        assert!(matches!(error, MirrorError::InvalidState { .. }), "{case}: {error:?}");
        assert_eq!(mirror, before);
    }
}
