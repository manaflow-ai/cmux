//! Unit tests for the Claude stdio translator.

use super::*;

#[tokio::test]
async fn prompt_becomes_user_line_and_result_answers_it() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let req = Message::request(
        7,
        method::SESSION_PROMPT,
        json!({"sessionId": "acp-1", "prompt": [{"type": "text", "text": "hi"}]}),
    );
    let Outbound::Lines(lines) = t.outbound(&req).await else { panic!() };
    assert_eq!(lines[0]["type"], "user");
    assert_eq!(lines[0]["message"]["content"][0]["text"], "hi");
    let msgs = t.inbound(&json!({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "yo"}}})).await;
    assert!(
        matches!(&msgs[0], Message::Notification { method, .. } if method == method::SESSION_UPDATE)
    );
    let msgs = t.inbound(&json!({"type": "result", "subtype": "success", "result": "yo"})).await;
    match &msgs[0] {
        Message::Response { id, result, .. } => {
            assert_eq!(*id, Value::from(7));
            assert_eq!(result.as_ref().unwrap()["stopReason"], "end_turn");
        }
        _ => panic!(),
    }
}

/// A steer Claude Code reads after the reply it is writing (cx-f51kv): the
/// reply's text and the steer's answer are two API messages, and each chunk
/// names its message, so the pane ends the reply where its message ends.
#[tokio::test]
async fn text_chunks_carry_their_message_id() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let start = |id: &str| json!({"type": "stream_event", "event": {"type": "message_start", "message": {"id": id, "model": "claude-haiku"}}});
    let text = |s: &str| json!({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": s}}});
    let mut ids = Vec::new();
    for line in [start("msg_1"), text("The Sun also rises."), start("msg_2"), text("DONE")] {
        for m in t.inbound(&line).await {
            if let Message::Notification { params, .. } = m
                && let Some(u) = params.as_ref().and_then(|p| p.get("update"))
                && u["sessionUpdate"] == "agent_message_chunk"
            {
                ids.push((u["content"]["text"].clone(), u["messageId"].clone()));
            }
        }
    }
    assert_eq!(
        ids,
        vec![(json!("The Sun also rises."), json!("msg_1")), (json!("DONE"), json!("msg_2"))]
    );
}
