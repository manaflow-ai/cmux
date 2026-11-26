//! Sending to a chat and keeping it in the Cloud, against the fake store.

mod support;

use cmux_auto_session::cloud::AutoCloud;
use cmux_auto_session::consts::LEASE_MS;
use cmux_auto_session::wire::Fence;
use cmux_mobile_auto::chat::ChatSession;
use cmux_mobile_auto::rows::Place;
use serde_json::json;
use support::*;

#[test]
fn a_sent_message_waits_until_the_chat_shows_it() {
    let owner = store();
    let session = ChatSession::new(owner.clone(), CHAT);
    ready(session.open()).expect("opened");

    let sent = ready(session.send("m1", "hello")).expect("sent");
    assert_eq!(drawn(&sent.records), ["queued:m1"]);
    assert_eq!(sent.records[0]["msg"]["text"], "hello");
    assert_eq!(chat(&owner).inbox, 1);

    // The laptop takes it and runs it under the message's id.
    let taken = drain(&owner, &mac(), 1);
    assert_eq!(taken.iter().map(|message| message.id.as_str()).collect::<Vec<_>>(), ["m1"]);
    append(
        &owner,
        &mac(),
        1,
        vec![prompt("m1", "t1", "hello"), log("turn_started", json!({ "turnId": "t1" }))],
    );

    // The phone's waiting row goes just before the chat's own record of the message.
    let batch = ready(session.next()).expect("the chat's records");
    assert_eq!(drawn(&batch.records), ["dequeued:m1", "user_message:m1", "turn_started"]);
    assert_eq!(batch.chat.expect("the chat").place, Place::OnMac);
}

#[test]
fn the_same_message_sent_again_is_not_a_second_message() {
    let owner = store();
    let session = ChatSession::new(owner.clone(), CHAT);
    ready(session.open()).expect("opened");

    assert_eq!(ready(session.send("m1", "hello")).expect("sent").records.len(), 1);
    // The person's retry, with the id the message had: nothing new anywhere.
    let again = ready(session.send("m1", "hello")).expect("sent again");
    assert!(again.records.is_empty());
    assert_eq!(chat(&owner).inbox, 1);
    assert_eq!(drain(&owner, &mac(), 1).len(), 1);
}

#[test]
fn a_lost_answer_is_retried_with_the_same_id() {
    let owner = store();
    let lossy = Lossy::new(&owner);
    let session = ChatSession::new(lossy, CHAT);
    ready(session.open()).expect("opened");

    // The store takes the message; the phone never hears. The send goes again by itself.
    let before = owner.calls().len();
    session.cloud().lose_next_answer();
    let sent = ready(session.send("m1", "hello")).expect("sent on the second try");
    assert_eq!(drawn(&sent.records), ["queued:m1"]);
    assert_eq!(owner.calls()[before..], ["post_inbox", "post_inbox"]);
    // One message reached the chat.
    let taken = drain(&owner, &mac(), 1);
    assert_eq!(taken.iter().map(|message| message.text.as_str()).collect::<Vec<_>>(), ["hello"]);
}

#[test]
fn a_send_with_no_network_fails_and_stores_nothing() {
    let owner = store();
    let session = ChatSession::new(owner.clone(), CHAT);
    ready(session.open()).expect("opened");

    owner.set_offline(true);
    let error = ready(session.send("m1", "hello")).expect_err("no network");
    assert!(error.retryable());
    owner.set_offline(false);
    assert_eq!(chat(&owner).inbox, 0);

    // The person sends it again under the same id: one message.
    assert_eq!(drawn(&ready(session.send("m1", "hello")).expect("sent").records), ["queued:m1"]);
    assert_eq!(chat(&owner).inbox, 1);
}

#[test]
fn a_message_for_a_chat_nobody_runs_says_resuming_until_the_machine_takes_it() {
    let owner = store();
    copied(&owner);
    owner.advance(LEASE_MS);
    let session = ChatSession::new(owner.clone(), CHAT);
    assert_eq!(ready(session.open()).expect("opened").chat.expect("the chat").place, Place::Idle);

    let sent = ready(session.send("m1", "go on")).expect("sent");
    assert_eq!(sent.chat.expect("the chat").place, Place::Resuming);
    assert_eq!(owner.machine_starts(), [VM]);
    let epoch = chat(&owner).epoch;

    // The machine starts, takes the message, acks what it was given and runs the message.
    let machine = owner.as_machine(VM);
    let mut held = Box::pin(session.next());
    assert!(look(&mut held).is_none());
    assert_eq!(drain(&machine, &vm(), epoch).len(), 1);
    let still = look(&mut held).expect("answered").expect("the chat");
    assert_eq!(still.chat.expect("the chat").place, Place::Resuming);

    ready(machine.ack_assignment(CHAT, &Fence::new(vm(), epoch))).expect("acked");
    append(&machine, &vm(), epoch, vec![prompt("m1", "t1", "go on")]);
    let mut seen = Vec::new();
    let mut place = Place::Resuming;
    for _ in 0..3 {
        let mut next = Box::pin(session.next());
        let Some(batch) = look(&mut next) else { break };
        let batch = batch.expect("the chat");
        place = batch.chat.expect("the chat").place;
        seen.extend(drawn(&batch.records));
    }
    assert_eq!(seen, ["dequeued:m1", "user_message:m1"]);
    assert_eq!(place, Place::Cloud);
}

#[test]
fn a_message_the_holder_renamed_still_replaces_the_waiting_row() {
    let owner = store();
    let session = ChatSession::new(owner.clone(), CHAT);
    ready(session.open()).expect("opened");
    ready(session.send("m1", "hello")).expect("sent");

    // Before the holder took the message, another prompt with the same words is not it.
    append(&owner, &mac(), 1, vec![prompt("typed-on-the-mac", "t1", "hello")]);
    assert_eq!(drawn(&ready(session.next()).expect("records").records), ["user_message:typed-on-the-mac"]);

    // Taken, and run under an id of the holder's own.
    drain(&owner, &mac(), 1);
    append(&owner, &mac(), 1, vec![prompt("holder-made", "t2", "hello")]);
    let mut seen = Vec::new();
    for _ in 0..3 {
        let mut next = Box::pin(session.next());
        let Some(batch) = look(&mut next) else { break };
        seen.extend(drawn(&batch.expect("records").records));
    }
    assert_eq!(seen, ["dequeued:m1", "user_message:holder-made"]);
}

#[test]
fn a_chat_is_kept_in_the_cloud_and_let_go_again() {
    let owner = store();
    renew(&owner, &mac(), 1, true);
    owner.advance(LEASE_MS);
    let machine = owner.as_machine(VM);
    ready(machine.ack_assignment(CHAT, &Fence::new(vm(), 2))).expect("acked");

    let session = ChatSession::new(owner.clone(), CHAT);
    let opened = ready(session.open()).expect("opened").chat.expect("the chat");
    assert_eq!((opened.place, opened.in_cloud, opened.keep_in_cloud), (Place::Cloud, true, false));

    let kept = ready(session.keep(true)).expect("kept").chat.expect("the chat");
    assert!(kept.keep_in_cloud && chat(&owner).keep_in_cloud);
    let let_go = ready(session.keep(false)).expect("let go").chat.expect("the chat");
    assert!(!let_go.keep_in_cloud && !chat(&owner).keep_in_cloud);
}
