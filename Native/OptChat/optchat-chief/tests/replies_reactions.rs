//! Replies and reactions (plans/cmux-next/chief-replies-reactions-DESIGN.md,
//! Lawrence 2026-10-20: "I send a message and I should reply to that specific
//! message"): a Chief reply goes into the thread of the message it answers
//! when it no longer sits right under it, and the Chief can react to a
//! message or reply in its thread with its `react` and `reply` tools.

mod common;

use std::sync::Arc;
use std::time::Duration;

use cmux_conversation::{Op, Part, PartRef, ReactionKind, Tapback};
use common::*;
use optchat_chief::brain::Input;
use optchat_chief::state::{SpawnRecord, SubRecord, SubStatus};
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;

fn spawner(h: &Harness) -> Arc<Spawner> {
    Arc::new(Spawner::new(
        h.chat.clone(),
        h.agents.clone(),
        SubagentSettings {
            harness: "claude".into(),
            policy: "approve-all".into(),
            model: None,
            effort: None,
            preset: Some("optchat-sub-h0me".into()),
            cwd: h.dir.path().join("subagent"),
            prefix: "optchat-sub-h0me".into(),
            parent: optchat_chief::brain::PARENT.into(),
            claude_md: None,
        },
        h.tx.clone(),
        Arc::new(|_: &str| {}),
    ))
}

/// Runs `f` on its own thread while the brain takes its inputs.
fn run<T: Send + 'static>(h: &mut Harness, f: impl FnOnce() -> T + Send + 'static) -> T {
    let worker = std::thread::spawn(f);
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    worker.join().unwrap()
}

/// The `message.send` ops whose text starts with `prefix`: (key, reply_to, thread_root).
fn sends_starting(h: &Harness, prefix: &str) -> Vec<(String, Option<PartRef>, Option<String>)> {
    h.owner
        .lock()
        .unwrap()
        .ops
        .iter()
        .filter_map(|(key, op)| match op {
            Op::MessageSend {
                parts,
                reply_to,
                thread_root,
                ..
            } => match parts.first() {
                Some(Part::Text { text, .. }) if text.starts_with(prefix) => {
                    Some((key.clone(), reply_to.clone(), thread_root.clone()))
                }
                _ => None,
            },
            _ => None,
        })
        .collect()
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

fn finish(h: &mut Harness) {
    h.agents.hold(false);
    h.agents.release();
    h.settle_posts();
}

/// The view line id of conversation message `seq`.
fn line_of(h: &Harness, seq: u64) -> u64 {
    h.chat
        .logged_id(&format!("{CONV}#{seq}"))
        .expect("the message is in the log")
}

#[test]
fn a_reply_right_under_its_message_stays_at_the_top_level() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "hi");
    h.settle_posts();
    let replies = sends_starting(&h, "answer");
    assert_eq!(replies.len(), 1, "{replies:?}");
    assert_eq!(replies[0].1, None, "no reply_to: {replies:?}");
    assert_eq!(replies[0].2, None, "no thread: {replies:?}");
}

#[test]
fn a_late_reply_goes_into_the_thread_of_the_message_it_answers() {
    let mut h = Harness::new(default_script());
    running(&mut h, "check the nightly");
    // Something else lands in the conversation while the turn works.
    h.brain.step(Input::Notice {
        key: "notice-1".into(),
        text: "a notice".into(),
    });
    finish(&mut h);
    let replies = sends_starting(&h, "answer");
    assert_eq!(replies.len(), 1, "{replies:?}");
    assert_eq!(
        replies[0].2.as_deref(),
        Some("msg_1"),
        "threaded under the message it answers: {replies:?}"
    );
    assert_eq!(
        replies[0].1.as_ref().map(|r| r.message_id.as_str()),
        Some("msg_1"),
        "{replies:?}"
    );
}

