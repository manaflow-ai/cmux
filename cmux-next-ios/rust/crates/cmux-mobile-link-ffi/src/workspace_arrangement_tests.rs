//! The Swift cases of `WorkspaceArrangementTests.swift`, ported, plus edge cases.

use super::*;

fn row(session: &str, key: &str, index: i64) -> PhoneSidebarRow {
    PhoneSidebarRow { session: session.into(), key: key.into(), index, group: None }
}

fn grouped(session: &str, key: &str, index: i64, group: &str) -> PhoneSidebarRow {
    PhoneSidebarRow { group: Some(group.into()), ..row(session, key, index) }
}

fn group(id: &str, index: i64, top_index: Option<i64>) -> PhoneWorkspaceGroup {
    PhoneWorkspaceGroup {
        id: id.into(),
        name: id.into(),
        color: None,
        is_collapsed: false,
        index,
        top_index,
        room: None,
        is_pinned: None,
    }
}

fn pin(item: &str, value: &str) -> ArrangementPin {
    ArrangementPin { item_id: item.into(), value: value.into() }
}

fn workspaces(ids: &[&str], resource: bool) -> Vec<ArrangementWorkspace> {
    ids.iter()
        .map(|id| ArrangementWorkspace {
            id: (*id).into(),
            resource_id: resource.then(|| format!("ws_{id}")),
        })
        .collect()
}

fn ids(list: &[&str]) -> Vec<String> {
    list.iter().map(|s| (*s).to_owned()).collect()
}

fn input(ids: &[&str]) -> ArrangementInput {
    ArrangementInput {
        workspaces: workspaces(ids, true),
        registry_id: Some("reg".into()),
        legacy_pinned: vec![],
        rows: None,
        pins: None,
        groups: vec![],
    }
}

/// The Mac's order: personal rows by place, the rest after in daemon order;
/// pins are the tiles of this session's workspaces, in tile order.
#[test]
fn applies_the_macs_order_and_pins() {
    let places = workspace_arrangement_apply(ArrangementInput {
        legacy_pinned: ids(&["b"]),
        rows: Some(vec![row("reg", "c", 0), row("other", "z", 1), row("reg", "a", 2)]),
        pins: Some(vec![pin("itm_1", "reg:ws_d"), pin("itm_2", "other:ws_b")]),
        ..input(&["a", "b", "c", "d"])
    });
    let (a, b, c, d) = (&places[0], &places[1], &places[2], &places[3]);
    assert_eq!(c.sidebar_index, 0);
    assert_eq!(a.sidebar_index, 2);
    // No personal row: after every row, in the daemon's order.
    assert_eq!(b.sidebar_index, 3 + 1);
    assert_eq!(d.sidebar_index, 3 + 3);
    assert!(d.is_pinned);
    assert_eq!(d.pin_index, Some(0));
    assert_eq!(d.pin_item_id.as_deref(), Some("itm_1"));
    // Another session's tile is not this workspace's; the legacy flag still
    // shows it pinned until the Mac turns it into a tile, after every tile.
    assert!(b.is_pinned);
    assert_eq!(b.pin_item_id, None);
    assert_eq!(b.pin_index, Some(2 + 1));
    assert!(!a.is_pinned && !c.is_pinned);
    assert!(places.iter().all(|p| p.group.is_none()));
}

/// An older Mac: the daemon's order and its pin flags.
#[test]
fn older_mac_uses_the_daemon_order_and_flags() {
    let places = workspace_arrangement_apply(ArrangementInput {
        workspaces: workspaces(&["a", "b", "c"], false),
        registry_id: None,
        legacy_pinned: ids(&["c"]),
        rows: None,
        pins: None,
        groups: vec![],
    });
    assert_eq!(places.iter().map(|p| p.sidebar_index).collect::<Vec<_>>(), vec![0, 1, 2]);
    assert_eq!(places.iter().map(|p| p.is_pinned).collect::<Vec<_>>(), vec![false, false, true]);
    assert_eq!(places[2].pin_index, Some(2));
}

/// The first tile wins when two tiles name the same workspace.
#[test]
fn a_doubled_tile_keeps_the_first() {
    let places = workspace_arrangement_apply(ArrangementInput {
        pins: Some(vec![pin("itm_1", "reg:ws_a"), pin("itm_2", "reg:ws_a")]),
        ..input(&["a"])
    });
    assert_eq!(places[0].pin_index, Some(0));
    assert_eq!(places[0].pin_item_id.as_deref(), Some("itm_1"));
}

