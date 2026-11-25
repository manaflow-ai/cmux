//! One task, one report. Seen live on build 108 (4d3e8ff, cmux-lawrence-2, 2026-11-18): a Chief
//! restart cut subagent a2's turn, the Chief told it to go on, and the host then logged "subagent
//! a2 finished / queued its report" three times for one task: (1) for the turn the restart cut,
//! though the Chief's new prompt was already queued behind it; (2) for the real report; (3) for
//! a turn an acpmux notice ("Background command finished") started after that report, under its
//! goal, which only said again what the report said.

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::brain::Input;
use optchat_chief::state::SubStatus;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;
use serde_json::{Value, json};

const TASK: &str = "Run the long command and report its output.";

fn spawner(h: &Harness, goal: bool) -> Arc<Spawner> {
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
        .with_goal(goal),
    )
}

fn drain(h: &mut Harness) {
    while let Ok(input) = h.rx.recv_timeout(Duration::from_millis(150)) {
        h.brain.step(input);
    }
}

fn spawn(h: &mut Harness, goal: bool) -> String {
    let sp = spawner(h, goal);
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

/// Reports of a1 in the Chief's log.
fn reports(h: &Harness) -> Vec<String> {
    h.log()
        .into_iter()
        .filter(|(_, t)| t.starts_with("[a1]"))
        .map(|(_, t)| t)
        .collect()
}

/// The subagent's own turn: its first prompt (the task) gets `first`, every
/// other prompt (the Chief's turns) the default reply.
fn script(first: fn() -> Vec<Value>) -> Script {
    Box::new(move |turn, blocks| {
        let text: String = blocks.iter().filter_map(|b| b["text"].as_str()).collect();
        if text.contains(TASK) && !text.contains("[a1]") {
            first()
        } else {
            default_script()(turn, blocks)
        }
    })
}

/// (1) The restart cut its turn (acpmux: `turn_end` stopReason cancelled, the agent closed), and
/// the Chief's next prompt is already queued behind it when the reopened session goes idle. The
/// cut turn is not its end: it is still running, and its one report is the next turn's.
#[test]
fn a_cut_turn_with_a_newer_prompt_queued_behind_it_is_not_reported() {
    let mut h = Harness::new(script(|| {
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            said("Started the long command."),
            json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "cancelled"}}),
        ]
    }));
    h.connect();
    let sid = spawn(&mut h, true);
    // The Chief's tell reaches the closed session: acpmux logs the prompt, the
    // session reopens idle before its turn starts.
    h.agents.append_events(
        &sid,
        vec![
            json!({"dir": "mux", "kind": "status", "msg": {"status": "closed"}}),
            json!({"dir": "mux", "kind": "user_message", "msg": {"promptId": "optchat-tell:a1:1", "text": "Your session closed before you reported. Finish your task."}}),
            json!({"dir": "mux", "kind": "status", "msg": {"status": "idle"}}),
        ],
    );
    changed(&mut h, &sid, "idle");
    let status = h.brain.state().sub("a1").map(|(_, s)| s.status);
    assert_eq!(
        status,
        Some(SubStatus::Running),
        "its next prompt is queued: {:?}",
        h.log()
    );
    assert!(
        reports(&h).is_empty(),
        "no report for the cut turn: {:?}",
        reports(&h)
    );

    h.agents.append_events(
        &sid,
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {"promptId": "optchat-tell:a1:1"}}),
            said("The command printed slept."),
            json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
        ],
    );
    changed(&mut h, &sid, "running");
    changed(&mut h, &sid, "idle");
    let got = reports(&h);
    assert_eq!(got.len(), 1, "one report: {got:?}");
    assert!(got[0].contains("printed slept"), "{got:?}");
}

fn notice_turn() -> Vec<Value> {
    vec![
        json!({"dir": "mux", "kind": "user_message", "msg": {
            "_meta": {"provenance": {"from": "fromAgent", "fromName": "acpmux", "kind": "notice",
                "notice": {"sender": "acpmux", "severity": "info", "title": "Background command finished: sleep 150 (exit 0)"}}},
            "client": "acpmux", "promptId": "bg-done-bg-1",
            "text": "[notice from acpmux] Background command finished: sleep 150 (exit 0)"}}),
        json!({"dir": "mux", "kind": "turn_started", "msg": {"client": "acpmux", "persons": false, "promptId": "bg-done-bg-1"}}),
        said("The background command finished with exit 0, as my report said."),
        json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
    ]
}

fn chief_prompts(h: &Harness) -> usize {
    h.agents.inner.lock().unwrap().prompts.len()
}

