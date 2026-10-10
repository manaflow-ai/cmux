//! The mirror's personal state (workspace groups and placements) against
//! sessions recorded from a real daemon (`fixture::GROUP_EVENTS`,
//! `fixture::GROUP_SNAPSHOT`).

use crate::fixture::{GROUP_EVENTS, GROUP_SNAPSHOT, events};
use crate::mirror::{Applied, Change, Mirror, MirrorChange, MirrorError};
use cmux::{Document, ResourceChange, SessionEvent, WorkspaceId};
use serde_json::json;

const ALPHA: &str = "ws_aa8f83640cab4ae79323021ba072f9c9";
const BETA: &str = "ws_77c7119f00d528146607271bffbf4998";
const WORK: &str = "grp_5260c9f0a00b4699ba58997061b15922";
const PLAY: &str = "grp_6a18dd49a8f64081a43b5532389debae";
const REGISTRY: &str = "91e61811-e9e8-4e54-992c-b4c2d04fb556";
const BETA_PLACEMENT: &str =
    "91e61811-e9e8-4e54-992c-b4c2d04fb556/8a946dcc-0819-4b8e-842a-0610ea60a157";
const ALPHA_PLACEMENT: &str =
    "91e61811-e9e8-4e54-992c-b4c2d04fb556/1eca7b69-bcb2-43c7-8053-e0195b0fdcc1";

fn ws(id: &str) -> WorkspaceId {
    WorkspaceId::parse(id).unwrap()
}

fn delta(mirror: &mut Mirror, event: SessionEvent) -> Vec<MirrorChange> {
    match mirror.apply(event).unwrap() {
        Applied::Delta(changes) => changes,
        other => panic!("expected a delta, got {other:?}"),
    }
}

fn group_names(mirror: &Mirror) -> Vec<(String, u32)> {
    mirror.workspace_groups_ordered().iter().map(|g| (g.name.clone(), g.index)).collect()
}

fn personal_names(mirror: &Mirror) -> Vec<String> {
    mirror.workspaces_in_personal_order().iter().map(|w| w.name.clone()).collect()
}

#[test]
fn replays_recorded_group_operations_as_typed_changes() {
    let recorded = events(GROUP_EVENTS);
    assert_eq!(recorded.len(), 12);
    let mut steps = recorded.into_iter();
    let mut mirror = Mirror::default();
    assert_eq!(mirror.apply(steps.next().unwrap()), Ok(Applied::Reset));
    assert!(mirror.workspace_groups.is_empty() && mirror.workspace_placements.is_empty());

    // rev 1-2: two empty workspaces; no placement rows yet, so the personal
    // order falls back to the daemon order.
    delta(&mut mirror, steps.next().unwrap());
    delta(&mut mirror, steps.next().unwrap());
    assert_eq!(personal_names(&mirror), ["alpha", "beta"]);

    // rev 3: group "Work" created.
    let changes = delta(&mut mirror, steps.next().unwrap());
    assert_eq!(changes, [MirrorChange::WorkspaceGroup(Change::Added(WORK.into()))]);
    let work = &mirror.workspace_groups[WORK];
    assert_eq!(
        (work.name.as_str(), work.color.as_deref(), work.collapsed, work.room_id.as_str()),
        ("Work", Some("#225588"), false, "default")
    );

    // rev 4: beta put into it first; both placements restated.
    let changes = delta(&mut mirror, steps.next().unwrap());
    assert_eq!(
        changes,
        [
            MirrorChange::WorkspacePlacement(Change::Added(BETA_PLACEMENT.into())),
            MirrorChange::WorkspacePlacement(Change::Added(ALPHA_PLACEMENT.into())),
        ]
    );
    assert_eq!(mirror.group_members(WORK), [ws(BETA)]);
    assert_eq!(personal_names(&mirror), ["beta", "alpha"]);
    let beta = mirror.placement_of(&ws(BETA)).unwrap();
    assert_eq!((beta.workspace.session_id.as_str(), beta.room_id.as_ref()), (REGISTRY, None));

    // rev 5: renamed, color cleared; rev 6: collapsed.
    let changes = delta(&mut mirror, steps.next().unwrap());
    assert_eq!(changes, [MirrorChange::WorkspaceGroup(Change::Updated(WORK.into()))]);
    assert_eq!(
        (mirror.workspace_groups[WORK].name.as_str(), &mirror.workspace_groups[WORK].color),
        ("Deep work", &None)
    );
    delta(&mut mirror, steps.next().unwrap());
    assert!(mirror.workspace_groups[WORK].collapsed);

    // rev 7: "Play" created first; "Deep work" restated at index 1.
    let changes = delta(&mut mirror, steps.next().unwrap());
    assert_eq!(
        changes,
        [
            MirrorChange::WorkspaceGroup(Change::Added(PLAY.into())),
            MirrorChange::WorkspaceGroup(Change::Updated(WORK.into())),
        ]
    );
    assert_eq!(group_names(&mirror), [("Play".into(), 0), ("Deep work".into(), 1)]);

    // rev 8: beta ungrouped; rev 9: alpha into "Deep work".
    delta(&mut mirror, steps.next().unwrap());
    assert!(mirror.group_members(WORK).is_empty());
    delta(&mut mirror, steps.next().unwrap());
    assert_eq!(mirror.group_members(WORK), [ws(ALPHA)]);

    // rev 10: "Deep work" deleted; its member ungrouped in the same batch.
    let changes = delta(&mut mirror, steps.next().unwrap());
    assert_eq!(changes[0], MirrorChange::WorkspaceGroup(Change::Removed(WORK.into())));
    assert_eq!(changes.len(), 4);
    assert_eq!(group_names(&mirror), [("Play".into(), 0)]);
    assert!(mirror.workspace_placements.values().all(|p| p.group_id.is_none()));

    // rev 11: rooms are named but not kept.
    let changes = delta(&mut mirror, steps.next().unwrap());
    assert_eq!(
        changes,
        [MirrorChange::IgnoredState("room".into()), MirrorChange::IgnoredState("room".into())]
    );
    assert_eq!(mirror.revision(), Some(11));
    assert!(steps.next().is_none());
}