/// Groups: before row i come the groups whose top index is i, then row i
/// when loose; rowless workspaces follow, then groups placed after every row.
#[test]
fn groups_take_the_macs_mixed_order() {
    let places = workspace_arrangement_apply(ArrangementInput {
        rows: Some(vec![
            row("reg", "a", 0),
            grouped("reg", "b", 1, "g1"),
            row("reg", "c", 2),
            grouped("reg", "d", 3, "g2"),
            grouped("reg", "e", 4, "gone"),
        ]),
        groups: vec![group("g2", 1, None), group("g1", 0, Some(0))],
        ..input(&["a", "b", "c", "d", "e", "f"])
    });
    let order: HashMap<i64, &str> =
        places.iter().zip(["a", "b", "c", "d", "e", "f"]).map(|(p, id)| (p.sidebar_index, id)).collect();
    let mut keys: Vec<i64> = order.keys().copied().collect();
    keys.sort_unstable();
    // g1 (b) before row 0, then a, c, e (its group is unknown: loose), then f (no row), then g2 (d).
    assert_eq!(keys.iter().map(|k| order[k]).collect::<Vec<_>>(), vec!["b", "a", "c", "e", "f", "d"]);
    assert_eq!(places[1].group.as_deref(), Some("g1"));
    assert_eq!(places[3].group.as_deref(), Some("g2"));
    assert_eq!(places[4].group, None);
}

/// Groups only count with a registry and a personal order.
#[test]
fn groups_need_a_personal_order() {
    let places = workspace_arrangement_apply(ArrangementInput {
        groups: vec![group("g", 0, Some(0))],
        ..input(&["a", "b"])
    });
    assert_eq!(places.iter().map(|p| p.sidebar_index).collect::<Vec<_>>(), vec![0, 1]);
}

#[test]
fn edges_of_the_container() {
    let order = ids(&["a", "b", "c"]);
    let anchor = |edge, ws: &str| workspace_edge_anchor(edge, ws.into(), order.clone());
    assert_eq!(
        anchor(WorkspaceEdgeSide::Top, "c"),
        Some(WorkspaceAnchor { anchor: "a".into(), after: false })
    );
    assert_eq!(
        anchor(WorkspaceEdgeSide::Bottom, "a"),
        Some(WorkspaceAnchor { anchor: "c".into(), after: true })
    );
    assert_eq!(anchor(WorkspaceEdgeSide::Top, "a"), None);
    assert_eq!(anchor(WorkspaceEdgeSide::Bottom, "c"), None);
    assert_eq!(anchor(WorkspaceEdgeSide::Top, "x"), None);
    assert_eq!(workspace_edge_anchor(WorkspaceEdgeSide::Top, "a".into(), vec![]), None);
}

fn sort_row(id: &str, directory: &str, focus: i64, at: Option<f64>) -> WorkspaceSortRow {
    WorkspaceSortRow {
        id: id.into(),
        title: id.into(),
        directory: directory.into(),
        last_activity_at: at,
        focus_order: focus,
    }
}

fn sorted_ids(key: WorkspaceSortBy, rows: &[WorkspaceSortRow]) -> Vec<String> {
    workspace_sorted(key, rows.to_vec()).into_iter().map(|i| rows[i as usize].id.clone()).collect()
}

/// The Mac's `WorkspaceSortKey`: Finder name order, folder then name, most recent first.
#[test]
fn sort_keys_order_as_the_mac() {
    let rows = vec![
        sort_row("b10", "~/z", 1, None),
        sort_row("a", "~/y", 4, None),
        sort_row("b2", "~/y", 9, None),
        sort_row("c", "", 2, None),
    ];
    assert_eq!(sorted_ids(WorkspaceSortBy::Name, &rows), ids(&["a", "b2", "b10", "c"]));
    assert_eq!(sorted_ids(WorkspaceSortBy::Directory, &rows), ids(&["a", "b2", "b10", "c"]));
    assert_eq!(sorted_ids(WorkspaceSortBy::LastUsed, &rows), ids(&["b2", "a", "c", "b10"]));
}

/// Rows with a time come first, newest first; then focus order; then their place.
#[test]
fn last_used_prefers_known_times() {
    let rows = vec![
        sort_row("old", "", 9, Some(10.0)),
        sort_row("none", "", 99, None),
        sort_row("new", "", 0, Some(20.0)),
        sort_row("tie1", "", 5, Some(10.0)),
        sort_row("same", "", 99, None),
    ];
    assert_eq!(sorted_ids(WorkspaceSortBy::LastUsed, &rows), ids(&["new", "old", "tie1", "none", "same"]));
}

