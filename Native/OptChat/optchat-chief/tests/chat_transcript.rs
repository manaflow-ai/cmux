//! The Chief sees the chat as the person does (a455, Lawrence 2026-10-21: "are
//! you able to self reflect and see what i can see on the chat? ... like the
//! optchat-2e448bc2-9041 we need to fix"). The Chief's view is its own log;
//! messages the host posts as the Chief (a turn's done marker, the front
//! desk's receipt, notices) never reach it. The `transcript` tool reads the
//! conversation as the daemon stores it, with every author and a flag on
//! each message no Chief tool call wrote, and a message posted as the Chief
//! that the Chief did not write is logged as a note for its next turn.

mod common;

use std::sync::mpsc::channel;

use cmux_conversation::{Change, Part, PartRef, Reaction, ReactionKind, Tapback, WorkStatus};
use common::*;
use optchat_chief::brain::Input;
use optchat_chief::daemon::DaemonEvent;

/// Puts `m` in the fake owner's store and delivers it as the subscription does.
fn deliver(h: &mut Harness, m: cmux_conversation::Message) {
    h.owner.lock().unwrap().messages.push(m.clone());
    h.brain.step(Input::from(DaemonEvent::Changed {
        conversation: CONV.into(),
        change: Change::Message { message: m },
    }));
}

/// The next message's seq in the fake owner's store.
fn next_seq(h: &Harness) -> u64 {
    h.owner.lock().unwrap().messages.len() as u64 + 1
}

/// A message posted as the Chief (`agent_mux`) under `key`.
fn as_chief(h: &Harness, key: &str, parts: Vec<Part>) -> cmux_conversation::Message {
    let mut m = message(next_seq(h), "agent_mux", "");
    m.client_msg_id = key.into();
    m.parts = parts;
    m
}

fn text(t: &str) -> Part {
    Part::Text {
        text: t.into(),
        runs: None,
    }
}

/// The `transcript` tool's answer for the last `n` messages.
fn transcript(h: &mut Harness, n: u32, before: Option<u64>) -> String {
    let (reply, answer) = channel();
    h.brain.step(Input::Transcript { n, before, reply });
    answer.recv().unwrap().expect("transcript answers")
}

fn notes(h: &Harness) -> Vec<String> {
    h.log()
        .into_iter()
        .filter(|(kind, _)| kind == "note")
        .map(|(_, text)| text)
        .collect()
}

#[test]
fn transcript_shows_every_author_and_flags_what_no_chief_tool_wrote() {
    let mut h = Harness::new(default_script());
    h.connect();
    let user = h.say("user_local", "check the nightly");
    h.settle_posts();
    // A user message with a picture, which the Chief reacted to.
    let mut shot = message(next_seq(&h), "user_local", "do you see this:");
    shot.parts.push(Part::Attachment {
        hash: "cff31db35b7d06ff3bd04a86e0e43ed35eec127e8753a7756204a1326da57ea6".into(),
        name: "Screenshot 2026-10-21 at 9.22.20 PM.png".into(),
        mime_type: "image/png".into(),
        byte_count: 1_386_076,
        width: Some(1092),
        height: Some(2014),
        duration_ms: None,
        poster: None,
        preview: None,
    });
    shot.reactions.push(Reaction {
        author: "agent_mux".into(),
        part_index: 0,
        kind: ReactionKind::Tapback(Tapback::Like),
        at: "2026-10-22T04:22:40.000Z".into(),
    });
    deliver(&mut h, shot);
    // The 9041 bubble, as the daemon stored it: a turn's done marker, one
    // work part naming the turn's session, in the thread of the message it
    // closes.
    let mut marker = as_chief(
        &h,
        "turn:optchat:9041:202610212119084400700",
        vec![Part::Work {
            session: "optchat-2e448bc2-9041".into(),
            host: None,
            status: WorkStatus::Done,
            preview: None,
        }],
    );
    marker.reply_to = Some(PartRef {
        message_id: user.id.clone(),
        part_index: 0,
    });
    marker.thread_root = Some(user.id.clone());
    marker.answers = vec![user.id.clone()];
    let marker_seq = marker.seq;
    deliver(&mut h, marker);
    // The front desk's receipt and a send-tool message.
    let desk = as_chief(
        &h,
        "voice:desk:turn:optchat:9082:1:12",
        vec![text(
            "Got it. The Chief is busy with a turn and reads your message next.",
        )],
    );
    let desk_seq = desk.seq;
    deliver(&mut h, desk);
    let sent = as_chief(
        &h,
        "send-conv-turn-0123456789abcdef",
        vec![text("Here is the plan.")],
    );
    let sent_seq = sent.seq;
    deliver(&mut h, sent);

    let out = transcript(&mut h, 20, None);
    // Every message, by its seq, with its author.
    assert!(out.contains("check the nightly"), "{out}");
    assert!(out.contains("do you see this:"), "{out}");
    assert!(
        out.contains("Screenshot 2026-10-21 at 9.22.20 PM.png") && out.contains("1092x2014"),
        "the attachment with its name and size: {out}"
    );
    assert!(
        out.contains("👍 like by Chief"),
        "the reaction and its author: {out}"
    );
    // The marker: flagged as the host's, with its session, its thread and
    // a word that Home does not draw it.
    let marker_block = block(&out, marker_seq);
    assert!(
        marker_block.contains("optchat-2e448bc2-9041"),
        "{marker_block}"
    );
    assert!(marker_block.contains("host: done marker"), "{marker_block}");
    assert!(marker_block.contains("hidden"), "{marker_block}");
    assert!(
        marker_block.contains(&format!("thread of #{}", user.seq)),
        "{marker_block}"
    );
    assert!(block(&out, desk_seq).contains("host: front desk"), "{out}");
    let sent_block = block(&out, sent_seq);
    assert!(sent_block.contains("you: send"), "{sent_block}");
    assert!(!sent_block.contains("host:"), "{sent_block}");
    // `before` pages back: only messages older than it.
    let older = transcript(&mut h, 20, Some(marker_seq));
    assert!(older.contains("do you see this:"), "{older}");
    assert!(!older.contains("optchat-2e448bc2-9041"), "{older}");
}

