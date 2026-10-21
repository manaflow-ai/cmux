//! A subagent whose account runs out of usage continues on the Chief's own
//! harness (Leo, 2026-10-20: "we need to fix chief"). a4 and a10-a13 ran on
//! the `claude` login, stopped on "(turn failed: You've hit your weekly limit
//! · resets Oct 25 at 9pm ...)" and were reported as done; the Chief had
//! moved to claude-sr2-pipe, but nothing moved them, and a retry on the same
//! login fails the same way until the limit resets five days later.

mod common;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::brain::Input;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;
use serde_json::{Value, json};

const LIMIT: &str = "You've hit your weekly limit · resets Oct 25 at 9pm (America/Los_Angeles)";

/// The first subagent turn runs out of usage after some work; every later
/// turn answers as usual.
fn limit_script() -> Script {
    let default = default_script();
    let subs = AtomicUsize::new(0);
    Box::new(move |turn, blocks: &[Value]| {
        let text = serde_json::to_string(blocks).unwrap_or_default();
        if !text.contains("LIMIT-TASK") || subs.fetch_add(1, Ordering::SeqCst) > 0 {
            return default(turn, blocks);
        }
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": "The plan model is written."}}),
            ),
            json!({"dir": "mux", "kind": "turn_error", "msg": {"error": LIMIT}}),
        ]
    })
}

/// A brain over `limit_script` whose host.log lines are kept.
fn harness() -> (Harness, Arc<Mutex<Vec<String>>>) {
    let dir = tempfile::tempdir().unwrap();
    let lines = Arc::new(Mutex::new(Vec::new()));
    let sink = lines.clone();
    let settings = settings(dir.path());
    let owner = Arc::new(Mutex::new(Owner {
        summary: Some(summary()),
        ..Owner::default()
    }));
    let h = Harness::configured(
        dir,
        limit_script(),
        owner,
        settings,
        Arc::new(move |line: &str| sink.lock().unwrap().push(line.to_owned())),
    );
    (h, lines)
}

fn spawner(h: &Harness, lines: &Arc<Mutex<Vec<String>>>, harness: &str) -> Arc<Spawner> {
    let sink = lines.clone();
    Arc::new(Spawner::new(
        h.chat.clone(),
        h.agents.clone(),
        SubagentSettings {
            harness: harness.into(),
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
        Arc::new(move |line: &str| sink.lock().unwrap().push(line.to_owned())),
    ))
}

/// Every subagent session: (session id, harness).
fn sub_sessions(h: &Harness) -> Vec<(String, String)> {
    let inner = h.agents.inner.lock().unwrap();
    inner
        .specs
        .iter()
        .enumerate()
        .filter(|(_, s)| s.tags.contains_key("optchat.subagent"))
        .map(|(k, s)| (format!("s{}", k + 1), s.harness.clone()))
        .collect()
}

/// The prompts sent to `session`, as JSON text.
fn prompts_of(h: &Harness, session: &str) -> Vec<String> {
    let inner = h.agents.inner.lock().unwrap();
    inner
        .prompts
        .iter()
        .zip(&inner.prompt_sessions)
        .filter(|(_, s)| s.as_str() == session)
        .map(|(blocks, _)| serde_json::to_string(blocks).unwrap())
        .collect()
}

fn idle(session: &str, harness: &str) -> cmux_chief::acp::SessionSummary {
    serde_json::from_value(json!({
        "sessionId": session, "name": "a1", "status": "idle", "harness": harness,
    }))
    .unwrap()
}

/// Spawns a1 on `sub_harness` and steps the brain until `done` holds (or
/// 20 s pass); each subagent session that got its prompt goes idle, as
/// acpmux reports it.
fn run_until(
    h: &mut Harness,
    lines: &Arc<Mutex<Vec<String>>>,
    sub_harness: &str,
    done: impl Fn(&Harness) -> bool,
) {
    // The host keeps its Spawner for its life; the queue's starter holds it
    // weakly, so the test keeps it too, or a queued restart never starts.
    let sp = spawner(h, lines, sub_harness);
    let _keep = sp.clone();
    h.brain.set_sub_starter(Some(sp.queue_starter()));
    h.connect();
    let worker =
        std::thread::spawn(move || sp.spawn(vec!["LIMIT-TASK fix the build".into()], None));
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut idled: Vec<String> = Vec::new();
    while !done(h) {
        assert!(
            Instant::now() < deadline,
            "timed out: {:?}; host.log: {:?}; sessions: {:?}",
            h.log(),
            lines.lock().unwrap(),
            sub_sessions(h)
        );
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
            continue;
        }
        for (session, harness) in sub_sessions(h) {
            if !idled.contains(&session) && !prompts_of(h, &session).is_empty() {
                idled.push(session.clone());
                h.brain.step(Input::from(AgentEvent::SessionChanged(idle(
                    &session, &harness,
                ))));
            }
        }
    }
    worker.join().unwrap().expect("the spawn answers");
}

#[test]
fn a_subagent_out_of_usage_continues_on_the_chiefs_harness() {
    // The Chief's turns run on claude-sr (settings), its subagent on claude.
    let (mut h, lines) = harness();
    run_until(&mut h, &lines, "claude", |h| {
        sub_sessions(h).len() >= 2 && !prompts_of(h, &sub_sessions(h)[1].0).is_empty()
    });
    let sessions = sub_sessions(&h);
    assert_eq!(sessions[0].1, "claude");
    assert_eq!(
        sessions[1].1, "claude-sr",
        "it moves to the Chief's harness"
    );
    let prompt = prompts_of(&h, &sessions[1].0).join("\n");
    assert!(
        prompt.contains("fix the build"),
        "its task goes with it: {prompt}"
    );
    assert!(
        prompt.contains("usage limit"),
        "it is told why it is in a new session: {prompt}"
    );
    // The note to the Chief is quiet (no turn of its own); host.log says
    // where it went.
    let lines = lines.lock().unwrap().clone();
    assert!(
        lines
            .iter()
            .any(|l| l.contains("a1") && l.contains("continuing it on claude-sr")),
        "{lines:?}"
    );
    assert!(
        h.agents
            .inner
            .lock()
            .unwrap()
            .ended
            .contains(&sessions[0].0),
        "its session on the used-up account is ended"
    );
}

#[test]
fn a_subagent_out_of_usage_on_the_chiefs_own_harness_is_reported() {
    let (mut h, lines) = harness();
    run_until(&mut h, &lines, "claude-sr", |h| {
        h.log().iter().any(|(_, t)| t.starts_with("[a1]"))
    });
    assert_eq!(sub_sessions(&h).len(), 1, "no other harness to move it to");
    let report = h
        .log()
        .into_iter()
        .map(|(_, t)| t)
        .find(|t| t.starts_with("[a1]"))
        .unwrap();
    assert!(report.contains("usage limit"), "{report}");
}
