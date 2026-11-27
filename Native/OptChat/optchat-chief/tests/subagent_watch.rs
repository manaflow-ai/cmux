//! The host watches its running subagents by their events, not by session
//! summary changes (acp-chief-issues.md #4-#7, #13, #16, #20; a204).
//!
//! - #4: an agent alive inside a fleet wait gets no "looks stuck" note.
//! - #5: a silent agent is continued automatically; the Chief hears of it
//!   only when the continue did not help.
//! - #6: `control status` names the task, what it does now, its last line
//!   and what it pushed.
//! - #7: a session that went idle without a turn end the host saw is done.
//! - #13: a stopped report carries the state it stopped in.
//! - #16: a restart of an agent in a live wait does not kill the wait, and a
//!   forced one tells it which fleet runs to wait on again.
//! - #20: an acknowledgement of a Chief message starts no Chief turn.

mod common;

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::{ControlCall, Orchestrator};
use serde_json::{Value, json};

const MIN: u64 = 60_000;
const JOB: &str = "4ef607bb70ac530208590c72";
const TASK: &str = "Watched task\n\nDo the watched work.";

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

fn bash(id: &str, command: &str, t: u64) -> Value {
    at(
        update(
            "tool_call",
            json!({"toolCallId": id, "title": "Bash", "rawInput": {"command": command}, "_meta": {"claude": {"tool": "Bash"}}}),
        ),
        t,
    )
}

fn result(id: &str, text: &str, t: u64) -> Value {
    at(
        update(
            "tool_call_update",
            json!({"toolCallId": id, "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": text}}]}),
        ),
        t,
    )
}

fn beat(id: &str, t: u64) -> Value {
    json!({"dir": "in", "kind": "claude.tool_progress", "at": t,
           "msg": {"heartbeat": true, "parent_tool_use_id": id, "tool_name": "Bash"}})
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
    setup_with_owner(events, false)
}

