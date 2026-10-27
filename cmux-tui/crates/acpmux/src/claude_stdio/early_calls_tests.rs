//! A tool call is named as its block starts (`early_calls.rs`), so the chat
//! shows the Write it is waiting on while the file's text streams in.

use super::*;

fn updates(msgs: &[Message]) -> Vec<Value> {
    msgs.iter()
        .filter_map(|m| match m {
            Message::Notification { params, .. } => {
                params.as_ref().and_then(|p| p.get("update")).cloned()
            }
            _ => None,
        })
        .collect()
}

fn block_start(id: &str, name: &str) -> Value {
    json!({"type": "stream_event", "event": {"type": "content_block_start", "index": 1,
        "content_block": {"type": "tool_use", "id": id, "name": name, "input": {}}}})
}

fn whole_call(id: &str, name: &str, input: Value) -> Value {
    json!({"type": "assistant", "message": {"id": "m1", "role": "assistant",
        "content": [{"type": "tool_use", "id": id, "name": name, "input": input}]}})
}

#[tokio::test]
async fn a_tool_call_goes_out_pending_as_its_block_starts_and_its_whole_call_updates_it() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let early = updates(&t.inbound(&block_start("toolu_w", "Write")).await);
    assert_eq!(early.len(), 1);
    assert_eq!(early[0]["sessionUpdate"], "tool_call");
    assert_eq!(early[0]["toolCallId"], "toolu_w");
    assert_eq!(early[0]["status"], "pending");
    assert_eq!(early[0]["title"], "Write");
    assert_eq!(early[0]["kind"], "edit");
    // The input streams in; nothing more goes out until the block ends.
    let delta = json!({"type": "stream_event", "event": {"type": "content_block_delta", "index": 1,
        "delta": {"type": "input_json_delta", "partial_json": "{\"file_path\": \"/a/b.rs\""}}});
    assert!(updates(&t.inbound(&delta).await).is_empty());
    let whole = updates(
        &t.inbound(&whole_call(
            "toolu_w",
            "Write",
            json!({"file_path": "/a/b.rs", "content": "fn main() {}\n"}),
        ))
        .await,
    );
    let call = whole.iter().find(|u| u["toolCallId"] == "toolu_w").expect("the whole call");
    assert_eq!(call["sessionUpdate"], "tool_call_update");
    assert_eq!(call["status"], "in_progress");
    assert_eq!(call["title"], "Write b.rs");
    assert_eq!(call["rawInput"]["file_path"], "/a/b.rs");
}

#[tokio::test]
async fn a_call_not_named_early_still_goes_out_whole() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let whole =
        updates(&t.inbound(&whole_call("toolu_r", "Read", json!({"file_path": "/a/b.rs"}))).await);
    assert_eq!(whole[0]["sessionUpdate"], "tool_call");
}

#[tokio::test]
async fn subagents_the_todo_list_and_questions_are_not_named_early() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    for name in ["Task", "Agent", "Workflow", "TodoWrite", "AskUserQuestion", "ExitPlanMode"] {
        assert!(updates(&t.inbound(&block_start("toolu_x", name)).await).is_empty(), "{name}");
    }
    // A text or thinking block starts nothing either.
    let text = json!({"type": "stream_event", "event": {"type": "content_block_start", "index": 0,
        "content_block": {"type": "text", "text": ""}}});
    assert!(updates(&t.inbound(&text).await).is_empty());
}

#[tokio::test]
async fn a_call_named_early_whose_whole_call_never_came_fails_with_its_turn() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let req = Message::request(
        3,
        method::SESSION_PROMPT,
        json!({"sessionId": "acp-1", "prompt": [{"type": "text", "text": "write it"}]}),
    );
    let _ = t.outbound(&req).await;
    t.inbound(&block_start("toolu_w", "Write")).await;
    let msgs = t
        .inbound(&json!({"type": "result", "subtype": "success", "is_error": false, "num_turns": 1, "duration_api_ms": 900, "result": ""}))
        .await;
    let ended = updates(&msgs);
    assert!(
        ended.iter().any(|u| u["sessionUpdate"] == "tool_call_update"
            && u["toolCallId"] == "toolu_w"
            && u["status"] == "failed"),
        "{ended:?}"
    );
    // The update comes before the prompt's answer.
    let at_update = msgs.iter().position(|m| matches!(m, Message::Notification { .. })).unwrap();
    let at_answer = msgs.iter().position(|m| matches!(m, Message::Response { .. })).unwrap();
    assert!(at_update < at_answer);
}

#[tokio::test]
async fn a_background_subagents_call_named_early_runs_on_past_the_turns_result() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let req = Message::request(
        3,
        method::SESSION_PROMPT,
        json!({"sessionId": "acp-1", "prompt": [{"type": "text", "text": "write it"}]}),
    );
    let _ = t.outbound(&req).await;
    t.background_subagents.lock().await.insert("toolu_bg".to_owned());
    let mut start = block_start("toolu_w", "Write");
    start["parent_tool_use_id"] = json!("toolu_bg");
    t.inbound(&start).await;
    let ended = updates(
        &t.inbound(&json!({"type": "result", "subtype": "success", "is_error": false, "num_turns": 1, "duration_api_ms": 900, "result": ""}))
            .await,
    );
    assert!(!ended.iter().any(|u| u["toolCallId"] == "toolu_w"), "{ended:?}");
    // Its whole call still updates the call named early.
    let mut whole = whole_call("toolu_w", "Write", json!({"file_path": "/a/b.rs", "content": ""}));
    whole["parent_tool_use_id"] = json!("toolu_bg");
    let whole = updates(&t.inbound(&whole).await);
    let call = whole.iter().find(|u| u["toolCallId"] == "toolu_w").expect("the whole call");
    assert_eq!(call["sessionUpdate"], "tool_call_update");
}

#[tokio::test]
async fn a_call_named_early_fails_when_claude_exits_while_its_input_streams() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&block_start("toolu_w", "Write")).await;
    // A background subagent's call ends with the process too.
    t.background_subagents.lock().await.insert("toolu_bg".to_owned());
    let mut start = block_start("toolu_b", "Edit");
    start["parent_tool_use_id"] = json!("toolu_bg");
    t.inbound(&start).await;
    let ended = updates(&t.end_background_shells().await);
    for id in ["toolu_w", "toolu_b"] {
        assert!(
            ended.iter().any(|u| u["sessionUpdate"] == "tool_call_update"
                && u["toolCallId"] == id
                && u["status"] == "failed"),
            "{id}: {ended:?}"
        );
    }
}

#[tokio::test]
async fn a_background_subagents_call_named_early_fails_when_the_subagent_ends() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let spawn = whole_call(
        "toolu_bg",
        "Agent",
        json!({"description": "look around", "prompt": "look", "run_in_background": true}),
    );
    t.inbound(&spawn).await;
    t.background_subagents.lock().await.insert("toolu_bg".to_owned());
    let mut start = block_start("toolu_w", "Write");
    start["parent_tool_use_id"] = json!("toolu_bg");
    t.inbound(&start).await;
    let stopped = json!({"type": "system", "subtype": "task_notification", "task_id": "task-1",
        "tool_use_id": "toolu_bg", "status": "stopped"});
    let ended = updates(&t.inbound(&stopped).await);
    assert!(
        ended.iter().any(|u| u["sessionUpdate"] == "subagent_state_update"),
        "the subagent ends: {ended:?}"
    );
    assert!(
        ended.iter().any(|u| u["sessionUpdate"] == "tool_call_update"
            && u["toolCallId"] == "toolu_w"
            && u["status"] == "failed"),
        "{ended:?}"
    );
}
