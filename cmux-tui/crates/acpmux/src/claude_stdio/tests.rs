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

#[tokio::test]
async fn interrupt_result_is_cancelled() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.outbound(&Message::request(
        1,
        method::SESSION_PROMPT,
        json!({"prompt": [{"type": "text", "text": "go"}]}),
    ))
    .await;
    let Outbound::Lines(lines) =
        t.outbound(&Message::notification(method::SESSION_CANCEL, json!({}))).await
    else {
        panic!()
    };
    assert_eq!(lines[0]["request"]["subtype"], "interrupt");
    let msgs = t.inbound(&json!({"type": "result", "subtype": "error_during_execution", "is_error": true, "result": null})).await;
    match &msgs[0] {
        Message::Response { result, .. } => {
            assert_eq!(result.as_ref().unwrap()["stopReason"], "cancelled")
        }
        _ => panic!(),
    }
}

#[tokio::test]
async fn resume_startup_result_is_ignored() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.outbound(&Message::request(
        3,
        method::SESSION_PROMPT,
        json!({"prompt": [{"type": "text", "text": "q"}]}),
    ))
    .await;
    let noise = t.inbound(&json!({"type": "result", "subtype": "success", "result": "", "num_turns": 0, "duration_api_ms": 0})).await;
    assert!(noise.is_empty(), "startup result must not answer the prompt");
    let real = t.inbound(&json!({"type": "result", "subtype": "success", "result": "A", "num_turns": 1, "duration_api_ms": 500})).await;
    assert!(matches!(&real[0], Message::Response { id, .. } if *id == 3));
}

#[tokio::test]
async fn permission_round_trip() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let msgs = t.inbound(&json!({"type": "control_request", "request_id": "abc", "request": {"subtype": "can_use_tool", "tool_name": "Write", "input": {"file_path": "/x/y.txt", "content": "ok"}, "tool_use_id": "tu1"}})).await;
    let Message::Request { id, method: m, params } = &msgs[0] else { panic!() };
    assert_eq!(m, method::SESSION_REQUEST_PERMISSION);
    assert_eq!(params.as_ref().unwrap()["toolCall"]["title"], "Write y.txt");
    let Outbound::Lines(lines) = t
        .outbound(&Message::ok(
            id.clone(),
            json!({"outcome": {"outcome": "selected", "optionId": "allow_once"}}),
        ))
        .await
    else {
        panic!()
    };
    assert_eq!(lines[0]["response"]["request_id"], "abc");
    assert_eq!(lines[0]["response"]["response"]["behavior"], "allow");
}

#[test]
fn wrapper_words_come_before_claude_flags() {
    let profile = crate::config::HarnessProfile {
        kind: crate::config::HarnessKind::ClaudeStdio,
        argv: vec!["sr".into(), "claude".into(), "proxy".into()],
        env: Default::default(),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let plan = spawn_plan(&profile, Some("abc"), false, None, Some("high"), "default");
    assert_eq!(plan.program, "sr");
    assert_eq!(&plan.args[..3], &["claude", "proxy", "-p"]);
    assert!(plan.args.windows(2).any(|w| w == ["--resume", "abc"]));
    assert!(plan.args.windows(2).any(|w| w == ["--effort", "high"]));
    assert!(plan.args.windows(2).any(|w| w == ["--permission-mode", "default"]));
}
