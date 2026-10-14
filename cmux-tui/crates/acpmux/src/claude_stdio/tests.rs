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

/// Stop that Claude Code answers late: acpmux ends the turn itself and sends
/// the next prompt, and the stopped turn's result ends only its own prompt.
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

/// A slash command Claude Code runs itself (`/permissions`, `/config`,
/// `/clear`) answers in one synthetic line and a result with no turn and no
/// API time, which is also what a resumed process's startup noise looks like.
/// That result ends the prompt; before, the chat stayed running with Stop doing
/// nothing (cosmic-gray, 2026-10-14). Lines as Claude Code 2.1.299 prints them.
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

/// One chat over Claude Code's stdio, for the Stop tests below. `named`:
/// results name the lines they end (`user_message_uuids`, Claude Code
/// 2.1.299); without it, results name nothing (older versions).
struct Chat {
    t: Arc<Translator>,
    named: bool,
}

impl Chat {
    fn new(named: bool) -> Self {
        Self { t: Translator::new("acp-1".into(), "default", "haiku", "default"), named }
    }

    /// The user line a prompt (or, with `steer`, a steer) went out as.
    async fn send(&self, id: i64, text: &str, steer: bool) -> Value {
        let mut params = json!({"sessionId": "acp-1", "prompt": [{"type": "text", "text": text}]});
        if steer {
            params["_meta"] = json!({"steer": true});
        }
        let Outbound::Lines(lines) =
            self.t.outbound(&Message::request(id, method::SESSION_PROMPT, params)).await
        else {
            panic!("prompt {id} was not sent")
        };
        lines[0].clone()
    }

    /// Stop: the hub's cancel. It ends the turn itself when Claude Code is slow.
    async fn stop(&self) {
        let cancel = Message::notification(method::SESSION_CANCEL, json!({"sessionId": "acp-1"}));
        self.t.outbound(&cancel).await;
    }

    async fn echo(&self, line: &Value) -> Vec<Message> {
        self.t.inbound(&json!({"type": "user", "isReplay": true, "uuid": line["uuid"], "message": line["message"]})).await
    }

    async fn say(&self, text: &str) -> Vec<Message> {
        self.t.inbound(&json!({"type": "assistant", "message": {"id": text, "role": "assistant", "content": [{"type": "text", "text": text}]}})).await
    }

    /// A result for the turn `lines` started (and the lines it read on the way).
    async fn result(&self, mut result: Value, lines: &[&Value]) -> Vec<Message> {
        if self.named {
            result["user_message_uuid"] = lines[0]["uuid"].clone();
            result["user_message_uuids"] = lines.iter().map(|l| l["uuid"].clone()).collect();
        }
        self.t.inbound(&result).await
    }

    /// How many interrupts acpmux queued for Claude Code's stdin.
    async fn interrupts(&self) -> usize {
        let replies = self.t.take_stdin_replies().await;
        replies.iter().filter(|r| r["request"]["subtype"] == "interrupt").count()
    }
}

fn interrupted() -> Value {
    json!({"type": "result", "subtype": "error_during_execution", "is_error": true, "num_turns": 2, "duration_api_ms": 0})
}

fn finished(text: &str) -> Value {
    json!({"type": "result", "subtype": "success", "is_error": false, "num_turns": 1, "duration_api_ms": 900, "result": text})
}

/// The stop reason `msgs` answer prompt `want` with ("error" for an error).
fn stop_reason(msgs: &[Message], want: i64) -> Option<String> {
    msgs.iter().find_map(|m| match m {
        Message::Response { id, result, .. } if *id == want => Some(
            result.as_ref().and_then(|r| r["stopReason"].as_str()).unwrap_or("error").to_owned(),
        ),
        _ => None,
    })
}

/// Two Stops in a row while Claude Code is stuck in the first turn: it reads
/// the second prompt only after the first turn's late result, so that prompt
/// is stopped too, and only the third prompt's own turn answers the third.
#[tokio::test]
async fn two_forced_stops_in_a_row_leave_the_third_prompt_its_own_turn() {
    for named in [false, true] {
        let chat = Chat::new(named);
        let first = chat.send(1, "run the slow build", false).await;
        chat.echo(&first).await;
        chat.say("building").await;
        chat.stop().await;
        let second = chat.send(2, "name three fruits", false).await;
        chat.stop().await;
        let third = chat.send(3, "name three trees", false).await;
        chat.interrupts().await;

        let msgs = chat.result(interrupted(), &[&first]).await;
        assert_eq!(stop_reason(&msgs, 1).as_deref(), Some("cancelled"), "named {named}: {msgs:?}");
        assert_eq!(stop_reason(&msgs, 3), None, "named {named}: the first turn ended the third");

        chat.echo(&second).await;
        assert_eq!(chat.interrupts().await, 1, "named {named}: the stopped second prompt ran on");
        chat.say("apple").await;
        let msgs = chat.result(interrupted(), &[&second]).await;
        assert_eq!(stop_reason(&msgs, 3), None, "named {named}: the second turn ended the third");
        assert_eq!(stop_reason(&msgs, 2).as_deref(), Some("cancelled"), "named {named}: {msgs:?}");

        chat.echo(&third).await;
        assert_eq!(chat.interrupts().await, 0, "named {named}: the third prompt was stopped");
        chat.say("oak").await;
        let msgs = chat.result(finished("oak"), &[&third]).await;
        assert_eq!(stop_reason(&msgs, 3).as_deref(), Some("end_turn"), "named {named}: {msgs:?}");
    }
}

