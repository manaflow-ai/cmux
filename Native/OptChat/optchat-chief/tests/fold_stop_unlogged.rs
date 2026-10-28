//! A `stop` call and its echo carry nothing the memory needs (the turn just
//! ends), yet they were 710 of the Chief's 11,530 logged messages: two view
//! lines and two compactions each. The fold logs neither; other tools stay.

use cmux_chief::acp::AcpmuxEvent;
use optchat_chief::fold::{Entry, TurnFold};
use optchat_core::Kind;
use serde_json::{Value, json};

const T0: u64 = 1_792_400_000_000;

fn update(seq: u64, kind: &str, mut update: Value) -> AcpmuxEvent {
    update["sessionUpdate"] = json!(kind);
    serde_json::from_value(json!({
        "seq": seq, "at": T0 + seq, "dir": "in", "kind": kind,
        "msg": {"method": "session/update", "params": {"sessionId": "acp-1", "update": update}}
    }))
    .unwrap()
}

fn call(seq: u64, id: &str, tool: &str, input: Value) -> [AcpmuxEvent; 2] {
    [
        update(
            seq,
            "tool_call",
            json!({"toolCallId": id, "title": tool, "rawInput": input, "_meta": {"claude": {"tool": tool}}}),
        ),
        update(
            seq + 1,
            "tool_call_update",
            json!({"toolCallId": id, "status": "completed",
                   "content": [{"type": "content", "content": {"type": "text", "text": format!("outcome: done. {tool}")}}]}),
        ),
    ]
}

fn fold(events: &[AcpmuxEvent]) -> Vec<Entry> {
    let mut fold = TurnFold::new();
    events.iter().flat_map(|e| fold.apply(e)).collect()
}

#[test]
fn a_stop_call_and_its_echo_are_not_logged() {
    let mut events = Vec::new();
    events.extend(call(
        1,
        "toolu_1",
        "mcp__optchat__send",
        json!({"text": "hi"}),
    ));
    events.extend(call(3, "toolu_2", "mcp__optchat__stop", Value::Null));
    let entries = fold(&events);
    let texts: Vec<String> = entries
        .iter()
        .map(|e| format!("{:?}: {}", e.kind, e.text))
        .collect();
    assert!(
        !texts.iter().any(|t| t.contains("stop")),
        "stop was logged: {texts:?}"
    );
    assert_eq!(
        entries.iter().filter(|e| e.kind == Kind::Tool).count(),
        1,
        "{texts:?}"
    );
    assert_eq!(
        entries.iter().filter(|e| e.kind == Kind::Echo).count(),
        1,
        "{texts:?}"
    );
}

#[test]
fn a_failed_stop_is_still_logged() {
    let events = [
        update(
            1,
            "tool_call",
            json!({"toolCallId": "toolu_9", "title": "mcp__optchat__stop", "_meta": {"claude": {"tool": "mcp__optchat__stop"}}}),
        ),
        update(
            2,
            "tool_call_update",
            json!({"toolCallId": "toolu_9", "status": "failed",
                   "content": [{"type": "content", "content": {"type": "text", "text": "no socket"}}]}),
        ),
    ];
    let entries = fold(&events);
    assert!(
        entries
            .iter()
            .any(|e| e.kind == Kind::Echo && e.text.contains("no socket")),
        "{:?}",
        entries.iter().map(|e| &e.text).collect::<Vec<_>>()
    );
}
