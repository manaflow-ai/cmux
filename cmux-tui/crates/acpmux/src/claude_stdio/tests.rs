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

/// Claude Code's stream-json bridge accepts a client `side_question` control
/// request while its main turn is running. It answers with the callback's
/// payload, without an ACP prompt or transcript event.
#[tokio::test]
async fn native_side_question_uses_claude_control_protocol() {
    let t = Translator::new("acp-1".into(), "default", "sonnet", "default");
    let req = Message::request(
        19,
        SIDE_QUESTION,
        json!({
            "question": "what does this function do?",
            "history": [{"question": "earlier", "response": "already answered"}]
        }),
    );
    let Outbound::Lines(lines) = t.outbound(&req).await else { panic!() };
    assert_eq!(
        lines,
        vec![json!({
            "type": "control_request",
            "request_id": "side-19",
            "request": {
                "subtype": "side_question",
                "question": "what does this function do?",
                "history": [{"question": "earlier", "response": "already answered"}]
            }
        })]
    );

    let msgs = t
        .inbound(&json!({
            "type": "control_response",
            "response": {
                "subtype": "success",
                "request_id": "side-19",
                "response": {"response": "It reads the file.", "synthetic": false}
            }
        }))
        .await;
    assert!(matches!(
        &msgs[..],
        [Message::Response { id, result: Some(result), error: None }]
            if *id == 19 && result["response"] == "It reads the file." && result["synthetic"] == false
    ));
}

#[tokio::test]
async fn native_side_question_rejects_missing_answer_callback() {
    let t = Translator::new("acp-1".into(), "default", "sonnet", "default");
    let req = Message::request(20, SIDE_QUESTION, json!({"question": "probe"}));
    let Outbound::Lines(_) = t.outbound(&req).await else { panic!() };
    let msgs = t
        .inbound(&json!({
            "type": "control_response",
            "response": {
                "subtype": "error",
                "request_id": "side-20",
                "error": "side_question is not supported in this context"
            }
        }))
        .await;
    assert!(matches!(
        &msgs[..],
        [Message::Response { id, result: None, error: Some(error) }]
            if *id == 20 && error.message.contains("side_question is not supported")
    ));
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

/// Claude Code 2.1.303's `/compact`, as it streams it: the compacting status,
/// the boundary, the summary as a synthetic user line, the command's stdout,
/// and a result with no turn and no API time. The prompt ends (before, that
/// result read as startup noise and the chat stayed running), the chat gets a
/// running and a completed `compaction` update, and the summary becomes a
/// `compaction_summary` update. A wrapper's `compact_metadata.reason` is kept.
#[tokio::test]
async fn compact_ends_its_prompt_and_reports_the_compaction() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let prompt = Message::request(
        4,
        method::SESSION_PROMPT,
        json!({"sessionId": "acp-1", "prompt": [{"type": "text", "text": "/compact"}]}),
    );
    let Outbound::Lines(_) = t.outbound(&prompt).await else { panic!() };
    let lines = [
        json!({"type": "system", "subtype": "status", "status": "compacting", "session_id": "s"}),
        json!({"type": "system", "subtype": "status", "status": null, "compact_result": "success", "session_id": "s"}),
        json!({"type": "system", "subtype": "compact_boundary", "session_id": "s", "compact_metadata": {"trigger": "manual", "pre_tokens": 27183, "post_tokens": 2047, "reason": "account_switch"}}),
        json!({"type": "user", "session_id": "s", "parent_tool_use_id": null, "isReplay": false, "isSynthetic": true, "message": {"role": "user", "content": "This session is being continued from a previous conversation. Summary: PLUM-42"}}),
        json!({"type": "user", "session_id": "s", "parent_tool_use_id": null, "isReplay": false, "message": {"role": "user", "content": "<local-command-stdout>Compacted </local-command-stdout>"}}),
        json!({"type": "result", "subtype": "success", "is_error": false, "num_turns": 0, "duration_api_ms": 0, "local_command": "compact", "result": ""}),
    ];
    let mut updates = Vec::new();
    let mut ended = false;
    for line in &lines {
        for m in t.inbound(line).await {
            match m {
                Message::Notification { params, .. } => {
                    if let Some(u) = params.as_ref().and_then(|p| p.get("update")) {
                        updates.push(u.clone());
                    }
                }
                Message::Response { id, result: Some(r), .. } if id == 4 => {
                    ended = r["stopReason"] == "end_turn";
                }
                _ => {}
            }
        }
    }
    assert!(ended, "/compact left its prompt open: {updates:?}");
    let kinds: Vec<&str> = updates.iter().filter_map(|u| u["sessionUpdate"].as_str()).collect();
    assert_eq!(kinds, ["compaction", "compaction", "compaction_summary"], "{updates:?}");
    assert_eq!(updates[0]["state"], "running");
    assert_eq!(
        updates[1],
        json!({"sessionUpdate": "compaction", "state": "completed", "trigger": "manual", "reason": "account_switch", "preTokens": 27183, "postTokens": 2047})
    );
    assert_eq!(
        updates[2]["text"],
        "This session is being continued from a previous conversation. Summary: PLUM-42"
    );

    // A synthetic user line after the compaction's result is not a summary.
    let later = json!({"type": "user", "session_id": "s", "parent_tool_use_id": null, "isSynthetic": true, "message": {"role": "user", "content": "hook text"}});
    let msgs = t.inbound(&later).await;
    assert!(
        !msgs.iter().any(|m| matches!(m, Message::Notification { params, .. } if params.as_ref().and_then(|p| p.pointer("/update/sessionUpdate")) == Some(&json!("compaction_summary")))),
        "{msgs:?}"
    );
}

