//! Messages delivered between tool calls (steering): Claude Code reads a
//! user line written to its stdin during a turn at its next tool boundary,
//! and with `--replay-user-messages` echoes it (`isReplay`) when it does
//! (checked live on 2.1.287, 2026-10-08). A steered prompt is answered when
//! its echo arrives; a `result` while a steered line is still unread is not
//! the end of the turn (Claude Code runs that line as one more turn).

use super::*;

fn prompt(id: i64, text: &str, steer: bool) -> Message {
    let mut params = json!({"sessionId": "acp-1", "prompt": [{"type": "text", "text": text}]});
    if steer {
        params["_meta"] = json!({"steer": true});
    }
    Message::request(id, method::SESSION_PROMPT, params)
}

fn replay(text: &str) -> Value {
    json!({"type": "user", "isReplay": true, "message": {"role": "user", "content": [{"type": "text", "text": text}]}})
}

fn turn_result() -> Value {
    json!({"type": "result", "subtype": "success", "result": "ok", "num_turns": 2, "duration_api_ms": 5})
}

fn response(msgs: &[Message], want: i64) -> Option<&Message> {
    msgs.iter().find(|m| matches!(m, Message::Response { id, .. } if *id == Value::from(want)))
}

#[test]
fn the_claude_command_replays_user_messages() {
    let profile = crate::config::HarnessProfile {
        kind: crate::config::HarnessKind::ClaudeStdio,
        argv: vec!["claude".into()],
        env: Default::default(),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let plan = spawn_plan(&profile, None, false, Some("id"), None, "default", None);
    assert!(plan.args.iter().any(|a| a == "--replay-user-messages"), "{:?}", plan.args);
}

#[tokio::test]
async fn initialize_advertises_steering() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.outbound(&Message::request(1, method::INITIALIZE, json!({}))).await;
    let msgs = t
        .inbound(&json!({"type": "control_response", "response": {"subtype": "success", "request_id": "init-1", "response": {}}}))
        .await;
    let Some(Message::Response { result: Some(result), .. }) = response(&msgs, 1) else {
        panic!("{msgs:?}")
    };
    assert_eq!(result.pointer("/_meta/steering/supported"), Some(&json!(true)));
}

#[tokio::test]
async fn a_steered_message_joins_the_running_turn() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.outbound(&prompt(1, "first", false)).await;
    assert!(t.inbound(&replay("first")).await.is_empty());
    let Outbound::Lines(lines) = t.outbound(&prompt(2, "later", true)).await else {
        panic!("a steer during a turn is a stdin line")
    };
    assert_eq!(lines[0]["type"], "user");
    assert_eq!(lines[0]["message"]["content"][0]["text"], "later");
    // Claude Code read it at its next tool boundary: the steer is answered.
    let msgs = t.inbound(&replay("later")).await;
    let Some(Message::Response { result: Some(result), .. }) = response(&msgs, 2) else {
        panic!("{msgs:?}")
    };
    assert_eq!(result["stopReason"], "steered");
    // The turn's own result ends the first prompt.
    let msgs = t.inbound(&turn_result()).await;
    let Some(Message::Response { result: Some(result), .. }) = response(&msgs, 1) else {
        panic!("{msgs:?}")
    };
    assert_eq!(result["stopReason"], "end_turn");
}

#[tokio::test]
async fn a_result_before_the_steered_line_was_read_does_not_end_the_turn() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.outbound(&prompt(1, "first", false)).await;
    t.inbound(&replay("first")).await;
    t.outbound(&prompt(2, "late", true)).await;
    // Claude Code finished before it read the line: it runs it next.
    let msgs = t.inbound(&turn_result()).await;
    assert!(response(&msgs, 1).is_none(), "the turn goes on: {msgs:?}");
    let msgs = t.inbound(&replay("late")).await;
    assert!(response(&msgs, 2).is_some(), "{msgs:?}");
    let msgs = t.inbound(&turn_result()).await;
    let Some(Message::Response { result: Some(result), .. }) = response(&msgs, 1) else {
        panic!("{msgs:?}")
    };
    assert_eq!(result["stopReason"], "end_turn");
}

#[tokio::test]
async fn a_steer_with_no_turn_running_is_refused() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let Outbound::Reply(Message::Response { error: Some(_), .. }) =
        t.outbound(&prompt(2, "late", true)).await
    else {
        panic!("refused")
    };
}

/// A Claude Code that never echoes (no replay support): the turn still ends
/// at its result, and an unconfirmed steer fails instead of hanging.
#[tokio::test]
async fn without_echoes_the_turn_ends_and_the_steer_fails() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.outbound(&prompt(1, "first", false)).await;
    t.outbound(&prompt(2, "later", true)).await;
    let msgs = t.inbound(&turn_result()).await;
    assert!(response(&msgs, 1).is_some(), "{msgs:?}");
    let Some(Message::Response { error: Some(_), .. }) = response(&msgs, 2) else {
        panic!("{msgs:?}")
    };
}
