//! A chat whose Auto is switched off, or off and on again, while the phone has it open, against
//! the fake store. Auto off drops the store's copy of the chat; switched on again it starts
//! over, empty.

mod support;

use cmux_auto_session::cloud::AutoCloud;
use cmux_auto_session::fake::FakeAutoCloud;
use cmux_auto_session::wire::PutRequest;
use cmux_mobile_auto::chat::ChatSession;
use serde_json::{Value, json};
use support::*;

/// A turn's records, the way a holder logs them.
fn turn(n: u64) -> Vec<Value> {
    vec![
        prompt(&format!("p{n}"), &format!("t{n}"), "go"),
        log("turn_started", json!({ "turnId": format!("t{n}") })),
        log("turn_result", json!({ "turnId": format!("t{n}"), "status": "completed" })),
    ]
}

fn switch_off(owner: &FakeAutoCloud) {
    let off = PutRequest { auto: false, ..put_request("Fix the build", None) };
    ready(owner.put(CHAT, &off)).expect("closed");
}

/// Auto on again for the closed chat: the laptop holds it at a new epoch, which is answered.
fn switch_on(owner: &FakeAutoCloud) -> u64 {
    ready(owner.put(CHAT, &put_request("Fix the build", None))).expect("opened again").epoch
}

/// Calls `next` until the chat ends, at most `most` times. Answers whether it ended. Nothing
/// may be held and nothing drawn on the way.
fn read_to_the_end(session: &ChatSession<FakeAutoCloud>, most: usize) -> bool {
    for _ in 0..most {
        let batch = ready(session.next()).expect("the chat");
        assert_eq!(drawn(&batch.records), Vec::<String>::new());
        assert_eq!(batch.retry_after_ms, None);
        if batch.ended {
            return true;
        }
    }
    false
}

#[test]
fn auto_switched_off_while_the_phone_reads_pages_ends_the_chat() {
    let owner = store();
    // 200 turns: 600 events. The phone has the first page of 256 and knows of more.
    append(&owner, &mac(), 1, (0..200).flat_map(turn).collect());
    let session = ChatSession::new(owner.clone(), CHAT);
    assert!(!ready(session.open()).expect("opened").caught_up);

    switch_off(&owner);

    // The next page is empty and says the store has no events. That is the end, in one request,
    // not the same page asked for again and again.
    let before = owner.calls().len();
    assert!(read_to_the_end(&session, 4));
    assert_eq!(owner.calls()[before..], ["events"]);

    // An ended chat answers at once and asks the store nothing.
    assert!(ready(session.next()).expect("ended").ended);
    assert_eq!(owner.calls()[before..], ["events"]);
}

#[test]
fn a_chat_started_over_while_the_phone_reads_pages_ends() {
    let owner = store();
    append(&owner, &mac(), 1, (0..200).flat_map(turn).collect());
    let session = ChatSession::new(owner.clone(), CHAT);
    assert!(!ready(session.open()).expect("opened").caught_up);

    // Off and on again, and the new chat already has as many events as the phone read of the
    // old one: the next page is empty though the phone was told of 600.
    switch_off(&owner);
    let epoch = switch_on(&owner);
    append(&owner, &mac(), epoch, (0..86).flat_map(turn).take(256).collect());
    assert_eq!(chat(&owner).last_seq, 256);

    // One empty page, then the chat as it is now, which has fewer events than it had: done.
    let before = owner.calls().len();
    assert!(read_to_the_end(&session, 4));
    assert_eq!(owner.calls()[before..], ["events", "wait"]);
}

#[test]
fn a_chat_started_over_behind_a_caught_up_phone_ends() {
    let owner = store();
    append(&owner, &mac(), 1, (0..2).flat_map(turn).collect());
    let session = ChatSession::new(owner.clone(), CHAT);
    assert!(ready(session.open()).expect("opened").caught_up);

    // Off and on again between two reads, and written to again: the phone never saw it closed.
    switch_off(&owner);
    let epoch = switch_on(&owner);
    append(&owner, &mac(), epoch, turn(9));
    assert!(chat(&owner).auto);

    // The chat has 3 events where the phone drew 6: it is another chat's log now.
    let before = owner.calls().len();
    assert!(read_to_the_end(&session, 4));
    assert_eq!(owner.calls()[before..], ["wait"]);
}
