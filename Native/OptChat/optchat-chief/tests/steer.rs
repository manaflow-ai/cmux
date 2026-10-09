//! A message the user sends during a turn reaches the model between its
//! tool calls (parity item 7): the brain steers it into the running acpmux
//! session (Claude Code reads it at its next tool boundary) instead of
//! stopping the turn; the turn's one reply answers both, and the message is
//! logged once, as `user`. A session that cannot steer falls back to the
//! stop of decision 2026-10-04 (audit3.rs covers that path).

mod common;

use common::*;
use serde_json::{Value, json};

fn tool_in_flight() -> Vec<Value> {
    vec![
        json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
        update(
            "agent_message_chunk",
            json!({"content": {"type": "text", "text": "Running the build."}}),
        ),
        update(
            "tool_call",
            json!({"toolCallId": "t0", "title": "Bash", "status": "in_progress", "rawInput": {"command": "make"}, "_meta": {"claude": {"tool": "Bash"}}}),
        ),
    ]
}

fn rest() -> Vec<Value> {
    vec![
        update(
            "tool_call_update",
            json!({"toolCallId": "t0", "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": "build ok"}}]}),
        ),
        update(
            "agent_message_chunk",
            json!({"content": {"type": "text", "text": "Built, and the tests pass."}}),
        ),
        json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
    ]
}

#[test]
fn a_message_during_a_turn_is_steered_in_not_a_stop() {
    let mut h = Harness::new(Box::new(|turn, _| {
        assert_eq!(turn, 0, "one turn answers both messages");
        tool_in_flight()
    }));
    h.agents.inner.lock().unwrap().steering = true;
    h.agents.hold(true);
    h.connect();
    h.say("user_local", "build it");
    h.step(); // settled: the turn starts
    h.agents.wait_prompts(1);
    h.say("user_local", "also run the tests");
    h.agents.wait_steers(1);
    h.agents.push_events("s1", rest());
    h.agents.hold(false);
    h.agents.release();
    h.settle();
    let inner = h.agents.inner.lock().unwrap();
    assert!(inner.cancels.is_empty(), "no stop: {:?}", inner.cancels);
    assert_eq!(inner.prompts.len(), 1, "no second turn");
    assert_eq!(inner.steers.len(), 1);
    assert_eq!(inner.steers[0].0, "s1");
    let text: Vec<&str> = inner.steers[0]
        .1
        .iter()
        .filter_map(|b| b["text"].as_str())
        .collect();
    assert_eq!(text, vec!["also run the tests"]);
    drop(inner);
    let users: Vec<String> = h
        .log()
        .into_iter()
        .filter(|(k, _)| k == "user")
        .map(|(_, t)| t)
        .collect();
    assert_eq!(
        users,
        vec!["build it", "also run the tests"],
        "logged once each"
    );
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(sends.len(), 1, "{sends:?}");
    assert_eq!(sends[0].1, "Built, and the tests pass.");
}
