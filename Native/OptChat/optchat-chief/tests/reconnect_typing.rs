//! E21 (.cmux-scratch/chief-errors/catalog.md): typing is the session
//! daemon's ephemeral state, so a daemon that restarts while a turn runs
//! has forgotten it. The brain says typing again when it binds to the new
//! daemon; else a `cmux chief -p` on the new daemon never sees the turn
//! start and never exits.

mod common;

use common::*;
use optchat_chief::brain::Input;
use optchat_chief::daemon::DaemonEvent;

fn reconnect(h: &mut Harness) {
    h.brain.step(Input::from(DaemonEvent::Down));
    let owner = h.owner.clone();
    let summary = owner.lock().unwrap().summary.clone().unwrap();
    h.brain.step(Input::from(DaemonEvent::Up {
        port: Box::new(FakeDaemon(owner)),
        conversation: summary,
        reconnect: Box::new(|| {}),
    }));
}

#[test]
fn a_daemon_restart_during_a_turn_says_typing_again() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    h.connect();
    h.say("user_local", "first");
    h.step();
    h.agents.wait_prompts(1);
    assert_eq!(h.owner.lock().unwrap().typing, vec![true]);
    reconnect(&mut h);
    assert_eq!(
        h.owner.lock().unwrap().typing,
        vec![true, true],
        "the new daemon hears that the Chief is typing"
    );
    h.agents.release();
    h.settle();
    assert_eq!(h.owner.lock().unwrap().typing, vec![true, true, false]);
}

#[test]
fn a_daemon_restart_while_idle_says_nothing() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "first");
    h.settle();
    assert_eq!(h.owner.lock().unwrap().typing, vec![true, false]);
    reconnect(&mut h);
    assert_eq!(h.owner.lock().unwrap().typing, vec![true, false]);
}
