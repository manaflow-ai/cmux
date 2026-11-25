use super::*;

fn user(text: &str, steer: bool) -> Item {
    Item::User { text: text.into(), steer, queued: false }
}
fn said(text: &str) -> Item {
    Item::Assistant { text: text.into() }
}
fn tool(id: &str) -> Item {
    Item::Tool {
        id: id.into(),
        title: format!("Read {id}"),
        kind: "read".into(),
        status: "completed".into(),
        detail: String::new(),
    }
}
fn transcript(items: Vec<Item>, status: &str) -> Transcript {
    let mut t = Transcript::default();
    t.items = items;
    t.status = status.into();
    t
}
fn order(t: &Transcript) -> Vec<usize> {
    late_steers_last(t, (0..t.items.len()).collect(), t.status == "running").0
}
/// The first row, in drawing order, whose text contains each needle.
fn drawn_at(t: &Transcript, needles: &[&str]) -> Vec<usize> {
    let rows = transcript_rows(t, 80, false, false, &Default::default(), &Chrome::dark());
    needles.iter().map(|n| rows.iter().position(|r| r.text.contains(n)).expect(n)).collect()
}

#[test]
fn late_steer_after_the_reply_draws_over_it_once_the_turn_ended() {
    let items = vec![
        user("fix it", false),
        tool("a.rs"),
        said("Fixed it"),
        user("also b", true),
        said("and b too"),
    ];
    let live = transcript(items.clone(), "running");
    assert_eq!(order(&live), vec![0, 1, 2, 3, 4], "a running turn draws as it came");
    let ended = transcript(items, "ready");
    assert_eq!(order(&ended), vec![0, 1, 3, 2, 4]);
    let at = drawn_at(&ended, &["fix it", "Worked", "also b", "Fixed it", "and b too"]);
    assert!(at.windows(2).all(|w| w[0] < w[1]), "prompt, work, steer, reply: {at:?}");
}

#[test]
fn steer_with_a_tool_after_it_keeps_its_order() {
    let t = transcript(
        vec![
            user("fix it", false),
            tool("a.rs"),
            said("Fixed it"),
            user("also b", true),
            tool("b.rs"),
            said("and b too"),
        ],
        "ready",
    );
    assert_eq!(order(&t), (0..6).collect::<Vec<_>>());
}

#[test]
fn turn_without_a_steer_keeps_its_order() {
    let t = transcript(vec![user("fix it", false), tool("a.rs"), said("Fixed it")], "ready");
    assert_eq!(order(&t), vec![0, 1, 2]);
    let at = drawn_at(&t, &["fix it", "Worked", "Fixed it"]);
    assert!(at.windows(2).all(|w| w[0] < w[1]), "{at:?}");
}