/// (3) Under its goal a subagent stops only when its task is done, so a turn that only an acpmux
/// notice started after its report adds nothing to wake the Chief for: it goes in quietly.
#[test]
fn a_notice_turn_after_a_goal_subagents_report_does_not_wake_the_chief() {
    let mut h = Harness::new(script(|| {
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            said("Done: the command printed slept."),
            json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
        ]
    }));
    h.connect();
    let sid = spawn(&mut h, true);
    changed(&mut h, &sid, "idle");
    assert_eq!(reports(&h).len(), 1, "its report: {:?}", h.log());
    let before = chief_prompts(&h);

    h.agents.append_events(&sid, notice_turn());
    changed(&mut h, &sid, "running");
    changed(&mut h, &sid, "idle");
    assert_eq!(
        chief_prompts(&h),
        before,
        "no Chief turn for the notice turn: {:?}",
        h.log()
    );
    let status = h.brain.state().sub("a1").map(|(_, s)| s.status);
    assert!(
        matches!(status, Some(SubStatus::Done | SubStatus::Reported)),
        "{status:?}"
    );
}

/// Without the goal a subagent may end its turn while it waits on a background command; the
/// notice turn is where its result comes, so that one still reaches the Chief.
#[test]
fn a_notice_turn_without_the_goal_still_reports() {
    let mut h = Harness::new(script(|| {
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            said("Waiting on the background command."),
            json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
        ]
    }));
    h.connect();
    let sid = spawn(&mut h, false);
    changed(&mut h, &sid, "idle");
    assert_eq!(reports(&h).len(), 1, "its first report: {:?}", h.log());

    h.agents.append_events(&sid, notice_turn());
    changed(&mut h, &sid, "running");
    changed(&mut h, &sid, "idle");
    let got = reports(&h);
    assert_eq!(
        got.len(),
        2,
        "the notice turn's result reaches the Chief: {got:?}"
    );
}

/// Live on build 108 of 5c8273a (cmux-lawrence-2, 2026-11-18): `cmux chief shutdown` mid-turn
/// closed subagent a1's session with no turn end. At the restart the host reported "(stopped
/// without a report: its session is Closed)", the Chief started a second subagent for the same
/// task, and when its tell reopened a1 the stale close was reported once more. The host resumes
/// the run itself, once, and a close with a newer prompt queued behind it is not an end.
#[test]
fn a_session_closed_mid_run_is_resumed_once_and_reports_once() {
    let mut h = Harness::new(Box::new(|turn, blocks| {
        let text: String = blocks.iter().filter_map(|b| b["text"].as_str()).collect();
        if text.contains(TASK) && !text.contains("[a1]") {
            // Its harness ends with the Chief's daemon: no turn end.
            vec![
                json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
                said("Started the long command."),
                json!({"dir": "mux", "kind": "exited", "at": 1, "msg": {"code": null}}),
                json!({"dir": "mux", "kind": "status", "at": 1, "msg": {"status": "closed"}}),
            ]
        } else if text.contains("session closed") {
            vec![
                json!({"dir": "mux", "kind": "user_message", "msg": {"promptId": "optchat-tell:a1:9"}}),
                json!({"dir": "mux", "kind": "status", "msg": {"status": "idle"}}),
                json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
                said("The command printed slept."),
                json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
            ]
        } else {
            default_script()(turn, blocks)
        }
    }));
    h.connect();
    let sid = spawn(&mut h, true);
    // Its harness ended with the last host (the close is stamped before this host started).
    let sub_prompts = |h: &Harness| {
        let inner = h.agents.inner.lock().unwrap();
        inner
            .prompts
            .iter()
            .zip(&inner.prompt_sessions)
            .filter(|(_, s)| **s == sid)
            .map(|(b, _)| serde_json::to_string(b).unwrap())
            .collect::<Vec<_>>()
    };
    changed(&mut h, &sid, "closed");
    assert!(
        reports(&h).is_empty(),
        "no report for the close: {:?}",
        reports(&h)
    );
    let prompts = sub_prompts(&h);
    assert_eq!(prompts.len(), 2, "the host resumed it: {prompts:?}");
    assert!(prompts[1].contains("session closed"), "{prompts:?}");

    // The stale close reaches the host after the resume prompt.
    changed(&mut h, &sid, "closed");
    assert!(
        reports(&h).is_empty(),
        "the stale close is no end: {:?}",
        reports(&h)
    );
    assert_eq!(
        sub_prompts(&h).len(),
        2,
        "resumed once: {:?}",
        sub_prompts(&h)
    );

    changed(&mut h, &sid, "idle");
    let got = reports(&h);
    assert_eq!(got.len(), 1, "one report: {got:?}");
    assert!(got[0].contains("printed slept"), "{got:?}");
}
