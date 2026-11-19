//! Each turn shows the open items the host knows, so the Chief's sleep notes
//! need not carry them as prose.
//!
//! Measured on Lawrence's Chief, Nov 15-19 (plans/cmux-next/chief-local-improvements.md,
//! item 3): 1,310 sleep notes, 726 with "owe(d)"; each one is a hand-kept list of
//! subagents, their state and what is still owed to the person ("a1176 Settings
//! (bench, OLD..NEW owed), a1185 Cmd+F (0/60), ..."), up to 700 characters, read
//! again on every wake. The only host line was "Subagents at work now: a1, a3."
//! The same status reached the person 3+ times on 130 of 208 subagent-days.
//!
//! Now the turn's tail holds `<open-items>`: one row per subagent at work or
//! waiting (title, state and for how long, its last report's first words, and
//! whether a post named it since that report), and the finished subagents whose
//! outcome no post told yet.

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::brain::Input;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;
use serde_json::{Value, json};

const TASK: &str = "Run the red and green fleet steps and land the fix.";
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

/// Its first run: a background wait is armed, and the run ends to wait.
fn waiting_then(words: &'static str) -> Vec<Value> {
    vec![
        json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
        process("bwait1", "running"),
        said(words),
        json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
    ]
}

/// The Chief's turns: on "how is it" it names a1 in its reply.
fn chief_names_a1(first: fn() -> Vec<Value>) -> Script {
    Box::new(move |turn, blocks| {
        let text: String = blocks.iter().filter_map(|b| b["text"].as_str()).collect();
        if text.contains(TASK) && !text.contains("[a1]") && !text.contains("open-items") {
            first()
        } else if text.contains("how is it") {
            vec![
                json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
                said("a1 still waits on the fleet steps."),
                json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
            ]
        } else {
            default_script()(turn, blocks)
        }
    })
}

fn turn_with(h: &Harness, needle: &str) -> String {
    let inner = h.agents.inner.lock().unwrap();
    inner
        .prompts
        .iter()
        .map(|p| Value::Array(p.clone()).to_string())
        .rfind(|p| p.contains(needle))
        .unwrap_or_else(|| panic!("no turn with {needle:?}"))
}

#[test]
fn each_turn_lists_open_subagents_with_state_last_report_and_whether_it_was_told() {
    let mut h = Harness::new(chief_names_a1(|| {
        waiting_then(
            "Red and green are on the fleet now. Both are still running; I report when they end.",
        )
    }));
    h.connect();
    let sid = spawn(&mut h);
    changed(&mut h, &sid, "idle");

    h.say("user_local", "how is it going?");
    h.settle_posts();
    let turn = turn_with(&h, "how is it going?");
    assert!(turn.contains("<open-items>"), "{turn}");
    assert!(
        turn.contains("Subagents at work now: a1."),
        "the at-work rule stays: {turn}"
    );
    assert!(
        turn.contains("- a1 · Run the red and green fleet"),
        "a row with its title: {turn}"
    );
    assert!(turn.contains("waiting"), "its state: {turn}");
    assert!(
        turn.contains("Red and green are on the fleet now."),
        "its last report's first words: {turn}"
    );
    assert!(turn.contains("not told yet"), "no post named it: {turn}");

    // That turn's reply named a1: the next turn's row says it was told.
    h.say("user_local", "and now?");
    h.settle_posts();
    let turn = turn_with(&h, "and now?");
    let row = turn
        .split("- a1 ·")
        .nth(1)
        .and_then(|r| r.split("\\n").next())
        .unwrap_or_else(|| panic!("a row for a1: {turn}"))
        .to_owned();
    assert!(row.contains(", told"), "{row}");
    assert!(!row.contains("not told"), "{row}");
}

#[test]
fn a_finished_subagent_no_post_told_is_listed_as_not_told() {
    let mut h = Harness::new(chief_names_a1(|| {
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            said("Landed 1a2b3c4d..5e6f7a8b on feat-cmux-next; red failed and green passed."),
            json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
        ]
    }));
    h.connect();
    let sid = spawn(&mut h);
    changed(&mut h, &sid, "idle");
    h.settle();
    h.say("user_local", "anything else?");
    h.settle();
    let turn = turn_with(&h, "anything else?");
    assert!(
        turn.contains("Finished, not told yet: a1 (Run the red and green fleet"),
        "{turn}"
    );
}

#[test]
fn no_open_items_no_block() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "hello there");
    h.settle_posts();
    let turn = turn_with(&h, "hello there");
    assert!(!turn.contains("<open-items>"), "{turn}");
}
