use super::*;

fn user(s: &str, steer: bool) -> Item {
    Item::User { text: s.into(), steer, queued: false }
}
fn tool(title: &str) -> Item {
    Item::Tool {
        id: "1".into(),
        title: title.into(),
        kind: "read".into(),
        status: "completed".into(),
        detail: String::new(),
    }
}
fn live(items: Vec<Item>) -> Transcript {
    let mut t = Transcript::default();
    t.items = items;
    t.status = "running".into();
    t.turn_times = vec![(0, 1_000, None)];
    t
}

#[test]
fn a_compact_turn_reads_compacting() {
    assert!(compacting(&live(vec![user("/compact", false)])));
    assert!(compacting(&live(vec![user("  /compact keep the plan", false)])));
    assert!(!compacting(&live(vec![user("/compactor", false)])));
    assert!(!compacting(&live(vec![user("fix it", false)])));
    let mut ended = live(vec![user("/compact", false)]);
    ended.turn_times = vec![(0, 1_000, Some(2_000))];
    assert!(!compacting(&ended), "an ended turn is not live");
}

#[test]
fn names_what_it_waits_on_after_silence() {
    let t = live(vec![user("fix it", false)]);
    assert_eq!(waiting_since(&t, 1_000, 5_000), None, "heard lately");
    assert_eq!(
        waiting_since(&t, 1_000, 11_000).as_deref(),
        Some("Waiting on the model's first reply")
    );
    let t = live(vec![user("fix it", false), tool("Read a.rs")]);
    assert_eq!(
        waiting_since(&t, 0, 20_000).as_deref(),
        Some("Waiting on the model after: Read a.rs")
    );
    let t = live(vec![user("fix it", false), tool("Read a.rs"), user("also b", true)]);
    assert_eq!(
        waiting_since(&t, 0, 20_000).as_deref(),
        Some("Waiting on the model to read your queued message")
    );
    let t = live(vec![user("fix it", false), Item::Assistant { text: "ok".into() }]);
    assert_eq!(waiting_since(&t, 0, 20_000).as_deref(), Some("Waiting on the model's next step"));
}

#[test]
fn never_waits_while_a_call_runs_or_compacts() {
    let mut t = live(vec![user("fix it", false), tool("Read a.rs")]);
    t.active_tools = 1;
    assert_eq!(waiting_since(&t, 0, 60_000), None);
    t.active_tools = 0;
    t.activity = Some("Editing a.rs".into());
    assert_eq!(waiting_since(&t, 0, 60_000), None);
    assert_eq!(waiting_since(&live(vec![user("/compact", false)]), 0, 60_000), None);
}

#[test]
fn heard_at_moves_with_each_event() {
    let mut t = live(vec![user("fix it", false)]);
    t.turn_times = vec![(0, 777_000, None)];
    t.last_seq = 5;
    assert_eq!(heard_at(&t, 780_000), 777_000, "the turn's start until an event comes");
    t.last_seq = 6;
    assert_eq!(heard_at(&t, 790_000), 790_000);
    assert_eq!(heard_at(&t, 799_000), 790_000);
}