#[test]
fn replies_thread_always_threads_even_a_reply_right_under_its_message() {
    let mut h = Harness::new(default_script());
    h.brain
        .set_setting("replies.thread", "always")
        .expect("replies.thread is a setting");
    h.connect();
    h.say("user_local", "hi");
    h.settle_posts();
    let replies = sends_starting(&h, "answer");
    assert_eq!(replies[0].2.as_deref(), Some("msg_1"), "{replies:?}");
}

#[test]
fn replies_thread_never_keeps_a_late_reply_at_the_top_level() {
    let mut h = Harness::new(default_script());
    h.brain
        .set_setting("replies.thread", "never")
        .expect("replies.thread is a setting");
    running(&mut h, "check the nightly");
    h.brain.step(Input::Notice {
        key: "notice-1".into(),
        text: "a notice".into(),
    });
    finish(&mut h);
    let replies = sends_starting(&h, "answer");
    assert_eq!(replies[0].2, None, "{replies:?}");
}

#[test]
fn a_reply_to_a_message_inside_a_thread_goes_into_that_thread() {
    let mut h = Harness::new(default_script());
    h.brain
        .set_setting("replies.thread", "always")
        .expect("replies.thread is a setting");
    h.connect();
    h.say("user_local", "root");
    h.settle_posts();
    // The user answers in the thread of msg_1.
    let m = {
        let mut owner = h.owner.lock().unwrap();
        let seq = owner.messages.len() as u64 + 1;
        let mut m = message(seq, "user_local", "and this too");
        m.thread_root = Some("msg_1".into());
        m.reply_to = Some(PartRef {
            message_id: "msg_1".into(),
            part_index: 0,
        });
        owner.messages.push(m.clone());
        m
    };
    h.brain
        .step(Input::from(optchat_chief::daemon::DaemonEvent::Changed {
            conversation: CONV.into(),
            change: cmux_conversation::Change::Message { message: m.clone() },
        }));
    h.settle_posts();
    let replies = sends_starting(&h, "answer");
    let last = replies.last().unwrap();
    assert_eq!(
        last.2.as_deref(),
        Some("msg_1"),
        "the thread's root: {replies:?}"
    );
    assert_eq!(
        last.1.as_ref().map(|r| r.message_id.clone()),
        Some(m.id),
        "the parent is the message it answers: {replies:?}"
    );
}

#[test]
fn a_thread_the_owner_refuses_falls_back_to_the_top_level() {
    let mut h = Harness::new(default_script());
    h.brain
        .set_setting("replies.thread", "always")
        .expect("replies.thread is a setting");
    h.owner
        .lock()
        .unwrap()
        .rejects
        .push_back(Some("invalid_thread_root".into()));
    h.connect();
    h.say("user_local", "hi");
    h.settle_posts();
    let replies = sends_starting(&h, "answer");
    assert_eq!(replies.len(), 2, "refused once, then sent: {replies:?}");
    assert!(replies[1].0.ends_with(":top"), "{replies:?}");
    assert_eq!(replies[1].1, None, "{replies:?}");
    assert_eq!(replies[1].2, None, "{replies:?}");
}

#[test]
fn react_puts_a_tapback_on_the_named_message_and_ack_is_a_like() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "thanks");
    h.settle_posts();
    let line = line_of(&h, 1);
    let sp = spawner(&h);
    let answer = run(&mut h, move || sp.react(line, "ack")).expect("react answers");
    assert!(answer.starts_with("outcome: done"), "{answer}");
    let reactions: Vec<(String, ReactionKind)> = h
        .owner
        .lock()
        .unwrap()
        .ops
        .iter()
        .filter_map(|(_, op)| match op {
            Op::ReactionAdd {
                message_id,
                reaction,
                ..
            } => Some((message_id.clone(), reaction.clone())),
            _ => None,
        })
        .collect();
    assert_eq!(
        reactions,
        vec![("msg_1".to_owned(), ReactionKind::Tapback(Tapback::Like))]
    );
    // Again: a noop, not a second op.
    let sp = spawner(&h);
    let again = run(&mut h, move || sp.react(line, "like")).expect("react answers");
    assert!(again.starts_with("outcome: noop"), "{again}");
}

