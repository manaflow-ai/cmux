//! Chief cards (issue 25830): a reply's `[next: …]` lines become a
//! next-steps card, `send(sign_in)` posts a Secure Store card, and a turn
//! that drives the browser shows one live browser card it edits as it goes
//! and marks done when the turn ends. An owner that refuses cards gets the
//! same words as text.

mod common;

use std::sync::Arc;
use std::time::Duration;

use cmux_conversation::{Card, CardSurface, Op, Part};
use common::*;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::{Orchestrator, SendCall, SignInCard};
use serde_json::{Value, json};

/// A turn that says `reply` and nothing else.
fn replying(reply: &'static str) -> Script {
    Box::new(move |_, _| {
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": reply}}),
            ),
            json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
        ]
    })
}

/// A turn that drives the browser twice, then answers.
fn browsing() -> Script {
    Box::new(|turn, _| {
        let call = |id: &str, command: &str, description: &str| {
            [
                update(
                    "tool_call",
                    json!({"toolCallId": id, "title": "Bash", "kind": "execute",
                           "rawInput": {"command": command, "description": description},
                           "_meta": {"claude": {"tool": "Bash"}}}),
                ),
                update(
                    "tool_call_update",
                    json!({"toolCallId": id, "status": "completed",
                           "content": [{"type": "content", "content": {"type": "text", "text": "ok"}}]}),
                ),
            ]
        };
        let mut events = vec![json!({"dir": "mux", "kind": "turn_started", "msg": {}})];
        events.extend(call(
            &format!("b{turn}a"),
            "cmux browser right open --agent Chief https://www.linkedin.com/messaging/",
            "Opening LinkedIn Messaging",
        ));
        events.extend(call(
            &format!("b{turn}b"),
            "cmux browser right click --agent Chief '#send'",
            "Sending the reply",
        ));
        events.push(update(
            "agent_message_chunk",
            json!({"content": {"type": "text", "text": "Sent."}}),
        ));
        events.push(json!({"dir": "mux", "kind": "turn_end", "msg": {}}));
        events
    })
}

fn ops(h: &Harness) -> Vec<(String, Op)> {
    h.owner.lock().unwrap().ops.clone()
}

/// The cards of every op's parts, in order: (key, card).
fn cards(h: &Harness) -> Vec<(String, Card)> {
    ops(h)
        .into_iter()
        .flat_map(|(key, op)| {
            let parts = match op {
                Op::MessageSend { parts, .. } | Op::MessageEdit { parts, .. } => parts,
                _ => Vec::new(),
            };
            parts.into_iter().filter_map(move |part| match part {
                Part::Card(card) => Some((key.clone(), card)),
                _ => None,
            })
        })
        .collect()
}

#[test]
fn a_replys_next_lines_become_its_next_steps_card() {
    let mut h = Harness::new(replying(
        "The retry was declined on the approval card.\n\n[next: Try sending the Kernel update again]",
    ));
    h.connect();
    h.say("user_local", "did the update go out?");
    h.settle_posts();
    let reply = ops(&h)
        .into_iter()
        .find_map(|(_, op)| match op {
            Op::MessageSend { parts, .. } if matches!(parts.first(), Some(Part::Text { .. })) => {
                Some(parts)
            }
            _ => None,
        })
        .expect("a reply");
    assert_eq!(
        reply,
        vec![
            Part::Text {
                text: "The retry was declined on the approval card.".into(),
                runs: None,
            },
            Part::Card(Card::NextSteps {
                choices: vec!["Try sending the Kernel update again".into()],
            }),
        ]
    );
}

#[test]
fn an_owner_that_refuses_cards_gets_the_choices_as_text() {
    let mut h = Harness::new(replying("Done.\n[next: Show me the draft]"));
    h.owner
        .lock()
        .unwrap()
        .rejects
        .push_back(Some("invalid_parts".into()));
    h.connect();
    h.say("user_local", "draft it");
    h.settle_posts();
    let texts: Vec<String> = ops(&h)
        .into_iter()
        .filter_map(|(key, op)| match op {
            Op::MessageSend { parts, .. } if key.ends_with(":text") => match &parts[..] {
                [Part::Text { text, .. }] => Some(text.clone()),
                _ => None,
            },
            _ => None,
        })
        .collect();
    assert_eq!(texts, vec!["Done.\n\n→ Show me the draft".to_owned()]);
}

#[test]
fn a_browsing_turn_shows_one_live_card_and_ends_it() {
    let mut h = Harness::new(browsing());
    h.connect();
    h.say("user_local", "reply to Jun Beom on LinkedIn");
    h.settle_posts();
    let shown = cards(&h);
    assert!(!shown.is_empty(), "no browser card: {:?}", ops(&h));
    let sends = ops(&h)
        .iter()
        .filter(|(key, op)| key.ends_with(":browser") && matches!(op, Op::MessageSend { .. }))
        .count();
    assert_eq!(sends, 1, "one card message per turn: {shown:?}");
    let first = &shown[0].1;
    assert!(
        matches!(first, Card::Browser { surface: CardSurface::Browser, live: true, target: Some(t), .. } if t == "browser:right"),
        "{first:?}"
    );
    let (_, last) = shown.last().unwrap();
    let Card::Browser { step, live, url, .. } = last else {
        panic!("{last:?}");
    };
    assert_eq!(step, "Sending the reply");
    assert!(!live, "the turn ended: {last:?}");
    assert_eq!(url.as_deref(), Some("https://www.linkedin.com/messaging/"));
    assert!(
        ops(&h)
            .iter()
            .any(|(_, op)| matches!(op, Op::MessageEdit { .. })),
        "edited in place: {:?}",
        ops(&h)
    );
}

