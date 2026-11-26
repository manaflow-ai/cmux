use super::*;

fn group(
    id: &str,
    name: &str,
    color: Option<&str>,
    collapsed: bool,
    index: i64,
    top: Option<i64>,
) -> WorkspaceGroupInfo {
    WorkspaceGroupInfo {
        id: id.into(),
        name: name.into(),
        color: color.map(Into::into),
        collapsed,
        index,
        top_index: top,
        room: None,
        pinned: None,
    }
}

fn row(session: &str, key: &str, index: i64, group: Option<&str>) -> WorkspaceGroupRow {
    WorkspaceGroupRow { session: session.into(), key: key.into(), index, group: group.map(Into::into) }
}

fn ids(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| s.to_string()).collect()
}

/// The Swift `WorkspaceGroupTests` fixture: grp_b "Backend" red collapsed (index 1),
/// grp_a "" green (index 0, before row 1).
fn fixture() -> (Vec<WorkspaceGroupRow>, Vec<WorkspaceGroupInfo>) {
    let groups = vec![
        group("grp_b", "Backend", Some("red"), true, 1, None),
        group("grp_a", "", Some("green"), false, 0, Some(1)),
    ];
    let rows = vec![
        row("reg", "a", 0, None),
        row("reg", "b", 1, Some("grp_a")),
        row("other", "x", 2, Some("grp_b")),
        row("reg", "c", 3, Some("grp_b")),
        row("reg", "d", 4, None),
    ];
    (rows, groups)
}

#[test]
fn placements_follow_the_macs_mixed_order() {
    let (rows, groups) = fixture();
    let out = workspace_group_placements(rows, groups, ids(&["a", "b", "c", "d", "e"]), "reg".into());
    let mut order: Vec<(&str, i64)> =
        ["a", "b", "c", "d", "e"].iter().copied().zip(out.iter().map(|p| p.sidebar_index)).collect();
    order.sort_by_key(|(_, i)| *i);
    assert_eq!(order.iter().map(|(k, _)| *k).collect::<Vec<_>>(), ["a", "b", "d", "e", "c"]);
    assert_eq!(out.iter().map(|p| p.group).collect::<Vec<_>>(), [None, Some(1), Some(0), None, None]);
}

#[test]
fn placements_ignore_unknown_groups_and_other_sessions() {
    let rows = vec![row("reg", "a", 0, Some("gone")), row("other", "z", 1, None)];
    let out = workspace_group_placements(rows, vec![], ids(&["a", "z"]), "reg".into());
    assert_eq!(out[0], WorkspaceGroupPlacement { sidebar_index: 0, group: None });
    // "z" is another session's row: not rowed here, so it follows as a workspace without a row.
    assert_eq!(out[1], WorkspaceGroupPlacement { sidebar_index: 1, group: None });
}

#[test]
fn placements_without_rows_keep_input_order() {
    let out = workspace_group_placements(vec![], vec![], ids(&["p", "q"]), "reg".into());
    assert_eq!(out.iter().map(|p| p.sidebar_index).collect::<Vec<_>>(), [0, 1]);
}