#[test]
fn react_refuses_a_line_that_is_not_a_conversation_message() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "hi");
    h.settle_posts();
    // The last line is the turn's own (its reply or tool lines), not a user message.
    let last = h.chat.status().messages - 1;
    let sp = spawner(&h);
    let refused = run(&mut h, move || sp.react(last, "love"));
    assert!(refused.is_err(), "{refused:?}");
    let sp = spawner(&h);
    let unknown = run(&mut h, move || sp.react(0, "wink"));
    assert!(unknown.unwrap_err().contains("no reaction"));
}

#[test]
fn reply_posts_now_in_the_thread_of_the_named_message() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "two asks: the build and the docs");
    h.settle_posts();
    let line = line_of(&h, 1);
    let sp = spawner(&h);
    let answer = run(&mut h, move || sp.reply(line, "The build is green.")).expect("reply answers");
    assert!(answer.starts_with("outcome: done"), "{answer}");
    h.settle_posts();
    let replies = sends_starting(&h, "The build is green.");
    assert_eq!(replies.len(), 1, "{replies:?}");
    assert_eq!(replies[0].2.as_deref(), Some("msg_1"), "{replies:?}");
    assert_eq!(
        replies[0].1.as_ref().map(|r| r.message_id.as_str()),
        Some("msg_1")
    );
}

#[test]
fn no_reply_posts_nothing_in_the_chief_dm() {
    let mut h = Harness::new(Box::new(|_, _| {
        vec![
            serde_json::json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "agent_message_chunk",
                serde_json::json!({"content": {"type": "text", "text": "NO_REPLY"}}),
            ),
            serde_json::json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
        ]
    }));
    h.connect();
    h.say("user_local", "ok thanks");
    h.settle_posts();
    assert!(sends_starting(&h, "NO_REPLY").is_empty(), "nothing posted");
}

#[test]
fn a_subagent_works_for_the_message_its_tell_was_for() {
    let record = SpawnRecord {
        answers: vec!["msg_1".into()],
        subs: vec![
            SubRecord {
                id: "a1".into(),
                status: SubStatus::Running,
                ..SubRecord::default()
            },
            SubRecord {
                id: "a2".into(),
                status: SubStatus::Running,
                answers: vec!["msg_5".into()],
                ..SubRecord::default()
            },
        ],
        ..SpawnRecord::default()
    };
    assert!(
        record.working_for("msg_1"),
        "a1 still works for the spawn's message"
    );
    assert!(record.working_for("msg_5"), "a2 was told for msg_5");
    let mut done = record.clone();
    done.subs[0].status = SubStatus::Reported;
    assert!(!done.working_for("msg_1"), "a2 works for msg_5, not msg_1");
}

