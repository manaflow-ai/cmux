use super::*;

fn row(session: &str, key: &str, index: i64) -> PhoneSidebarRow {
    PhoneSidebarRow { session: session.into(), key: key.into(), index, group: None }
}

fn ids(list: &[&str]) -> Vec<String> {
    list.iter().map(|s| (*s).to_owned()).collect()
}

#[test]
fn moving_goes_next_to_the_neighbour() {
    let rows = vec![row("reg", "a", 0), row("reg", "b", 1), row("x", "z", 2), row("reg", "c", 3)];
    let visible = ids(&["a", "b", "c"]);
    let at = |id: &str, offset: i64| {
        personal_index_moving(rows.clone(), id.into(), offset, visible.clone(), "reg".into())
    };
    // b up: before a (0); b down: after c, whose place without b is 2, so 3.
    assert_eq!(at("b", -1), Some(0));
    assert_eq!(at("b", 1), Some(3));
    assert_eq!(at("a", -1), None);
    assert_eq!(at("c", 1), None);
    assert_eq!(at("gone", 1), None);
    assert_eq!(personal_index_moving(vec![], "b".into(), -1, visible, "reg".into()), None);
}

#[test]
fn rows_come_in_place_order_whatever_the_list_order() {
    let rows = vec![row("reg", "c", 3), row("x", "z", 2), row("reg", "b", 1), row("reg", "a", 0)];
    assert_eq!(personal_index_moving(rows, "b".into(), 1, ids(&["a", "b", "c"]), "reg".into()), Some(3));
}

#[test]
fn a_neighbour_of_another_session_has_no_place() {
    // The same key in another session is not this Mac's row.
    let rows = vec![row("reg", "a", 0), row("x", "b", 1)];
    assert_eq!(personal_index_moving(rows, "a".into(), 1, ids(&["a", "b"]), "reg".into()), None);
}

#[test]
fn placing_goes_before_or_after_the_anchor() {
    let rows = vec![row("reg", "a", 0), row("x", "z", 1), row("reg", "b", 2), row("reg", "c", 3)];
    let at = |id: &str, anchor: &str, after: bool| {
        personal_index_placing(rows.clone(), id.into(), anchor.into(), after, "reg".into())
    };
    assert_eq!(at("c", "a", false), Some(0));
    assert_eq!(at("a", "c", true), Some(3));
    assert_eq!(at("b", "a", false), Some(0));
    assert_eq!(at("b", "b", false), None);
    // A workspace with no personal row yet still goes next to an anchor that has one.
    assert_eq!(at("new", "a", false), Some(0));
    assert_eq!(at("a", "new", false), None);
    assert_eq!(personal_index_placing(vec![], "b".into(), "a".into(), false, "reg".into()), None);
}

#[test]
fn neighbor_targets_leave_out_the_row_it_already_sits_beside() {
    let order = ids(&["a", "b", "c", "d"]);
    assert_eq!(neighbor_move_targets(true, "b".into(), order.clone()), ids(&["a", "d"]));
    assert_eq!(neighbor_move_targets(false, "b".into(), order.clone()), ids(&["c", "d"]));
    assert_eq!(neighbor_move_targets(false, "a".into(), order.clone()), ids(&["b", "c", "d"]));
    assert_eq!(neighbor_move_targets(true, "d".into(), order.clone()), ids(&["a", "b", "c"]));
    assert!(neighbor_move_targets(true, "z".into(), order).is_empty());
}

#[test]
fn the_workspace_lands_on_the_picked_side() {
    let order = ids(&["a", "b", "c", "d"]);
    assert_eq!(
        neighbor_move_reordered(true, "d".into(), "b".into(), order.clone()),
        ids(&["a", "d", "b", "c"])
    );
    assert_eq!(
        neighbor_move_reordered(false, "a".into(), "c".into(), order.clone()),
        ids(&["b", "c", "a", "d"])
    );
    assert_eq!(
        neighbor_move_reordered(false, "a".into(), "d".into(), order.clone()),
        ids(&["b", "c", "d", "a"])
    );
    assert_eq!(neighbor_move_reordered(true, "a".into(), "z".into(), order.clone()), order);
}

fn step(workspace: &str, anchor: &str, after: bool) -> WorkspaceSortStep {
    WorkspaceSortStep { workspace: workspace.into(), anchor: anchor.into(), after }
}

#[test]
fn sort_steps_move_only_what_is_out_of_place() {
    let order = ids(&["c", "a", "b"]);
    assert_eq!(
        workspace_sort_steps(order.clone(), ids(&["a", "b", "c"])),
        vec![step("a", "c", false), step("b", "a", true)]
    );
    assert!(workspace_sort_steps(order.clone(), order).is_empty());
}

#[test]
fn sort_steps_of_a_reversed_container() {
    assert_eq!(
        workspace_sort_steps(ids(&["a", "b", "c", "d"]), ids(&["d", "c", "b", "a"])),
        vec![step("d", "a", false), step("c", "d", true), step("b", "c", true)]
    );
}

#[test]
fn sort_steps_skip_a_row_the_container_lacks() {
    // z is not in the container: a is already at place 1, b goes after a (clamped to the end).
    assert_eq!(workspace_sort_steps(ids(&["b", "a"]), ids(&["z", "a", "b"])), vec![step("b", "a", true)]);
}
