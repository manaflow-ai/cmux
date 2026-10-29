//! Chief fast eval, group tenacity (a676, Lawrence 2026-10-26: "it follows
//! every open task until done ... restarts stuck agents by rule with no
//! model call"). Host behavior only: no model call.
//!
//! - A subagent report that says its code is not landed gets the host's
//!   landing follow-up, and no Chief turn starts for it.
//! - A report with no code in it ("nothing committed") reaches the Chief.
//! - A silent subagent is continued by rule before the Chief hears of it.
#![allow(dead_code)]

mod common;

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::{ControlCall, Orchestrator};
use serde_json::{Value, json};

const MIN: u64 = 60_000;
const TASK: &str = "Landing task\n\nDo the watched work.";

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

/// A script whose subagent turn records `sub` (the Chief's turns run the
/// default script).
fn script(sub: Arc<Mutex<Vec<Value>>>) -> Script {
    let chief = default_script();
    Box::new(move |turn, blocks| {
        let text = serde_json::to_string(blocks).unwrap();
        if text.contains("Do the watched work") {
            sub.lock().unwrap().clone()
        } else {
            chief(turn, blocks)
        }
    })
}

fn at(mut e: Value, at: u64) -> Value {
    e["at"] = json!(at);
    e
}

fn say(text: &str, t: u64) -> Value {
    at(
        update(
            "agent_message_chunk",
            json!({"content": {"type": "text", "text": text}}),
        ),
        t,
    )
}

fn started(t: u64) -> Value {
    json!({"dir": "mux", "kind": "turn_started", "at": t, "msg": {}})
}

fn prompt(prompt_id: &str, t: u64) -> Value {
    json!({"dir": "mux", "kind": "user_message", "at": t, "msg": {"promptId": prompt_id}})
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
    settle(h);
    worker.join().unwrap()
}

fn settle(h: &mut Harness) {
    while let Ok(input) = h.rx.recv_timeout(Duration::from_millis(80)) {
        h.brain.step(input);
    }
}

