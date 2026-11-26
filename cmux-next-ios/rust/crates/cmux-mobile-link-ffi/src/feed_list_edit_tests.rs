use super::*;

fn ids(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| (*s).to_string()).collect()
}

fn item(id: &str, chat: &str) -> FeedStackItem {
    FeedStackItem {
        id: id.into(),
        mac_id: None,
        workspace_id: "w".into(),
        tab_id: Some(chat.into()),
        keeps_own_row: false,
    }
}

fn a(id: &str) -> FeedStackItem {
    item(id, "a")
}

/// The row ids the Swift FeedStacksTests compared: events by id, a fold line as `fold:<head>`.
fn row_ids(items: &[FeedStackItem], s: &FeedStacking) -> Vec<String> {
    s.rows
        .iter()
        .map(|r| match r {
            FeedStackRow::Event { index } => items[*index as usize].id.clone(),
            FeedStackRow::Fold { head, .. } => format!("fold:{}", items[*head as usize].id),
        })
        .collect()
}

fn stack(items: &[FeedStackItem], expanded: &[&str], open: &[&str]) -> (Vec<String>, FeedStacking) {
    let s = feed_stacking(items.to_vec(), ids(expanded), ids(open));
    (row_ids(items, &s), s)
}

#[test]
fn a_run_from_one_chat_folds_under_its_newest_event() {
    let items = [item("b1", "b"), a("a4"), a("a3"), a("a2"), a("a1"), item("b0", "b")];
    let (rows, s) = stack(&items, &[], &[]);
    assert_eq!(rows, ["b1", "a4", "fold:a4", "b0"]);
    assert_eq!(s.rows[2], FeedStackRow::Fold { head: 1, count: 3, expanded: false });
    assert_eq!(s.heads, ["a4"]);
    assert_eq!(s.hidden, ["a3", "a2", "a1"]);
}

#[test]
fn another_chats_event_between_them_ends_the_run() {
    let items = [a("a3"), item("b1", "b"), a("a2"), a("a1")];
    let (rows, s) = stack(&items, &[], &[]);
    assert_eq!(rows, ["a3", "b1", "a2", "fold:a2"]);
    assert_eq!(s.rows[3], FeedStackRow::Fold { head: 2, count: 1, expanded: false });
}

#[test]
fn the_same_tab_in_another_workspace_or_on_another_mac_is_another_chat() {
    let mut other_ws = a("a2");
    other_ws.workspace_id = "w2".into();
    let mut other_mac = a("a1");
    other_mac.mac_id = Some("mac-2".into());
    let items = [a("a3"), other_ws, other_mac];
    let (rows, s) = stack(&items, &[], &[]);
    assert_eq!(rows, ["a3", "a2", "a1"]);
    assert!(s.heads.is_empty());
}

#[test]
fn an_open_stack_shows_its_older_events_under_the_fold_line() {
    let items = [a("a3"), a("a2"), a("a1"), item("b1", "b")];
    let (rows, s) = stack(&items, &["a3"], &[]);
    assert_eq!(rows, ["a3", "fold:a3", "a2", "a1", "b1"]);
    assert_eq!(s.rows[1], FeedStackRow::Fold { head: 0, count: 2, expanded: true });
    assert!(s.hidden.is_empty());
    assert_eq!(s.expanded, ["a3"]);
}

#[test]
fn a_row_that_needs_you_is_never_folded_and_leads_no_stack() {
    let mut ask = a("ask");
    ask.keeps_own_row = true;
    let items = [a("a4"), a("a3"), ask.clone(), a("a2"), a("a1")];
    assert_eq!(stack(&items, &[], &[]).0, ["a4", "fold:a4", "ask", "a2", "fold:a2"]);
    // An ask first (the Feed pins them): the chat's later events are not folded under it.
    let pinned = [ask, a("a2"), a("a1")];
    assert_eq!(stack(&pinned, &[], &[]).0, ["ask", "a2", "fold:a2"]);
    // An answer on its way or a refused answer stays in sight too.
    let mut refused = a("a2");
    refused.keeps_own_row = true;
    let mut sending = a("a1");
    sending.keeps_own_row = true;
    assert_eq!(stack(&[a("a3"), refused, sending], &[], &[]).0, ["a3", "a2", "a1"]);
}

#[test]
fn a_row_with_an_open_reply_is_never_folded_but_may_lead_a_stack() {
    let items = [a("a3"), a("a2"), a("a1")];
    assert_eq!(stack(&items, &[], &["a2"]).0, ["a3", "a2", "fold:a2"]);
    assert_eq!(stack(&items, &[], &["a3"]).0, ["a3", "fold:a3"]);
}

#[test]
fn an_open_stack_stays_open_when_its_chat_posts_again() {
    let items = [a("a4"), a("a3"), a("a2"), a("a1")];
    let (rows, s) = stack(&items, &["a3"], &[]);
    assert_eq!(s.expanded, ["a4"]);
    assert_eq!(rows, ["a4", "fold:a4", "a3", "a2", "a1"]);
}

