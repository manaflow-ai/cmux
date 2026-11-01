//! Owner turn actions run through the same serialized brain loop as Stop.
mod common;

use common::*;
use optchat_chief::brain::Input;
use serde_json::{Value, json};
use std::sync::mpsc::channel;

fn action(h: &mut Harness, retry: Option<&str>) -> Value {
    let (reply, answer) = channel();
    h.brain.step(match retry {
        Some(message) => Input::Retry {
            message: message.into(),
            reply,
        },
        None => Input::Continue { reply },
    });
    answer
        .try_recv()
        .expect("the owner action answers immediately")
}

fn prompts(h: &Harness) -> usize {
    h.agents.inner.lock().unwrap().prompts.len()
}

fn running() -> Harness {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    h.connect();
    h.say("user_local", "finish the migration");
    while prompts(&h) == 0 {
        h.step();
    }
    h
}

fn stop(h: &mut Harness) {
    let (reply, answer) = channel();
    h.brain.step(Input::Stop { reply });
    assert_eq!(answer.try_recv().unwrap()["stopped"], true);
    h.agents.hold(false);
    h.agents.release();
    h.settle();
    assert!(h.brain.awaiting_replies().is_empty());
    assert!(h.owner.lock().unwrap().sends().is_empty());
}

#[test]
fn stop_then_continue_reopens_the_messages_and_runs_one_turn() {
    let mut h = running();
    stop(&mut h);
    h.agents.hold(true);
    assert_eq!(action(&mut h, None)["continued"], true);
    assert_eq!(h.brain.awaiting_replies()[0].id, "msg_1");
    while prompts(&h) < 2 {
        h.step();
    }
    assert!(
        Value::Array(h.agents.inner.lock().unwrap().prompts[1].clone())
            .to_string()
            .contains("[continue]")
    );
    h.agents.hold(false);
    h.agents.release();
    h.settle();
    assert_eq!(prompts(&h), 2);
    assert!(h.brain.awaiting_replies().is_empty());
    assert_eq!(h.owner.lock().unwrap().sends().len(), 1);
    assert_eq!(action(&mut h, None), json!({"continued": false}));
}

#[test]
fn continue_without_a_stopped_turn_does_nothing() {
    let mut h = Harness::new(default_script());
    h.connect();
    assert_eq!(action(&mut h, None), json!({"continued": false}));
    assert_eq!(prompts(&h), 0);
    assert!(h.brain.is_idle());
}

#[test]
fn retry_reopens_and_answers_the_named_message() {
    let mut h = Harness::new(default_script());
    h.connect();
    let message = h.say("user_local", "explain the migration");
    h.settle();
    h.agents.hold(true);
    assert_eq!(action(&mut h, Some(&message.id))["retried"], true);
    assert_eq!(h.brain.awaiting_replies()[0].id, message.id);
    while prompts(&h) < 2 {
        h.step();
    }
    let prompt = Value::Array(h.agents.inner.lock().unwrap().prompts[1].clone()).to_string();
    assert!(
        prompt.contains("[retry]") && prompt.contains(&message.id),
        "{prompt}"
    );
    h.agents.hold(false);
    h.agents.release();
    h.settle();
    assert_eq!(prompts(&h), 2);
    assert_eq!(h.owner.lock().unwrap().sends().len(), 2);
    assert!(h.brain.awaiting_replies().is_empty());
}

#[test]
fn retry_while_busy_is_refused_without_starting_a_turn() {
    let mut h = running();
    assert_eq!(
        action(&mut h, Some("msg_1")),
        json!({"retried": false, "reason": "busy"})
    );
    assert_eq!(prompts(&h), 1);
    h.agents.hold(false);
    h.agents.release();
    h.settle();
    assert_eq!(prompts(&h), 1);
}