#[test]
fn own_groups_skip_groups_with_other_sessions_rows() {
    let (rows, mut groups) = fixture();
    groups.push(group("grp_empty", "Empty", None, false, 2, None));
    let own = workspace_group_own(rows, groups.clone(), "reg".into());
    let own: Vec<&str> = own.iter().map(|&i| groups[i as usize].id.as_str()).collect();
    assert_eq!(own, ["grp_a", "grp_empty"]);
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

fn edit_row(id: &str, g: Option<WorkspaceGroupInfo>) -> GroupEditRow {
    GroupEditRow { id: id.into(), group: g }
}

#[test]
fn ledger_holds_until_a_refresh_shows_the_answered_edit() {
    let ledger = GroupEditLedger::new();
    let collapsed = group("grp_b", "Backend", Some("red"), true, 1, None);
    let open = WorkspaceGroupInfo { collapsed: false, ..collapsed.clone() };
    let generation = ledger.begin(ids(&["c"]), Some(collapsed.clone()), true);
    ledger.sent(ids(&["c"]), generation, 0);
    // In flight: a stale refresh is overridden.
    let held = ledger.apply(vec![edit_row("a", None), edit_row("c", Some(open.clone()))], 1_000);
    assert_eq!(held, [GroupEditHeld { index: 1, group: Some(collapsed.clone()) }]);
    ledger.answered(ids(&["c"]), generation, 2_000);
    assert_eq!(ledger.apply(vec![edit_row("c", Some(open.clone()))], 3_000).len(), 1);
    // A refresh that shows it ends the edit.
    assert!(ledger.apply(vec![edit_row("c", Some(collapsed))], 4_000).is_empty());
    assert!(ledger.is_empty());
    assert!(ledger.apply(vec![edit_row("c", Some(open))], 5_000).is_empty());
}

#[test]
fn ledger_windows_expire_edits() {
    let ledger = GroupEditLedger::new();
    let g = group("grp", "G", None, true, 0, None);
    let first = ledger.begin(ids(&["a"]), Some(g.clone()), true);
    ledger.sent(ids(&["a"]), first, 0);
    assert_eq!(ledger.apply(vec![edit_row("a", None)], UNANSWERED_WINDOW_MS).len(), 1);
    assert!(ledger.apply(vec![edit_row("a", None)], UNANSWERED_WINDOW_MS + 1).is_empty());
    let second = ledger.begin(ids(&["a"]), Some(g), true);
    ledger.sent(ids(&["a"]), second, 0);
    ledger.answered(ids(&["a"]), second, 100);
    assert_eq!(ledger.apply(vec![edit_row("a", None)], 100 + CONFIRM_WINDOW_MS).len(), 1);
    assert!(ledger.apply(vec![edit_row("a", None)], 101 + CONFIRM_WINDOW_MS).is_empty());
}

#[test]
fn queued_edit_never_expires_before_it_is_sent() {
    let ledger = GroupEditLedger::new();
    ledger.begin(ids(&["a"]), None, true);
    let held = ledger.apply(vec![edit_row("a", Some(group("g", "G", None, false, 0, None)))], 1_000_000);
    assert_eq!(held, [GroupEditHeld { index: 0, group: None }]);
}

#[test]
fn only_the_latest_edit_is_refused_or_answered() {
    let ledger = GroupEditLedger::new();
    let early = ledger.begin(ids(&["a", "b"]), None, true);
    let late = ledger.begin(ids(&["b"]), Some(group("g", "G", None, false, 0, None)), true);
    assert_eq!(ledger.refused(ids(&["a", "b"]), early), ["a"]);
    assert_eq!(ledger.refused(ids(&["b"]), late), ["b"]);
    assert!(ledger.is_empty());
}

#[test]
fn non_holding_edit_marks_latest_only_and_ends_on_answer() {
    let ledger = GroupEditLedger::new();
    let moved = ledger.begin(ids(&["a"]), Some(group("g", "G", None, false, 0, None)), true);
    let made =
        ledger.begin(ids(&["a"]), Some(group("tmp", "New Group", Some("yellow"), false, 9, None)), false);
    assert!(ledger.apply(vec![edit_row("a", None)], 0).is_empty());
    assert!(ledger.refused(ids(&["a"]), moved).is_empty());
    ledger.answered(ids(&["a"]), made, 10);
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

#[test]
fn merged_keeps_the_macs_place_and_the_edits_fields() {
    let expected = group("g", "Mine", Some("red"), true, 0, None);
    let incoming = group("g", "Theirs", Some("blue"), false, 5, Some(2));
    let merged = group_merged(Some(&incoming), Some(&expected)).unwrap();
    assert_eq!(
        (merged.name.as_str(), merged.collapsed, merged.index, merged.top_index),
        ("Mine", true, 5, Some(2))
    );
    let other = group("h", "Other", None, false, 7, None);
    assert_eq!(group_merged(Some(&other), Some(&expected)).unwrap().index, 7);
    assert_eq!(group_merged(None, Some(&expected)), Some(expected.clone()));
    assert_eq!(group_merged(Some(&incoming), None), None);
    assert!(group_shows(None, None));
    assert!(group_shows(Some(&WorkspaceGroupInfo { index: 9, ..expected.clone() }), Some(&expected)));
    assert!(!group_shows(Some(&incoming), Some(&expected)));
}
