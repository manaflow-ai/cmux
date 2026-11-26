//! Opening a chat and keeping up with it, against the fake store.

mod support;

use cmux_auto_session::cloud::AutoCloud;
use cmux_auto_session::consts::{LEASE_MS, WAIT_MAX_MS};
use cmux_auto_session::wire::PutRequest;
use cmux_mobile_auto::chat::ChatSession;
use cmux_mobile_auto::rows::Place;
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

fn seqs(records: &[Value]) -> Vec<u64> {
    records.iter().filter_map(|record| record["seq"].as_u64()).collect()
}

#[test]
fn a_chat_opens_page_by_page() {
    let owner = store();
    // 200 turns: 600 events, more than two pages of 256.
    append(&owner, &mac(), 1, (0..200).flat_map(turn).collect());
    let session = ChatSession::new(owner, CHAT);

    let first = ready(session.open()).expect("opened");
    let chat = first.chat.clone().expect("the chat");
    assert_eq!((chat.title.as_str(), chat.place), ("Fix the build", Place::OnMac));
    assert_eq!(seqs(&first.records), (1..=256).collect::<Vec<u64>>());
    assert!(!first.caught_up);
    // Every record names the chat, not what the holder called it.
    assert!(first.records.iter().all(|record| record["sessionId"] == CHAT));
    assert_eq!(drawn(&first.records[..3]), ["user_message:p0", "turn_started", "turn_result"]);

    let second = ready(session.next()).expect("the second page");
    assert_eq!(seqs(&second.records), (257..=512).collect::<Vec<u64>>());
    assert!(!second.caught_up);

    let third = ready(session.next()).expect("the last page");
    assert_eq!(seqs(&third.records), (513..=600).collect::<Vec<u64>>());
    assert!(third.caught_up && !third.ended);
    assert_eq!(third.retry_after_ms, None);
}

#[test]
fn an_open_chat_is_kept_current_by_one_held_request() {
    let owner = store();
    append(&owner, &mac(), 1, turn(1));
    let session = ChatSession::new(owner.clone(), CHAT);
    assert_eq!(ready(session.open()).expect("opened").records.len(), 3);

    // Nothing new: the request is held, and holding it asks the store nothing more.
    let before = owner.calls().len();
    let mut held = Box::pin(session.next());
    assert!(look(&mut held).is_none());
    assert!(look(&mut held).is_none());
    assert_eq!(owner.calls()[before..], ["wait"]);

    // The holder writes a turn: the held request answers with it.
    append(&owner, &mac(), 1, turn(2));
    let batch = look(&mut held).expect("answered").expect("the new records");
    assert_eq!(seqs(&batch.records), [4, 5, 6]);
    assert!(batch.caught_up);
    assert_eq!(owner.calls()[before..], ["wait", "append_events", "events"]);
}

#[test]
fn a_held_request_ends_at_the_stores_deadline_with_nothing_to_draw() {
    let owner = store();
    let session = ChatSession::new(owner.clone(), CHAT);
    ready(session.open()).expect("opened");
    let mut held = Box::pin(session.next());
    assert!(look(&mut held).is_none());

    owner.advance(WAIT_MAX_MS);
    let batch = look(&mut held).expect("the deadline").expect("the chat as it is");
    assert!(batch.records.is_empty() && batch.caught_up && !batch.ended);
    assert_eq!(batch.retry_after_ms, None);
    // The next call holds again.
    let mut again = Box::pin(session.next());
    assert!(look(&mut again).is_none());
}

#[test]
fn where_the_chat_is_follows_the_store() {
    let owner = store();
    renew(&owner, &mac(), 1, true);
    let session = ChatSession::new(owner.clone(), CHAT);
    assert_eq!(ready(session.open()).expect("opened").chat.expect("the chat").place, Place::OnMac);

    // The laptop goes away mid-work: the machine is started for the chat.
    let mut held = Box::pin(session.next());
    assert!(look(&mut held).is_none());
    owner.advance(LEASE_MS);
    let batch = look(&mut held).expect("answered").expect("the chat");
    assert_eq!(batch.chat.expect("the chat").place, Place::Resuming);
    assert_eq!(owner.machine_starts(), [VM]);
}

#[test]
fn no_network_is_a_wait_and_not_an_error() {
    let owner = store();
    append(&owner, &mac(), 1, turn(1));
    let session = ChatSession::new(owner.clone(), CHAT);
    ready(session.open()).expect("opened");

    owner.set_offline(true);
    let first = ready(session.next()).expect("no error");
    assert_eq!((first.records.len(), first.retry_after_ms), (0, Some(1_000)));
    assert_eq!(ready(session.next()).expect("no error").retry_after_ms, Some(2_000));

    // Back: what was written meanwhile arrives, and the wait starts over.
    owner.set_offline(false);
    append(&owner, &mac(), 1, turn(2));
    let batch = ready(session.next()).expect("the new records");
    assert_eq!((seqs(&batch.records), batch.retry_after_ms), (vec![4, 5, 6], None));
    owner.set_offline(true);
    assert_eq!(ready(session.next()).expect("no error").retry_after_ms, Some(1_000));
}

#[test]
fn a_chat_opened_with_no_network_waits_and_opens_when_it_is_back() {
    let owner = store();
    append(&owner, &mac(), 1, turn(1));
    let session = ChatSession::new(owner.clone(), CHAT);

    owner.set_offline(true);
    let first = ready(session.next()).expect("no error");
    assert_eq!((first.chat.is_none(), first.records.len(), first.retry_after_ms), (true, 0, Some(1_000)));
    assert_eq!(ready(session.next()).expect("no error").retry_after_ms, Some(2_000));

    owner.set_offline(false);
    let opened = ready(session.next()).expect("opened");
    assert_eq!((seqs(&opened.records), opened.retry_after_ms), (vec![1, 2, 3], None));
    assert!(opened.chat.is_some());
}

#[test]
fn a_chat_with_auto_switched_off_ends() {
    let owner = store();
    let session = ChatSession::new(owner.clone(), CHAT);
    ready(session.open()).expect("opened");
    let mut held = Box::pin(session.next());
    assert!(look(&mut held).is_none());

    let off = PutRequest { auto: false, ..put_request("Fix the build", None) };
    ready(owner.put(CHAT, &off)).expect("closed");
    let batch = look(&mut held).expect("answered").expect("the chat");
    assert!(batch.ended);
    // An ended chat answers at once and asks the store nothing.
    let before = owner.calls().len();
    assert!(ready(session.next()).expect("ended").ended);
    assert_eq!(owner.calls().len(), before);
}

#[test]
fn a_chat_the_store_does_not_have_is_an_error() {
    let owner = store();
    let session = ChatSession::new(owner, "no_such_chat");
    let error = ready(session.open()).expect_err("no such chat");
    assert_eq!(error.status(), Some(404));
    assert!(!error.retryable());
}

#[test]
fn an_event_that_is_no_log_record_is_skipped() {
    let owner = store();
    let mut records = turn(1);
    records.insert(1, json!({ "note": "not a log record" }));
    append(&owner, &mac(), 1, records);
    let session = ChatSession::new(owner, CHAT);
    let batch = ready(session.open()).expect("opened");
    assert_eq!(seqs(&batch.records), [1, 3, 4]);
    assert!(batch.caught_up);
}
