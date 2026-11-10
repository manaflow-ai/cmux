//! The `acpmux-github` SDK MCP server (`github_mcp.rs`): a remote chain's Claude Code reaches the
//! GitHub broker over its own stdio, and only a chat the hub turned it on for has it.

use super::github_mcp::{SERVER, action_of};
use super::*;

fn mcp(rid: &str, server: &str, message: Value) -> Value {
    json!({"type": "control_request", "request_id": rid, "request": {
        "subtype": "mcp_message", "server_name": server, "message": message}})
}

fn on() -> Arc<Translator> {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    t.github_broker.store(true, Ordering::SeqCst);
    t
}

async fn init_request(t: &Translator) -> Value {
    let Outbound::Lines(lines) =
        t.outbound(&Message::request(7, method::INITIALIZE, json!({}))).await
    else {
        panic!("initialize is a line for Claude Code");
    };
    lines[0]["request"].clone()
}

/// Only a chat the hub turned it on for names the server at `initialize`; `--strict-mcp-config`
/// and the empty server list stay as they are.
#[tokio::test]
async fn only_a_chat_with_the_broker_names_its_server_at_initialize() {
    let off = Translator::new("acp-1".into(), "default", "haiku", "default");
    assert!(init_request(&off).await.get("sdkMcpServers").is_none());
    assert_eq!(init_request(&on()).await["sdkMcpServers"], json!([SERVER]));
}

/// A chat without it, or another server's name, is declined as before: no other server and no
/// other name reaches the hub.
#[tokio::test]
async fn another_server_or_a_chat_without_it_is_declined() {
    let off = Translator::new("acp-1".into(), "default", "haiku", "default");
    let call = json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"});
    assert!(off.inbound(&mcp("m1", SERVER, call.clone())).await.is_empty());
    assert_eq!(off.take_stdin_replies().await[0]["response"]["subtype"], "error");
    let t = on();
    assert!(t.inbound(&mcp("m2", "other", call)).await.is_empty());
    assert_eq!(t.take_stdin_replies().await[0]["response"]["subtype"], "error");
}

/// The handshake and the tool list are answered by the translator itself.
#[tokio::test]
async fn the_server_answers_its_handshake_and_lists_its_tools() {
    let t = on();
    let init = json!({"jsonrpc": "2.0", "id": 0, "method": "initialize",
        "params": {"protocolVersion": "2025-11-25", "capabilities": {}}});
    assert!(t.inbound(&mcp("i1", SERVER, init)).await.is_empty());
    let reply = &t.take_stdin_replies().await[0]["response"];
    assert_eq!(reply["subtype"], "success");
    assert_eq!(reply["request_id"], "i1");
    let answer = &reply["response"]["mcp_response"];
    assert_eq!(answer["id"], 0);
    assert_eq!(answer["result"]["protocolVersion"], "2025-11-25");
    assert_eq!(answer["result"]["serverInfo"]["name"], SERVER);

    let note = json!({"jsonrpc": "2.0", "method": "notifications/initialized"});
    assert!(t.inbound(&mcp("n1", SERVER, note)).await.is_empty());
    assert_eq!(t.take_stdin_replies().await[0]["response"]["subtype"], "success");

    let list = json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"});
    t.inbound(&mcp("l1", SERVER, list)).await;
    let tools =
        t.take_stdin_replies().await[0]["response"]["response"]["mcp_response"]["result"]["tools"]
            .clone();
    let names: Vec<&str> =
        tools.as_array().unwrap().iter().filter_map(|t| t["name"].as_str()).collect();
    assert_eq!(
        names,
        ["repo_view", "pr_view", "issue_create", "issue_comment", "pr_create_draft", "repo_clone"]
    );
}

