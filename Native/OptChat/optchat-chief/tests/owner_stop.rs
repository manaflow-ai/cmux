//! chief.stop: a turn the owner stopped posts nothing to the conversation
//! (and so to no bridge), however it ends. The owner pressed stop and
//! already knows (Lawrence 2026-10-19).

mod common;

use std::sync::mpsc::channel;

use cmux_conversation::Op;
use common::*;
use optchat_chief::brain::Input;
use optchat_chief::state::{HostState, StateFile};

/// chief.stop, as the host's control socket sends it.
fn owner_stop(h: &mut Harness) {
    let (reply, answer) = channel();
    h.brain.step(Input::Stop { reply });
    let answer = answer.try_recv().expect("chief.stop answers at once");
    assert_eq!(answer["stopped"], true, "{answer}");
}

/// A turn is running for `text`, held at the fake agent.
fn running(h: &mut Harness, text: &str) {
    h.agents.hold(true);
    h.connect();
    h.say("user_local", text);
    while h.agents.inner.lock().unwrap().prompts.is_empty() {
        h.step();
    }
}

/// Nothing reached the conversation: no reply, no done marker.
fn assert_no_post(h: &Harness) {
    let owner = h.owner.lock().unwrap();
    let posts: Vec<_> = owner
        .ops
        .iter()
        .filter(|(_, op)| matches!(op, Op::MessageSend { .. }))
        .collect();
    assert!(posts.is_empty(), "nothing posted: {posts:?}");
}

#[test]
fn a_stopped_turn_that_finishes_before_the_interrupt_posts_nothing() {
    let mut h = Harness::new(default_script());
    running(&mut h, "hi");
    // The agent never sees the cancel: its turn ends normally, with a reply.
    h.agents.inner.lock().unwrap().ignore_cancels = usize::MAX;
    owner_stop(&mut h);
    h.agents.hold(false);
    h.agents.release();
    h.settle_posts();
    assert_no_post(&h);
}

#[test]
fn a_stopped_turn_that_closes_open_work_posts_no_done_marker() {
    // An earlier reply left msg_1's work open (a subagent was at work); the
    // turn now running answers msg_1 and so would close it.
    let dir = tempfile::tempdir().unwrap();
    StateFile::new(&dir.path().join("host.json"))
        .save(&HostState {
            open_answers: vec!["msg_1".into()],
            ..Default::default()
        })
        .unwrap();
    let owner = std::sync::Arc::new(std::sync::Mutex::new(Owner {
        summary: Some(summary()),
        ..Owner::default()
    }));
    let mut h = Harness::in_dir(dir, default_script(), owner);
    running(&mut h, "how did it go?");
    owner_stop(&mut h);
    h.agents.hold(false);
    h.settle_posts();
    assert_no_post(&h);
    // With no done marker, msg_1's work stays open for a later turn to
    // close: a client's pending mark must not stick forever.
    let rows = h.chat.state_prefix("host/").unwrap();
    assert!(
        rows.iter()
            .any(|(k, v)| k == "host/open_answers" && v.contains("msg_1")),
        "{rows:?}"
    );
}
