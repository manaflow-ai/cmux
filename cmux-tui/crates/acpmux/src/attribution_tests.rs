use super::*;
use serde_json::json;

fn canon(path: &str) -> Option<String> {
    Some(if path.starts_with('/') { path.to_owned() } else { format!("/repo/{path}") })
}

fn author(turn: &str, head: &str, at: u64) -> Author {
    Author {
        session_id: "s1".into(),
        turn_id: turn.into(),
        head: head.into(),
        model: Some("opus".into()),
        title: Some("Parser fix".into()),
        prompt: Author::first_line(&format!("\n  prompt of {turn}\nmore")),
        at,
    }
}

fn edit(id: &str, old: Option<&str>, new: &str) -> Value {
    json!({
        "sessionUpdate": "tool_call",
        "toolCallId": id,
        "kind": "edit",
        "status": "pending",
        "content": [{"type": "diff", "path": "src/a.rs", "oldText": old, "newText": new}],
    })
}

fn done(id: &str, status: &str) -> Value {
    json!({"sessionUpdate": "tool_call_update", "toolCallId": id, "status": status})
}

/// A turn's edits as `record` takes them: each block located in `text`.
fn record_turn(index: &mut Index, turn: &mut TurnEdits, text: &str, who: &Author) {
    let ranges: Vec<(u32, u32)> = turn.take_written().iter().filter_map(|b| locate(text, b)).collect();
    index.record("/repo", "src/a.rs", text, &ranges, who);
}

fn turns_of(found: &[Written]) -> Vec<&str> {
    found.iter().map(|w| w.turn_id.as_str()).collect()
}

#[test]
fn a_line_a_turn_wrote_names_its_chat_turn_model_and_prompt() {
    let file = "fn a() {}\nfn b() {\n    1\n}\n";
    let after = "fn a() {}\nfn b() {\n    2\n    3\n}\n";
    let mut turn = TurnEdits::default();
    turn.absorb(&edit("t1", Some("fn b() {\n    1\n}"), "fn b() {\n    2\n    3\n}"), canon);
    turn.absorb(&done("t1", "completed"), canon);
    let mut index = Index::default();
    record_turn(&mut index, &mut turn, after, &author("turn-1", "h1", 10));
    let _ = file;

    let found = verify(after, index.candidates("/repo", "h1", "src/a.rs", &[(3, 3)]));
    assert_eq!(found.len(), 1);
    let w = &found[0];
    // Only the changed lines, not the context the edit carried.
    assert_eq!((w.start, w.end), (3, 4));
    assert_eq!(w.session_id, "s1");
    assert_eq!(w.turn_id, "turn-1");
    assert_eq!(w.model.as_deref(), Some("opus"));
    assert_eq!(w.prompt.as_deref(), Some("prompt of turn-1"));
    let wire = serde_json::to_value(w).unwrap();
    assert_eq!(wire["sessionId"], "s1");
    assert!(wire.get("hash").is_none() && wire.get("head").is_none());
}

#[test]
fn a_line_two_turns_edited_lists_the_newest_first_then_the_older() {
    let mut index = Index::default();
    let mut turn = TurnEdits::default();
    let v1 = "a\nb\nc\n";
    turn.absorb(&edit("e1", Some("a\nx\nc"), "a\nb\nc"), canon);
    turn.absorb(&done("e1", "completed"), canon);
    record_turn(&mut index, &mut turn, v1, &author("turn-1", "h1", 10));

    // The second turn writes a line just under the first turn's, and its edit's range covers both.
    let v2 = "a\nb\nb2\nc\n";
    turn.absorb(&edit("e2", None, "b\nb2"), canon);
    turn.absorb(&done("e2", "completed"), canon);
    record_turn(&mut index, &mut turn, v2, &author("turn-2", "h1", 20));

    let found = verify(v2, index.candidates("/repo", "h1", "src/a.rs", &[(2, 2)]));
    assert_eq!(turns_of(&found), ["turn-2", "turn-1"]);
}

