//! The mirror keeps the session's tab groups: seeded from the snapshot's
//! `extra.state.tab_groups`, then `state_upsert` / `state_delete` changes of
//! `tab_group` (the shapes of resource-operations-v2.json `TabGroupSnapshot`,
//! as cmux-tui-core `state/tab_state_store.rs` writes them).

use crate::fixture::{GROUP_SNAPSHOT, event};
use crate::mirror::{Applied, Change, Mirror, MirrorChange, MirrorError};
use cmux::{Document, PaneId, ResourceChange, SessionEvent, TabId};
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

fn apply(mirror: &mut Mirror, change: Value) -> Vec<MirrorChange> {
    match mirror.apply(state_delta(mirror, change)).unwrap() {
        Applied::Delta(changes) => changes,
        other => panic!("expected a delta, got {other:?}"),
    }
}

fn upsert(value: Value) -> Value {
    json!({"kind": "state_upsert", "sequence": 0, "resource": "tab_group",
           "id": value["id"].clone(), "value": value})
}

fn names(mirror: &Mirror) -> Vec<String> {
    let pane = PaneId::parse(PANE).unwrap();
    mirror.tab_groups_of(&pane).iter().map(|g| g.name.clone()).collect()
}

#[test]
fn snapshot_seeds_tab_groups_in_strip_order_and_keeps_unknown_fields() {
    let mirror = seeded();
    assert_eq!(mirror.tab_groups.len(), 2);
    assert_eq!(names(&mirror), ["Sooner", "Later"]);
    let first = &mirror.tab_groups[FIRST];
    assert_eq!(first.tab_ids, [TabId::parse(TAB_B).unwrap()]);
    assert_eq!((first.color.as_str(), first.saved_tab_group_id.as_deref()), ("blue", None));
    assert_eq!(first.additional["future_field"], json!({"kept": true}));
}

#[test]
fn tab_group_state_changes_are_typed_mirror_changes() {
    let mut mirror = seeded();
    let mut renamed = group(FIRST, "Renamed", &[TAB_B]);
    renamed["color"] = json!("magenta");
    renamed["collapsed"] = json!(true);
    assert_eq!(
        apply(&mut mirror, upsert(renamed)),
        [MirrorChange::TabGroup(Change::Updated(FIRST.into()))]
    );
    // A color this SDK does not list still decodes.
    assert_eq!(
        (mirror.tab_groups[FIRST].color.as_str(), mirror.tab_groups[FIRST].collapsed),
        ("magenta", true)
    );

    let third = "tgrp_00000000000000000000000000000003";
    let added = apply(&mut mirror, upsert(group(third, "New", &[TAB_A])));
    assert_eq!(added, [MirrorChange::TabGroup(Change::Added(third.into()))]);

    let delete =
        json!({"kind": "state_delete", "sequence": 0, "resource": "tab_group", "id": FIRST});
    assert_eq!(
        apply(&mut mirror, delete.clone()),
        [MirrorChange::TabGroup(Change::Removed(FIRST.into()))]
    );
    assert!(!mirror.tab_groups.contains_key(FIRST));
    // Deleting an absent group is not an error.
    assert_eq!(apply(&mut mirror, delete), [MirrorChange::IgnoredState("tab_group".into())]);
    // Saved tab groups are named but not kept.
    let saved = json!({"kind": "state_delete", "sequence": 0, "resource": "saved_tab_group",
                       "id": "saved_00000000000000000000000000000001"});
    assert_eq!(apply(&mut mirror, saved), [MirrorChange::IgnoredState("saved_tab_group".into())]);
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
