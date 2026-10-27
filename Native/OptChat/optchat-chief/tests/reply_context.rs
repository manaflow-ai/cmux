//! Reply context (2026-10-26): a person's thread reply in Home or iOS reaches
//! the Chief with one short first line naming the message it answers,
//! `(reply to #N: <quote>)`, or `(reply to #N)` right under its target. A
//! message that is no reply reads as it was written.

mod common;

use cmux_conversation::{Change, Message, PartRef};
use common::*;
use optchat_chief::daemon::DaemonEvent;
use optchat_chief::brain::Input;

/// Delivers every message the owner holds after seq `after` (the Chief's
/// posts too, as the subscription does); returns the newest seq.
fn deliver_from(h: &mut Harness, after: u64) -> u64 {
    let new: Vec<Message> = h
        .owner
        .lock()
        .unwrap()
        .messages
        .iter()
        .filter(|m| m.seq > after)
        .cloned()
        .collect();
    let newest = new.last().map_or(after, |m| m.seq);
    for message in new {
        h.brain.step(Input::from(DaemonEvent::Changed {
            conversation: CONV.into(),
            change: Change::Message { message },
        }));
    }
    newest
}

/// The person's message `text`, a thread reply to message `target`.
fn reply(h: &mut Harness, target: &str, text: &str) -> Message {
    let m = {
        let mut owner = h.owner.lock().unwrap();
        let seq = owner.messages.len() as u64 + 1;
        let mut m = message(seq, "user_local", text);
        m.thread_root = Some(target.into());
        m.reply_to = Some(PartRef {
            message_id: target.into(),
            part_index: 0,
        });
        owner.messages.push(m.clone());
        m
    };
    h.brain.step(Input::from(DaemonEvent::Changed {
        conversation: CONV.into(),
        change: Change::Message { message: m.clone() },
    }));
    m
}

/// The logged user texts, oldest first.
fn user_lines(h: &Harness) -> Vec<String> {
    h.log()
        .into_iter()
        .filter(|(kind, _)| kind == "user")
        .map(|(_, text)| text)
        .collect()
}

/// Every block of every prompt the agent saw, as JSON.
fn prompts(h: &Harness) -> String {
    serde_json::to_string(&h.agents.inner.lock().unwrap().prompts).unwrap()
}

#[test]
fn a_message_that_is_no_reply_reads_as_written() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "Ship the tagged build?");
    h.settle_posts();
    assert_eq!(user_lines(&h), vec!["Ship the tagged build?".to_owned()]);
    assert!(!prompts(&h).contains("(reply to"), "{}", prompts(&h));
}

#[test]
fn a_reply_to_an_older_message_quotes_it_in_one_short_line() {
    let mut h = Harness::new(default_script());
    h.connect();
    let first = h.say(
        "user_local",
        "Ship the tagged build of the reply marker change to the dogfood channel today, and post the PR link when it is up",
    );
    h.settle_posts();
    let seen = deliver_from(&mut h, first.seq);
    h.say("user_local", "also check CI");
    h.settle_posts();
    deliver_from(&mut h, seen);
    let r = reply(&mut h, &first.id, "yes, today");
    h.settle_posts();
    assert!(r.seq > first.seq + 1, "the target is not right above it");
    let quote: String = "Ship the tagged build of the reply marker change to the dogfood channel today, and post the PR link when it is up"
        .chars()
        .take(80)
        .collect();
    let want = format!("(reply to #{}: {quote}…)\nyes, today", first.seq);
    assert_eq!(user_lines(&h).last(), Some(&want), "{:?}", user_lines(&h));
    // The turn reads the same line (JSON escapes the newline).
    assert!(
        prompts(&h).contains(&format!("(reply to #{}: {quote}…)\\nyes, today", first.seq)),
        "{}",
        prompts(&h)
    );
}

#[test]
fn a_reply_right_under_its_target_names_it_without_a_quote() {
    let mut h = Harness::new(default_script());
    h.connect();
    let first = h.say("user_local", "Ship the tagged build?");
    h.settle_posts();
    // The Chief's answer is the newest message; the person replies to it.
    let newest = deliver_from(&mut h, first.seq);
    assert!(newest > first.seq, "the Chief answered");
    let chief = format!("msg_{newest}");
    reply(&mut h, &chief, "thanks");
    h.settle_posts();
    assert_eq!(
        user_lines(&h).last().map(String::as_str),
        Some(format!("(reply to #{newest})\nthanks").as_str()),
        "{:?}",
        user_lines(&h)
    );
}

#[test]
fn a_reply_whose_target_was_handled_before_a_restart_still_quotes_it() {
    let mut h = Harness::new(default_script());
    {
        // Messages 1 and 2 were read before this host started.
        let mut owner = h.owner.lock().unwrap();
        owner
            .messages
            .push(message(1, "user_local", "Rename the dashboard tab"));
        owner.messages.push(message(2, "agent_mux", "Renamed."));
        let summary = owner.summary.as_mut().unwrap();
        summary.last_seq = 2;
        summary.read_cursors.insert("agent_mux".into(), 2);
    }
    h.connect();
    reply(&mut h, "msg_1", "make it shorter");
    h.settle_posts();
    assert_eq!(
        user_lines(&h),
        vec!["(reply to #1: Rename the dashboard tab)\nmake it shorter".to_owned()]
    );
}

#[test]
fn a_reply_to_a_message_out_of_reach_says_so_briefly() {
    let mut h = Harness::new(default_script());
    h.connect();
    reply(&mut h, "msg_gone", "and this");
    h.settle_posts();
    assert_eq!(
        user_lines(&h),
        vec!["(reply to an earlier message)\nand this".to_owned()]
    );
}