#[test]
fn an_earlier_range_follows_its_text_when_a_later_turn_adds_lines_above() {
    let mut index = Index::default();
    let mut turn = TurnEdits::default();
    let v1 = "head\nfn one() {}\ntail\n";
    turn.absorb(&edit("e1", Some("head\ntail"), "head\nfn one() {}\ntail"), canon);
    turn.absorb(&done("e1", "completed"), canon);
    record_turn(&mut index, &mut turn, v1, &author("turn-1", "h1", 10));

    let v2 = "use x;\nuse y;\nhead\nfn one() {}\ntail\n";
    turn.absorb(&edit("e2", Some("head"), "use x;\nuse y;\nhead"), canon);
    turn.absorb(&done("e2", "completed"), canon);
    record_turn(&mut index, &mut turn, v2, &author("turn-2", "h1", 20));

    let found = verify(v2, index.candidates("/repo", "h1", "src/a.rs", &[(4, 4)]));
    assert_eq!(turns_of(&found), ["turn-1"]);
    assert_eq!((found[0].start, found[0].end), (4, 4));
    let top = verify(v2, index.candidates("/repo", "h1", "src/a.rs", &[(1, 2)]));
    assert_eq!(turns_of(&top), ["turn-2"]);
}

#[test]
fn a_line_no_turn_wrote_gets_nothing() {
    let mut index = Index::default();
    let mut turn = TurnEdits::default();
    let text = "keep\nnew line\nkeep too\n";
    turn.absorb(&edit("e1", Some("keep\nkeep too"), "keep\nnew line\nkeep too"), canon);
    turn.absorb(&done("e1", "completed"), canon);
    record_turn(&mut index, &mut turn, text, &author("turn-1", "h1", 10));

    assert!(verify(text, index.candidates("/repo", "h1", "src/a.rs", &[(1, 1)])).is_empty());
    assert!(verify(text, index.candidates("/repo", "h1", "src/a.rs", &[(3, 3)])).is_empty());
    assert!(index.candidates("/repo", "h1", "src/other.rs", &[(1, 9)]).is_empty());
}

#[test]
fn a_stale_head_or_changed_text_gets_nothing_rather_than_a_wrong_answer() {
    let mut index = Index::default();
    let mut turn = TurnEdits::default();
    let text = "a\nwritten\nz\n";
    turn.absorb(&edit("e1", Some("a\nz"), "a\nwritten\nz"), canon);
    turn.absorb(&done("e1", "completed"), canon);
    record_turn(&mut index, &mut turn, text, &author("turn-1", "h1", 10));

    // Another head: the lines may be anything there.
    assert!(index.candidates("/repo", "h2", "src/a.rs", &[(2, 2)]).is_empty());
    // The same head, but someone changed the line since: no answer.
    let edited_by_hand = "a\nrewritten by hand\nz\n";
    assert!(verify(edited_by_hand, index.candidates("/repo", "h1", "src/a.rs", &[(2, 2)])).is_empty());
    // And a line pushed down by a hand edit above it is not named at its old place.
    let shifted = "inserted\na\nwritten\nz\n";
    assert!(verify(shifted, index.candidates("/repo", "h1", "src/a.rs", &[(2, 2)])).is_empty());
}

#[test]
fn failed_running_and_non_edit_calls_write_nothing() {
    let mut turn = TurnEdits::default();
    turn.absorb(&edit("failed", None, "x"), canon);
    turn.absorb(&done("failed", "failed"), canon);
    turn.absorb(&edit("running", None, "y"), canon);
    let mut read = edit("read", None, "z");
    read["kind"] = json!("read");
    turn.absorb(&read, canon);
    turn.absorb(&done("read", "completed"), canon);
    turn.absorb(&edit("ok", None, "w"), canon);
    turn.absorb(&done("ok", "completed"), canon);
    let written = turn.take_written();
    assert_eq!(written.len(), 1);
    assert_eq!(written[0].new_text, "w");
    assert_eq!(written[0].path, "/repo/src/a.rs");
    // Taken once: the next turn starts empty.
    assert!(turn.take_written().is_empty());
}

