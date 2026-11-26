//! A send whose answer is lost or late while the chat is read on, against the fake store.

mod slow;
mod support;

use cmux_mobile_auto::chat::ChatSession;
use cmux_mobile_auto::rows::Place;
use serde_json::{Value, json};
use slow::{Fate, Slow};
use support::*;

/// A turn's records, the way a holder logs them.
fn turn(n: u64) -> Vec<Value> {
    vec![
        prompt(&format!("p{n}"), &format!("t{n}"), "go"),
        log("turn_started", json!({ "turnId": format!("t{n}") })),
        log("turn_result", json!({ "turnId": format!("t{n}"), "status": "completed" })),
    ]
}

fn seqs(records: &[Value]) -> Vec<u64> {
    records.iter().filter_map(|record| record["seq"].as_u64()).collect()
}

#[test]
fn a_retry_that_lands_after_the_chat_showed_the_message_adds_no_waiting_row() {
    let owner = store();
    let session = ChatSession::new(Slow::new(&owner), CHAT);
    ready(session.open()).expect("opened");

    // The store takes the message. Its answer is lost, and the phone still waits for it.
    session.cloud().hold_next_send(Fate::Lost);
    let mut sending = Box::pin(session.send("m1", "hello"));
    assert!(look(&mut sending).is_none());
    assert_eq!(chat(&owner).inbox, 1);

    // Meanwhile the laptop takes the message and runs it, and the phone draws its record.
    drain(&owner, &mac(), 1);
    append(&owner, &mac(), 1, vec![prompt("m1", "t1", "hello")]);
    let shown = ready(session.next()).expect("the chat's records");
    assert_eq!(drawn(&shown.records), ["user_message:m1"]);

    // The phone gives up on the first answer and sends again under the same id. The store
    // answers this time. The chat already shows the message: no waiting row is added for it.
    let before = owner.calls().len();
    session.cloud().let_go();
    let sent = look(&mut sending).expect("answered").expect("sent on the second try");
    assert_eq!(owner.calls()[before..], ["post_inbox"]);
    assert_eq!(drawn(&sent.records), Vec::<String>::new());
    assert_eq!(sent.chat.expect("the chat").place, Place::OnMac);

    // The person's own retry of that message adds none either.
    let again = ready(session.send("m1", "hello")).expect("sent again");
    assert_eq!(drawn(&again.records), Vec::<String>::new());
    assert_eq!(chat(&owner).inbox, 1);
}

#[test]
fn a_send_answered_before_later_events_does_not_end_the_chat() {
    let owner = store();
    // 100 turns: 300 events, more than one page of 256, so the phone still reads pages.
    append(&owner, &mac(), 1, (0..100).flat_map(turn).collect());
    let session = ChatSession::new(Slow::new(&owner), CHAT);
    let first = ready(session.open()).expect("opened");
    assert_eq!(seqs(&first.records).last(), Some(&256));
    assert!(!first.caught_up);

    // The store answers the send while the chat has 300 events. The answer is slow to arrive.
    session.cloud().hold_next_send(Fate::Late);
    let mut sending = Box::pin(session.send("m1", "hello"));
    assert!(look(&mut sending).is_none());

    // The laptop writes another turn, and the phone's next page brings it too.
    append(&owner, &mac(), 1, turn(100));
    let rest = ready(session.next()).expect("the rest");
    assert_eq!(seqs(&rest.records), (257..=303).collect::<Vec<u64>>());
    assert!(rest.caught_up);

    // The send's answer arrives. It says the chat has 300 events, fewer than the phone has:
    // the answer is older than the page, and the chat did not start over.
    session.cloud().let_go();
    let sent = look(&mut sending).expect("answered").expect("sent");
    assert_eq!(drawn(&sent.records), ["queued:m1"]);
    assert!(!sent.ended);

    // The chat is read on: the laptop takes the message and runs it.
    drain(&owner, &mac(), 1);
    append(&owner, &mac(), 1, vec![prompt("m1", "t101", "hello")]);
    let ran = ready(session.next()).expect("the message's record");
    assert_eq!(drawn(&ran.records), ["dequeued:m1", "user_message:m1"]);
    assert_eq!(seqs(&ran.records), [0, 304]);
    assert!(ran.caught_up && !ran.ended);

    // And it takes another message.
    assert_eq!(drawn(&ready(session.send("m2", "more")).expect("sent").records), ["queued:m2"]);
}
