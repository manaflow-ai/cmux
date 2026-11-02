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
    assert_eq!(
        action(&mut h, None)["continued"],
        false,
        "a repeated click cannot start another turn"
    );
    assert!(
        Value::Array(h.agents.inner.lock().unwrap().prompts[1].clone())
            .to_string()
            .contains("[continue]")
    );
    h.agents.hold(false);
    h.agents.release();
    h.settle_posts();
    assert_eq!(prompts(&h), 2);
    assert!(h.brain.awaiting_replies().is_empty());
    assert_eq!(h.owner.lock().unwrap().sends().len(), 1);
    assert_eq!(action(&mut h, None), json!({"continued": false}));
}

#[test]
fn continue_restarts_a_stopped_turn_without_reply_obligations() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    h.connect();
    h.brain.step(Input::PeerChiefNote {
        text: "[chief:peer] Finish the ongoing migration.".into(),
    });
    while prompts(&h) == 0 {
        h.step();
    }
    assert!(h.brain.awaiting_replies().is_empty());
    stop(&mut h);
    assert_eq!(action(&mut h, None)["continued"], true);
    h.settle_posts();
    assert_eq!(prompts(&h), 2);
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
    h.settle_posts();
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

#[test]
fn retry_is_refused_while_the_next_turn_is_settling() {
    let mut h = Harness::new(default_script());
    h.connect();
    let message = h.say("user_local", "start this turn");
    assert_eq!(
        action(&mut h, Some(&message.id)),
        json!({"retried": false, "reason": "busy"})
    );
    h.settle_posts();
    assert_eq!(prompts(&h), 1);
}

#[test]
fn a_new_message_expires_continue() {
    let mut h = running();
    stop(&mut h);
    h.say("user_local", "do this instead");
    h.settle_posts();
    assert_eq!(action(&mut h, None), json!({"continued": false}));
    assert_eq!(prompts(&h), 2);
}

#[test]
fn retracting_the_stopped_message_removes_continue() {
    let mut h = running();
    stop(&mut h);
    let mut removed = h.owner.lock().unwrap().messages[0].clone();
    removed.retracted_at = Some("now".into());
    h.brain
        .step(Input::from(optchat_chief::daemon::DaemonEvent::Changed {
            conversation: CONV.into(),
            change: cmux_conversation::Change::MessageUpdated { message: removed },
        }));
    assert_eq!(action(&mut h, None), json!({"continued": false}));
    assert_eq!(prompts(&h), 1);
}

#[test]
fn retry_refuses_unknown_retracted_and_other_person_messages() {
    let mut h = Harness::new(default_script());
    h.connect();
    assert_eq!(action(&mut h, Some("missing"))["reason"], "invalid_message");
    let mut removed = message(1, "user_local", "removed");
    removed.retracted_at = Some("now".into());
    h.owner.lock().unwrap().messages.extend([
        removed,
        message(2, "agent_mux", "Chief reply"),
        message(3, "other_person", "someone else's request"),
    ]);
    for id in ["msg_1", "msg_2", "msg_3"] {
        assert_eq!(
            action(&mut h, Some(id))["reason"],
            "invalid_message",
            "{id}"
        );
    }
    assert_eq!(prompts(&h), 0);
}

#[test]
fn retry_uses_the_current_message_text_and_keeps_the_original_post() {
    let mut h = Harness::new(default_script());
    h.connect();
    let message = h.say("user_local", "old request");
    h.settle_posts();
    h.owner.lock().unwrap().messages[0].parts = vec![cmux_conversation::Part::Text {
        text: "edited request".into(),
        runs: None,
    }];
    assert_eq!(action(&mut h, Some(&message.id))["retried"], true);
    h.settle_posts();
    let prompt = Value::Array(h.agents.inner.lock().unwrap().prompts[1].clone()).to_string();
    assert!(
        prompt.contains("current contents:") && prompt.contains("edited request"),
        "{prompt}"
    );
    assert_eq!(h.owner.lock().unwrap().sends().len(), 2);
}

#[test]
fn continue_retains_the_stopped_turns_approval_floor() {
    let dir = tempfile::tempdir().unwrap();
    let mut settings = settings(dir.path());
    settings.membership.owner = "another_owner".into();
    let owner = std::sync::Arc::new(std::sync::Mutex::new(Owner {
        summary: Some(summary()),
        ..Owner::default()
    }));
    let mut h = Harness::configured(
        dir,
        default_script(),
        owner,
        settings,
        std::sync::Arc::new(|_| {}),
    );
    h.agents.hold(true);
    h.connect();
    h.say("user_local", "finish the migration");
    while prompts(&h) == 0 {
        h.step();
    }
    assert_eq!(h.agents.inner.lock().unwrap().specs[0].policy, "ask");
    stop(&mut h);
    let state = h.brain.state().clone();
    assert!(state.stopped_reply.as_ref().unwrap().requires_approval);
    let dir = tempfile::tempdir().unwrap();
    optchat_chief::state::StateFile::new(&dir.path().join("host.json"))
        .save(&state)
        .unwrap();
    let owner = h.owner.clone();
    let mut resumed = Harness::in_dir(dir, default_script(), owner);
    resumed.connect();
    assert_eq!(action(&mut resumed, None)["continued"], true);
    resumed.settle_posts();
    let inner = resumed.agents.inner.lock().unwrap();
    assert_eq!(inner.specs.last().unwrap().policy, "ask");
}