fn setup_with_owner(events: Vec<Value>, connected: bool) -> Setup {
    let sub = Arc::new(Mutex::new(events));
    let mut h = Harness::new(script(sub));
    h.agents.hold(true);
    // Connect before spawning: a later reconnect also reconciles the child.
    if connected {
        h.connect();
    }
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

/// A run waiting on fleet job JOB from `t0`, beating every 30 s for `minutes`.
fn fleet_wait(t0: u64, minutes: u64) -> Vec<Value> {
    let mut events = vec![
        prompt("optchat-sub:a1", t0),
        say("Waiting for the fleet run.", t0 + 500),
        bash(
            "toolu_w",
            &format!("timeout 1700 ~/.local/bin/cmux-ci wait {JOB} | tail -5"),
            t0 + 1000,
        ),
    ];
    let mut t = t0 + 1000;
    while t < t0 + minutes * MIN {
        t += 30_000;
        events.push(beat("toolu_w", t));
    }
    events
}

#[test]
fn a_subagent_alive_in_a_fleet_wait_gets_no_stuck_note() {
    let t0 = now_ms();
    let mut s = setup(fleet_wait(t0, 40));
    s.at(t0 + 40 * MIN + 5_000);
    s.tick();
    assert!(s.trace("subagent.stuck").is_empty(), "no stuck note");
    assert!(
        s.trace("subagent.auto_continue").is_empty(),
        "nothing to continue"
    );
    assert!(!s.chief_prompts().contains("looks stuck"));
    assert!(s.h.agents.inner.lock().unwrap().cancels.is_empty());
    let status = s.control("status", None);
    assert!(status.contains("[waiting]"), "{status}");
    assert!(
        status.contains(&format!("waiting on fleet run {JOB}")),
        "{status}"
    );
}

#[test]
fn a_silent_subagent_is_continued_once_then_reported() {
    let t0 = now_ms();
    let mut s = setup(vec![
        prompt("optchat-sub:a1", t0),
        say("Reading the code.", t0 + 1000),
    ]);
    s.at(t0 + 16 * MIN);
    s.tick();
    // First the host continues it itself: no note to the Chief.
    assert_eq!(
        s.h.agents.inner.lock().unwrap().cancels,
        vec![s.session.clone()]
    );
    assert_eq!(s.trace("subagent.auto_continue").len(), 1);
    assert!(s.trace("subagent.stuck").is_empty());
    let follow = s.sub().after_stop.unwrap_or_default();
    assert!(follow.contains("git status"), "{follow}");
    // acpmux runs the continue as its next turn, which stays silent.
    s.running();
    // Still silent 16 minutes after the continue: now the Chief hears.
    s.at(t0 + 33 * MIN);
    s.tick();
    let stuck = s.trace("subagent.stuck");
    assert_eq!(stuck.len(), 1, "{stuck:?}");
    assert_eq!(stuck[0]["after_continue"], json!(true));
    // Once only.
    s.at(t0 + 40 * MIN);
    s.tick();
    assert_eq!(s.trace("subagent.stuck").len(), 1);
}

#[test]
fn status_names_the_task_the_work_and_the_pushes() {
    let t0 = now_ms();
    let mut s = setup(vec![
        prompt("optchat-sub:a1", t0),
        started(t0),
        bash("p", "git push origin HEAD:feat-cmux-next", t0 + 1000),
        result(
            "p",
            "   1a2b3c4d5e..9f8e7d6c5b  HEAD -> feat-cmux-next",
            t0 + 2000,
        ),
        say("Pushed; now the tests.", t0 + 3000),
        bash("t", "cargo test -p optchat-chief", t0 + 4000),
        beat("t", t0 + 60_000),
    ]);
    s.at(t0 + 70_000);
    let status = s.control("status", None);
    assert!(status.contains("task: Watched task"), "{status}");
    assert!(!status.contains("<chat>"), "{status}");
    assert!(status.contains("[running-tool]"), "{status}");
    assert!(status.contains("cargo test -p optchat-chief"), "{status}");
    assert!(
        status.contains("last said: Pushed; now the tests."),
        "{status}"
    );
    assert!(
        status.contains("pushed: 1a2b3c4d5e..9f8e7d6c5b -> feat-cmux-next"),
        "{status}"
    );
}

#[test]
fn an_idle_session_without_a_turn_end_is_done_not_at_work() {
    // a51, a60, a62: idle in acpmux for 15 h, "running" for the host.
    let t0 = now_ms();
    let mut s = setup(vec![
        prompt("optchat-sub:a1", t0),
        say("Working.", t0 + 1000),
    ]);
    s.idle();
    s.at(t0 + 20 * MIN);
    s.tick();
    let sub = s.sub();
    assert!(
        matches!(
            sub.status,
            optchat_chief::state::SubStatus::Done | optchat_chief::state::SubStatus::Reported
        ),
        "{sub:?}"
    );
    assert!(sub.stopped, "quiet: it has nothing new to say");
    assert!(s.trace("subagent.stuck").is_empty());
    let status = s.control("status", None);
    assert!(status.contains("[done]"), "{status}");
}

#[test]
fn a_stopped_report_says_where_it_stopped() {
    let t0 = now_ms();
    let mut s = setup(vec![
        prompt("optchat-sub:a1", t0),
        started(t0),
        bash("p", "git push origin HEAD:feat-cmux-next", t0 + 1000),
        result(
            "p",
            "   1a2b3c4d5e..9f8e7d6c5b  HEAD -> feat-cmux-next",
            t0 + 2000,
        ),
        bash("w", &format!("cmux-ci wait {JOB}"), t0 + 3000),
        json!({"dir": "mux", "kind": "turn_end", "at": t0 + 4000, "msg": {"stopReason": "cancelled"}}),
    ]);
    s.idle();
    s.at(t0 + 10 * MIN);
    s.tick();
    let report = s.sub().report.unwrap_or_default();
    assert!(report.starts_with("(stopped by the user)"), "{report}");
    assert!(
        report.contains("pushed: 1a2b3c4d5e..9f8e7d6c5b -> feat-cmux-next"),
        "{report}"
    );
    assert!(report.contains(&format!("fleet runs: {JOB}")), "{report}");
}

#[test]
fn a_restart_keeps_a_live_wait_and_a_forced_one_names_the_runs() {
    let t0 = now_ms();
    let mut s = setup(fleet_wait(t0, 20));
    s.at(t0 + 20 * MIN + 5_000);
    let answer = s.control("restart", Some("Continue and push."));
    assert!(
        s.h.agents.inner.lock().unwrap().cancels.is_empty(),
        "{answer}"
    );
    assert!(answer.contains(&format!("fleet run {JOB}")), "{answer}");
    // The Chief can still force it; the follow-up names the run.
    s.control("interrupt", Some("Stop waiting and report."));
    assert_eq!(s.h.agents.inner.lock().unwrap().cancels.len(), 1);
    let follow = s.sub().after_stop.unwrap_or_default();
    assert!(follow.starts_with("Stop waiting and report."), "{follow}");
    assert!(follow.contains(JOB), "{follow}");
}

#[test]
fn an_ack_to_a_chief_tell_is_quiet() {
    let t0 = now_ms();
    let mut s = setup(vec![
        prompt("optchat-sub:a1", t0),
        started(t0),
        json!({"dir": "mux", "kind": "turn_end", "at": t0 + 500, "msg": {"stopReason": "end_turn"}}),
        prompt(&format!("optchat-tell:a1:{t0}"), t0 + 1000),
        started(t0 + 1000),
        say(
            "Understood: no more force pushes. I'm stopping now.",
            t0 + 2000,
        ),
        json!({"dir": "mux", "kind": "turn_end", "at": t0 + 3000, "msg": {"stopReason": "end_turn"}}),
    ]);
    s.idle();
    s.at(t0 + 10 * MIN);
    s.tick();
    let sub = s.sub();
    assert!(
        sub.report
            .as_deref()
            .unwrap_or("")
            .contains("I'm stopping now"),
        "{sub:?}"
    );
    assert!(sub.stopped, "an ack starts no Chief turn");
}

#[test]
fn a_stopped_report_stays_quiet_in_home() {
    let t0 = now_ms();
    let mut s = setup_with_owner(
        vec![
            prompt("optchat-sub:a1", t0),
            started(t0),
            say("Partial work before cancellation.", t0 + 1000),
            json!({"dir": "mux", "kind": "turn_end", "at": t0 + 2000, "msg": {"stopReason": "cancelled"}}),
        ],
        true,
    );
    s.idle();
    s.at(t0 + 10 * MIN);
    s.tick();
    assert!(s.sub().stopped, "the cancellation was observed");
    assert!(s.h.brain.state().pending_reports.is_empty());
    assert!(
        s.h.owner
            .lock()
            .unwrap()
            .run_steps
            .iter()
            .all(|(_, run, _)| {
                !run["id"]
                    .as_str()
                    .is_some_and(|id| id.starts_with("reports:"))
            }),
        "a stopped report stays quiet in Home"
    );
}