/// A `/compact` that fails: the compacting status, then a status clearing it
/// with a failed `compact_result`, and the same zero-turn success result. The
/// failed status is the turn's output, so the result ends the prompt rather
/// than read as startup noise, and the chat gets a failed `compaction` that
/// says why (`compact_error`).
#[tokio::test]
async fn a_failed_compact_ends_its_prompt() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let prompt = Message::request(
        5,
        method::SESSION_PROMPT,
        json!({"sessionId": "acp-1", "prompt": [{"type": "text", "text": "/compact"}]}),
    );
    let Outbound::Lines(_) = t.outbound(&prompt).await else { panic!() };
    let lines = [
        json!({"type": "system", "subtype": "status", "status": "compacting", "session_id": "s"}),
        json!({"type": "system", "subtype": "status", "status": null, "compact_result": "failed", "compact_error": "Prompt is too long", "session_id": "s"}),
        json!({"type": "result", "subtype": "success", "is_error": false, "num_turns": 0, "duration_api_ms": 0, "local_command": "compact", "result": ""}),
    ];
    let mut states = Vec::new();
    let mut errors = Vec::new();
    let mut ended = false;
    for line in &lines {
        for m in t.inbound(line).await {
            match m {
                Message::Notification { params, .. } => {
                    if let Some(u) = params.as_ref().and_then(|p| p.get("update")) {
                        states.push(u["state"].clone());
                        errors.push(u.get("error").cloned());
                    }
                }
                Message::Response { id, result: Some(_), .. } if id == 5 => ended = true,
                _ => {}
            }
        }
    }
    assert!(ended, "a failed /compact left its prompt open: {states:?}");
    assert_eq!(states, [json!("running"), json!("failed")]);
    assert_eq!(errors, [None, Some(json!("Prompt is too long"))]);
}

/// The mode menu shows Claude Code's own modes, as Claude Code shows them:
/// its labels, its one-line descriptions and its order (Auto, Manual, Accept
/// edits, Plan, Bypass permissions). acpmux invents none ("Normal", "Full
/// access"); the ids stay Claude Code's `--permission-mode` values.
#[tokio::test]
async fn modes_are_claude_codes_own_labels_descriptions_and_order() {
    let t = Translator::new("acp-1".into(), "bypassPermissions", "haiku", "default");
    let modes = t.modes_value().await;
    assert_eq!(modes["currentModeId"], "bypassPermissions");
    let listed: Vec<(String, String, String)> = modes["availableModes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| {
            let s = |k: &str| m[k].as_str().unwrap_or("").to_owned();
            (s("id"), s("name"), s("description"))
        })
        .collect();
    let want = [
        ("auto", "Auto", "Claude handles permission decisions"),
        ("default", "Manual", "Always ask before making changes"),
        ("acceptEdits", "Accept edits", "Automatically accept all file edits"),
        ("plan", "Plan", "Create a plan before making changes"),
        ("bypassPermissions", "Bypass permissions", "Accepts all permissions"),
    ];
    let want: Vec<(String, String, String)> =
        want.iter().map(|(i, n, d)| (i.to_string(), n.to_string(), d.to_string())).collect();
    assert_eq!(listed, want);
    // The config option offers the same list, in the same order.
    let options = t.config_options_value().await;
    let mode = options.as_array().unwrap().iter().find(|o| o["id"] == "mode").unwrap();
    let values: Vec<&str> =
        mode["options"].as_array().unwrap().iter().filter_map(|o| o["value"].as_str()).collect();
    assert_eq!(values, ["auto", "default", "acceptEdits", "plan", "bypassPermissions"]);
}
