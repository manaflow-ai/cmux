//! A message steered into a Chief turn after Claude Code's last answer is
//! read by Claude Code in a turn of its own (acpmux carried_turn.rs: the
//! prompt's answer carries `_meta.claude.carried`, the turn_result names
//! `carriedTo`). The Chief turn follows that carried turn, so its answer to
//! the message is posted. Before 2026-11-19 the turn ended at the first
//! `turn_end`: the late message was logged as read, closed by the first
//! answer, and its real answer was never posted (burst2 probe, round 1:
//! a correction 4 s after the ask got no reply).

mod common;

use std::time::Duration;

use common::*;
use serde_json::json;

fn carried_events() -> Vec<serde_json::Value> {
    vec![
        json!({"dir": "mux", "kind": "turn_result", "msg": {"status": "completed", "carriedTo": {"turnId": "t2"}}}),
        json!({"dir": "mux", "kind": "turn_started", "msg": {"carried": ["optchat-steer:x:1"]}}),
        update(
            "agent_message_chunk",
            json!({"content": {"type": "text", "text": "Corrected: 418."}}),
        ),
        json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
        // acpmux writes every turn's result after its end; with no carriedTo
        // the carried turn is the last (no wait for a later one).
        json!({"dir": "mux", "kind": "turn_result", "msg": {"status": "completed"}}),
    ]
}

fn posts(h: &Harness) -> Vec<String> {
    h.owner
        .lock()
        .unwrap()
        .sends()
        .into_iter()
        .map(|(_, text)| text)
        .collect()
}

fn run_carried(answer_meta: bool, result_event: bool) -> Harness {
    let mut h = Harness::new(default_script());
    {
        let mut inner = h.agents.inner.lock().unwrap();
        inner.hold = true;
        if answer_meta {
            inner.answer = Some(json!({"stopReason": "end_turn",
                "_meta": {"claude": {"carried": {"seq": 7, "promptIds": ["optchat-steer:x:1"]}}}}));
        }
    }
    h.connect();
    h.say("user_local", "what is 19 times 21?");
    while h.agents.inner.lock().unwrap().prompts.is_empty() {
        h.step();
    }
    // The fake records the prompt before it appends the turn's own events:
    // the carried turn comes after them, as in acpmux.
    while !h
        .agents
        .inner
        .lock()
        .unwrap()
        .events
        .get("s1")
        .is_some_and(|e| e.iter().any(|e| e.kind == "turn_end"))
    {
        std::thread::yield_now();
    }
    let mut events = carried_events();
    if !result_event {
        events.remove(0);
    }
    h.agents.append_events("s1", events);
    h.agents.hold(false);
    h.settle_posts();
    h
}

#[test]
fn the_turn_follows_a_carried_turn_named_by_its_turn_result_and_the_answer() {
    let h = run_carried(true, true);
    let all = posts(&h).join("\n---\n");
    assert!(all.contains("answer 0"), "the first answer: {all}");
    assert!(all.contains("Corrected: 418."), "the carried answer: {all}");
    assert_eq!(h.agents.inner.lock().unwrap().prompts.len(), 1, "one turn");
}

#[test]
fn the_turn_follows_a_carried_turn_started_with_no_turn_result_read() {
    let h = run_carried(true, false);
    let all = posts(&h).join("\n---\n");
    assert!(all.contains("Corrected: 418."), "the carried answer: {all}");
}