/// A tool call becomes one broker request to the hub, and the hub's answer, its output or its
/// refusal, becomes the tool's result for that call.
#[tokio::test]
async fn a_tool_call_asks_the_hub_and_its_answer_is_the_result() {
    let t = on();
    let call = json!({"jsonrpc": "2.0", "id": 5, "method": "tools/call",
        "params": {"name": "repo_view", "arguments": {"repo": "o/r"}}});
    let out = t.inbound(&mcp("c1", SERVER, call)).await;
    let (id, params) = out
        .into_iter()
        .find_map(|m| match m {
            Message::Request { id, method: m, params: Some(p) } if m == GITHUB_ACTION => {
                Some((id, p))
            }
            _ => None,
        })
        .expect("the call asks the hub");
    assert_eq!(params["action"], "read");
    assert_eq!(params["repo"], "o/r");
    assert!(
        t.take_stdin_replies().await.is_empty(),
        "nothing for Claude Code until the hub answers"
    );
    let Outbound::Lines(lines) =
        t.outbound(&Message::ok(id, json!({"output": "gh repo view o/r"}))).await
    else {
        panic!("the answer goes to Claude Code");
    };
    let reply = &lines[0]["response"];
    assert_eq!(reply["request_id"], "c1");
    let answer = &reply["response"]["mcp_response"];
    assert_eq!(answer["id"], 5);
    assert_eq!(answer["result"]["isError"], false);
    assert_eq!(answer["result"]["content"][0]["text"], "gh repo view o/r");

    let call = json!({"jsonrpc": "2.0", "id": 6, "method": "tools/call",
        "params": {"name": "repo_clone", "arguments": {"repo": "o/r", "dir": "x"}}});
    let out = t.inbound(&mcp("c2", SERVER, call)).await;
    let Some(Message::Request { id, params: Some(params), .. }) = out.into_iter().next() else {
        panic!("the clone asks the hub");
    };
    assert_eq!(params["action"], "clone");
    assert_eq!(params["dir"], "x");
    let refused = RpcError::new(-32040, "not lent").with_data(json!({"reason": "github.denied"}));
    let Outbound::Lines(lines) = t.outbound(&Message::err(id, refused)).await else {
        panic!("the refusal goes to Claude Code");
    };
    let result = &lines[0]["response"]["response"]["mcp_response"]["result"];
    assert_eq!(result["isError"], true);
    assert_eq!(result["content"][0]["text"], "not lent");
}

/// What maps to no action is the tool's error, answered here: nothing reaches the hub.
#[tokio::test]
async fn a_call_that_names_no_action_is_refused_here() {
    let t = on();
    for (name, args) in [
        ("merge", json!({"repo": "o/r"})),
        ("repo_view", json!({"repo": "o/r", "token": "x"})),
        ("repo_view", json!("o/r")),
    ] {
        let call = json!({"jsonrpc": "2.0", "id": 9, "method": "tools/call",
            "params": {"name": name, "arguments": args}});
        assert!(t.inbound(&mcp("e1", SERVER, call)).await.is_empty(), "{name}");
        let result =
            t.take_stdin_replies().await[0]["response"]["response"]["mcp_response"]["result"]
                .clone();
        assert_eq!(result["isError"], true, "{name}: {result}");
    }
}

/// Each tool maps to its own action and fields only.
#[test]
fn each_tool_names_its_own_action() {
    let pr = action_of("pr_view", &json!({"repo": "o/r", "number": 3})).unwrap();
    assert_eq!(pr, json!({"action": "read", "repo": "o/r", "issue": 3}));
    let draft = action_of(
        "pr_create_draft",
        &json!({"repo": "o/r", "branch": "b", "title": "t", "body": "x"}),
    )
    .unwrap();
    assert_eq!(
        draft,
        json!({"action": "draft_pr", "repo": "o/r", "branch": "b", "title": "t", "body": "x"})
    );
    let comment = action_of("issue_comment", &json!({"repo": "o/r", "number": 1, "body": "hi"}));
    assert_eq!(comment.unwrap()["action"], "comment");
    assert!(action_of("issue_create", &json!({"repo": "o/r", "issue": 1})).is_err());
}