/// Names equal but for case keep their order; digits compare by value.
#[test]
fn finder_order_rules() {
    assert_eq!(finder_order("Alpha", "alpha"), Ordering::Equal);
    assert_eq!(finder_order("a9", "a10"), Ordering::Less);
    assert_eq!(finder_order("a010", "a9"), Ordering::Greater);
    assert_eq!(finder_order("Zed", "alpha"), Ordering::Greater);
    assert_eq!(finder_order("ab", "abc"), Ordering::Less);
    let rows = vec![sort_row("B", "", 0, None), sort_row("b", "", 0, None), sort_row("a", "", 0, None)];
    assert_eq!(sorted_ids(WorkspaceSortBy::Name, &rows), ids(&["a", "B", "b"]));
}

fn close_row(id: &str, group: Option<&str>, home: bool) -> WorkspaceCloseRow {
    WorkspaceCloseRow { id: id.into(), group: group.map(Into::into), is_home: home }
}

fn close_ids(kind: WorkspaceCloseKind, ws: &str, order: &[WorkspaceCloseRow]) -> Vec<String> {
    workspace_close_targets(kind, ws.into(), order.to_vec())
        .into_iter()
        .map(|i| order[i as usize].id.clone())
        .collect()
}

#[test]
fn bulk_close_targets() {
    let order: Vec<_> = ["a", "b", "c", "d"].iter().map(|id| close_row(id, None, false)).collect();
    assert_eq!(close_ids(WorkspaceCloseKind::Others, "b", &order), ids(&["a", "c", "d"]));
    assert_eq!(close_ids(WorkspaceCloseKind::Above, "b", &order), ids(&["a"]));
    assert_eq!(close_ids(WorkspaceCloseKind::Below, "b", &order), ids(&["c", "d"]));
    assert!(close_ids(WorkspaceCloseKind::Above, "a", &order).is_empty());
    assert!(close_ids(WorkspaceCloseKind::All, "x", &order).is_empty());
    assert_eq!(workspace_close_question(1), "Close 1 workspace?");
    assert_eq!(workspace_close_question(3), "Close 3 workspaces?");
}

/// Close Other Workspaces in Group and Close All Workspaces; Home never closes.
#[test]
fn group_and_all_close_targets() {
    let order = vec![
        close_row("home", None, true),
        close_row("a", Some("g"), false),
        close_row("b", Some("g"), false),
        close_row("c", None, false),
    ];
    assert_eq!(close_ids(WorkspaceCloseKind::OthersInGroup, "a", &order), ids(&["b"]));
    assert!(close_ids(WorkspaceCloseKind::OthersInGroup, "c", &order).is_empty());
    assert_eq!(close_ids(WorkspaceCloseKind::All, "b", &order), ids(&["a", "b", "c"]));
    assert_eq!(close_ids(WorkspaceCloseKind::All, "home", &order), ids(&["a", "b", "c"]));
    assert_eq!(close_ids(WorkspaceCloseKind::Others, "a", &order), ids(&["b", "c"]));
    assert_eq!(close_ids(WorkspaceCloseKind::Others, "home", &order), ids(&["a", "b", "c"]));
    assert_eq!(close_ids(WorkspaceCloseKind::Below, "home", &order), ids(&["a", "b", "c"]));
    assert_eq!(close_ids(WorkspaceCloseKind::Above, "b", &order), ids(&["a"]));
}

fn container_row(group: Option<&str>, place: Option<i64>) -> WorkspaceContainerRow {
    WorkspaceContainerRow { group: group.map(Into::into), sidebar_index: place }
}

/// The loose rows first, then each group in the order its first row shows,
/// each by sidebar place (rows without one last, ties in input order).
#[test]
fn containers_split_loose_rows_and_groups() {
    let rows = vec![
        container_row(Some("g2"), Some(1)),
        container_row(None, Some(5)),
        container_row(Some("g1"), Some(3)),
        container_row(Some("g2"), Some(0)),
        container_row(None, None),
        container_row(None, Some(2)),
        container_row(None, None),
    ];
    assert_eq!(workspace_containers(rows), vec![vec![5, 1, 4, 6], vec![3, 0], vec![2]]);
    // No loose rows: only the groups.
    assert_eq!(workspace_containers(vec![container_row(Some("g"), Some(0))]), vec![vec![0]]);
    assert!(workspace_containers(vec![]).is_empty());
}
