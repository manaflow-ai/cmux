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

/// A slash command Claude Code runs itself (`/permissions`, `/config`,
/// `/clear`) answers in one synthetic line and a result with no turn and no
/// API time, which is also what a resumed process's startup noise looks like.
/// That result ends the prompt; before, the chat stayed running with Stop doing
/// nothing (cosmic-gray, 2026-10-14). Lines as Claude Code 2.1.299 prints them.
#[tokio::test]
async fn a_late_result_for_a_stopped_prompt_ends_only_that_prompt() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let prompt = |id: i64, text: &str| {
        Message::request(
            id,
            method::SESSION_PROMPT,
            json!({"sessionId": "acp-1", "prompt": [{"type": "text", "text": text}]}),
        )
    };
    let answered = |msgs: &[Message], want: i64| {
        msgs.iter().any(|m| matches!(m, Message::Response { id, .. } if *id == want))
    };
    let echo = |lines: &[Value]| json!({"type": "user", "isReplay": true, "uuid": lines[0]["uuid"], "message": lines[0]["message"]});
    let result = json!({"type": "result", "subtype": "success", "is_error": false, "num_turns": 2, "duration_api_ms": 900, "result": "done"});

    let Outbound::Lines(first) = t.outbound(&prompt(1, "run the slow build")).await else {
        panic!()
    };
    t.inbound(&echo(&first)).await;
    t.inbound(&json!({"type": "assistant", "message": {"id": "a1", "role": "assistant", "content": [{"type": "text", "text": "building"}]}})).await;
    // Stop: Claude Code is slow to answer the interrupt, so acpmux ends the turn
    // itself (hub/cancel.rs) and sends the next prompt before that result comes.
    let Outbound::Lines(second) = t.outbound(&prompt(2, "name three fruits")).await else {
        panic!()
    };
    let msgs = t.inbound(&result).await;
    assert!(!answered(&msgs, 2), "the stopped turn's result ended the next prompt: {msgs:?}");
    assert!(answered(&msgs, 1), "the stopped prompt stayed open: {msgs:?}");

    t.inbound(&echo(&second)).await;
    t.inbound(&json!({"type": "assistant", "message": {"id": "a2", "role": "assistant", "content": [{"type": "text", "text": "apple"}]}})).await;
    let msgs = t.inbound(&result).await;
    assert!(answered(&msgs, 2), "the next prompt's own result did not end it: {msgs:?}");
}

#[tokio::test]
async fn a_local_command_result_ends_the_prompt() {
    let local_result = |text: &str| json!({"type": "result", "subtype": "success", "is_error": false, "num_turns": 0, "duration_api_ms": 0, "result": text});
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let prompt = |id: i64, text: &str| {
        Message::request(
            id,
            method::SESSION_PROMPT,
            json!({"sessionId": "acp-1", "prompt": [{"type": "text", "text": text}]}),
        )
    };
    let answered = |msgs: &[Message], want: i64| {
        msgs.iter().any(|m| {
            matches!(m, Message::Response { id, result: Some(r), .. } if *id == want && r["stopReason"] == "end_turn")
        })
    };

    let Outbound::Lines(_) = t.outbound(&prompt(1, "/permissions")).await else { panic!() };
    let said = "/permissions isn't available in this environment.";
    t.inbound(&json!({"type": "assistant", "local_command_outcome": {"kind": "unavailable_headless"}, "message": {"id": "s1", "model": "<synthetic>", "role": "assistant", "content": [{"type": "text", "text": said}]}})).await;
    let msgs = t.inbound(&local_result(said)).await;
    assert!(answered(&msgs, 1), "/permissions left its prompt open: {msgs:?}");

    // /clear says nothing: its reset line comes before the empty result.
    let Outbound::Lines(_) = t.outbound(&prompt(2, "/clear")).await else { panic!() };
    t.inbound(&json!({"type": "system", "subtype": "conversation_reset"})).await;
    let msgs = t.inbound(&local_result("")).await;
    assert!(answered(&msgs, 2), "/clear left its prompt open: {msgs:?}");

    // A resumed process's empty result before anything of the turn is still noise.
    let Outbound::Lines(_) = t.outbound(&prompt(3, "hi")).await else { panic!() };
    let msgs = t.inbound(&local_result("")).await;
    assert!(!answered(&msgs, 3), "startup noise ended the prompt: {msgs:?}");
}