#[test]
fn text_found_twice_or_nowhere_is_an_unknown_location() {
    let block = |new: &str| EditBlock { path: "/repo/a".into(), old_text: None, new_text: new.into() };
    assert_eq!(locate("x = 1\nx = 1\n", &block("x = 1")), None);
    assert_eq!(locate("x = 2\n", &block("x = 1")), None);
    assert_eq!(locate("x = 2\n", &block("  ")), None);
    assert_eq!(locate("a\nx = 1\n", &block("x = 1")), Some((2, 2)));
    // An edit inside a line counts that line.
    let inside = EditBlock { path: "/repo/a".into(), old_text: Some("foo".into()), new_text: "bar(1)".into() };
    assert_eq!(locate("let a = bar(1);\n", &inside), Some((1, 1)));
    // A deletion writes no line.
    let deletion = EditBlock { path: "/repo/a".into(), old_text: Some("a\nb\nc".into()), new_text: "a\nc".into() };
    assert_eq!(locate("a\nc\n", &deletion), None);
}

#[test]
fn a_chat_keeps_at_most_its_bound_oldest_out() {
    let mut index = Index::default();
    let text: String = (0..MAX_PER_CHAT + 5).map(|i| format!("line {i}\n")).collect();
    let ranges: Vec<(u32, u32)> = (1..=MAX_PER_CHAT as u32 + 5).map(|i| (i, i)).collect();
    index.record("/repo", "src/a.rs", &text, &ranges, &author("turn-1", "h1", 10));
    assert_eq!(index.per_chat["s1"].len(), MAX_PER_CHAT);
    assert!(index.candidates("/repo", "h1", "src/a.rs", &[(1, 5)]).is_empty());
    assert_eq!(index.candidates("/repo", "h1", "src/a.rs", &[(6, 6)]).len(), 1);
}

#[test]
fn a_query_names_relative_paths_and_bounded_ranges_only() {
    assert!(query_path(Some(&json!("src/a.rs"))).is_ok());
    for bad in ["/etc/passwd", "../x", "a/../../b", "a//b", "./a", ""] {
        assert!(query_path(Some(&json!(bad))).is_err(), "{bad}");
    }
    assert_eq!(query_ranges(Some(&json!([[1, 3], [5, 5]]))).unwrap(), vec![(1, 3), (5, 5)]);
    assert!(query_ranges(Some(&json!([[0, 3]]))).is_err());
    assert!(query_ranges(Some(&json!([[4, 3]]))).is_err());
    let many: Vec<Value> = (1..=MAX_QUERY_RANGES as u64 + 1).map(|i| json!([i, i])).collect();
    assert!(query_ranges(Some(&Value::Array(many))).is_err());
}

#[test]
fn an_older_diff_whose_lines_were_rewritten_since_names_no_one() {
    // Turn A wrote `foo` at line 2; turn B rewrote it to `bar`. A's diff still shows `foo` there.
    let mut index = Index::default();
    let mut turn = TurnEdits::default();
    let v1 = "a\nfoo\nz\n";
    turn.absorb(&edit("e1", Some("a\nz"), "a\nfoo\nz"), canon);
    turn.absorb(&done("e1", "completed"), canon);
    record_turn(&mut index, &mut turn, v1, &author("turn-a", "h1", 10));
    let v2 = "a\nbar\nz\n";
    turn.absorb(&edit("e2", Some("foo"), "bar"), canon);
    turn.absorb(&done("e2", "completed"), canon);
    record_turn(&mut index, &mut turn, v2, &author("turn-b", "h1", 20));

    let shown_a = vec![vec!["foo".to_owned()]];
    assert!(shown_ranges(v2, &[(2, 2)], Some(&shown_a)).is_empty());
    let shown_b = vec![vec!["bar".to_owned()]];
    let ranges = shown_ranges(v2, &[(2, 2)], Some(&shown_b));
    let found = verify(v2, index.candidates("/repo", "h1", "src/a.rs", &ranges));
    assert_eq!(turns_of(&found), ["turn-b"]);
    // A query with no texts keeps every range.
    assert_eq!(shown_ranges(v2, &[(2, 2)], None), vec![(2, 2)]);
}

#[test]
fn shown_texts_have_one_list_a_range_and_one_line_a_line() {
    let ranges = [(1, 2), (5, 5)];
    assert_eq!(query_texts(None, &ranges).unwrap(), None);
    assert!(query_texts(Some(&json!([["a", "b"], ["c"]])), &ranges).unwrap().is_some());
    assert!(query_texts(Some(&json!([["a"], ["c"]])), &ranges).is_err());
    assert!(query_texts(Some(&json!([["a", "b"]])), &ranges).is_err());
    assert!(query_texts(Some(&json!([["a", 1], ["c"]])), &ranges).is_err());
}
