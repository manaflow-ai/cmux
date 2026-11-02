//! Claude Code's /context after each turn (`get_context_usage`, its answer as a trimmed
//! `contextBreakdown`) and its MCP reconnect (`MCP_RECONNECT`). Lines as Claude Code 2.1.305
//! writes them.

use super::*;

fn breakdowns(msgs: &[Message]) -> Vec<Value> {
    msgs.iter()
        .filter_map(|m| match m {
            Message::Notification { params, .. } => {
                params.as_ref()?.pointer("/update/_meta/acpmux/contextBreakdown").cloned()
            }
            _ => None,
        })
        .collect()
}

/// A turn whose result came; returns the line acpmux wrote to Claude Code after it.
async fn ended_turn(t: &Translator) -> Vec<Value> {
    let prompt = Message::request(
        1,
        method::SESSION_PROMPT,
        json!({"sessionId": "acp-1", "prompt": [{"type": "text", "text": "hi"}]}),
    );
    let Outbound::Lines(_) = t.outbound(&prompt).await else { panic!() };
    t.inbound(
        &json!({"type": "assistant", "message": {"content": [{"type": "text", "text": "yo"}]}}),
    )
    .await;
    t.inbound(&json!({"type": "result", "subtype": "success", "result": "yo", "num_turns": 1}))
        .await;
    t.take_stdin_replies().await
}

#[tokio::test]
async fn a_turns_result_asks_for_the_context_and_its_answer_is_trimmed() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let written = ended_turn(&t).await;
    assert_eq!(written.len(), 1, "{written:?}");
    assert_eq!(written[0]["request"], json!({"subtype": "get_context_usage", "detail": "summary"}));
    let rid = written[0]["request_id"].clone();
    let answer = json!({"type": "control_response", "response": {"subtype": "success", "request_id": rid, "response": {
        "categories": [
            {"id": "system_prompt", "name": "System prompt", "tokens": 3000, "color": "promptBorder", "kind": "used"},
            {"name": "MCP tools (deferred)", "tokens": 900, "color": "inactive", "isDeferred": true, "kind": "deferred"},
            {"id": "free_space", "name": "Free space", "tokens": 196100, "color": "promptBorder", "kind": "free"},
        ],
        "totalTokens": 3900, "maxTokens": 200000, "rawMaxTokens": 200000, "percentage": 2,
        "gridRows": [[{"color": "purple", "isFilled": true, "categoryName": "Messages", "tokens": 1, "percentage": 1, "squareFullness": 1}]],
        "model": "claude-haiku",
        "memoryFiles": [{"path": "/repo/CLAUDE.md", "type": "Project", "tokens": 120}],
        "mcpTools": [
            {"name": "mcp__cmux__a", "serverName": "cmux", "tokens": 40, "isLoaded": true},
            {"name": "mcp__cmux__b", "serverName": "cmux", "tokens": 60},
        ],
        "agents": [],
        "skills": {"totalSkills": 1, "includedSkills": 1, "tokens": 30, "skillFrontmatter": [{"name": "pdf", "source": "user", "tokens": 30}]},
        "isAutoCompactEnabled": true,
    }}});
    assert!(is_context_answer(&answer));
    let msgs = t.inbound(&answer).await;
    assert_eq!(
        breakdowns(&msgs),
        vec![json!({
            "categories": [
                {"id": "system_prompt", "name": "System prompt", "tokens": 3000, "kind": "used"},
                {"name": "MCP tools (deferred)", "tokens": 900, "kind": "deferred"},
                {"id": "free_space", "name": "Free space", "tokens": 196100, "kind": "free"},
            ],
            "memoryFiles": [{"path": "/repo/CLAUDE.md", "type": "Project", "tokens": 120}],
            "mcpTools": [
                {"name": "mcp__cmux__b", "serverName": "cmux", "tokens": 60},
                {"name": "mcp__cmux__a", "serverName": "cmux", "tokens": 40},
            ],
            "skills": [{"name": "pdf", "tokens": 30}],
            "totalTokens": 3900,
            "maxTokens": 200000,
        })]
    );
    // It goes to the chat's own session, as a session_info_update.
    let Message::Notification { params, .. } = &msgs[0] else { panic!("{msgs:?}") };
    let params = params.as_ref().unwrap();
    assert_eq!(params["sessionId"], "acp-1");
    assert_eq!(params["update"]["sessionUpdate"], "session_info_update");
}

/// An older Claude Code refuses the request, and one may answer without categories: the chat
/// keeps no breakdown, and the refusal answers nothing.
#[tokio::test]
async fn a_context_refusal_leaves_no_breakdown() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let written = ended_turn(&t).await;
    let rid = written[0]["request_id"].clone();
    let refused = json!({"type": "control_response", "response": {"subtype": "error", "request_id": rid,
        "error": "get_context_usage is not supported in this context (onGetContextUsage callback not registered)"}});
    assert!(t.inbound(&refused).await.is_empty());
    let empty = json!({"type": "control_response", "response": {"subtype": "success", "request_id": rid, "response": {}}});
    assert!(t.inbound(&empty).await.is_empty());
}

#[tokio::test]
async fn an_mcp_reconnect_names_its_server_and_answers_as_claude_code_does() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let ask = |id: i64, server: &str| {
        Message::request(id, MCP_RECONNECT, json!({"sessionId": "acp-1", "server": server}))
    };
    let Outbound::Lines(lines) = t.outbound(&ask(4, "github")).await else { panic!() };
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert_eq!(lines[0]["request"], json!({"subtype": "mcp_reconnect", "serverName": "github"}));
    let ok = json!({"type": "control_response", "response": {"subtype": "success", "request_id": lines[0]["request_id"], "response": {}}});
    let msgs = t.inbound(&ok).await;
    assert!(
        matches!(&msgs[..], [Message::Response { id, result: Some(r), error: None }] if *id == 4 && *r == json!({})),
        "{msgs:?}"
    );

    let Outbound::Lines(lines) = t.outbound(&ask(5, "linear")).await else { panic!() };
    let refused = json!({"type": "control_response", "response": {"subtype": "error", "request_id": lines[0]["request_id"], "error": "Server status: failed"}});
    let msgs = t.inbound(&refused).await;
    assert!(
        matches!(&msgs[..], [Message::Response { id, error: Some(e), .. }] if *id == 5 && e.message == "Server status: failed"),
        "{msgs:?}"
    );

    // No server: refused before Claude Code is asked.
    let Outbound::Reply(Message::Response { error: Some(_), .. }) = t.outbound(&ask(6, "")).await
    else {
        panic!("an empty server name was sent")
    };
}
