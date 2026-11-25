//! A subagent that ends a run only to wait on its own background work wakes no Chief turn.
//!
//! Measured on Lawrence's Chief, Nov 12-18 (measure/chief_loop_stats.py and the replay in
//! plans/cmux-next/chief-local-improvements.md): 2,072 Chief turns for 145 person messages. 860 of
//! 1,787 subagent reports were followed by the subagent's own background notice (a fleet run, a
//! CI wait, a monitor it armed): it had ended its run only to wait ("Red is still running; I
//! report when it ends"). Each such report started a Chief turn, and the outcome ledger then
//! forced an `[untold]` turn to tell the person a status that was not an outcome: 1,066 of the
//! 2,072 turns (51%) had nothing else to wake them.
//!
//! Now a run that ends with its background work still pending (acpmux `process_update` running,
//! or a daemon task from `bg_start` with no notice yet) and a report that says it waits goes to
//! the Chief quietly: no turn, no outcome owed. The run its notice starts is the continuation, so
//! its report wakes the Chief as before (the report-once rule for a notice turn after a final
//! report stays). A report that names a landed range, asks something, or waits on a person is
//! never held. A held subagent whose background work ended without waking it, or that waits past
//! [`WAIT_SURFACE_AFTER`], reaches the Chief from the tick.

mod common;

use std::sync::{Arc, Mutex};
use std::time::Duration;

use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::brain::Input;
use optchat_chief::state::SubStatus;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;
use serde_json::{Value, json};

const TASK: &str = "Run the red and green fleet steps and land the fix.";
const MIN: u64 = 60_000;

fn spawner(h: &Harness) -> Arc<Spawner> {
    Arc::new(
        Spawner::new(
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
        )
        .with_goal(true),
    )
}

fn drain(h: &mut Harness) {
    while let Ok(input) = h.rx.recv_timeout(Duration::from_millis(150)) {
        h.brain.step(input);
    }
}

fn spawn(h: &mut Harness) -> String {
    let sp = spawner(h);
    let worker = std::thread::spawn(move || sp.spawn(vec![TASK.to_owned()], None));
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    drain(h);
    worker.join().unwrap().unwrap();
    let inner = h.agents.inner.lock().unwrap();
    let k = inner
        .specs
        .iter()
        .position(|s| s.tags.contains_key("optchat.subagent"))
        .expect("a subagent session");
    format!("s{}", k + 1)
}

fn session(id: &str, status: &str) -> cmux_chief::acp::SessionSummary {
    serde_json::from_value(json!({
        "sessionId": id, "name": "a1", "status": status, "harness": "claude",
    }))
    .unwrap()
}

fn changed(h: &mut Harness, id: &str, status: &str) {
    h.brain
        .step(Input::from(AgentEvent::SessionChanged(session(id, status))));
    drain(h);
}

fn said(text: &str) -> Value {
    update(
        "agent_message_chunk",
        json!({"content": {"type": "text", "text": text}}),
    )
}

/// acpmux's record of one of the harness's background shells (`hub/processes.rs`).
fn process(id: &str, state: &str) -> Value {
    json!({"dir": "mux", "kind": "process_update", "msg": {"process": {
        "id": format!("s/{id}"), "state": state, "origin": "background",
        "description": "wait for the red and green fleet steps"}}})
}

/// The notice acpmux sends when that work ends, and the run it starts.
fn notice_run(words: &str) -> Vec<Value> {
    vec![
        process("bwait1", "exited"),
        json!({"dir": "mux", "kind": "user_message", "msg": {
            "_meta": {"provenance": {"from": "fromAgent", "fromName": "acpmux", "kind": "notice",
                "notice": {"sender": "acpmux", "severity": "info", "title": "Background command \"wait for the red and green fleet steps\" completed (exit code 0)"}}},
            "client": "acpmux", "promptId": "bg-done-bwait1",
            "text": "[notice from acpmux] Background command completed"}}),
        json!({"dir": "mux", "kind": "turn_started", "msg": {"client": "acpmux", "persons": false, "promptId": "bg-done-bwait1"}}),
        said(words),
        json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
    ]
}

/// Its first run: the steps go to the fleet, a background wait is armed, and the run ends.
fn waiting_run(words: &'static str) -> impl Fn() -> Vec<Value> + Send + Sync + 'static {
    move || {
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            process("bwait1", "running"),
            said(words),
            json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
        ]
    }
}