/// The lines of `out` for message `seq`: its header to the next header.
fn block(out: &str, seq: u64) -> String {
    let head = format!("#{seq} ");
    let mut lines = out.lines().skip_while(|l| !l.starts_with(&head));
    let mut block: Vec<&str> = lines.next().into_iter().collect();
    block.extend(lines.take_while(|l| !l.starts_with('#')));
    block.join("\n")
}

#[test]
fn a_bubble_posted_as_the_chief_that_no_chief_tool_wrote_is_a_note_for_its_next_turn() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "hi");
    h.settle_posts();
    // A bubble that reads as the Chief's, from no Chief tool call.
    let leak = as_chief(&h, "c-unknown", vec![text("optchat-2e448bc2-9041")]);
    let leak_seq = leak.seq;
    deliver(&mut h, leak.clone());
    // Replayed: noted once.
    h.brain.step(Input::from(DaemonEvent::Changed {
        conversation: CONV.into(),
        change: Change::Message { message: leak },
    }));
    // The Chief's own words and a hidden done marker are no note.
    let mine = as_chief(&h, "send-conv-turn-00000000000000aa", vec![text("mine")]);
    deliver(&mut h, mine);
    let marker = as_chief(
        &h,
        "turn:optchat:4:20261021",
        vec![Part::Work {
            session: "optchat-h0me-4".into(),
            host: None,
            status: WorkStatus::Done,
            preview: None,
        }],
    );
    deliver(&mut h, marker);
    let posted: Vec<String> = notes(&h)
        .into_iter()
        .filter(|n| n.starts_with("posted as you"))
        .collect();
    assert_eq!(posted.len(), 1, "{posted:?}");
    assert!(posted[0].contains("optchat-2e448bc2-9041"), "{posted:?}");
    assert!(posted[0].contains(&format!("#{leak_seq}")), "{posted:?}");
    // The next turn's prompt carries it.
    h.say("user_local", "next");
    h.settle_posts();
    let prompts = h.agents.inner.lock().unwrap().prompts.clone();
    let next: String = prompts
        .last()
        .expect("a second turn")
        .iter()
        .map(|b| b["text"].as_str().unwrap_or_default())
        .collect();
    assert!(next.contains("posted as you"), "{next}");
}

#[test]
fn the_chief_has_the_transcript_tool_and_a_subagent_does_not() {
    let names = |list: serde_json::Value| -> Vec<String> {
        list.as_array()
            .unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap().to_owned())
            .collect()
    };
    assert!(names(optchat_chief::mcp::tools_for(false)).contains(&"transcript".to_owned()));
    assert!(!names(optchat_chief::mcp::tools_for(true)).contains(&"transcript".to_owned()));
    assert_eq!(
        optchat_chief::tools::command("transcript", &["30"]),
        Ok(optchat_chief::tools::Command::Call(
            optchat_chief::tools::Call::Transcript {
                n: 30,
                before: None
            }
        ))
    );
}

#[test]
fn a_reply_logs_the_message_it_replies_to_when_the_log_has_no_line_for_it() {
    let mut h = Harness::new(default_script());
    h.connect();
    // The bubble the person replies to: posted as the Chief by no Chief tool
    // (the Claude Docs text the person saw in Home). The log has no line for
    // its message id, so the reply alone names a message the Chief cannot read.
    let parent = as_chief(
        &h,
        "c-unknown-docs",
        vec![text(
            "Claude Docs guide: the skeleton goes first, then the sections",
        )],
    );
    deliver(&mut h, parent.clone());
    let mut reply = message(next_seq(&h), "user_local", "dyk what this means");
    reply.reply_to = Some(PartRef {
        message_id: parent.id.clone(),
        part_index: 0,
    });
    deliver(&mut h, reply);
    // The reply's own line is logged when its turn starts: let the turn run.
    h.settle_posts();
    // The parent's text, under its id and seq, logged before the reply, so the
    // next turn's delta carries it and zoom on its line shows it.
    let log = h.log();
    let parent_at = log
        .iter()
        .position(|(kind, text)| kind == "note" && text.contains(&parent.id))
        .unwrap_or_else(|| panic!("the replied-to message is not in the log: {log:?}"));
    let parent_note = &log[parent_at].1;
    assert!(parent_note.contains("skeleton goes first"), "{parent_note}");
    assert!(
        parent_note.contains(&format!("#{}", parent.seq)),
        "{parent_note}"
    );
    let reply_at = log
        .iter()
        .position(|(_, text)| text.contains("dyk what this means"))
        .expect("the reply is logged");
    assert!(parent_at < reply_at, "the parent comes first: {log:?}");
    // A reply to a message that already has its own line adds no note.
    let earlier = h.say("user_local", "check the nightly");
    h.settle_posts();
    let mut again = message(next_seq(&h), "user_local", "and this one");
    again.reply_to = Some(PartRef {
        message_id: earlier.id.clone(),
        part_index: 0,
    });
    deliver(&mut h, again);
    let repeats: Vec<String> = notes(&h)
        .into_iter()
        .filter(|n| n.contains(&format!("replies to {} ", earlier.id)))
        .collect();
    assert!(repeats.is_empty(), "{repeats:?}");
}
