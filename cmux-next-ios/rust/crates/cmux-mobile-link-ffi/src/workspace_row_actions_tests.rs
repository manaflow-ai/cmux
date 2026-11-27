//! Mirrors WorkspaceRowActionsTests.swift: where New Workspace puts a row and what a row can
//! merge into.

use super::*;
use WorkspaceRowPlacement as P;

fn row(id: &str, index: Option<i64>) -> WorkspaceRowFacts {
    WorkspaceRowFacts {
        id: id.into(),
        mac_id: "m".into(),
        sidebar_index: index,
        pinned: false,
        home: false,
        grouped: false,
        pending: false,
    }
}

fn ids(rows: &[&str]) -> Vec<String> {
    rows.iter().map(|s| s.to_string()).collect()
}

#[test]
fn a_row_offers_above_below_top_and_bottom() {
    assert_eq!(
        workspace_row_placements(row("b", Some(1)), true, true),
        vec![P::Above, P::Below, P::Top, P::Bottom]
    );
}

#[test]
fn a_pinned_row_offers_only_the_edges_and_home_nothing() {
    let pinned = WorkspaceRowFacts { pinned: true, ..row("p", Some(0)) };
    assert_eq!(workspace_row_placements(pinned, true, true), vec![P::Top, P::Bottom]);
    let home = WorkspaceRowFacts { home: true, ..row("h", None) };
    assert!(workspace_row_placements(home, true, true).is_empty());
    assert!(workspace_row_placements(row("b", Some(1)), false, true).is_empty());
    assert!(workspace_row_placements(row("b", Some(1)), true, false).is_empty());
}

#[test]
fn edge_anchors_skip_pinned_rows_and_home() {
    let rows = vec![
        WorkspaceRowFacts { pinned: true, ..row("p", Some(0)) },
        WorkspaceRowFacts { grouped: true, ..row("g", Some(1)) },
        row("x", Some(2)),
        row("y", Some(3)),
        WorkspaceRowFacts { home: true, ..row("h", Some(5)) },
        row("new", Some(4)),
    ];
    // Top skips the grouped first row; bottom is the last row.
    assert_eq!(workspace_new_row_anchor(true, "new".into(), "m".into(), rows.clone()), Some("x".into()));
    assert_eq!(workspace_new_row_anchor(false, "new".into(), "m".into(), rows), Some("y".into()));
    assert_eq!(workspace_new_row_anchor(true, "new".into(), "m".into(), vec![row("new", Some(4))]), None);
}

/// Every first row grouped: Top goes before the first one anyway.
#[test]
fn top_falls_back_to_the_first_row_when_every_row_is_grouped() {
    let rows = vec![WorkspaceRowFacts { grouped: true, ..row("g", Some(0)) }, row("new", None)];
    assert_eq!(workspace_new_row_anchor(true, "new".into(), "m".into(), rows), Some("g".into()));
}

/// Sidebar order, rows with no index last in list order, other Macs, Home, itself and pending
/// rows left out.
#[test]
fn merge_targets_are_the_macs_others_in_sidebar_order() {
    let rows = vec![
        row("src", Some(1)),
        row("late-a", None),
        row("c", Some(2)),
        WorkspaceRowFacts { mac_id: "other".into(), ..row("o", Some(0)) },
        WorkspaceRowFacts { home: true, ..row("h", Some(0)) },
        WorkspaceRowFacts { pending: true, ..row("p", Some(3)) },
        row("a", Some(0)),
        row("late-b", None),
    ];
    assert_eq!(workspace_merge_targets("src".into(), "m".into(), rows), ids(&["a", "c", "late-a", "late-b"]));
}
