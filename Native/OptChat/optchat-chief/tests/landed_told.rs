//! A turn that saw a landed report tells it before it ends.
//!
//! Measured on Lawrence's Chief, Nov 12-18 (plans/cmux-next/chief-local-improvements.md,
//! item 7): of 382 subagent reports that named a landed range, 376 were told, but only
//! 176 in the turn that saw them; in 74 such turns the Chief posted nothing and slept.
//! The report reached a turn in under a second (p50 0.5 s); telling it took p50 23 s and
//! p90 379 s, because the next turn told it.
//!
//! Now `sleep` and `stop` in a turn that saw a landed report and posted nothing naming
//! that subagent are refused once, naming it; a second call goes through, so a Chief that
//! has a reason is never stuck.

mod common;

use std::sync::Arc;
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::brain::Input;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::{Orchestrator, SendCall, SleepCall};
use serde_json::{Value, json};

fn script(report: &'static str) -> Script {
    let default = default_script();
    Box::new(move |turn, blocks: &[Value]| {
        let text = serde_json::to_string(blocks).unwrap_or_default();
        if text.contains("REPORT-TASK") && !text.contains("<open-items>") {
            return vec![
                json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
                update(
                    "agent_message_chunk",
                    json!({"content": {"type": "text", "text": report}}),
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

/// a1 reports `report`; the Chief's turn on it runs and is held there.
fn report_turn(report: &'static str) -> (Harness, Arc<Spawner>) {
    let mut h = Harness::new(script(report));
    h.agents.hold(true);
    h.connect();
    let sp = spawner(&h);
    let s = sp.clone();
    let worker = std::thread::spawn(move || s.spawn(vec!["REPORT-TASK fix it".into()], None));
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut idle_sent = false;
    loop {
        let in_turn = h
            .agents
            .inner
            .lock()
            .unwrap()
            .prompts
            .iter()
            .any(|p| serde_json::to_string(p).unwrap().contains("[a1]"));
        if in_turn {
            break;
        }
        assert!(Instant::now() < deadline, "no report turn: {:?}", h.log());
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
            continue;
        }
        if !idle_sent && worker.is_finished() {
            let session = {
                let inner = h.agents.inner.lock().unwrap();
                inner
                    .specs
                    .iter()
                    .position(|s| s.tags.contains_key("optchat.subagent"))
                    .map(|k| format!("s{}", k + 1))
            };
            if let Some(session) = session {
                idle_sent = true;
                let idle: cmux_chief::acp::SessionSummary = serde_json::from_value(json!({
                    "sessionId": session, "name": "a1", "status": "idle", "harness": "claude",
                }))
                .unwrap();
                h.brain.step(Input::from(AgentEvent::SessionChanged(idle)));
            }
        }
    }
    (h, sp)
}

fn sleep_call() -> SleepCall {
    SleepCall {
        seconds: 1800,
        note: Some("check the others".into()),
        until: Some("event".into()),
    }
}

#[test]
fn a_turn_that_saw_a_landed_report_cannot_sleep_before_it_names_the_subagent() {
    let (mut h, sp) = report_turn("Landed 1a2b3c4d..5e6f7a8b on feat-cmux-next; tests green.");
    let s = sp.clone();
    let refused = run(&mut h, move || s.sleep(sleep_call())).expect_err("refused once");
    assert!(refused.starts_with("sleep: refused"), "{refused}");
    assert!(refused.contains("a1"), "{refused}");
    assert!(
        refused.contains("1a2b3c4d..5e6f7a8b"),
        "names what landed: {refused}"
    );
    let s = sp.clone();
    run(&mut h, move || {
        s.send(SendCall {
            text: Some("a1 landed the fix: 1a2b3c4d..5e6f7a8b.".into()),
            ..SendCall::default()
        })
    })
    .expect("send posts");
    let s = sp.clone();
    let answer = run(&mut h, move || s.sleep(sleep_call())).expect("sleeps once told");
    assert!(answer.starts_with("outcome: done"), "{answer}");
}

#[test]
fn the_refusal_comes_once_a_turn() {
    let (mut h, sp) = report_turn("Landed 1a2b3c4d..5e6f7a8b on feat-cmux-next; tests green.");
    let s = sp.clone();
    run(&mut h, move || s.stop_turn()).expect_err("refused once");
    let s = sp.clone();
    let answer = run(&mut h, move || s.stop_turn()).expect("the second stop goes through");
    assert!(answer.starts_with("outcome: done"), "{answer}");
}

#[test]
fn a_report_that_did_not_land_does_not_hold_the_turn() {
    let (mut h, sp) = report_turn("Red is still running on the fleet; nothing landed yet.");
    let s = sp.clone();
    let answer = run(&mut h, move || s.sleep(sleep_call())).expect("sleeps");
    assert!(answer.starts_with("outcome: done"), "{answer}");
}

#[test]
fn a_turn_that_sends_the_subagent_back_to_work_passes() {
    for how in ["tell", "restart"] {
        let (mut h, sp) = report_turn("Landed 1a2b3c4d..5e6f7a8b on feat-cmux-next; tests green.");
        let s = sp.clone();
        let sent = run(&mut h, move || {
            if how == "tell" {
                s.tell("a1", "Also add the After shots, then report.")
            } else {
                s.control(optchat_chief::tools::ControlCall {
                    action: "restart".into(),
                    id: Some("a1".into()),
                    message: Some("Add the After shots, then report.".into()),
                    option: None,
                    n: None,
                    peer: None,
                })
            }
        });
        assert!(sent.is_ok(), "{how}: {sent:?}");
        let s = sp.clone();
        let answer = run(&mut h, move || s.sleep(sleep_call()))
            .unwrap_or_else(|e| panic!("{how}: its next report is the one to tell: {e}"));
        assert!(answer.starts_with("outcome: done"), "{how}: {answer}");
    }
}

#[test]
fn a_report_with_one_sha_and_no_range_does_not_hold_the_turn() {
    let (mut h, sp) = report_turn("Landed 1a2b3c4d5e on feat-cmux-next; tests green.");
    let s = sp.clone();
    let answer = run(&mut h, move || s.sleep(sleep_call())).expect("no range: no hold");
    assert!(answer.starts_with("outcome: done"), "{answer}");
}
