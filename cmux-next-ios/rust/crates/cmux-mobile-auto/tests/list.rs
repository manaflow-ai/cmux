//! The list of the person's Auto chats, against the fake store.

mod support;

use cmux_auto_session::cloud::AutoCloud;
use cmux_auto_session::consts::LEASE_MS;
use cmux_auto_session::fake::FakeAutoCloud;
use cmux_auto_session::wire::{Fence, InboxPost, LeaseRequest};
use cmux_mobile_auto::rows::{self, Place};
use support::*;

#[test]
fn the_list_says_where_each_chat_is() {
    let owner = with_machine();
    // Three chats a laptop started, a millisecond apart, so their order is known.
    for (id, repo) in
        [("on_mac", repo("app", "main")), ("in_cloud", repo("app", "fix")), ("idle", repo("site", "main"))]
    {
        ready(owner.put(id, &put_request(id, Some(repo)))).expect("the chat");
        owner.advance(1);
    }
    // One was at work when the laptop went away: the machine took it and acked.
    let at_work = LeaseRequest { holder: mac(), epoch: 1, needs_run: true, standby: None };
    ready(owner.lease("in_cloud", &at_work)).expect("renewed");
    owner.advance(LEASE_MS);
    let machine = owner.as_machine(VM);
    ready(machine.ack_assignment("in_cloud", &Fence::new(vm(), 2))).expect("acked");
    // One is the laptop's again.
    let again = LeaseRequest { holder: mac(), epoch: 1, needs_run: false, standby: None };
    ready(owner.lease("on_mac", &again)).expect("retaken");

    let list = ready(rows::list(&owner)).expect("the list");
    let shown: Vec<(&str, Place)> = list.chats.iter().map(|chat| (chat.id.as_str(), chat.place)).collect();
    // Newest first.
    assert_eq!(shown, [("idle", Place::Idle), ("in_cloud", Place::Cloud), ("on_mac", Place::OnMac)]);
    assert!(list.chats[1].in_cloud && !list.chats[0].in_cloud);
    assert!(!list.more);
    assert_eq!(list.chats[1].title, "in_cloud");
}

#[test]
fn a_chat_being_started_says_resuming() {
    let owner = store();
    copied(&owner);
    owner.advance(LEASE_MS);
    assert_eq!(ready(rows::list(&owner)).expect("the list").chats[0].place, Place::Idle);

    // A message for a chat nobody runs starts the machine.
    ready(owner.post_inbox(CHAT, &InboxPost { id: "m1".into(), text: "go on".into() })).expect("sent");
    let list = ready(rows::list(&owner)).expect("the list");
    assert_eq!(list.chats[0].place, Place::Resuming);
    assert!(list.chats[0].in_cloud);
}

#[test]
fn a_chat_with_work_and_no_machine_says_so() {
    let owner = FakeAutoCloud::new();
    ready(owner.put(CHAT, &put_request("Fix the build", None))).expect("the chat");
    renew(&owner, &mac(), 1, true);
    owner.advance(LEASE_MS);
    assert_eq!(ready(rows::list(&owner)).expect("the list").chats[0].place, Place::NoMachine);
}

#[test]
fn the_list_is_read_page_by_page() {
    let owner = with_machine();
    for n in 0..230 {
        ready(owner.put(&format!("chat_{n:03}"), &put_request("A chat", Some(repo("app", "main")))))
            .expect("the chat");
        owner.advance(1);
    }
    let before = owner.calls().len();
    let list = ready(rows::list(&owner)).expect("the list");
    assert_eq!(list.chats.len(), 230);
    assert_eq!(list.chats.first().map(|chat| chat.id.as_str()), Some("chat_229"));
    assert_eq!(list.chats.last().map(|chat| chat.id.as_str()), Some("chat_000"));
    assert!(!list.more);
    // Three pages of at most 100, and nothing else.
    assert_eq!(owner.calls()[before..], ["list", "list", "list"]);
}

#[test]
fn recent_repositories_are_listed_once_newest_first() {
    let owner = with_machine();
    for (id, repo) in [
        ("a", repo("app", "main")),
        ("b", repo("site", "main")),
        ("c", repo("app", "main")),
        ("d", repo("app", "fix")),
    ] {
        ready(owner.put(id, &put_request(id, Some(repo)))).expect("the chat");
        owner.advance(1);
    }
    ready(owner.put("no_repo", &put_request("no repo", None))).expect("the chat");
    let list = ready(rows::list(&owner)).expect("the list");
    assert_eq!(list.repos, [repo("app", "fix"), repo("app", "main"), repo("site", "main")]);
}

#[test]
fn a_list_that_cannot_be_read_is_the_stores_error() {
    let owner = store();
    owner.set_offline(true);
    let error = ready(rows::list(&owner)).expect_err("no network");
    assert!(error.is_transport() && error.retryable());
}
