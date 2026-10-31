//! A Claude chat's subagent text stays out of the turn's reply. acpmux logs a
//! subagent's translated updates under its own session (`<acp>/<toolu>`), and
//! since 2026-10-21 it keeps none of the subagent's raw `stream_event` lines, so
//! the fold cannot rely on a raw line before each chunk to say whose it is.

use cmux_chief::acp::AcpmuxEvent;
use optchat_chief::fold::TurnFold;
use serde_json::{Value, json};

const T0: u64 = 1_792_400_000_000;

fn ev(seq: u64, dir: &str, kind: &str, msg: Value) -> AcpmuxEvent {
    serde_json::from_value(
        json!({"seq": seq, "at": T0 + seq, "dir": dir, "kind": kind, "msg": msg}),
    )
    .unwrap()
}

fn update(seq: u64, session: &str, kind: &str, mut update: Value) -> AcpmuxEvent {
    update["sessionUpdate"] = json!(kind);
    ev(
        seq,
        "in",
        kind,
        json!({"method": "session/update", "params": {"sessionId": session, "update": update}}),
    )
}

fn text(seq: u64, session: &str, text: &str) -> AcpmuxEvent {
    update(
        seq,
        session,
        "agent_message_chunk",
        json!({"content": {"type": "text", "text": text}}),
    )
}

#[test]
fn a_subagents_text_is_not_the_turns_reply() {
    let mut fold = TurnFold::new();
    let events = [
        ev(
            1,
            "in",
            "claude.assistant",
            json!({"type": "assistant", "message": {"id": "msg_1", "content": [
                {"type": "tool_use", "id": "toolu_1", "name": "Agent", "input": {"prompt": "look"}}]}}),
        ),
        update(
            2,
            "acp-1",
            "tool_call",
            json!({"toolCallId": "toolu_1", "title": "Agent", "_meta": {"claude": {"tool": "Agent"}}}),
        ),
        // The subagent talks; acpmux logged no raw line of its own before this.
        text(3, "acp-1/toolu_1", "subagent notes"),
        text(4, "acp-1", "the answer"),
        ev(5, "mux", "turn_end", json!({"stopReason": "end_turn"})),
    ];
    for event in &events {
        fold.apply(event);
    }
    assert_eq!(fold.final_text().as_deref(), Some("the answer"));
}

#[test]
fn the_main_agents_text_after_a_background_subagents_line_is_the_reply() {
    let mut fold = TurnFold::new();
    let events = [
        ev(
            1,
            "in",
            "claude.stream_event",
            json!({"type": "stream_event", "event": {"type": "message_start", "message": {"id": "msg_1"}}}),
        ),
        text(2, "acp-1", "the "),
        // A background subagent's raw line; the main agent's later deltas are not logged.
        ev(
            3,
            "in",
            "claude.assistant",
            json!({"type": "assistant", "parent_tool_use_id": "toolu_bg", "message": {"id": "msg_sub",
                   "content": [{"type": "text", "text": "subagent notes"}]}}),
        ),
        text(4, "acp-1/toolu_bg", "subagent notes"),
        text(5, "acp-1", "answer"),
        ev(6, "mux", "turn_end", json!({"stopReason": "end_turn"})),
    ];
    for event in &events {
        fold.apply(event);
    }
    assert_eq!(fold.final_text().as_deref(), Some("the answer"));
}
