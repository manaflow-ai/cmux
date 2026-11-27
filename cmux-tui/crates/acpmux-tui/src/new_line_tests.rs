use super::*;

fn chat(items: &[Item], status: &str) -> Transcript {
    let mut t = Transcript::default();
    t.items = items.to_vec();
    t.status = status.to_owned();
    t
}

fn user(s: &str) -> Item {
    Item::User { text: s.into(), steer: false, queued: false }
}

#[test]
fn marks_what_arrived_since_you_left() {
    let t = chat(
        &[
            user("a"),
            Item::Assistant { text: "b".into() },
            user("c"),
            Item::Assistant { text: "d".into() },
        ],
        "idle",
    );
    let line = NewLine::on_return("s", &t, 2).unwrap();
    assert_eq!((line.item, line.messages, line.label().as_str()), (2, 2, "2 new messages"));
    assert!(NewLine::on_return("s", &t, 4).is_none());
}

#[test]
fn a_running_turn_is_not_new() {
    let t = chat(
        &[
            user("a"),
            Item::Assistant { text: "b".into() },
            user("c"),
            Item::Assistant { text: "d".into() },
        ],
        "running",
    );
    // Only the running turn arrived: no line.
    assert!(NewLine::on_return("s", &t, 2).is_none());
    // A finished turn and the running one: the line counts the finished one.
    let line = NewLine::on_return("s", &t, 1).unwrap();
    assert_eq!((line.item, line.messages, line.label().as_str()), (1, 1, "1 new message"));
}

#[test]
fn takes_the_blank_row_and_lands_past_a_screen() {
    let rows = [(0, "› a"), (1, ""), (1, "b"), (2, ""), (2, "› c"), (3, "d")];
    assert_eq!(row(&rows, 2), Some(3));
    assert_eq!(row(&rows, 0), None);
    let tight = [(0, "a"), (1, "b")];
    assert_eq!(row(&tight, 1), None);
    assert_eq!(landing(3, 100, 20), Some(3));
    assert_eq!(landing(90, 100, 20), None);
}

#[test]
fn rule_centers_its_label() {
    assert_eq!(rule("New", 11), "─── New ───");
    assert_eq!(rule("3 new messages", 3), "3 new messages");
}
