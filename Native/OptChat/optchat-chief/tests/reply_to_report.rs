//! A reply the Chief threads under a subagent's report line (`[a1] ...`) goes
//! into the thread of the person's message that started a1, not into an
//! error: a report is a memory line, not a conversation message. Lawrence's
//! Chief, Oct 20-26: 28 send/reply/react calls named a report line and failed
//! with "line N is not a message in the conversation", and 14 were not
//! retried at once.

mod common;

use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_conversation::{Op, Part, PartRef};
use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::brain::Input;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::{Orchestrator, SendCall};
use serde_json::{Value, json};

const REPORT: &str = "Landed the sidebar fix.";

/// A subagent's turn ends with `REPORT`; the Chief's first turn never ends by
/// itself (it is held until the test releases it), the later ones answer.
fn script() -> Script {
    let default = default_script();
    Box::new(move |turn, blocks: &[Value]| {
        let text = serde_json::to_string(blocks).unwrap_or_default();
        if text.contains("REPORT-TASK") {
            return vec![
                json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
                update(
                    "agent_message_chunk",
                    json!({"content": {"type": "text", "text": REPORT}}),
                ),
                json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
            ];
        }
        default(turn, blocks)
    })
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

fn run<T: Send + 'static>(h: &mut Harness, f: impl FnOnce() -> T + Send + 'static) -> T {
    let worker = std::thread::spawn(f);
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    worker.join().unwrap()
}

/// (parts, reply_to, thread_root) of every `message.send` the owner took.
fn sends(h: &Harness) -> Vec<(Vec<Part>, Option<PartRef>, Option<String>)> {
    h.owner
        .lock()
        .unwrap()
        .ops
        .iter()
        .filter_map(|(_, op)| match op {
            Op::MessageSend {
                parts,
                reply_to,
                thread_root,
                ..
            } => Some((parts.clone(), reply_to.clone(), thread_root.clone())),
            _ => None,
        })
        .collect()
}

fn has_text(parts: &[Part], needle: &str) -> bool {
    parts
        .iter()
        .any(|p| matches!(p, Part::Text { text, .. } if text.contains(needle)))
}

fn sub_session(h: &Harness) -> Option<String> {
    let inner = h.agents.inner.lock().unwrap();
    let k = inner
        .specs
        .iter()
        .position(|s| s.tags.contains_key("optchat.subagent"))?;
    let session = format!("s{}", k + 1);
    inner.prompt_sessions.contains(&session).then_some(session)
}

fn idle(session: &str) -> cmux_chief::acp::SessionSummary {
    serde_json::from_value(json!({
        "sessionId": session, "name": "a1", "status": "idle", "harness": "claude",
    }))
    .unwrap()
}

/// The person asks (msg_1); the turn that answers it spawns a1; a1 reports.
/// The memory line of a1's report.
fn report_line(h: &mut Harness) -> u64 {
    h.agents.hold(true);
    h.connect();
    h.say("user_local", "fix the sidebar flicker");
    while h.agents.inner.lock().unwrap().prompts.is_empty() {
        h.step();
    }
    let sp = spawner(h);
    run(h, move || {
        sp.spawn(vec!["REPORT-TASK fix the flicker".into()], None)
    })
    .expect("the spawn answers");
    h.agents.hold(false);
    h.agents.release();
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut idle_sent = false;
    loop {
        // A memory line's id is its place in the log.
        if let Some(id) = h.log().iter().position(|(_, t)| t.starts_with("[a1] ")) {
            return id as u64;
        }
        assert!(Instant::now() < deadline, "no report: {:?}", h.log());
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
            continue;
        }
        if !idle_sent && let Some(session) = sub_session(h) {
            idle_sent = true;
            h.brain
                .step(Input::from(AgentEvent::SessionChanged(idle(&session))));
        }
    }
}

fn wait_send(h: &mut Harness, needle: &str) -> (Vec<Part>, Option<PartRef>, Option<String>) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(s) = sends(h).into_iter().find(|(p, _, _)| has_text(p, needle)) {
            return s;
        }
        assert!(
            Instant::now() < deadline,
            "no send with {needle:?}: {:?}",
            sends(h)
        );
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
    }
}

#[test]
fn a_send_to_a_report_line_goes_into_the_thread_of_the_message_that_started_it() {
    let mut h = Harness::new(script());
    let line = report_line(&mut h);
    let sp = spawner(&h);
    let call = SendCall {
        text: Some("a1 landed the sidebar fix.".into()),
        attachments: Vec::new(),
        reply_to: Some(line),
    };
    let answer = run(&mut h, move || sp.send(call)).expect("a send to a report line is no error");
    assert!(answer.starts_with("outcome: done"), "{answer}");
    let (_, reply_to, root) = wait_send(&mut h, "a1 landed the sidebar fix.");
    assert_eq!(reply_to.map(|r| r.message_id), Some("msg_1".to_owned()));
    assert_eq!(root.as_deref(), Some("msg_1"));
}

#[test]
fn a_reply_to_a_report_line_goes_into_the_thread_of_the_message_that_started_it() {
    let mut h = Harness::new(script());
    let line = report_line(&mut h);
    let sp = spawner(&h);
    let answer = run(&mut h, move || sp.reply(line, "a1 is done."))
        .expect("a reply to a report line is no error");
    assert!(answer.starts_with("outcome: done"), "{answer}");
    let (_, reply_to, root) = wait_send(&mut h, "a1 is done.");
    assert_eq!(reply_to.map(|r| r.message_id), Some("msg_1".to_owned()));
    assert_eq!(root.as_deref(), Some("msg_1"));
}

#[test]
fn a_send_to_a_line_with_no_message_behind_it_goes_to_the_top_level() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "hello");
    h.settle_posts();
    // A note: no person message and no subagent behind it.
    let line = h
        .chat
        .append(optchat_core::Kind::Note, "a note the Chief wrote")
        .unwrap();
    let sp = spawner(&h);
    let call = SendCall {
        text: Some("Top level instead.".into()),
        attachments: Vec::new(),
        reply_to: Some(line),
    };
    let answer = run(&mut h, move || sp.send(call)).expect("a send is no error");
    assert!(answer.contains("top level"), "{answer}");
    let (_, reply_to, root) = wait_send(&mut h, "Top level instead.");
    assert_eq!(reply_to, None);
    assert_eq!(root, None);
}
