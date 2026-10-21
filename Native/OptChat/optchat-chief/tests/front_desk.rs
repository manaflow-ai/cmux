//! The front desk's receipt (brain/desk.rs): a message that waits on a
//! running turn gets an answer in the desk voice at once, without a model.

mod common;
use common::*;

use std::time::Duration;

use cmux_conversation::Op;
use optchat_chief::voice;

/// A turn is running for `text`, held at the fake agent.
fn running(h: &mut Harness, text: &str) {
    h.agents.hold(true);
    h.connect();
    h.say("user_local", text);
    while h.agents.inner.lock().unwrap().prompts.is_empty() {
        h.step();
    }
}

/// Fires every timer that is due within `within`.
fn pass(h: &mut Harness, within: Duration) {
    let until = std::time::Instant::now() + within;
    while let Some(at) = h.brain.next_timer().filter(|at| *at <= until) {
        std::thread::sleep(at.saturating_duration_since(std::time::Instant::now()));
        h.brain.on_timer();
    }
}

/// The desk's posts: (key, text).
fn receipts(h: &Harness) -> Vec<(String, String)> {
    h.owner
        .lock()
        .unwrap()
        .sends()
        .into_iter()
        .filter(|(key, _)| voice::of(key) == Some(voice::DESK))
        .collect()
}

#[test]
fn a_message_that_waits_on_a_running_turn_gets_the_desks_receipt() {
    let mut h = Harness::new(default_script());
    h.brain.set_desk_grace(Some(Duration::from_millis(20)));
    running(&mut h, "fix the sidebar");
    h.say("user_local", "hello?");
    h.say("user_local", "are you there?");
    pass(&mut h, Duration::from_millis(200));

    let posted = receipts(&h);
    assert_eq!(posted.len(), 1, "one receipt per turn: {posted:?}");
    let (key, text) = &posted[0];
    assert!(key.starts_with("voice:desk:turn:optchat:"), "{key}");
    assert!(
        text.starts_with("Got it. The Chief is busy with a turn"),
        "{text}"
    );
    // Its client_msg_id is the voice the app labels.
    let owner = h.owner.lock().unwrap();
    assert!(owner.ops.iter().any(|(_, op)| matches!(
        op,
        Op::MessageSend { client_msg_id, .. } if client_msg_id == key
    )));
    drop(owner);

    // The turn's own reply follows as the Chief's, a separate message.
    h.agents.hold(false);
    h.agents.release();
    h.settle_posts();
    let sends = h.owner.lock().unwrap().sends();
    let last = sends.last().expect("the turn's reply");
    assert_eq!(voice::of(&last.0), None, "{sends:?}");
}

#[test]
fn a_turn_that_ends_within_the_grace_gets_no_receipt() {
    let mut h = Harness::new(default_script());
    h.brain.set_desk_grace(Some(Duration::from_secs(30)));
    running(&mut h, "fix the sidebar");
    h.say("user_local", "and the composer");
    h.agents.hold(false);
    h.agents.release();
    h.settle_posts();
    assert!(receipts(&h).is_empty(), "{:?}", receipts(&h));
}

#[test]
fn without_a_grace_the_desk_stays_quiet() {
    let mut h = Harness::new(default_script());
    running(&mut h, "fix the sidebar");
    h.say("user_local", "hello?");
    pass(&mut h, Duration::from_millis(50));
    assert!(receipts(&h).is_empty());
}

#[test]
fn the_receipt_leaves_the_chiefs_reply_at_the_top_level() {
    let mut h = Harness::new(default_script());
    h.agents.inner.lock().unwrap().steering = true;
    h.brain.set_desk_grace(Some(Duration::from_millis(20)));
    running(&mut h, "fix the sidebar");
    h.say("user_local", "hello?");
    while h.agents.inner.lock().unwrap().steers.is_empty() {
        h.step();
    }
    pass(&mut h, Duration::from_millis(200));
    assert_eq!(receipts(&h).len(), 1);

    // The reply answers "hello?" right under it: the receipt in between is
    // an aside, not a newer message that moves the reply into a thread.
    h.agents.hold(false);
    h.agents.release();
    h.settle_posts();
    let owner = h.owner.lock().unwrap();
    let reply = owner
        .ops
        .iter()
        .filter_map(|(key, op)| match op {
            Op::MessageSend {
                thread_root,
                reply_to,
                ..
            } if voice::of(key).is_none() => Some((key, thread_root, reply_to)),
            _ => None,
        })
        .next_back()
        .expect("the turn's reply");
    assert_eq!((reply.1, reply.2), (&None, &None), "{reply:?}");
}
