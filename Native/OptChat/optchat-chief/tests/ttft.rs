//! Time to first token (parity item 10): every `request` trace event says
//! how long the model took to answer the request (`headers_ms`, to Claude
//! Code's `message_start`) and to stream its first token (`ttft_ms`, to the
//! first content delta), both from acpmux's event times, measured from what
//! started the request: the prompt for the first, a tool result for the
//! next. `turn.end` says how long the turn waited for its session before the
//! prompt went out (`start_ms`) and the first request's `ttft_ms`.

mod common;

use common::*;
use optchat_chief::trace::Trace;
use serde_json::{Value, json};

fn at(mut event: Value, ms: u64) -> Value {
    event["at"] = json!(ms);
    event
}

fn raw(kind: &str, msg: Value) -> Value {
    json!({"dir": "in", "kind": kind, "msg": msg})
}

fn stream(event: Value) -> Value {
    raw(
        "claude.stream_event",
        json!({"type": "stream_event", "event": event}),
    )
}

fn assistant(id: &str) -> Value {
    raw(
        "claude.assistant",
        json!({"type": "assistant", "message": {"id": id, "model": "m", "usage": {"input_tokens": 1, "cache_read_input_tokens": 2, "cache_creation_input_tokens": 3, "output_tokens": 4}}}),
    )
}

fn delta() -> Value {
    stream(json!({"type": "content_block_delta", "delta": {"type": "text_delta", "text": "x"}}))
}

fn script() -> Script {
    Box::new(|_, _| {
        vec![
            at(json!({"dir": "mux", "kind": "turn_started", "msg": {}}), 990),
            at(
                json!({"dir": "out", "kind": "claude.stdin", "msg": {"type": "user"}}),
                1_000,
            ),
            at(
                stream(json!({"type": "message_start", "message": {"id": "m1"}})),
                1_400,
            ),
            at(delta(), 1_900),
            at(delta(), 2_000),
            at(assistant("m1"), 2_500),
            at(
                update(
                    "tool_call",
                    json!({"toolCallId": "t1", "title": "Bash", "rawInput": {"command": "ls"}, "_meta": {"claude": {"tool": "Bash"}}}),
                ),
                2_500,
            ),
            at(
                raw(
                    "claude.user",
                    json!({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1", "content": "a"}]}}),
                ),
                3_000,
            ),
            at(
                update(
                    "tool_call_update",
                    json!({"toolCallId": "t1", "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": "a"}}]}),
                ),
                3_000,
            ),
            at(
                stream(json!({"type": "message_start", "message": {"id": "m2"}})),
                3_200,
            ),
            at(delta(), 3_500),
            at(assistant("m2"), 3_600),
            at(
                update(
                    "agent_message_chunk",
                    json!({"content": {"type": "text", "text": "done"}}),
                ),
                3_600,
            ),
            at(json!({"dir": "mux", "kind": "turn_end", "msg": {}}), 3_700),
        ]
    })
}

#[test]
fn requests_and_turns_record_time_to_first_token() {
    let mut h = Harness::new(script());
    let traces = h.dir.path().join("traces");
    h.brain.set_trace(Trace::open(&traces, false).unwrap());
    h.connect();
    h.say("user_local", "hi");
    h.settle();
    let events = optchat_chief::report::read(&traces, 0).unwrap();
    let requests: Vec<&Value> = events.iter().filter(|e| e["ev"] == "request").collect();
    assert_eq!(requests.len(), 2, "{events:?}");
    assert_eq!(requests[0]["headers_ms"], 400, "{:?}", requests[0]);
    assert_eq!(requests[0]["ttft_ms"], 900, "{:?}", requests[0]);
    assert_eq!(requests[1]["headers_ms"], 200, "{:?}", requests[1]);
    assert_eq!(requests[1]["ttft_ms"], 500, "{:?}", requests[1]);
    let end = events
        .iter()
        .find(|e| e["ev"] == "turn.end")
        .expect("turn.end");
    assert_eq!(end["ttft_ms"], 900, "{end:?}");
    assert!(end["start_ms"].is_u64(), "{end:?}");
}

/// A Claude Code subagent's stream (its lines carry `parent_tool_use_id`)
/// never stands for the turn's own request.
#[test]
fn a_subagents_stream_is_not_the_turns_first_token() {
    let mut h = Harness::new(Box::new(|_, _| {
        let mut sub = stream(json!({"type": "message_start", "message": {"id": "s1"}}));
        sub["msg"]["parent_tool_use_id"] = json!("toolu_1");
        let mut sub_delta = delta();
        sub_delta["msg"]["parent_tool_use_id"] = json!("toolu_1");
        vec![
            at(
                json!({"dir": "out", "kind": "claude.stdin", "msg": {"type": "user"}}),
                1_000,
            ),
            at(sub, 1_100),
            at(sub_delta, 1_200),
            at(
                stream(json!({"type": "message_start", "message": {"id": "m1"}})),
                1_500,
            ),
            at(delta(), 1_700),
            at(assistant("m1"), 1_800),
            at(json!({"dir": "mux", "kind": "turn_end", "msg": {}}), 1_900),
        ]
    }));
    let traces = h.dir.path().join("traces");
    h.brain.set_trace(Trace::open(&traces, false).unwrap());
    h.connect();
    h.say("user_local", "hi");
    h.settle();
    let events = optchat_chief::report::read(&traces, 0).unwrap();
    let request = events
        .iter()
        .find(|e| e["ev"] == "request")
        .expect("request");
    assert_eq!(request["headers_ms"], 500, "{request:?}");
    assert_eq!(request["ttft_ms"], 700, "{request:?}");
}