fn script(first: impl Fn() -> Vec<Value> + Send + Sync + 'static) -> Script {
    Box::new(move |turn, blocks| {
        let text: String = blocks.iter().filter_map(|b| b["text"].as_str()).collect();
        if text.contains(TASK) && !text.contains("[a1]") {
            first()
        } else {
            default_script()(turn, blocks)
        }
    })
}

/// Prompts the Chief's turns got (the subagent's own prompts left out).
fn chief_turns(h: &Harness, sid: &str) -> usize {
    let inner = h.agents.inner.lock().unwrap();
    inner.prompt_sessions.iter().filter(|s| *s != sid).count()
}

/// Reports of a1 the Chief's log holds.
fn reports(h: &Harness) -> Vec<String> {
    h.log()
        .into_iter()
        .filter(|(_, t)| t.starts_with("[a1]"))
        .map(|(_, t)| t)
        .collect()
}

#[test]
fn a_run_that_ends_to_wait_on_its_own_background_work_wakes_no_chief_turn() {
    let mut h = Harness::new(script(waiting_run(
        "Red and green are on the fleet now. Both are still running; I report when they end.",
    )));
    h.connect();
    let sid = spawn(&mut h);
    let before = chief_turns(&h, &sid);
    changed(&mut h, &sid, "idle");
    assert_eq!(
        chief_turns(&h, &sid),
        before,
        "a waiting report starts no Chief turn: {:?}",
        h.log()
    );
    let state = h.brain.state();
    let (_, sub) = state.sub("a1").unwrap();
    assert!(sub.waiting_ms > 0, "it is held as waiting: {sub:?}");
    assert!(sub.waiting(), "a waiting subagent's task goes on");
    assert!(
        h.brain.untold_outcomes().is_empty(),
        "no outcome is owed for a status: {:?}",
        h.brain.untold_outcomes()
    );

    // Its wait ends: the notice starts its next run, which lands. That report is its outcome.
    h.agents.append_events(
        &sid,
        notice_run("Red failed and green passed. Landed 1a2b3c4d..5e6f7a8b on feat-cmux-next."),
    );
    changed(&mut h, &sid, "running");
    changed(&mut h, &sid, "idle");
    assert_eq!(
        chief_turns(&h, &sid),
        before + 1,
        "the run after the wait wakes the Chief: {:?}",
        h.log()
    );
    let got = reports(&h);
    assert!(
        got.last()
            .is_some_and(|r| r.contains("Landed 1a2b3c4d..5e6f7a8b")),
        "{got:?}"
    );
    let state = h.brain.state();
    let (_, sub) = state.sub("a1").unwrap();
    assert_eq!(sub.waiting_ms, 0, "no longer waiting: {sub:?}");
}

#[test]
fn a_report_that_asks_or_landed_wakes_the_chief_even_with_work_in_the_background() {
    for words in [
        "Red is still running. Should I delete the scratch branch? Reply `yes` or `no`.",
        "Landed 1a2b3c4d..5e6f7a8b. The cleanup wait is still running.",
        "Still waiting for your reply before I push.",
    ] {
        let mut h = Harness::new(script(waiting_run(words)));
        h.connect();
        let sid = spawn(&mut h);
        let before = chief_turns(&h, &sid);
        changed(&mut h, &sid, "idle");
        assert_eq!(
            chief_turns(&h, &sid),
            before + 1,
            "{words:?} reaches the Chief: {:?}",
            h.log()
        );
        let state = h.brain.state();
        assert_eq!(state.sub("a1").unwrap().1.waiting_ms, 0, "{words:?}");
    }
}

#[test]
fn a_report_with_no_background_work_left_wakes_the_chief() {
    let mut h = Harness::new(script(|| {
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            process("bwait1", "running"),
            process("bwait1", "exited"),
            said("The steps are still running; I report when they end."),
            json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
        ]
    }));
    h.connect();
    let sid = spawn(&mut h);
    let before = chief_turns(&h, &sid);
    changed(&mut h, &sid, "idle");
    assert_eq!(
        chief_turns(&h, &sid),
        before + 1,
        "nothing will wake it: the Chief hears now: {:?}",
        h.log()
    );
}

