//! Starting a chat from the phone, against the fake store.

mod support;

use cmux_auto_session::cloud::AutoCloud;
use cmux_auto_session::fake::FakeAutoCloud;
use cmux_auto_session::wire::{AssignmentKind, State};
use cmux_mobile_auto::chat::ChatSession;
use cmux_mobile_auto::rows::{self, Place};
use cmux_mobile_auto::start::{self, NewChat, Started};
use support::*;

fn new_chat(message_id: &str) -> NewChat {
    NewChat {
        remote: " https://example.com/app.git ".to_owned(),
        branch: "main".to_owned(),
        message_id: message_id.to_owned(),
        text: "Fix the failing test".to_owned(),
    }
}

fn started(outcome: Started) -> rows::ChatRow {
    match outcome {
        Started::Chat { chat } => chat,
        other => panic!("not started: {other:?}"),
    }
}

#[test]
fn a_chat_starts_on_the_auto_machine() {
    let owner = with_machine();
    assert_eq!(ready(start::has_machine(&owner)), Ok(true));

    let chat = started(ready(start::start(&owner, &new_chat("first-1"))).expect("started"));
    assert_eq!(chat.place, Place::Resuming);
    assert!(chat.in_cloud);
    assert_eq!(chat.repo, Some(repo("app", "main")));
    assert_eq!(owner.machine_starts(), [VM]);

    // The machine is asked to make it, with the first message waiting in its inbox.
    let machine = owner.as_machine(VM);
    let assignments = ready(machine.assignments(0)).expect("assignments");
    assert_eq!(
        assignments.iter().map(|a| (a.kind, a.session.id.as_str())).collect::<Vec<_>>(),
        [(AssignmentKind::Create, chat.id.as_str())]
    );
    let stored = owner.peek(&chat.id).expect("the chat");
    assert_eq!((stored.harness.as_str(), stored.state, stored.inbox), ("claude", State::Resuming, 1));
    let inbox = ready(machine.inbox(&chat.id, 0)).expect("the inbox");
    assert_eq!(
        inbox.iter().map(|m| (m.id.as_str(), m.text.as_str())).collect::<Vec<_>>(),
        [("first-1", "Fix the failing test")]
    );

    // It is in the list, and it opens.
    assert_eq!(ready(rows::list(&owner)).expect("the list").chats.len(), 1);
    let session = ChatSession::new(owner, chat.id);
    assert_eq!(ready(session.open()).expect("opened").chat.expect("the chat").place, Place::Resuming);
}

#[test]
fn the_same_start_again_reaches_the_same_chat() {
    let owner = with_machine();
    let first = started(ready(start::start(&owner, &new_chat("first-1"))).expect("started"));
    let again = started(ready(start::start(&owner, &new_chat("first-1"))).expect("started again"));
    assert_eq!(first.id, again.id);
    // Another first message is another chat.
    let other = started(ready(start::start(&owner, &new_chat("first-2"))).expect("started"));
    assert_ne!(first.id, other.id);
    assert_eq!(ready(rows::list(&owner)).expect("the list").chats.len(), 2);
}

#[test]
fn a_start_whose_answer_was_lost_is_retried_into_one_chat() {
    let owner = with_machine();
    let lossy = Lossy::new(&owner);
    lossy.lose_next_answer();
    let before = owner.calls().len();
    let chat = started(ready(start::start(&lossy, &new_chat("first-1"))).expect("started on the second try"));
    assert_eq!(owner.calls()[before..], ["create", "create"]);
    let list = ready(rows::list(&owner)).expect("the list");
    assert_eq!(list.chats.iter().map(|row| row.id.as_str()).collect::<Vec<_>>(), [chat.id.as_str()]);
    // One machine start, one first message.
    assert_eq!(owner.machine_starts(), [VM]);
    assert_eq!(owner.peek(&chat.id).expect("the chat").inbox, 1);
}

#[test]
fn with_no_auto_machine_nothing_starts() {
    let owner = FakeAutoCloud::new();
    assert_eq!(ready(start::has_machine(&owner)), Ok(false));
    assert_eq!(ready(start::start(&owner, &new_chat("first-1"))), Ok(Started::NoMachine));
    assert!(ready(rows::list(&owner)).expect("the list").chats.is_empty());
    assert!(owner.machine_starts().is_empty());
}

#[test]
fn a_start_with_an_empty_field_sends_nothing() {
    let owner = with_machine();
    let before = owner.calls().len();
    for new in [
        NewChat { remote: "  ".to_owned(), ..new_chat("m") },
        NewChat { branch: String::new(), ..new_chat("m") },
        NewChat { text: " \n".to_owned(), ..new_chat("m") },
        NewChat { message_id: String::new(), ..new_chat("m") },
    ] {
        assert_eq!(ready(start::start(&owner, &new)), Ok(Started::Incomplete));
    }
    assert_eq!(owner.calls().len(), before);
}

#[test]
fn a_start_with_no_network_is_an_error_the_person_can_retry() {
    let owner = with_machine();
    owner.set_offline(true);
    let error = ready(start::start(&owner, &new_chat("first-1"))).expect_err("no network");
    assert!(error.retryable());
    owner.set_offline(false);
    assert!(ready(rows::list(&owner)).expect("the list").chats.is_empty());
    // The same sheet sent again, with the id it had.
    started(ready(start::start(&owner, &new_chat("first-1"))).expect("started"));
    assert_eq!(ready(rows::list(&owner)).expect("the list").chats.len(), 1);
}