/// A steer Claude Code had not read when Stop came: it runs as one more turn
/// after the stopped one's late result, which the Stop still stops, and the
/// next prompt's answer comes only from that prompt's own turn.
#[tokio::test]
async fn a_steer_read_after_a_forced_stop_is_stopped_and_never_ends_the_next_prompt() {
    for named in [false, true] {
        let chat = Chat::new(named);
        let first = chat.send(1, "run the slow build", false).await;
        chat.echo(&first).await;
        chat.say("building").await;
        let steer = chat.send(10, "use release mode", true).await;
        chat.stop().await;
        let second = chat.send(2, "name three fruits", false).await;
        chat.interrupts().await;

        let msgs = chat.result(interrupted(), &[&first]).await;
        assert_eq!(stop_reason(&msgs, 2), None, "named {named}: the stopped turn ended prompt 2");

        let msgs = chat.echo(&steer).await;
        assert_eq!(stop_reason(&msgs, 10).as_deref(), Some("steered"), "named {named}: {msgs:?}");
        assert_eq!(chat.interrupts().await, 1, "named {named}: the stopped steer ran on");
        let msgs = chat.result(interrupted(), &[&steer]).await;
        assert_eq!(stop_reason(&msgs, 2), None, "named {named}: the steer's turn ended prompt 2");
        assert_eq!(stop_reason(&msgs, 1).as_deref(), Some("cancelled"), "named {named}: {msgs:?}");

        chat.echo(&second).await;
        chat.say("apple").await;
        let msgs = chat.result(finished("apple"), &[&second]).await;
        assert_eq!(stop_reason(&msgs, 2).as_deref(), Some("end_turn"), "named {named}: {msgs:?}");
    }
}

/// A slash command Claude Code runs itself sent right after a forced Stop:
/// Claude Code does not echo `/permissions`, so its result is told from the
/// stopped turn's by order, or by the line the result names.
#[tokio::test]
async fn a_local_command_after_a_forced_stop_gets_its_own_result() {
    let local_result = |text: &str| json!({"type": "result", "subtype": "success", "is_error": false, "num_turns": 0, "duration_api_ms": 0, "result": text});
    let said = "/permissions isn't available in this environment.";
    let synthetic = json!({"type": "assistant", "local_command_outcome": {"kind": "unavailable_headless"}, "message": {"id": "s1", "model": "<synthetic>", "role": "assistant", "content": [{"type": "text", "text": said}]}});
    for named in [false, true] {
        let chat = Chat::new(named);
        let first = chat.send(1, "run the slow build", false).await;
        chat.echo(&first).await;
        chat.say("building").await;
        chat.stop().await;
        let local = chat.send(2, "/permissions", false).await;

        let msgs = chat.result(interrupted(), &[&first]).await;
        assert_eq!(stop_reason(&msgs, 1).as_deref(), Some("cancelled"), "named {named}: {msgs:?}");
        assert_eq!(
            stop_reason(&msgs, 2),
            None,
            "named {named}: the stopped turn ended /permissions"
        );
        chat.t.inbound(&synthetic).await;
        let msgs = chat.result(local_result(said), &[&local]).await;
        assert_eq!(stop_reason(&msgs, 2).as_deref(), Some("end_turn"), "named {named}: {msgs:?}");
    }

    // Claude Code took the Stop while idle and wrote no result for it: the
    // command's result names its own line, so it ends the command too.
    let chat = Chat::new(true);
    chat.send(1, "/cost", false).await;
    chat.stop().await;
    let local = chat.send(2, "/permissions", false).await;
    chat.t.inbound(&synthetic).await;
    let msgs = chat.result(local_result(said), &[&local]).await;
    assert_eq!(stop_reason(&msgs, 2).as_deref(), Some("end_turn"), "{msgs:?}");
    assert_eq!(stop_reason(&msgs, 1).as_deref(), Some("cancelled"), "{msgs:?}");
}

/// A stopped turn's late result still ends its foreground subagents.
#[tokio::test]
async fn a_forced_stops_late_result_cancels_its_foreground_subagents() {
    for named in [false, true] {
        let chat = Chat::new(named);
        let first = chat.send(1, "review the diff", false).await;
        chat.echo(&first).await;
        chat.t.inbound(&json!({"type": "assistant", "message": {"id": "a1", "role": "assistant", "content": [{"type": "tool_use", "id": "toolu_sub", "name": "Agent", "input": {"description": "Review", "prompt": "review it"}}]}})).await;
        chat.stop().await;
        chat.send(2, "name three fruits", false).await;
        let msgs = chat.result(interrupted(), &[&first]).await;
        let cancelled = msgs.iter().any(|m| {
            matches!(m, Message::Notification { params: Some(p), .. }
                if p["update"]["sessionUpdate"] == "subagent_state_update"
                    && p["update"]["subagentSessionId"] == "acp-1/toolu_sub"
                    && p["update"]["state"] == "cancelled")
        });
        assert!(cancelled, "named {named}: the stopped turn's subagent ran on: {msgs:?}");
    }
}