/// A daemon task (`bg_start`) counts as pending work until its notice comes.
#[test]
fn a_daemon_background_task_counts_until_its_notice() {
    let mut h = Harness::new(script(|| {
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "tool_call_update",
                json!({"toolCallId": "t1", "status": "completed", "content": [{"type": "content", "content": {"type": "text",
                    "text": "{\"call_log\":[{\"name\":\"acpmux_bg_start\",\"ok\":true}],\"result\":\"bg-0123456789ab\"}"}}]}),
            ),
            said("The CI loop is still following the queued runs. I report once all of them pass."),
            json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
        ]
    }));
    h.connect();
    let sid = spawn(&mut h);
    let before = chief_turns(&h, &sid);
    changed(&mut h, &sid, "idle");
    assert_eq!(chief_turns(&h, &sid), before, "held: {:?}", h.log());

    h.agents.append_events(
        &sid,
        vec![
            json!({"dir": "mux", "kind": "user_message", "msg": {
                "_meta": {"provenance": {"kind": "agent_digest", "messages": [{"class": "result", "from": "acpmux",
                    "promptId": "bg-done-bg-0123456789ab", "provenance": {"bgTaskId": "bg-0123456789ab", "kind": "notice"}}]}},
                "client": "acpmux", "promptId": "bg-done-bg-0123456789ab", "text": "[notice from acpmux] done"}}),
            json!({"dir": "mux", "kind": "turn_started", "msg": {"client": "acpmux", "promptId": "bg-done-bg-0123456789ab"}}),
            said("All runs passed. Landed 1a2b3c4d..5e6f7a8b."),
            json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
        ],
    );
    changed(&mut h, &sid, "running");
    changed(&mut h, &sid, "idle");
    assert_eq!(chief_turns(&h, &sid), before + 1, "{:?}", h.log());
}

/// The tick: a held subagent whose background work ended without a new run reaches the Chief.
#[test]
fn a_held_subagent_whose_work_ended_without_waking_it_reaches_the_chief() {
    let mut h = Harness::new(script(waiting_run(
        "Red and green are still running on the fleet; I report when they end.",
    )));
    h.connect();
    let clock = Arc::new(Mutex::new(1_800_000_000_000u64));
    let c = clock.clone();
    h.brain.set_clock(Arc::new(move || *c.lock().unwrap()));
    let sid = spawn(&mut h);
    let before = chief_turns(&h, &sid);
    changed(&mut h, &sid, "idle");
    assert_eq!(chief_turns(&h, &sid), before, "held: {:?}", h.log());

    // Its harness went away with the wait (hibernation): the process is lost, no notice comes.
    h.agents
        .append_events(&sid, vec![process("bwait1", "lost")]);
    *clock.lock().unwrap() += 11 * MIN;
    h.brain.step(Input::SubTick);
    drain(&mut h);
    assert_eq!(
        chief_turns(&h, &sid),
        before + 1,
        "the Chief hears it stopped waiting: {:?}",
        h.log()
    );
    let got = reports(&h);
    assert!(
        got.last()
            .is_some_and(|r| r.contains("still running on the fleet")),
        "with its last words: {got:?}"
    );
    let state = h.brain.state();
    let (_, sub) = state.sub("a1").unwrap();
    assert_eq!(sub.waiting_ms, 0, "no longer held: {sub:?}");
    assert!(
        matches!(sub.status, SubStatus::Done | SubStatus::Reported),
        "{:?}",
        sub.status
    );
}

/// The tick: a held subagent still waiting after WAIT_SURFACE_AFTER reaches the Chief once.
#[test]
fn a_subagent_waiting_past_the_limit_reaches_the_chief_once() {
    let mut h = Harness::new(script(waiting_run(
        "Red and green are still queued on the fleet; I report when they end.",
    )));
    h.connect();
    let clock = Arc::new(Mutex::new(1_800_000_000_000u64));
    let c = clock.clone();
    h.brain.set_clock(Arc::new(move || *c.lock().unwrap()));
    let sid = spawn(&mut h);
    let before = chief_turns(&h, &sid);
    changed(&mut h, &sid, "idle");
    for _ in 0..20 {
        *clock.lock().unwrap() += 10 * MIN;
        h.brain.step(Input::SubTick);
        drain(&mut h);
    }
    assert_eq!(
        chief_turns(&h, &sid),
        before + 1,
        "one Chief turn after the limit, not one per tick: {:?}",
        h.log()
    );
}
