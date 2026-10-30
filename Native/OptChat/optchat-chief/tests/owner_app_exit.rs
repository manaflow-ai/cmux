//! cp/quit-chief-idle (2026-10-27): after a Cmd-Q the Chief's host, its
//! acpmux and its owner daemon ran on, idle, about 300 MB. The app names
//! itself (`OPTCHAT_OWNER_APP_PID`); when it exits, an idle Chief stops
//! (`brain/owner_exit.rs`, `owner_app.rs`), and live work keeps it: Keep
//! Sessions Running keeps the Chief working.

mod common;

use std::time::{Duration, Instant};

use cmux_owner_liveness::OwnerState;
use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::brain::{Input, OWNER_APP_EXITED, PARENT};
use optchat_chief::daemon::DaemonEvent;

fn stopped_for_the_quit(h: &Harness) -> bool {
    h.brain
        .fatal()
        .is_some_and(|fatal| fatal.starts_with(OWNER_APP_EXITED))
}

/// Steps the brain until it stops or `within` passes.
fn step_until_stopped(h: &mut Harness, within: Duration) {
    let deadline = Instant::now() + within;
    while h.brain.fatal().is_none() && Instant::now() < deadline {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(50)) {
            h.brain.step(input);
        }
    }
}

fn child(session: &str, status: &str) -> cmux_chief::acp::SessionSummary {
    serde_json::from_value(serde_json::json!({
        "sessionId": session, "name": "bg", "status": status, "harness": "claude",
        "tags": {"mux.parent": PARENT},
    }))
    .unwrap()
}

#[test]
fn an_idle_chief_stops_when_its_app_quits() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "hello");
    h.settle_posts();
    assert!(h.brain.fatal().is_none());
    app_quits(&mut h);
    assert!(
        stopped_for_the_quit(&h),
        "an idle Chief outlived its app's quit: {:?}, held by {:?}",
        h.brain.fatal(),
        h.brain.owner_exit_held_by()
    );
}

#[test]
fn a_running_turn_keeps_the_chief_until_it_ends() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    h.connect();
    h.say("user_local", "a long task");
    while h.agents.inner.lock().unwrap().prompts.is_empty() {
        h.step();
    }
    app_quits(&mut h);
    assert!(h.brain.fatal().is_none(), "the quit cut a running turn");
    h.agents.hold(false);
    h.agents.release();
    step_until_stopped(&mut h, Duration::from_secs(10));
    assert!(
        stopped_for_the_quit(&h),
        "the Chief did not stop after its turn: {:?}, held by {:?}",
        h.brain.fatal(),
        h.brain.owner_exit_held_by()
    );
    let sends = h.owner.lock().unwrap().sends();
    assert!(
        sends.iter().any(|(_, t)| t.contains("answer 0")),
        "the turn's reply posted before the stop: {sends:?}"
    );
}

#[test]
fn a_child_at_work_keeps_the_chief_until_it_ends() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.settle_posts();
    h.brain
        .step(Input::from(AgentEvent::Up(vec![child("bg-1", "running")])));
    app_quits(&mut h);
    assert!(h.brain.fatal().is_none(), "the quit ended a child at work");
    h.brain.step(Input::from(AgentEvent::SessionChanged(child(
        "bg-1", "idle",
    ))));
    step_until_stopped(&mut h, Duration::from_secs(10));
    assert!(
        stopped_for_the_quit(&h),
        "the Chief did not stop once its child ended: {:?}, held by {:?}",
        h.brain.fatal(),
        h.brain.owner_exit_held_by()
    );
}

#[test]
fn a_chief_whose_app_runs_never_stops_idle() {
    let mut h = Harness::new(default_script());
    h.brain.set_owner(std::sync::Arc::new(|| OwnerState::Alive));
    h.connect();
    h.say("user_local", "hello");
    h.settle_posts();
    h.brain.on_timer();
    assert!(h.brain.fatal().is_none(), "{:?}", h.brain.fatal());
}

#[test]
fn a_chief_no_app_named_never_stops_idle() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "hello");
    h.settle_posts();
    h.brain.step(Input::OwnerChanged);
    assert!(h.brain.fatal().is_none(), "{:?}", h.brain.fatal());
}

/// The app quits (its process is gone and no newer app took the host over):
/// the owner level says gone, and its kernel watch reports the change.
fn app_quits(h: &mut Harness) {
    h.brain.set_owner(std::sync::Arc::new(|| OwnerState::Gone));
    h.brain.step(Input::OwnerChanged);
}

// cp/redesign-quit-helpers (principled audit, R5): on the base an idle host
// whose conversation link was down waited LINK_WAIT (30 s) after its app
// quit, a hold limit that decided what is delivered. Nothing is lost by
// stopping: the person's messages stay in the owner daemon and the brain's
// outbox is saved with its state, so the next host reads and sends them.
// "Down" is what the link reports: it could not connect (the review of the
// redesign made "not read since start" live work, ended by Up or Down).
#[test]
fn owner_level_an_idle_chief_whose_link_is_down_stops_when_its_app_quits() {
    let mut h = Harness::new(default_script());
    h.brain.step(Input::from(AgentEvent::Up(Vec::new())));
    h.brain.step(Input::from(DaemonEvent::Down));
    app_quits(&mut h);
    assert!(
        stopped_for_the_quit(&h),
        "an idle Chief with no live owner and no work still runs: {:?}, held by {:?}",
        h.brain.fatal(),
        h.brain.owner_exit_held_by()
    );
}

// A host that starts after the quit (the Chief owner wakes another Chief
// for a message while Keep Sessions keeps the default Chief working) reads
// the message that woke it and answers it before it stops; it does not stop
// before its link is up (review of cp/redesign-quit-helpers, finding 1).
#[test]
fn owner_level_a_chief_started_after_the_quit_reads_the_message_that_woke_it() {
    let mut h = Harness::new(default_script());
    h.brain.step(Input::from(AgentEvent::Up(Vec::new())));
    // Its app is gone before its link is up.
    app_quits(&mut h);
    assert!(
        h.brain.fatal().is_none(),
        "the Chief stopped before it read its conversation: {:?}",
        h.brain.fatal()
    );
    // The message that woke it waits in the conversation.
    h.owner
        .lock()
        .unwrap()
        .messages
        .push(message(1, "user_local", "the woken task"));
    h.connect();
    step_until_stopped(&mut h, Duration::from_secs(10));
    assert!(
        stopped_for_the_quit(&h),
        "the Chief did not stop after it answered: {:?}, held by {:?}",
        h.brain.fatal(),
        h.brain.owner_exit_held_by()
    );
    let sends = h.owner.lock().unwrap().sends();
    assert!(
        sends.iter().any(|(_, t)| t.contains("answer 0")),
        "the message that woke the Chief was not answered before it stopped: {sends:?}"
    );
}
