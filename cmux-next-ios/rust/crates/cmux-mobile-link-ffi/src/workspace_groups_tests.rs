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

fn named(id: &str, name: &str, color: Option<&str>, collapsed: bool, index: i64) -> PhoneWorkspaceGroup {
    PhoneWorkspaceGroup {
        name: name.into(),
        color: color.map(Into::into),
        is_collapsed: collapsed,
        ..group(id, index, None)
    }
}

#[test]
fn many_groups_and_rows_keep_the_mixed_order() {
    // Linear in rows plus groups: every group sits before its own row.
    let n = 2_000;
    let rows: Vec<PhoneSidebarRow> = (0..n)
        .map(|i| row("me", &format!("w{i}"), i, (i % 2 == 1).then(|| format!("g{i}")).as_deref()))
        .collect();
    let groups: Vec<PhoneWorkspaceGroup> =
        (0..n).filter(|i| i % 2 == 1).map(|i| group(&format!("g{i}"), i, Some(i - 1))).collect();
    let ws: Vec<String> = (0..n).map(|i| format!("w{i}")).collect();
    let slots = workspace_group_slots(rows, groups, ws.clone(), "me".into());
    // Group g(2k+1) sits before row 2k, so w(2k+1) comes right before w(2k).
    assert_eq!(slots[1].sidebar_index, 0);
    assert_eq!(slots[0].sidebar_index, 1);
    assert_eq!(slots[1].group.as_deref(), Some("g1"));
}

#[test]
fn own_groups_skip_groups_with_other_sessions_rows() {
    let rows = vec![
        row("me", "a", 0, Some("mine")),
        row("other", "x", 1, Some("shared")),
        row("me", "b", 2, Some("shared")),
    ];
    let groups = vec![group("shared", 0, None), group("empty", 2, None), group("mine", 1, None)];
    let own = workspace_group_own(rows, groups.clone(), "me".into());
    let own: Vec<&str> = own.iter().map(|&i| groups[i as usize].id.as_str()).collect();
    assert_eq!(own, ["mine", "empty"]);
}

#[test]
fn new_group_room_uses_pin_then_following_room_then_default() {
    let rooms = vec![
        WorkspaceGroupRoom { id: "home".into(), index: 2, follows: ids(&["reg"]) },
        WorkspaceGroupRoom { id: "default".into(), index: 0, follows: vec![] },
        WorkspaceGroupRoom { id: "work".into(), index: 1, follows: ids(&["reg"]) },
    ];
    let pins = vec![WorkspaceGroupRoomPin { session: "reg".into(), key: "d".into(), room: "home".into() }];
    assert_eq!(workspace_group_room(rooms.clone(), pins.clone(), "d".into(), "reg".into()), "home");
    assert_eq!(workspace_group_room(rooms.clone(), pins.clone(), "a".into(), "reg".into()), "work");
    assert_eq!(workspace_group_room(rooms, pins, "a".into(), "elsewhere".into()), "default");
}

#[test]
fn next_color_follows_the_macs_automatic_order() {
    assert_eq!(workspace_group_next_color(vec![]), "red");
    assert_eq!(workspace_group_next_color(ids(&["red", "green"])), "yellow");
    assert_eq!(workspace_group_next_color(ids(&AUTOMATIC_COLORS)), "grey");
}

#[test]
fn names_trim_and_fall_back() {
    assert_eq!(workspace_group_new_name("  ".into()), "New Group");
    assert_eq!(workspace_group_new_name(" API \n".into()), "API");
    assert_eq!(workspace_group_rename("Backend".into(), "  Server ".into()), Some("Server".into()));
    assert_eq!(workspace_group_rename("Backend".into(), " Backend ".into()), None);
    assert_eq!(workspace_group_rename("Backend".into(), "   ".into()), None);
    assert_eq!(workspace_group_display_name("".into()), "Unnamed Group");
    assert_eq!(workspace_group_display_name(" \t".into()), "Unnamed Group");
    assert_eq!(workspace_group_display_name("\n".into()), "\n");
    assert_eq!(workspace_group_display_name("Backend".into()), "Backend");
}

#[test]
fn shown_groups_are_first_occurrences_in_sidebar_order() {
    let r = |i: Option<i64>, g: Option<&str>| WorkspaceGroupShownRow {
        sidebar_index: i,
        group: g.map(Into::into),
    };
    let rows = vec![
        r(Some(3), Some("b")),
        r(None, Some("c")),
        r(Some(1), Some("a")),
        r(Some(0), None),
        r(Some(2), Some("b")),
    ];
    assert_eq!(workspace_group_shown(rows), [2, 4, 1]);
}