fn wait_for(h: &mut Harness, what: impl Fn(&Harness) -> bool) {
    let until = Instant::now() + Duration::from_secs(5);
    while !what(h) && Instant::now() < until {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    assert!(what(h), "timed out");
}

/// A Chief harness with a trace, a clock the test sets, and subagent a1
/// running a turn that recorded `events` and is still in flight.
struct Setup {
    h: Harness,
    sp: Arc<Spawner>,
    clock: Arc<Mutex<u64>>,
    traces: std::path::PathBuf,
    session: String,
}

fn setup(events: Vec<Value>) -> Setup {
    let sub = Arc::new(Mutex::new(events));
    let mut h = Harness::new(script(sub));
    h.agents.hold(true);
    let traces = h.dir.path().join("traces");
    h.brain
        .set_trace(optchat_chief::trace::Trace::open(&traces, false).unwrap());
    let clock = Arc::new(Mutex::new(now_ms()));
    let c = clock.clone();
    h.brain.set_clock(Arc::new(move || *c.lock().unwrap()));
    let sp = spawner(&h);
    let a = sp.clone();
    run(&mut h, move || a.spawn(vec![TASK.into()], None)).unwrap();
    wait_for(&mut h, |h| {
        h.brain
            .state()
            .sub("a1")
            .is_some_and(|(_, s)| s.session_id.is_some() && !s.awaiting_task)
    });
    let session = h
        .brain
        .state()
        .sub("a1")
        .unwrap()
        .1
        .session_id
        .clone()
        .unwrap();
    Setup {
        h,
        sp,
        clock,
        traces,
        session,
    }
}

impl Setup {
    fn at(&self, ms: u64) {
        *self.clock.lock().unwrap() = ms;
    }

    fn tick(&mut self) {
        self.h.brain.step(optchat_chief::brain::Input::SubTick);
        settle(&mut self.h);
    }

    fn trace(&self, ev: &str) -> Vec<Value> {
        let mut out = Vec::new();
        for entry in std::fs::read_dir(&self.traces)
            .into_iter()
            .flatten()
            .flatten()
        {
            let text = std::fs::read_to_string(entry.path()).unwrap_or_default();
            out.extend(
                text.lines()
                    .filter_map(|l| serde_json::from_str::<Value>(l).ok())
                    .filter(|v| v["ev"] == ev),
            );
        }
        out
    }

    fn control(&mut self, action: &str, message: Option<&str>) -> String {
        let a = self.sp.clone();
        let (action, message) = (action.to_owned(), message.map(str::to_owned));
        run(&mut self.h, move || {
            a.control(ControlCall {
                action,
                id: Some("a1".into()),
                message,
                ..ControlCall::default()
            })
        })
        .unwrap()
    }

    fn sub(&self) -> optchat_chief::state::SubRecord {
        self.h.brain.state().sub("a1").unwrap().1.clone()
    }

    /// acpmux reports the session running (a turn in flight).
    fn running(&self) {
        self.h
            .agents
            .inner
            .lock()
            .unwrap()
            .session_status
            .insert(self.session.clone(), "running".into());
    }

    fn idle(&self) {
        self.h
            .agents
            .inner
            .lock()
            .unwrap()
            .session_status
            .insert(self.session.clone(), "idle".into());
    }

    /// Every prompt text sent to the Chief's own turn sessions.
    fn chief_prompts(&self) -> String {
        let inner = self.h.agents.inner.lock().unwrap();
        inner
            .prompts
            .iter()
            .zip(&inner.prompt_sessions)
            .filter(|(_, s)| **s != self.session)
            .map(|(b, _)| serde_json::to_string(b).unwrap())
            .collect::<Vec<_>>()
            .join("\n")
    }
}

fn ended(report: &str, t0: u64) -> Vec<Value> {
    vec![
        prompt("optchat-sub:a1", t0),
        started(t0),
        say(report, t0 + 1000),
        json!({"dir": "mux", "kind": "turn_end", "at": t0 + 2000, "msg": {"stopReason": "end_turn"}}),
    ]
}

/// Every prompt text sent to subagent a1's session.
fn sub_prompts(s: &Setup) -> String {
    let inner = s.h.agents.inner.lock().unwrap();
    inner
        .prompts
        .iter()
        .zip(&inner.prompt_sessions)
        .filter(|(_, sess)| **sess == s.session)
        .map(|(b, _)| serde_json::to_string(b).unwrap())
        .collect::<Vec<_>>()
        .join("\n")
}

#[test]
fn an_unlanded_report_gets_a_landing_follow_up_and_no_chief_turn() {
    let t0 = now_ms();
    let mut s = setup(ended(
        "Fixed the scroll bug in commit 1a2b3c4d5e6 on branch a1-fix. Not landed yet: it is unpushed.",
        t0,
    ));
    s.idle();
    s.at(t0 + 10 * MIN);
    s.tick();
    assert_eq!(s.trace("subagent.land_followup").len(), 1, "one follow-up");
    assert!(
        !s.chief_prompts().contains("Not landed yet"),
        "no Chief turn for the unlanded report: {}",
        s.chief_prompts()
    );
    assert!(
        sub_prompts(&s).contains("[follow-up]"),
        "the subagent is told to land it: {}",
        sub_prompts(&s)
    );
}

#[test]
fn a_report_with_no_code_reaches_the_chief() {
    let t0 = now_ms();
    let mut s = setup(ended(
        "Filed GitHub Support ticket 4906279. Nothing committed, nothing landed: no code in this task.",
        t0,
    ));
    s.idle();
    s.at(t0 + 10 * MIN);
    s.tick();
    let sub = s.sub();
    assert!(!sub.stopped, "{sub:?}");
    assert!(s.trace("subagent.land_followup").is_empty());
}

#[test]
fn a_silent_subagent_is_continued_by_rule_before_the_chief_hears() {
    let t0 = now_ms();
    let mut s = setup(vec![
        prompt("optchat-sub:a1", t0),
        say("Reading the code.", t0 + 1000),
    ]);
    s.at(t0 + 16 * MIN);
    s.tick();
    assert_eq!(s.trace("subagent.auto_continue").len(), 1);
    assert!(s.trace("subagent.stuck").is_empty(), "no model call yet");
}