#[test]
fn the_turn_follows_a_carried_turn_that_carries_again() {
    let mut h = Harness::new(default_script());
    {
        let mut inner = h.agents.inner.lock().unwrap();
        inner.hold = true;
        inner.answer = Some(json!({"stopReason": "end_turn",
            "_meta": {"claude": {"carried": {"seq": 7, "promptIds": ["optchat-steer:x:1"]}}}}));
    }
    h.connect();
    h.say("user_local", "what is 19 times 21?");
    while h.agents.inner.lock().unwrap().prompts.is_empty() {
        h.step();
    }
    // The fake records the prompt before it appends the turn's own events:
    // the carried turn comes after them, as in acpmux.
    while !h
        .agents
        .inner
        .lock()
        .unwrap()
        .events
        .get("s1")
        .is_some_and(|e| e.iter().any(|e| e.kind == "turn_end"))
    {
        std::thread::yield_now();
    }
    let mut events = carried_events();
    // This carried turn carries again: its result names the next one.
    events.pop();
    events.push(json!({"dir": "mux", "kind": "turn_result", "msg": {"status": "completed", "carriedTo": {"turnId": "t3"}}}));
    events.push(
        json!({"dir": "mux", "kind": "turn_started", "msg": {"carried": ["optchat-steer:x:2"]}}),
    );
    events.push(update(
        "agent_message_chunk",
        json!({"content": {"type": "text", "text": "And the ttl is 600."}}),
    ));
    events.push(json!({"dir": "mux", "kind": "turn_end", "msg": {}}));
    events.push(json!({"dir": "mux", "kind": "turn_result", "msg": {"status": "completed"}}));
    h.agents.append_events("s1", events);
    h.agents.hold(false);
    h.settle_posts();
    let all = posts(&h).join("\n---\n");
    assert!(
        all.contains("Corrected: 418."),
        "the first carried answer: {all}"
    );
    assert!(
        all.contains("And the ttl is 600."),
        "the second carried answer: {all}"
    );
}

#[test]
fn a_turn_with_no_carry_ends_at_its_turn_end_as_before() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "hello");
    h.settle_posts();
    let all = posts(&h).join("\n---\n");
    assert!(all.contains("answer 0"), "{all}");
    let _ = Duration::from_millis(0);
}

/// A step a `steerNow` message stopped: Claude Code ends it with
/// `error_during_execution` while it writes; its cut words never post, the
/// finished segment before them does, and the carried turn's answer follows.
/// The carried turn's own cost joins the turn's.
#[test]
fn a_step_stopped_for_a_message_drops_its_cut_words_and_the_carried_answer_posts() {
    let script: Script = Box::new(|turn, _| {
        if turn > 0 {
            return Vec::new();
        }
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": "Port is 8443."}}),
            ),
            update(
                "tool_call",
                json!({"toolCallId": "t0", "title": "Bash", "rawInput": {"command": "true"}, "_meta": {"claude": {"tool": "Bash"}}}),
            ),
            update(
                "tool_call_update",
                json!({"toolCallId": "t0", "status": "completed", "content": []}),
            ),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": "The cache ttl is half-wri"}}),
            ),
            json!({"dir": "in", "kind": "claude.result", "msg": {"type": "result", "subtype": "error_during_execution", "is_error": true}}),
            json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "cancelled"}}),
            json!({"dir": "mux", "kind": "turn_result", "msg": {"status": "cancelled", "carriedTo": {"turnId": "t2"}}}),
            json!({"dir": "mux", "kind": "turn_started", "msg": {"carried": {"fromTurnId": "t1", "promptIds": ["optchat-steer:x:1"]}}}),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": "7 times 9 is 63. The cache ttl is 600."}}),
            ),
            json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
            json!({"dir": "mux", "kind": "turn_result", "msg": {"status": "completed", "costUsd": 0.25}}),
        ]
    });
    let mut h = Harness::new(script);
    let traces = h.dir.path().join("traces");
    h.brain
        .set_trace(optchat_chief::trace::Trace::open(&traces, false).unwrap());
    h.agents.inner.lock().unwrap().answer = Some(json!({"stopReason": "cancelled",
        "_meta": {"claude": {"cost_usd": 0.10, "carried": {"seq": 7, "promptIds": ["optchat-steer:x:1"]}}}}));
    h.connect();
    h.say("user_local", "what port, and what ttl?");
    h.settle_posts();
    let all = posts(&h).join("\n---\n");
    assert!(all.contains("Port is 8443."), "the finished segment: {all}");
    assert!(
        all.contains("The cache ttl is 600."),
        "the carried answer: {all}"
    );
    assert!(!all.contains("half-wri"), "no cut words: {all}");
    let cost: f64 = std::fs::read_dir(&traces)
        .unwrap()
        .flatten()
        .flat_map(|e| {
            std::fs::read_to_string(e.path())
                .unwrap()
                .lines()
                .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
                .collect::<Vec<_>>()
        })
        .filter(|e| e["ev"] == "turn.end")
        .filter_map(|e| e["cost_usd"].as_f64())
        .sum();
    assert!(
        (cost - 0.35).abs() < 1e-9,
        "the first and the carried turn: {cost}"
    );
}