#[test]
fn fold_changes_for_collapse_others_and_all() {
    let f = |id: &str, c: bool| WorkspaceGroupFold { id: id.into(), collapsed: c };
    let shown = vec![f("a", true), f("b", false), f("c", true)];
    assert_eq!(
        workspace_group_fold_changes(shown.clone(), Some("a".into()), true),
        [f("a", false), f("b", true)]
    );
    assert!(
        workspace_group_fold_changes(vec![f("a", false), f("b", true)], Some("a".into()), true).is_empty()
    );
    assert_eq!(workspace_group_fold_changes(shown.clone(), None, true), [f("b", true)]);
    assert_eq!(workspace_group_fold_changes(shown, None, false), [f("a", false), f("c", false)]);
}

fn edit_row(id: &str, g: Option<PhoneWorkspaceGroup>) -> GroupEditRow {
    GroupEditRow { id: id.into(), group: g }
}

#[test]
fn ledger_holds_until_a_refresh_shows_the_answered_edit() {
    let ledger = GroupEditLedger::new();
    let collapsed = named("grp_b", "Backend", Some("red"), true, 1);
    let open = PhoneWorkspaceGroup { is_collapsed: false, ..collapsed.clone() };
    let generation = ledger.begin(ids(&["c"]), Some(collapsed.clone()), true);
    ledger.sent(ids(&["c"]), generation, 0.0);
    // In flight: a stale refresh is overridden.
    let held = ledger.apply(vec![edit_row("a", None), edit_row("c", Some(open.clone()))], 1.0);
    assert_eq!(held, [GroupEditHeld { index: 1, group: Some(collapsed.clone()) }]);
    ledger.answered(ids(&["c"]), generation, 2.0);
    assert_eq!(ledger.apply(vec![edit_row("c", Some(open.clone()))], 3.0).len(), 1);
    // A refresh that shows it ends the edit.
    assert!(ledger.apply(vec![edit_row("c", Some(collapsed))], 4.0).is_empty());
    assert!(ledger.is_empty());
    assert!(ledger.apply(vec![edit_row("c", Some(open))], 5.0).is_empty());
}

#[test]
fn ledger_windows_expire_edits() {
    let ledger = GroupEditLedger::new();
    let g = named("grp", "G", None, true, 0);
    let first = ledger.begin(ids(&["a"]), Some(g.clone()), true);
    ledger.sent(ids(&["a"]), first, 0.0);
    assert_eq!(ledger.apply(vec![edit_row("a", None)], GROUP_EDIT_UNANSWERED_WINDOW).len(), 1);
    assert!(ledger.apply(vec![edit_row("a", None)], GROUP_EDIT_UNANSWERED_WINDOW + 0.5).is_empty());
    let second = ledger.begin(ids(&["a"]), Some(g), true);
    ledger.sent(ids(&["a"]), second, 0.0);
    ledger.answered(ids(&["a"]), second, 100.0);
    assert_eq!(ledger.apply(vec![edit_row("a", None)], 100.0 + GROUP_EDIT_CONFIRM_WINDOW).len(), 1);
    assert!(ledger.apply(vec![edit_row("a", None)], 100.5 + GROUP_EDIT_CONFIRM_WINDOW).is_empty());
}

#[test]
fn ledger_queued_edit_never_expires_before_it_is_sent() {
    let ledger = GroupEditLedger::new();
    ledger.begin(ids(&["a"]), None, true);
    let held = ledger.apply(vec![edit_row("a", Some(group("g", 0, None)))], 1e9);
    assert_eq!(held, [GroupEditHeld { index: 0, group: None }]);
}

#[test]
fn only_the_latest_edit_is_refused_or_answered() {
    let ledger = GroupEditLedger::new();
    let early = ledger.begin(ids(&["a", "b"]), None, true);
    let late = ledger.begin(ids(&["b"]), Some(group("g", 0, None)), true);
    assert_eq!(ledger.refused(ids(&["a", "b"]), early), ["a"]);
    assert_eq!(ledger.refused(ids(&["b"]), late), ["b"]);
    assert!(ledger.is_empty());
}

#[test]
fn non_holding_edit_marks_latest_only_and_ends_on_answer() {
    let ledger = GroupEditLedger::new();
    let moved = ledger.begin(ids(&["a"]), Some(group("g", 0, None)), true);
    let made = ledger.begin(ids(&["a"]), Some(named("tmp", "New Group", Some("yellow"), false, 9)), false);
    assert!(ledger.apply(vec![edit_row("a", None)], 0.0).is_empty());
    assert!(ledger.refused(ids(&["a"]), moved).is_empty());
    ledger.answered(ids(&["a"]), made, 10.0);
    assert!(ledger.is_empty());
}

#[test]
fn remove_all_keeps_generations_counting() {
    let ledger = GroupEditLedger::new();
    let first = ledger.begin(ids(&["a"]), None, true);
    ledger.remove_all();
    let second = ledger.begin(ids(&["a"]), None, true);
    assert!(second > first);
    assert!(ledger.refused(ids(&["a"]), first).is_empty());
}
