//! Conformance case `delta-edit` (plans/cmux-next/optchat.md 5a.2) for
//! optchat-chief, through the brain and the fake owners: the user edits a
//! message that the turn's frozen view shows; the next turn's input carries
//! an entry after `</chat>` that names that line (`<id>|edit of <target>:
//! <new text>`), and a scripted model that quotes what it reads quotes the
//! edited text, not the old one.

mod common;

use cmux_conversation::{Change, Part};
use common::*;
use optchat_chief::brain::Input;
use optchat_chief::daemon::DaemonEvent;
use optchat_core::Kind;
use serde_json::{Value, json};

const OLD: &str = "the build host is alpha-7";
const NEW: &str = "the build host is beta-9";

fn joined(blocks: &[Value]) -> String {
    blocks
        .iter()
        .map(|b| b["text"].as_str().unwrap_or_default())
        .collect()
}

/// A model that answers with the newest statement of the build host it can
/// read: an edit entry's text, else a line that says it word for word.
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
                    .find(|l| l.contains("the build host is"))
                    .map(|l| l.to_owned())
            })
            .unwrap_or_else(|| "nothing".to_owned());
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": format!("quote: {quote}")}}),
            ),
            json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
        ]
    })
}

#[test]
fn delta_edit_the_next_turn_carries_the_edit_naming_the_line_and_the_model_quotes_it() {
    let mut h = Harness::new(quoting_script());
    h.connect();
    let first = h.say("user_local", OLD);
    h.settle_posts();
    // Enough log after it that the next turn renders a new view (the delta
    // is past DELTA_HARD), so the message is a line of the frozen view.
    for i in 0..600 {
        h.chat
            .append(
                Kind::Note,
                &format!("note {i:04}: the cache for project {i} lives in /srv/cache/{i} on b{i}"),
            )
            .unwrap();
    }
    assert!(h.chat.wait_idle(None, Some(WAIT)));
    h.say("user_local", "what is in the notes?");
    h.settle_posts();
    let target = h
        .log()
        .iter()
        .position(|(kind, text)| kind == "user" && text == OLD)
        .expect("the first message is logged") as u64;
    let second = h.agents.inner.lock().unwrap().prompts[1].clone();
    let view = joined(&second);
    let view = &view[..view.find("</chat>").expect("the view")];
    assert!(
        view.lines().any(|l| l
            .split_once('|')
            .and_then(|(id, _)| id.split_once('+'))
            .and_then(|(start, n)| Some((start.parse::<u64>().ok()?, n.parse::<u64>().ok()?)))
            .is_some_and(|(start, n)| start <= target && target < start + n)),
        "the second turn's view shows a line over message {target}"
    );

    // The user edits the first message.
    let mut edited = first.clone();
    edited.parts = vec![Part::Text {
        text: NEW.into(),
        runs: None,
    }];
    edited.edited_at = Some("2026-10-15T12:00:00Z".into());
    h.owner.lock().unwrap().messages[0] = edited.clone();
    h.brain.step(Input::from(DaemonEvent::Changed {
        conversation: CONV.into(),
        change: Change::MessageUpdated { message: edited },
    }));
    h.say("user_local", "where is the build host?");
    h.settle_posts();

    let third = joined(&h.agents.inner.lock().unwrap().prompts[2]);
    let after = &third[third.find("</chat>").expect("the view") + "</chat>".len()..];
    assert!(
        after
            .lines()
            .any(|l| l.ends_with(&format!("|edit of {target}: {NEW}"))),
        "the third turn's input names line {target} with the edit after </chat>: {after}"
    );
    let sends = h.owner.lock().unwrap().sends();
    let last = &sends.last().expect("a reply").1;
    assert!(
        last.contains(NEW),
        "the reply quotes the edited text: {last}"
    );
    assert!(
        !last.contains(OLD),
        "the reply does not quote the old text: {last}"
    );
}
