//! ACP `initialize` is answered as it is written to Claude Code, never after Claude Code boots
//! (`outbound.rs`): every start's `session/new` waited out that boot (0.7 to 6.5 s; a production
//! Cloud start never took less than 533 ms).

use super::*;

#[tokio::test]
async fn initialize_is_answered_at_once_and_claude_code_still_asked() {
    let t = Translator::new("acp-1".into(), "default", "opus", "default");
    let out = t.outbound(&Message::request(7, method::INITIALIZE, json!({}))).await;
    let Outbound::LinesThenReply(
        lines,
        Message::Response { id, result: Some(answer), error: None },
    ) = out
    else {
        panic!("initialize answers at once");
    };
    assert_eq!(id, json!(7));
    assert_eq!(lines[0]["request_id"], "init-7", "{lines:?}");
    assert_eq!(lines[0]["request"]["subtype"], "initialize", "{lines:?}");
    assert!(steers_by_info(answer.get("agentInfo")), "{answer}");
    assert_eq!(answer["agentCapabilities"]["loadSession"], true, "{answer}");
    assert_eq!(answer["_meta"]["steering"]["supported"], true, "{answer}");
}

#[tokio::test]
async fn claude_codes_late_answer_brings_its_commands_and_no_second_answer() {
    let t = Translator::new("acp-1".into(), "default", "opus", "default");
    let _ = t.outbound(&Message::request(7, method::INITIALIZE, json!({}))).await;
    let out = t
        .inbound(&json!({"type": "control_response", "response": {"subtype": "success",
            "request_id": "init-7", "response": {"version": "2.1.319",
            "commands": [{"name": "review", "description": "Review a PR", "argumentHint": ""}]}}}))
        .await;
    assert!(!out.iter().any(|m| matches!(m, Message::Response { .. })), "{out:?}");
    assert_eq!(t.slash_commands.lock().await.len(), 1);
    // A failed answer answers nothing either: the hub's `initialize` was answered.
    let failed = t
        .inbound(&json!({"type": "control_response", "response": {"subtype": "error",
            "request_id": "init-8", "error": "boom"}}))
        .await;
    assert!(failed.is_empty(), "{failed:?}");
}
