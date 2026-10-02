use crate::fixture::recorded;
use crate::mirror::{Applied, Change, Mirror, MirrorChange, MirrorError};
use cmux::{SessionEvent, TabContentId, WorkspaceId};

fn names(mirror: &Mirror) -> Vec<String> {
    mirror.workspaces_ordered().iter().map(|w| w.name.clone()).collect()
}

fn ws(id: &str) -> WorkspaceId {
    WorkspaceId::parse(id).unwrap()
}

const ALPHA: &str = "ws_d3d26af068bda672e5d8a00329032823";
const GAMMA: &str = "ws_d4d2738e890429883e645aa52b7cc095";

#[test]
fn replays_recorded_session() {
    let events = recorded();
    assert_eq!(events.len(), 6);
    let mut mirror = Mirror::default();
    let mut steps = events.into_iter();

    assert_eq!(mirror.apply(steps.next().unwrap()), Ok(Applied::Reset));
    assert_eq!(mirror.revision(), Some(0));
    assert!(mirror.workspaces.is_empty());
    assert_eq!(mirror.clients.len(), 1);

    // rev 1: workspace "alpha" with one screen, pane, terminal tab.
    let Applied::Delta(changes) = mirror.apply(steps.next().unwrap()).unwrap() else { panic!() };
    assert_eq!(changes[0], MirrorChange::Workspace(Change::Added(ws(ALPHA))));
    assert_eq!(changes.len(), 5);
    assert_eq!(names(&mirror), ["alpha"]);
    let screens = mirror.screens_of(&ws(ALPHA));
    assert_eq!(screens.len(), 1);
    let panes = mirror.panes_of(&screens[0].id);
    assert_eq!(panes.len(), 1);
    let tabs = mirror.tabs_of(&panes[0].id);
    assert_eq!(tabs.len(), 1);
    let TabContentId::Terminal(term) = tabs[0].content_id.clone() else { panic!("terminal tab") };
    assert!(mirror.terminals.contains_key(&term));

    // rev 2: terminal title update.
    let Applied::Delta(changes) = mirror.apply(steps.next().unwrap()).unwrap() else { panic!() };
    assert!(matches!(&changes[..], [MirrorChange::Terminal(Change::Updated(id))] if *id == term));
    assert_eq!(mirror.terminals[&term].title, "user@host:~/project");

    // rev 3: rename.
    mirror.apply(steps.next().unwrap()).unwrap();
    assert_eq!(names(&mirror), ["beta"]);

    // rev 4: second workspace takes focus.
    mirror.apply(steps.next().unwrap()).unwrap();
    assert_eq!(names(&mirror), ["beta", "gamma"]);
    assert!(mirror.workspaces[&ws(GAMMA)].focused);
    assert!(!mirror.workspaces[&ws(ALPHA)].focused);
    assert_eq!(mirror.tabs.len(), 2);

    // rev 5: close gamma; its terminal survives (reap grace), its tree goes.
    let Applied::Delta(changes) = mirror.apply(steps.next().unwrap()).unwrap() else { panic!() };
    assert!(changes.contains(&MirrorChange::Workspace(Change::Removed(ws(GAMMA)))));
    assert_eq!(names(&mirror), ["beta"]);
    assert!(mirror.workspaces[&ws(ALPHA)].focused);
    assert_eq!((mirror.screens.len(), mirror.panes.len(), mirror.tabs.len()), (1, 1, 1));
    assert_eq!(mirror.terminals.len(), 2);
    assert_eq!(mirror.revision(), Some(5));
    assert_eq!(mirror.session.as_ref().unwrap().revision, 5);

    let tree = mirror.render_tree();
    assert!(tree.contains("workspace ws_d3d26af068bda672e5d8a00329032823 \"beta\" *"), "{tree}");
}

#[test]
fn delta_before_snapshot_is_rejected() {
    let events = recorded();
    let mut mirror = Mirror::default();
    assert_eq!(mirror.apply(events[1].clone()), Err(MirrorError::NoBaseline));
}

#[test]
fn revision_gap_leaves_mirror_unchanged() {
    let events = recorded();
    let mut mirror = Mirror::default();
    mirror.apply(events[0].clone()).unwrap();
    mirror.apply(events[1].clone()).unwrap();
    let before = mirror.clone();
    // Skip rev 2 and 3.
    assert_eq!(
        mirror.apply(events[4].clone()),
        Err(MirrorError::RevisionGap { mirror: 1, previous: 3 })
    );
    assert_eq!(mirror, before);
    // Replaying an already-applied delta is also a gap.
    assert!(matches!(mirror.apply(events[1].clone()), Err(MirrorError::RevisionGap { .. })));
}

#[test]
fn new_generation_without_snapshot_is_rejected() {
    let events = recorded();
    let mut mirror = Mirror::default();
    mirror.apply(events[0].clone()).unwrap();
    let SessionEvent::Delta(mut delta) = events[1].clone() else { panic!() };
    delta.cursor.generation = "11111111-2222-3333-4444-555555555555".into();
    assert!(matches!(
        mirror.apply(SessionEvent::Delta(delta)),
        Err(MirrorError::GenerationChanged { .. })
    ));
}

#[test]
fn snapshot_mid_stream_resets() {
    let events = recorded();
    let mut mirror = Mirror::default();
    for event in events.iter().take(5).cloned() {
        mirror.apply(event).unwrap();
    }
    assert_eq!(mirror.workspaces.len(), 2);
    // A snapshot item (e.g. cursor_expired) replaces everything.
    assert_eq!(mirror.apply(events[0].clone()), Ok(Applied::Reset));
    assert!(mirror.workspaces.is_empty());
    assert_eq!(mirror.revision(), Some(0));
}

#[test]
fn delete_of_unknown_resource_is_ignored() {
    let events = recorded();
    let mut mirror = Mirror::default();
    mirror.apply(events[0].clone()).unwrap();
    mirror.apply(events[1].clone()).unwrap();
    mirror.apply(events[2].clone()).unwrap();
    mirror.apply(events[3].clone()).unwrap();
    // Rev 4 -> 5 deletes gamma, which this mirror never saw (rev 4 skipped
    // by forcing the cursor): deletes of absent IDs are not errors.
    mirror.cursor.as_mut().unwrap().revision = 4;
    let Applied::Delta(changes) = mirror.apply(events[5].clone()).unwrap() else { panic!() };
    assert!(
        changes
            .iter()
            .any(|c| matches!(c, MirrorChange::Ignored(Some(cmux::ResourceKind::Workspace))))
    );
    assert_eq!(names(&mirror), ["beta"]);
}

/// Documents the daemon/SDK mismatch at the pinned commit: when this starts
/// failing, the SDK (or daemon) is fixed and `patch_detached_terminal` can go.
#[test]
fn pinned_sdk_rejects_detached_terminal_upsert() {
    let line = crate::fixture::SESSION_EVENTS.lines().last().unwrap();
    let envelope: serde_json::Value = serde_json::from_str(line).unwrap();
    let detached = envelope["item"]["changes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["resource"] == "terminal" && c["value"]["tab_ids"] == serde_json::json!([]))
        .expect("detached terminal upsert")["value"]
        .clone();
    assert!(serde_json::from_value::<cmux::TerminalSnapshot>(detached.clone()).is_err());
    let patched = crate::fixture::patch_detached_terminal(&detached);
    assert!(serde_json::from_value::<cmux::TerminalSnapshot>(patched).is_ok());
}
