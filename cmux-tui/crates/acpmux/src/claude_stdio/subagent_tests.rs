//! Claude's Agent (Task) tool becomes a native ACP subagent session: a
//! `subagent_spawned` update, the child's own lines under its session id,
//! and a `subagent_state_update` when the tool returns.

use super::*;

fn updates(msgs: &[Message]) -> Vec<(String, Value)> {
    msgs.iter()
        .filter_map(|m| match m {
            Message::Notification { method: m, params: Some(p) } if m == method::SESSION_UPDATE => {
                Some((p["sessionId"].as_str().unwrap_or("").to_owned(), p["update"].clone()))
            }
            _ => None,
        })
        .collect()
}

fn spawn_line(id: &str, parent: Option<&str>) -> Value {
    json!({
        "type": "assistant",
        "parent_tool_use_id": parent,
        "message": {"content": [{"type": "tool_use", "id": id, "name": "Agent", "input": {
            "description": "Branch A", "prompt": "Look at the tests", "subagent_type": "Explore"
        }}]}
    })
}

#[tokio::test]
async fn an_agent_tool_call_spawns_a_subagent_session() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let out = updates(&t.inbound(&spawn_line("toolu_1", None)).await);
    assert_eq!(out.len(), 2, "{out:?}");
    assert_eq!(out[1].1["sessionUpdate"], "tool_call");
    assert_eq!(out[0].0, "acp-1");
    assert_eq!(
        out[0].1,
        json!({
            "sessionUpdate": "subagent_spawned",
            "subagentSessionId": "acp-1/toolu_1",
            "name": "Branch A",
            "task": "Branch A",
            "prompt": "Look at the tests",
            "capabilities": {},
            "_meta": {"claude": {"subagentType": "Explore", "toolUseId": "toolu_1"}}
        })
    );
}

#[tokio::test]
async fn a_subagents_lines_stream_under_its_own_session() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&spawn_line("toolu_1", None)).await;
    let text = json!({"type": "stream_event", "parent_tool_use_id": "toolu_1", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "reading"}}});
    let read = json!({"type": "assistant", "parent_tool_use_id": "toolu_1", "message": {"content": [{"type": "tool_use", "id": "toolu_2", "name": "Read", "input": {"file_path": "/a/b.rs"}}]}});
    let result = json!({"type": "user", "parent_tool_use_id": "toolu_1", "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_2", "content": "fn main() {}"}]}});
    for line in [text, read, result] {
        let out = updates(&t.inbound(&line).await);
        assert_eq!(out.len(), 1, "{out:?}");
        assert_eq!(out[0].0, "acp-1/toolu_1");
    }
}

#[tokio::test]
async fn a_nested_agent_call_spawns_under_its_parent_subagent() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&spawn_line("toolu_1", None)).await;
    let out = updates(&t.inbound(&spawn_line("toolu_9", Some("toolu_1"))).await);
    assert_eq!(out[0].0, "acp-1/toolu_1");
    assert_eq!(out[0].1["subagentSessionId"], "acp-1/toolu_9");
}

#[tokio::test]
async fn the_agent_tools_result_ends_the_subagent() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.inbound(&spawn_line("toolu_1", None)).await;
    t.inbound(&spawn_line("toolu_3", None)).await;
    let done = |id: &str, is_error: bool| json!({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": id, "content": "report", "is_error": is_error}]}});
    let out = updates(&t.inbound(&done("toolu_1", false)).await);
    assert_eq!(out[0].1["sessionUpdate"], "tool_call_update");
    assert_eq!(
        out[1],
        (
            "acp-1".to_owned(),
            json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": "acp-1/toolu_1", "state": "completed"})
        )
    );
    let out = updates(&t.inbound(&done("toolu_3", true)).await);
    assert_eq!(out[1].1["state"], "failed");
}

#[tokio::test]
async fn a_cancelled_turn_cancels_its_running_subagents() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.outbound(&Message::request(
        1,
        method::SESSION_PROMPT,
        json!({"prompt": [{"type": "text", "text": "go"}]}),
    ))
    .await;
    t.inbound(&spawn_line("toolu_1", None)).await;
    t.outbound(&Message::notification(method::SESSION_CANCEL, json!({}))).await;
    let msgs = t.inbound(&json!({"type": "result", "subtype": "error_during_execution", "is_error": true, "result": null})).await;
    let out = updates(&msgs);
    assert_eq!(
        out,
        [(
            "acp-1".to_owned(),
            json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": "acp-1/toolu_1", "state": "cancelled"})
        )]
    );
}