#[test]
fn snapshot_extra_state_seeds_groups_and_placements() {
    let snapshot = events(GROUP_SNAPSHOT).remove(0);
    let mut mirror = Mirror::default();
    assert_eq!(mirror.apply(snapshot), Ok(Applied::Reset));
    assert_eq!(group_names(&mirror), [("Play".into(), 0)]);
    assert_eq!(mirror.group_members(PLAY), [ws(BETA)]);
    assert_eq!(mirror.placements_ordered().iter().map(|p| p.index).collect::<Vec<_>>(), [0, 1]);
    assert_eq!(personal_names(&mirror), ["beta", "alpha"]);
    assert_eq!(mirror.placement_of(&ws(ALPHA)).unwrap().group_id, None);
}

/// A state change addressed to the mirror's revision, built from the
/// recorded snapshot's cursor.
fn state_delta(mirror: &Mirror, change: serde_json::Value) -> SessionEvent {
    let cursor = mirror.cursor.clone().unwrap();
    let mut next = cursor.clone();
    next.revision += 1;
    let kind = change["kind"].as_str().unwrap().to_string();
    let raw = Document::from_serializable(&change).unwrap();
    SessionEvent::Delta(cmux::SessionDeltaEvent {
        cursor: next.clone(),
        previous_revision: cursor.revision,
        revision: next.revision,
        changes: vec![ResourceChange::Unknown { kind, raw }],
    })
}

fn apply_state(mirror: &mut Mirror, change: serde_json::Value) -> Vec<MirrorChange> {
    let event = state_delta(mirror, change);
    delta(mirror, event)
}

#[test]
fn malformed_state_changes_leave_the_mirror_unchanged() {
    let mut mirror = Mirror::default();
    mirror.apply(events(GROUP_SNAPSHOT).remove(0)).unwrap();
    let before = mirror.clone();
    let group = |value| {
        json!({"kind": "state_upsert", "sequence": 0, "resource": "workspace_group",
               "id": PLAY, "value": value})
    };
    let cases = [
        // The value's id differs from the change id.
        group(json!({"id": WORK, "room_id": "default", "name": "x", "color": null,
                     "collapsed": false, "index": 0})),
        // A missing field.
        group(json!({"id": PLAY, "room_id": "default", "color": null, "collapsed": false,
                     "index": 0})),
        // An unknown field.
        group(json!({"id": PLAY, "room_id": "default", "name": "x", "color": null,
                     "collapsed": false, "index": 0, "pinned": true})),
        // A placement whose workspace does not match its id.
        json!({"kind": "state_upsert", "sequence": 0, "resource": "workspace_placement",
               "id": ALPHA_PLACEMENT, "value": {"workspace": {"session_id": REGISTRY,
               "workspace_ref": "other", "workspace_id": null}, "index": 0,
               "group_id": null, "room_id": null}}),
    ];
    for case in cases {
        let error = mirror.apply(state_delta(&mirror, case.clone())).unwrap_err();
        assert!(matches!(error, MirrorError::InvalidState { .. }), "{case}: {error:?}");
        assert_eq!(mirror, before);
    }
}

#[test]
fn state_deletes_of_absent_rows_and_unknown_kinds_are_ignored() {
    let mut mirror = Mirror::default();
    mirror.apply(events(GROUP_SNAPSHOT).remove(0)).unwrap();
    let gone = json!({"kind": "state_delete", "sequence": 0, "resource": "workspace_group",
                      "id": WORK});
    let changes = apply_state(&mut mirror, gone);
    assert_eq!(changes, [MirrorChange::IgnoredState("workspace_group".into())]);
    let delete = json!({"kind": "state_delete", "sequence": 0,
                        "resource": "workspace_placement", "id": ALPHA_PLACEMENT});
    let changes = apply_state(&mut mirror, delete);
    assert_eq!(
        changes,
        [MirrorChange::WorkspacePlacement(Change::Removed(ALPHA_PLACEMENT.into()))]
    );
    // Alpha has no placement now: it follows the placed workspaces.
    assert_eq!(personal_names(&mirror), ["beta", "alpha"]);
    let future = json!({"kind": "future_change", "sequence": 0});
    assert_eq!(apply_state(&mut mirror, future), [MirrorChange::Ignored(None)]);
}
