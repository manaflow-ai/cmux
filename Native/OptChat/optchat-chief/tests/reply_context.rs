//! A person's thread reply reaches the Chief with its target (user
//! 2026-10-26: "the Chief's prompt shows only the plain text; the reply
//! target is lost"). The logged user line, which the turn's prompt and the
//! compactor read, starts with one short marker line: `(reply to #<line>:
//! <quote>)`, only `(reply to #<line>)` when the target is the message right
//! before it, and nothing for a message that is not a reply.

mod common;

use cmux_conversation::{Change, Message, PartRef};
use common::*;
use optchat_chief::brain::Input;
use optchat_chief::daemon::DaemonEvent;

/// A message of the person that replies to `parent` in `root`'s thread, as
/// Home sends it (`reply_to` the parent, `thread_root` the root).
fn reply(h: &mut Harness, text: &str, parent: &str, root: &str) -> Message {
    let mut m = message(
        h.owner.lock().unwrap().messages.len() as u64 + 1,
        "user_local",
        text,
    );
    m.reply_to = Some(PartRef {
        message_id: parent.into(),
        part_index: 0,
    });
    m.thread_root = Some(root.into());
    h.owner.lock().unwrap().messages.push(m.clone());
    h.brain.step(Input::from(DaemonEvent::Changed {
        conversation: CONV.into(),
        change: Change::Message { message: m.clone() },
    }));
    m
}

/// The logged user line of conversation message `seq`.
fn user_line(h: &Harness, seq: u64) -> String {
    let id = h
        .chat
        .logged_id(&format!("{CONV}#{seq}"))
        .expect("the message is in the log");
    let (kind, text) = h.chat.message(id).unwrap();
    assert_eq!(kind.as_str(), "user");
    text
}

/// Every prompt the turns got, as one string.
fn prompts(h: &Harness) -> String {
    serde_json::to_string(&h.agents.inner.lock().unwrap().prompts).unwrap()
}

/// The newest message the Chief posted.
fn last_chief(h: &Harness) -> Message {
    h.owner
        .lock()
        .unwrap()
        .messages
        .iter()
        .rev()
        .find(|m| m.author == "agent_mux")
        .cloned()
        .expect("the Chief replied")
}

#[test]
fn a_reply_to_an_earlier_message_names_its_line_and_a_short_quote() {
    let mut h = Harness::new(default_script());
    h.connect();
    let long = "Please check why the nightly build for the iOS app failed on the AWS Mac yesterday and fix the signing step";
    let first = h.say("user_local", long);
    h.settle_posts();
    let plain = h.say("user_local", "and the web dashboard?");
    h.settle_posts();
    // A plain message gets no marker.
    assert_eq!(user_line(&h, plain.seq), "and the web dashboard?");

    let r = reply(&mut h, "any news on this one?", &first.id, &first.id);
    h.settle_posts();
    let first_line = h.chat.logged_id(&format!("{CONV}#{}", first.seq)).unwrap();
    let quote: String = long.chars().take(80).collect();
    let expected = format!(
        "(reply to #{first_line}: {}…)\nany news on this one?",
        quote.trim_end()
    );
    assert_eq!(user_line(&h, r.seq), expected);
    // The marker is one line: never the whole target message.
    assert!(!user_line(&h, r.seq).contains("signing step"));
    // The turn's prompt carries it (newlines as in the log entry).
    assert!(
        prompts(&h).contains(&format!("(reply to #{first_line}: ")),
        "{}",
        prompts(&h)
    );
}

#[test]
fn a_reply_to_the_message_right_before_it_has_no_quote() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "deploy the staging web app");
    h.settle_posts();
    // The person replies to the Chief's answer right above: no line of its
    // own in the log (the Chief's words are its talk lines), no quote.
    let answer = last_chief(&h);
    let r = reply(&mut h, "thanks, ship it", &answer.id, &answer.id);
    h.settle_posts();
    assert_eq!(
        user_line(&h, r.seq),
        "(reply to previous message)\nthanks, ship it"
    );
}

#[test]
fn a_reply_to_the_last_user_line_while_a_turn_runs_names_only_its_line() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    h.connect();
    let ask = h.say("user_local", "run the full iOS test suite please");
    while h.agents.inner.lock().unwrap().prompts.is_empty() {
        h.step();
    }
    let line = h.chat.logged_id(&format!("{CONV}#{}", ask.seq)).unwrap();
    let r = reply(&mut h, "only the UI tests", &ask.id, &ask.id);
    h.agents.hold(false);
    h.agents.release();
    h.settle_posts();
    assert_eq!(
        user_line(&h, r.seq),
        format!("(reply to #{line})\nonly the UI tests")
    );
}

#[test]
fn a_reply_to_an_earlier_chief_message_names_the_chief_and_a_quote() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "status?");
    h.settle_posts();
    let answer = last_chief(&h);
    h.say("user_local", "and the docs?");
    h.settle_posts();
    let r = reply(&mut h, "redo that", &answer.id, &answer.id);
    h.settle_posts();
    // The answer is short: its whole text on one line.
    let quote = cmux_chief::rules::message_text(&answer)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    assert!(quote.chars().count() <= 80);
    assert_eq!(
        user_line(&h, r.seq),
        format!("(reply to Chief: {quote})\nredo that")
    );
}

#[test]
fn a_reply_to_a_message_the_chief_never_logged_quotes_it() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "status?");
    h.settle_posts();
    // A bubble with no text, image or file does not wake the Chief: no line.
    let silent = h.say_parts("user_local", Vec::new());
    h.settle_posts();
    assert!(h.chat.logged_id(&format!("{CONV}#{}", silent.seq)).is_none());
    let r = reply(&mut h, "what was this?", &silent.id, &silent.id);
    h.settle_posts();
    let line = user_line(&h, r.seq);
    assert!(
        line.starts_with("(reply to ") && line.contains(": [no text])\n"),
        "{line}"
    );
}
