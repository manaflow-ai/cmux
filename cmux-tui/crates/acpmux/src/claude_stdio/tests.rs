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
    let plan =
        spawn_plan(&profile, Some("abc"), false, None, Some("high"), "default", Some("opus"));
    assert_eq!(plan.program, "sr");
    assert_eq!(&plan.args[..3], &["claude", "proxy", "-p"]);
    assert!(plan.args.windows(2).any(|w| w == ["--resume", "abc"]));
    assert!(plan.args.windows(2).any(|w| w == ["--effort", "high"]));
    assert!(plan.args.windows(2).any(|w| w == ["--model", "opus"]));
    assert!(plan.args.windows(2).any(|w| w == ["--permission-mode", "default"]));
}

#[tokio::test]
async fn unknown_permission_option_denies() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let msgs = t.inbound(&json!({"type": "control_request", "request_id": "r1", "request": {"subtype": "can_use_tool", "tool_name": "Bash", "input": {"command": "ls"}, "tool_use_id": "tu1"}})).await;
    let Message::Request { id, .. } = &msgs[0] else { panic!() };
    let Outbound::Lines(lines) = t
        .outbound(&Message::ok(
            id.clone(),
            json!({"outcome": {"outcome": "selected", "optionId": "forged"}}),
        ))
        .await
    else {
        panic!()
    };
    assert_eq!(lines[0]["response"]["response"]["behavior"], "deny");
}

#[tokio::test]
async fn rejected_model_change_keeps_the_old_model() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.outbound(&Message::request(5, method::SESSION_SET_MODEL, json!({"modelId": "opus"}))).await;
    assert_eq!(t.config_options_value().await[0]["currentValue"], "haiku");
    let msgs = t.inbound(&json!({"type": "control_response", "response": {"subtype": "error", "request_id": "ctl-5", "error": "no"}})).await;
    assert!(matches!(&msgs[0], Message::Response { error: Some(_), .. }));
    assert_eq!(t.config_options_value().await[0]["currentValue"], "haiku");
    t.outbound(&Message::request(6, method::SESSION_SET_MODEL, json!({"modelId": "opus"}))).await;
    t.inbound(&json!({"type": "control_response", "response": {"subtype": "success", "request_id": "ctl-6"}})).await;
    assert_eq!(t.config_options_value().await[0]["currentValue"], "opus");
}

#[tokio::test]
async fn failed_initialize_is_an_error() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.outbound(&Message::request(1, method::INITIALIZE, json!({}))).await;
    let msgs = t.inbound(&json!({"type": "control_response", "response": {"subtype": "error", "request_id": "init-1", "error": "bad"}})).await;
    assert!(matches!(&msgs[0], Message::Response { error: Some(_), .. }));
}

#[tokio::test]
async fn max_turns_ends_the_prompt_and_startup_errors_answer_it() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.outbound(&Message::request(
        2,
        method::SESSION_PROMPT,
        json!({"prompt": [{"type": "text", "text": "q"}]}),
    ))
    .await;
    let msgs = t.inbound(&json!({"type": "result", "subtype": "error_max_turns", "is_error": true, "num_turns": 3, "duration_api_ms": 9})).await;
    match &msgs[0] {
        Message::Response { result, error: None, .. } => {
            assert_eq!(result.as_ref().unwrap()["stopReason"], "max_turn_requests")
        }
        _ => panic!(),
    }
    t.outbound(&Message::request(
        3,
        method::SESSION_PROMPT,
        json!({"prompt": [{"type": "text", "text": "q"}]}),
    ))
    .await;
    let msgs = t.inbound(&json!({"type": "result", "subtype": "success", "is_error": true, "result": "limit", "num_turns": 0, "duration_api_ms": 0})).await;
    assert!(matches!(&msgs[0], Message::Response { error: Some(_), .. }));
}

#[tokio::test]
async fn unsupported_control_request_is_answered() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let msgs = t.inbound(&json!({"type": "control_request", "request_id": "h1", "request": {"subtype": "hook_callback"}})).await;
    assert!(msgs.is_empty());
    let replies = t.take_stdin_replies().await;
    assert_eq!(replies[0]["response"]["subtype"], "error");
    assert_eq!(replies[0]["response"]["request_id"], "h1");
}

#[tokio::test]
async fn embedded_resource_reaches_claude() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let req = Message::request(
        4,
        method::SESSION_PROMPT,
        json!({"prompt": [{"type": "resource", "resource": {"uri": "file:///a.rs", "text": "fn a() {}"}}]}),
    );
    let Outbound::Lines(lines) = t.outbound(&req).await else { panic!() };
    let text = lines[0]["message"]["content"][0]["text"].as_str().unwrap();
    assert!(text.contains("file:///a.rs") && text.contains("fn a() {}"), "{text}");
}