#[test]
fn a_stack_that_is_gone_forgets_it_was_open() {
    let items = [item("b1", "b"), a("a2"), a("a1")];
    let (rows, s) = stack(&items, &["a3", "gone"], &[]);
    assert!(s.expanded.is_empty());
    assert_eq!(rows, ["b1", "a2", "fold:a2"]);
}

#[test]
fn a_live_insert_is_an_edit_not_a_rebuild() {
    let edit =
        feed_snapshot_edit(ids(&["a", "b", "c"]), ids(&["n1", "n2", "a", "b", "x", "c", "z"])).unwrap();
    assert!(edit.removed.is_empty());
    assert_eq!(
        edit.groups,
        [
            FeedInsertGroup { before: "a".into(), ids: ids(&["n1", "n2"]) },
            FeedInsertGroup { before: "c".into(), ids: ids(&["x"]) },
        ]
    );
    assert_eq!(edit.tail, ["z"]);
}

#[test]
fn a_removal_is_an_edit() {
    let edit = feed_snapshot_edit(ids(&["a", "b", "c"]), ids(&["a", "c"])).unwrap();
    assert_eq!(edit.removed, ["b"]);
    assert!(edit.groups.is_empty() && edit.tail.is_empty());
}

#[test]
fn a_re_sort_rebuilds() {
    assert_eq!(feed_snapshot_edit(ids(&["a", "b", "c"]), ids(&["b", "a", "c"])), None);
}

fn mv(id: &str, before: Option<&str>) -> FeedMoveStep {
    FeedMoveStep { id: id.into(), before: before.map(Into::into), moved: true }
}

fn ins(id: &str, before: Option<&str>) -> FeedMoveStep {
    FeedMoveStep { id: id.into(), before: before.map(Into::into), moved: false }
}

fn moved(old: &[&str], new: &[&str], movers: &[&str], limit: u32) -> Option<FeedMoveEdit> {
    feed_move_edit(ids(old), ids(new), ids(movers), limit)
}

#[test]
fn an_answered_ask_is_a_row_move() {
    let old = ["ask-new", "ask-old", "new", "mid", "last"];
    let new = ["ask-new", "new", "mid", "ask-old", "last"];
    assert_eq!(feed_snapshot_edit(ids(&old), ids(&new)), None);
    let edit = moved(&old, &new, &["ask-old"], 4).unwrap();
    assert!(edit.removed.is_empty());
    assert_eq!(edit.steps, [mv("ask-old", Some("last"))]);
    assert_eq!(feed_move_edit_applied(edit, ids(&old)), new);
    // The oldest event of all: it goes after the last row.
    let to_end = moved(&["ask", "a", "b"], &["a", "b", "ask"], &["ask"], 4).unwrap();
    assert_eq!(to_end.steps, [mv("ask", None)]);
    assert_eq!(feed_move_edit_applied(to_end, ids(&["ask", "a", "b"])), ["a", "b", "ask"]);
    // An ask that opens again goes back up.
    let back = moved(&["a", "b", "ask"], &["ask", "a", "b"], &["ask"], 4).unwrap();
    assert_eq!(feed_move_edit_applied(back, ids(&["a", "b", "ask"])), ["ask", "a", "b"]);
}

#[test]
fn a_move_carries_inserts_and_removals() {
    let old = ["ask-1", "ask-2", "a", "b", "c"];
    let new = ["ask-2", "n1", "a", "ask-1", "c", "n2"];
    let edit = moved(&old, &new, &["ask-1"], 4).unwrap();
    assert_eq!(edit.removed, ["b"]);
    assert_eq!(edit.steps, [ins("n2", None), mv("ask-1", Some("c")), ins("n1", Some("a"))]);
    assert_eq!(feed_move_edit_applied(edit, ids(&old)), new);
    // Two asks answered at once.
    let both_new = ["a", "ask-1", "b", "c", "ask-2"];
    let both = moved(&old, &both_new, &["ask-1", "ask-2"], 4).unwrap();
    assert_eq!(feed_move_edit_applied(both, ids(&old)), both_new);
}

#[test]
fn other_reorders_still_rebuild() {
    assert_eq!(moved(&["ask", "a", "b"], &["b", "a", "ask"], &["ask"], 4), None);
    assert_eq!(moved(&["a", "b"], &["b", "a"], &[], 4), None);
    assert_eq!(moved(&["a", "b"], &["b", "a"], &["gone"], 4), None);
    let asks = ["ask0", "ask1", "ask2", "ask3", "ask4"];
    let old: Vec<&str> = asks.iter().copied().chain(["a"]).collect();
    let new: Vec<&str> = ["a"].into_iter().chain(asks.iter().copied()).collect();
    assert_eq!(moved(&old, &new, &asks, 4), None);
    let edit = moved(&old, &new, &asks, 5).unwrap();
    assert_eq!(feed_move_edit_applied(edit, ids(&old)), new);
}

#[test]
fn the_same_mover_twice_counts_once() {
    let edit = moved(&["ask", "a"], &["a", "ask"], &["ask", "ask"], 1).unwrap();
    assert_eq!(edit.steps, [mv("ask", None)]);
}
