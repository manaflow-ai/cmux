//! One history (plans/cmux-next/home-state-ownership.md): the Chief home's
//! host stops and starts again (an app relaunch from another build, a reboot)
//! and keeps one memory that holds the same human messages, in the same order,
//! as the conversation the Home transcript shows; a message sent while no host
//! ran is taken at the next start, once.

mod common;

use std::sync::{Arc, Mutex};

use cmux_conversation::Part;
use common::*;

fn texts(owner: &Arc<Mutex<Owner>>, author: &str) -> Vec<String> {
    owner
        .lock()
        .unwrap()
        .messages
        .iter()
        .filter(|m| m.author == author)
        .map(|m| match &m.parts[0] {
            Part::Text { text, .. } => text.clone(),
            _ => String::new(),
        })
        .collect()
}

fn memory_users(h: &Harness) -> Vec<String> {
    h.log()
        .into_iter()
        .filter(|(kind, _)| kind == "user")
        .map(|(_, text)| text)
        .collect()
}

/// Stops the host (its brain and memory handle), keeping its directory.
fn stop(h: Harness) -> (tempfile::TempDir, Arc<Mutex<Owner>>, usize) {
    let Harness {
        dir,
        chat,
        owner,
        brain,
        ..
    } = h;
    let entries = chat.status().messages as usize;
    drop(brain);
    chat.shutdown();
    drop(chat);
    (dir, owner, entries)
}

#[test]
fn a_restarted_host_keeps_its_memory_and_takes_what_was_sent_while_it_was_down() {
    let mut first = Harness::new(default_script());
    first.connect();
    first.say("user_local", "hi");
    first.settle();
    let before = first.log();
    let (dir, owner, entries) = stop(first);
    assert!(entries >= 2, "the first turn is in the memory: {before:?}");

    // Sent from another build while no host ran.
    {
        let mut o = owner.lock().unwrap();
        let seq = o.messages.len() as u64 + 1;
        o.messages.push(message(seq, "user_local", "still there?"));
    }
    let mut second = Harness::in_dir(dir, default_script(), owner.clone());
    second.connect();
    second.settle();
    assert_eq!(
        second.log()[..before.len()],
        before[..],
        "the memory is the same memory"
    );
    assert_eq!(
        second.agents.inner.lock().unwrap().prompts.len(),
        1,
        "only the message sent while down wakes a turn; hi is not answered again"
    );
    assert_eq!(texts(&owner, "agent_mux").len(), 2, "one reply per message");
    assert_eq!(texts(&owner, "user_local"), memory_users(&second));
}

#[test]
fn the_chat_and_the_memory_hold_the_same_human_messages_across_restarts() {
    let mut h = Harness::new(default_script());
    h.connect();
    for text in ["one", "two"] {
        h.say("user_local", text);
        h.settle();
    }
    let (dir, owner, _) = stop(h);
    let mut h = Harness::in_dir(dir, default_script(), owner.clone());
    h.connect();
    h.settle();
    h.say("user_local", "three");
    h.settle();
    let (dir, owner, _) = stop(h);
    let mut h = Harness::in_dir(dir, default_script(), owner.clone());
    h.connect();
    h.settle();
    assert_eq!(texts(&owner, "user_local"), vec!["one", "two", "three"]);
    assert_eq!(memory_users(&h), texts(&owner, "user_local"));
    assert_eq!(h.agents.inner.lock().unwrap().prompts.len(), 0);
}
