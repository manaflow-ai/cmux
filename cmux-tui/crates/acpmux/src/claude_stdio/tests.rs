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
