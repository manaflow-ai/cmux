//! An edit redoes the conversation from the edited message (Codex parity,
//! Lawrence 2026-10-19: "You can now edit previous messages within a thread
//! in the desktop app [Codex]... make sure to implement this for us too"):
//! the user edits the message the Chief answered last, so the Chief's reply
//! after it is retracted from the chat and a new turn answers the edited
//! text. An edit of a message someone wrote after is only its `edit of`
//! note (delta_edit.rs), and a replayed update redoes nothing again.

mod common;

use cmux_conversation::{Change, Message, Op, Part};
use common::*;
use optchat_chief::brain::Input;
use optchat_chief::daemon::DaemonEvent;
use serde_json::{Value, json};

const OLD: &str = "deploy to alpha-7";
const NEW: &str = "deploy to beta-9";

fn joined(blocks: &[Value]) -> String {
    blocks
        .iter()
        .map(|b| b["text"].as_str().unwrap_or_default())
        .collect()
}

/// A model that answers with the newest target it can read: an edit
/// entry's text, else the newest line that names one.
fn quoting_script() -> Script {
    Box::new(|_, blocks| {
        let text = joined(blocks);
        let quote = text
            .lines()
            .filter_map(|l| l.split_once("|edit of ").map(|(_, rest)| rest))
            .filter_map(|rest| rest.split_once(": ").map(|(_, t)| t.to_owned()))
            .next_back()
            .or_else(|| {
                text.lines()
                    .rfind(|l| l.contains("deploy to"))
                    .map(|l| l.to_owned())
            })
            .unwrap_or_else(|| "nothing".to_owned());
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": format!("on it: {quote}")}}),
            ),
            json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
        ]
    })
}

fn edit(h: &mut Harness, original: &Message, text: &str, at: &str) {
    let mut edited = original.clone();
    edited.parts = vec![Part::Text {
        text: text.into(),
        runs: None,
    }];
    edited.edited_at = Some(at.into());
    let i = h
        .owner
        .lock()
        .unwrap()
        .messages
        .iter()
        .position(|m| m.id == original.id)
        .unwrap();
    h.owner.lock().unwrap().messages[i] = edited.clone();
    h.brain.step(Input::from(DaemonEvent::Changed {
        conversation: CONV.into(),
        change: Change::MessageUpdated { message: edited },
    }));
}

fn retracts(h: &Harness) -> Vec<String> {
    h.owner
        .lock()
        .unwrap()
        .ops
        .iter()
        .filter_map(|(_, op)| match op {
            Op::MessageRetract { message_id } => Some(message_id.clone()),
            _ => None,
        })
        .collect()
}

#[test]
fn editing_the_last_answered_message_retracts_the_reply_and_answers_the_edit() {
    let mut h = Harness::new(quoting_script());
    h.connect();
    let first = h.say("user_local", OLD);
    h.settle_posts();
    let reply = h
        .owner
        .lock()
        .unwrap()
        .messages
        .iter()
        .find(|m| m.author == "agent_mux")
        .map(|m| m.id.clone())
        .expect("the Chief answered");
    assert_eq!(h.agents.inner.lock().unwrap().prompts.len(), 1);

    edit(&mut h, &first, NEW, "2026-10-19T12:00:00Z");
    h.settle_posts();

    assert_eq!(retracts(&h), vec![reply.clone()], "the reply after the edited message leaves the chat");
    assert_eq!(
        h.agents.inner.lock().unwrap().prompts.len(),
        2,
        "a turn answers the edit"
    );
    let sends = h.owner.lock().unwrap().sends();
    let last = &sends.last().expect("a reply").1;
    assert!(last.contains(NEW), "the new reply answers the edited text: {last}");

    // The same update again (a replay after a reconnect) redoes nothing.
    let mut again = first.clone();
    again.parts = vec![Part::Text {
        text: NEW.into(),
        runs: None,
    }];
    again.edited_at = Some("2026-10-19T12:00:00Z".into());
    h.brain.step(Input::from(DaemonEvent::Changed {
        conversation: CONV.into(),
        change: Change::MessageUpdated { message: again },
    }));
    h.settle_posts();
    assert_eq!(retracts(&h).len(), 1);
    assert_eq!(h.agents.inner.lock().unwrap().prompts.len(), 2);
}

#[test]
fn editing_a_message_someone_wrote_after_only_notes_the_edit() {
    let mut h = Harness::new(quoting_script());
    h.connect();
    let first = h.say("user_local", OLD);
    h.settle_posts();
    h.say("user_local", "and tell me when it is done");
    h.settle_posts();
    let turns = h.agents.inner.lock().unwrap().prompts.len();

    edit(&mut h, &first, NEW, "2026-10-19T12:00:00Z");
    h.settle_posts();

    assert!(retracts(&h).is_empty(), "nothing leaves the chat");
    assert_eq!(h.agents.inner.lock().unwrap().prompts.len(), turns, "no turn starts");
}