/// The user (2026-10-20): Chief reacts with 👍 ❤️ 😂 ‼️ ❓ "and any emoji". The iMessage tapback
/// emoji map to their tapbacks; any other single emoji is an emoji reaction.
#[test]
fn react_takes_tapback_emoji_and_any_other_emoji() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "shipped it");
    h.settle_posts();
    let line = line_of(&h, 1);
    for reaction in ["😂", "‼️", "❓", "🔥"] {
        let sp = spawner(&h);
        let answer = run(&mut h, move || sp.react(line, reaction)).expect("react answers");
        assert!(answer.starts_with("outcome: done"), "{reaction}: {answer}");
    }
    let reactions: Vec<ReactionKind> = h
        .owner
        .lock()
        .unwrap()
        .ops
        .iter()
        .filter_map(|(_, op)| match op {
            Op::ReactionAdd { reaction, .. } => Some(reaction.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(
        reactions,
        vec![
            ReactionKind::Tapback(Tapback::Laugh),
            ReactionKind::Tapback(Tapback::Emphasize),
            ReactionKind::Tapback(Tapback::Question),
            ReactionKind::Emoji("🔥".to_owned()),
        ]
    );
    // The same emoji again is a noop; words that are no reaction stay refused.
    let sp = spawner(&h);
    let again = run(&mut h, move || sp.react(line, "🔥")).expect("react answers");
    assert!(again.starts_with("outcome: noop"), "{again}");
    let sp = spawner(&h);
    assert!(
        run(&mut h, move || sp.react(line, "wink"))
            .unwrap_err()
            .contains("no reaction")
    );
    let sp = spawner(&h);
    assert!(
        run(&mut h, move || sp.react(line, "🔥 🔥"))
            .unwrap_err()
            .contains("no reaction")
    );
}

/// The user's own tapback on a Chief reply (Lawrence 2026-10-21, "chief
/// needs to be able to send reactions"; a416): the update reaches the Chief,
/// as a note that says who reacted, with what, to which reply, and the next
/// turn reads it. A replayed update logs it once; the Chief's own reaction
/// and a removed one log nothing.
#[test]
fn a_user_tapback_on_a_chief_reply_reaches_the_next_turn() {
    use cmux_conversation::{Change, Reaction};
    use optchat_chief::daemon::DaemonEvent;
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "hi");
    h.settle_posts();
    let mut reply = h
        .owner
        .lock()
        .unwrap()
        .messages
        .iter()
        .find(|m| m.author == "agent_mux")
        .cloned()
        .expect("the Chief replied");
    let reply_text = match &reply.parts[0] {
        Part::Text { text, .. } => text.clone(),
        _ => panic!("a text reply"),
    };
    let react = |reply: &mut cmux_conversation::Message, author: &str, kind: ReactionKind| {
        reply.reactions.push(Reaction {
            author: author.into(),
            part_index: 0,
            kind,
            at: "2026-10-21T18:00:00Z".into(),
        });
    };
    react(
        &mut reply,
        "user_local",
        ReactionKind::Tapback(Tapback::Love),
    );
    react(
        &mut reply,
        "agent_mux",
        ReactionKind::Tapback(Tapback::Like),
    );
    react(&mut reply, "user_local", ReactionKind::Emoji("🔥".into()));
    for _ in 0..2 {
        h.brain.step(Input::from(DaemonEvent::Changed {
            conversation: CONV.into(),
            change: Change::MessageUpdated {
                message: reply.clone(),
            },
        }));
    }
    let notes: Vec<String> = h
        .log()
        .into_iter()
        .filter(|(kind, text)| kind == "note" && text.starts_with("reaction "))
        .map(|(_, text)| text)
        .collect();
    let quoted = reply_text.lines().next().unwrap_or_default().to_owned();
    let who = h
        .owner
        .lock()
        .unwrap()
        .summary
        .as_ref()
        .and_then(|s| s.participants.iter().find(|p| p.id == "user_local"))
        .map(|p| p.display_name.clone())
        .filter(|n| !n.is_empty())
        .unwrap_or_else(|| "user_local".into());
    assert_eq!(
        notes,
        vec![
            format!("reaction ❤️ love from {who} on your message: {quoted}"),
            format!("reaction 🔥 from {who} on your message: {quoted}"),
        ],
        "one note per user reaction, none for the Chief's own"
    );
    h.say("user_local", "next");
    h.settle_posts();
    let prompts = h.agents.inner.lock().unwrap().prompts.clone();
    let next: String = prompts
        .last()
        .expect("a second turn")
        .iter()
        .map(|b| b["text"].as_str().unwrap_or_default())
        .collect();
    assert!(
        next.contains(&format!("reaction ❤️ love from {who} on your message")),
        "the next turn reads the tapback: {next}"
    );
}
