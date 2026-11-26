use super::*;

fn group(id: &str, index: i64, top: Option<i64>) -> PhoneWorkspaceGroup {
    PhoneWorkspaceGroup {
        id: id.into(),
        name: id.to_uppercase(),
        color: None,
        is_collapsed: false,
        index,
        top_index: top,
        room: None,
        is_pinned: None,
    }
}

fn row(session: &str, key: &str, index: i64, group: Option<&str>) -> PhoneSidebarRow {
    PhoneSidebarRow { session: session.into(), key: key.into(), index, group: group.map(Into::into) }
}

fn ids(list: &[&str]) -> Vec<String> {
    list.iter().map(|s| (*s).to_owned()).collect()
}

/// The workspace ids in sidebar order.
fn order(slots: &[WorkspaceGroupSlot], workspaces: &[&str]) -> Vec<String> {
    let mut pairs: Vec<(i64, &str)> =
        slots.iter().zip(workspaces).map(|(s, w)| (s.sidebar_index, *w)).collect();
    pairs.sort();
    pairs.into_iter().map(|(_, w)| w.to_owned()).collect()
}

#[test]
fn groups_sit_before_their_top_row_and_loose_rows_keep_their_place() {
    let rows = vec![
        row("me", "a", 0, None),
        row("me", "b", 1, Some("g")),
        row("me", "c", 2, None),
        row("me", "d", 3, Some("g")),
    ];
    let groups = vec![group("g", 0, Some(2))];
    let ws = ["d", "c", "b", "a"];
    let slots = workspace_group_slots(rows, groups, ids(&ws), "me".into());
    assert_eq!(order(&slots, &ws), ids(&["a", "b", "d", "c"]));
    assert_eq!(slots[0].group.as_deref(), Some("g"));
    assert_eq!(slots[1].group, None);
}

#[test]
fn groups_after_every_row_and_rowless_workspaces_follow_the_rows() {
    let rows = vec![row("me", "a", 0, Some("late")), row("me", "b", 1, None)];
    let groups = vec![group("late", 0, None)];
    let ws = ["new", "a", "b"];
    let slots = workspace_group_slots(rows, groups, ids(&ws), "me".into());
    assert_eq!(order(&slots, &ws), ids(&["b", "new", "a"]));
}

#[test]
fn a_top_index_past_the_rows_counts_as_after_them() {
    let rows = vec![row("me", "a", 0, Some("g")), row("me", "b", 1, None)];
    let slots = workspace_group_slots(rows, vec![group("g", 0, Some(9))], ids(&["a", "b"]), "me".into());
    assert_eq!(order(&slots, &["a", "b"]), ids(&["b", "a"]));
}

#[test]
fn other_sessions_rows_take_a_place_but_never_join_the_order() {
    // Another Mac's row at place 0 moves this Mac's group, which sits before row 1, after it.
    let rows = vec![row("other", "x", 0, None), row("me", "a", 1, None), row("me", "b", 2, Some("g"))];
    let ws = ["a", "b"];
    let slots = workspace_group_slots(rows, vec![group("g", 0, Some(1))], ids(&ws), "me".into());
    assert_eq!(order(&slots, &ws), ids(&["b", "a"]));
    assert_eq!(slots[0].sidebar_index, 1);
    assert_eq!(slots[1].sidebar_index, 0);
}

#[test]
fn a_row_in_a_group_the_list_lacks_is_loose() {
    let rows = vec![row("me", "a", 0, Some("gone"))];
    let slots = workspace_group_slots(rows, vec![], ids(&["a"]), "me".into());
    assert_eq!(slots, vec![WorkspaceGroupSlot { sidebar_index: 0, group: None }]);
}

#[test]
fn groups_emit_in_group_order_and_rows_sort_by_place() {
    let rows = vec![row("me", "b", 5, Some("g2")), row("me", "a", 1, Some("g1"))];
    let groups = vec![group("g2", 1, Some(0)), group("g1", 0, Some(0))];
    let ws = ["b", "a"];
    let slots = workspace_group_slots(rows, groups, ids(&ws), "me".into());
    assert_eq!(order(&slots, &ws), ids(&["a", "b"]));
}

#[test]
fn a_workspace_missing_from_the_order_goes_after_it() {
    let slots = workspace_group_slots(vec![], vec![], ids(&["a", "b"]), "me".into());
    assert_eq!(slots.iter().map(|s| s.sidebar_index).collect::<Vec<_>>(), vec![0, 1]);
}

fn edit(group: Option<PhoneWorkspaceGroup>, sent: Option<f64>, answered: Option<f64>) -> PendingGroupEdit {
    PendingGroupEdit { group, holds: true, sent_at: sent, answered_at: answered }
}

#[test]
fn a_non_holding_edit_passes_the_macs_group_through() {
    let mut e = edit(Some(group("pending", 0, None)), Some(0.0), None);
    e.holds = false;
    assert_eq!(pending_group_edit_step(e, None, 1.0), GroupEditStep::Pass);
}

#[test]
fn an_unanswered_edit_holds_until_its_window_passes() {
    let mut collapsed = group("g", 0, None);
    collapsed.is_collapsed = true;
    let e = edit(Some(collapsed), Some(100.0), None);
    let incoming = Some(group("g", 3, None));
    let mut shown = incoming.clone().unwrap();
    shown.is_collapsed = true;
    assert_eq!(
        pending_group_edit_step(e.clone(), incoming.clone(), 120.0),
        GroupEditStep::Hold { group: Some(shown) }
    );
    assert_eq!(pending_group_edit_step(e, incoming, 131.0), GroupEditStep::Forget);
}

#[test]
fn a_queued_edit_never_expires() {
    let e = edit(Some(group("g", 0, None)), None, None);
    assert!(matches!(pending_group_edit_step(e, None, 1e9), GroupEditStep::Hold { .. }));
}

#[test]
fn an_unanswered_edit_holds_even_when_a_refresh_shows_it() {
    let g = group("g", 0, None);
    let e = edit(Some(g.clone()), Some(0.0), None);
    assert!(matches!(pending_group_edit_step(e, Some(g), 1.0), GroupEditStep::Hold { .. }));
}

#[test]
fn an_answered_edit_ends_when_a_refresh_shows_it_or_its_window_passes() {
    let g = group("g", 0, None);
    let e = edit(Some(g), Some(0.0), Some(1.0));
    assert_eq!(pending_group_edit_step(e.clone(), Some(group("g", 7, Some(2))), 2.0), GroupEditStep::Forget);
    assert!(matches!(pending_group_edit_step(e.clone(), None, 5.0), GroupEditStep::Hold { group: Some(_) }));
    assert_eq!(pending_group_edit_step(e, None, 11.5), GroupEditStep::Forget);
}

#[test]
fn a_removal_holds_no_group_and_ends_when_shown() {
    let e = edit(None, Some(0.0), Some(0.0));
    assert_eq!(
        pending_group_edit_step(e.clone(), Some(group("g", 0, None)), 1.0),
        GroupEditStep::Hold { group: None }
    );
    assert_eq!(pending_group_edit_step(e, None, 1.0), GroupEditStep::Forget);
}

#[test]
fn a_move_to_another_group_takes_the_macs_index() {
    let target = group("new", 0, None);
    let e = edit(Some(target.clone()), Some(0.0), None);
    let mut expected = target;
    expected.index = 4;
    assert_eq!(
        pending_group_edit_step(e, Some(group("old", 4, Some(1))), 1.0),
        GroupEditStep::Hold { group: Some(expected) }
    );
}