#[test]
fn a_turn_without_browsing_shows_no_browser_card() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "list the files");
    h.settle_posts();
    assert!(cards(&h).is_empty(), "{:?}", cards(&h));
}

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

#[test]
fn send_with_sign_in_posts_a_secure_store_card() {
    let mut h = Harness::new(default_script());
    h.connect();
    let sp = spawner(&h);
    let worker = std::thread::spawn(move || {
        sp.send(SendCall {
            text: None,
            attachments: Vec::new(),
            reply_to: None,
            sign_in: Some(SignInCard {
                site: "linkedin.com".into(),
                url: Some("https://www.linkedin.com/login".into()),
            }),
        })
    });
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    let answer = worker.join().unwrap().expect("send answers");
    assert!(answer.starts_with("outcome: done"), "{answer}");
    h.settle_posts();
    let posted: Vec<Value> = cards(&h)
        .into_iter()
        .map(|(_, card)| serde_json::to_value(card).unwrap())
        .collect();
    assert_eq!(
        posted,
        vec![json!({"kind": "sign_in", "site": "linkedin.com",
                    "url": "https://www.linkedin.com/login"})]
    );
}

#[test]
fn send_refuses_a_sign_in_that_is_not_a_host_name() {
    let call = optchat_chief::tools::Call::parse(
        "send",
        &json!({"sign_in": {"site": "https://linkedin.com/login"}}),
    );
    assert!(call.is_err(), "{call:?}");
    let ok = optchat_chief::tools::Call::parse(
        "send",
        &json!({"sign_in": {"site": "LinkedIn.com"}}),
    );
    assert!(ok.is_ok(), "a host name in any case: {ok:?}");
}

#[test]
fn the_text_fallback_answers_the_same_messages() {
    let mut h = Harness::new(replying("Done.\n[next: Show me the draft]"));
    h.owner
        .lock()
        .unwrap()
        .rejects
        .push_back(Some("invalid_parts".into()));
    h.connect();
    h.say("user_local", "draft it");
    h.settle_posts();
    let answers: Vec<Vec<String>> = ops(&h)
        .into_iter()
        .filter_map(|(key, op)| match op {
            Op::MessageSend { answers, .. } if key.ends_with(":text") => Some(answers),
            _ => None,
        })
        .collect();
    assert_eq!(answers.len(), 1, "{:?}", ops(&h));
    assert!(!answers[0].is_empty(), "the fallback answers the person's message");
}

#[test]
fn an_owner_that_refuses_the_browser_card_gets_its_text_once() {
    let mut h = Harness::new(browsing());
    h.owner
        .lock()
        .unwrap()
        .rejects
        .push_back(Some("invalid_parts".into()));
    h.connect();
    h.say("user_local", "reply to Jun Beom on LinkedIn");
    h.settle_posts();
    let browser_ops: Vec<String> = ops(&h)
        .into_iter()
        .map(|(key, _)| key)
        .filter(|key| key.contains(":browser"))
        .collect();
    assert_eq!(
        browser_ops.len(),
        2,
        "the refused card, then its text, and nothing more: {browser_ops:?}"
    );
    assert!(browser_ops[1].ends_with(":browser:text"), "{browser_ops:?}");
}

#[test]
fn a_browsing_turns_reply_stays_right_under_its_message() {
    let mut h = Harness::new(browsing());
    h.connect();
    h.say("user_local", "reply to Jun Beom on LinkedIn");
    h.settle_posts();
    let reply = ops(&h)
        .into_iter()
        .find_map(|(key, op)| match op {
            Op::MessageSend {
                parts,
                thread_root,
                reply_to,
                answers,
                ..
            } if !key.contains(":browser")
                && matches!(parts.first(), Some(Part::Text { text, .. }) if text == "Sent.") =>
            {
                Some((thread_root, reply_to, answers))
            }
            _ => None,
        })
        .expect("the turn's reply");
    assert_eq!(reply.0, None, "no thread: the card is an aside: {reply:?}");
    assert_eq!(reply.1, None, "{reply:?}");
    assert!(!reply.2.is_empty(), "the reply answers the person's message");
}

#[test]
fn a_thread_refusal_is_not_a_card_refusal() {
    let mut h = Harness::new(replying("Done.\n[next: Show me the draft]"));
    h.owner
        .lock()
        .unwrap()
        .rejects
        .push_back(Some("agent_budget".into()));
    h.connect();
    h.say("user_local", "draft it");
    h.settle_posts();
    assert!(
        !ops(&h).iter().any(|(key, _)| key.ends_with(":text")),
        "no text fallback for a refusal that is not about the parts: {:?}",
        ops(&h)
    );
}
