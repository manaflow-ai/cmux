//! The `acpmux` MCP server's tools against a daemon with the fake agent behind a real socket.

use super::*;
use crate::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
use std::collections::BTreeMap;

async fn daemon() -> (Arc<crate::hub::Hub>, Arc<Client>, cmux_unix_socket::TestDir) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut harnesses = BTreeMap::new();
    harnesses.insert(
        "fake".to_owned(),
        HarnessProfile {
            kind: Default::default(),
            argv: vec!["python3".into(), fake.into()],
            env: BTreeMap::new(),
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        },
    );
    let mut cfg = Config { harnesses, default_harness: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = crate::hub::Hub::new(cfg, store);
    let dir = cmux_unix_socket::short_test_dir("acpmux-mcp");
    let path = dir.path().join("d.sock");
    let listener = crate::server::bind_unix(&path).await.unwrap();
    tokio::spawn(crate::server::serve_unix(hub.clone(), listener));
    let client = Client::connect(&path).await.unwrap();
    (hub, client, dir)
}

async fn session(client: &Arc<Client>, name: &str) -> String {
    let s = client
        .request(
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": name}}}),
        )
        .await
        .unwrap();
    s["sessionId"].as_str().unwrap().to_owned()
}

fn tool(name: &str, arguments: Value) -> Value {
    json!({"name": name, "arguments": arguments})
}

fn text(result: &Value) -> String {
    result["content"][0]["text"].as_str().unwrap_or_default().to_owned()
}

#[test]
fn the_tools_say_they_message_other_sessions_instead_of_the_shell() {
    let tools = tools();
    let names: Vec<&str> =
        tools.as_array().unwrap().iter().filter_map(|t| t["name"].as_str()).collect();
    assert_eq!(
        names,
        [
            "send",
            "inbox_read",
            "inbox_reply",
            "ls",
            "last",
            "info",
            "team_send",
            "team_inbox",
            "team_ack",
            "bg_start",
            "bg_list",
            "bg_output",
            "bg_stop"
        ]
    );
    let send = tools[0]["description"].as_str().unwrap();
    assert!(send.contains("Message another agent session"), "{send}");
    assert!(send.contains("instead of running `acpmux send` in a shell"), "{send}");
    assert_eq!(tools[0]["inputSchema"]["required"], json!(["to", "text"]));
    assert_eq!(tools[6]["inputSchema"]["required"], json!(["to", "body"]));
    assert_eq!(tools[8]["inputSchema"]["required"], json!(["id"]));
}

#[tokio::test]
async fn send_delivers_to_the_named_session_and_returns_its_prompt_id() {
    let (hub, client, _dir) = daemon().await;
    let lane = session(&client, "lane-a").await;
    let r = call(&client, &tool("send", json!({"to": "lane-a", "text": "rebase on main"}))).await;
    assert_eq!(r["isError"], false, "{r}");
    let prompt_id = r["structuredContent"]["promptId"].as_str().unwrap().to_owned();
    assert_eq!(r["structuredContent"]["sessionId"], json!(lane), "{r}");
    assert!(text(&r).starts_with("Sent to lane-a:"), "{r}");
    assert!(text(&r).contains(&prompt_id), "{r}");
    // The message reached the lane's agent.
    let mut seen = false;
    for _ in 0..100 {
        let events = hub.events(&lane, 0, 1000).unwrap();
        if events
            .iter()
            .any(|e| e.kind == "user_message" && e.msg.to_string().contains("rebase on main"))
        {
            seen = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(seen, "the lane never got the message");
}

/// Codex review: a send goes through this daemon's outbox (`_acpmux/send_queue`), as
/// `acpmux send --no-wait` does, so a peer that is down or a slow target is retried and survives a
/// restart; the result names the delivery, and `send_status` knows it.
#[tokio::test]
async fn send_goes_through_the_outbox_and_names_its_delivery() {
    let (_hub, client, _dir) = daemon().await;
    session(&client, "lane-c").await;
    let r = call(&client, &tool("send", json!({"to": "lane-c", "text": "status?"}))).await;
    assert_eq!(r["isError"], false, "{r}");
    let delivery = r["structuredContent"]["deliveryId"].as_str().unwrap_or_default().to_owned();
    assert!(!delivery.is_empty(), "no delivery id: {r}");
    let status = client
        .request(method::MUX_SEND_STATUS, json!({"deliveryId": delivery, "waitMs": 5000}))
        .await
        .unwrap();
    assert_eq!(status["status"], "delivered", "{status}");
    assert_eq!(status["promptId"], r["structuredContent"]["promptId"], "{status} {r}");
}

/// `class` (`prompt_class.rs`) goes with the message; a class that is not one of the four is
/// this call's error, sent nowhere.
#[tokio::test]
async fn send_carries_its_class_and_refuses_any_other() {
    let (_hub, client, _dir) = daemon().await;
    session(&client, "lane-d").await;
    let bad = json!({"to": "lane-d", "text": "x", "class": "urgent"});
    let r = call(&client, &tool("send", bad)).await;
    assert_eq!(r["isError"], true, "{r}");
    assert!(text(&r).contains("class must be one of"), "{r}");
    let block = json!({"to": "lane-d", "text": "stuck on review", "class": "block"});
    let r = call(&client, &tool("send", block)).await;
    assert_eq!(r["isError"], false, "{r}");
    assert_eq!(send_class(&json!({"class": "fyi"})), Ok(Some("fyi".to_owned())));
    assert_eq!(send_class(&json!({})), Ok(None));
    assert!(send_class(&json!({"class": 2})).is_err());
    let schema = &tools()[0]["inputSchema"]["properties"]["class"]["enum"];
    assert_eq!(schema, &json!(["block", "question", "result", "fyi", "blocker", "action"]));
}

#[tokio::test]
async fn ls_last_and_info_read_the_sessions() {
    let (_hub, client, _dir) = daemon().await;
    let lane = session(&client, "lane-b").await;
    let r = call(&client, &tool("last", json!({"name": "lane-b"}))).await;
    assert_eq!(text(&r), "lane-b has not replied yet.", "{r}");
    let prompt = PromptId::new(None);
    crate::cli::output::collect_reply(
        client.clone(),
        &lane,
        "hello",
        crate::cli::output::CollectOpts {
            deadline: None,
            timeout: Some(20),
            on_permission: crate::cli::output::OnPermission::Fail,
            stall_secs: 30,
            retries: 0,
            steer: false,
        },
        &prompt,
    )
    .await
    .unwrap();
    let r = call(&client, &tool("last", json!({"name": "lane-b"}))).await;
    assert_eq!(text(&r), "echo: hello", "{r}");
    let r = call(&client, &tool("ls", json!({}))).await;
    assert!(text(&r).lines().any(|l| l.starts_with("lane-b  [")), "{r}");
    let r = call(&client, &tool("info", json!({"name": "lane-b"}))).await;
    assert_eq!(r["structuredContent"]["sessionId"], json!(lane), "{r}");
}

#[tokio::test]
async fn an_unknown_session_or_a_missing_argument_is_an_error_the_agent_reads() {
    let (_hub, client, _dir) = daemon().await;
    let r = call(&client, &tool("send", json!({"to": "nobody", "text": "hi"}))).await;
    assert_eq!(r["isError"], true, "{r}");
    let r = call(&client, &tool("send", json!({"to": "nobody"}))).await;
    assert_eq!(r["isError"], true, "{r}");
    assert_eq!(text(&r), "to and text are required", "{r}");
    let r = call(&client, &tool("nope", json!({}))).await;
    assert_eq!(text(&r), "unknown tool: nope", "{r}");
}

/// Arguments that are not an object are an error the agent reads, never a panic.
#[tokio::test]
async fn bg_tools_refuse_arguments_that_are_not_an_object() {
    let (_hub, client, _dir) = daemon().await;
    for name in bg::TOOLS {
        let r = bg::call(&client, "any", name, &json!([])).await;
        assert_eq!(r["isError"], true, "{name}: {r}");
        assert_eq!(text(&r), "arguments must be an object", "{name}: {r}");
    }
}

/// Exercise the actual MCP-to-daemon socket path without substituting an MCP
/// implementation. Any wrong RPC method, argument, lost receipt field or hidden
/// refusal fails independently of the mesh client's tests.
#[cfg(unix)]
#[tokio::test]
async fn team_tools_use_the_shared_rpc_paths_and_preserve_receipts_and_refusals() {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    let receipt = json!({"messageId": "msg_example", "state": "queued",
        "resolution": {"teamAddress": "@team/reviewer", "sessionId": "resolved-agent"},
        "startWork": "information"});
    let inbox = json!({"messages": [{"messageId": "msg_example", "body": "review ready",
        "from": {"teamAddress": "@member/coordinator"}, "state": "delivered",
        "startWork": "information"}]});
    let acknowledged = json!({"messageId": "msg_example", "state": "acked"});
    let cases = vec![
        (
            "team_send",
            json!({"to": "@team/reviewer", "body": "review ready"}),
            "_acpmux/team/send",
            json!({"to": "@team/reviewer", "body": "review ready"}),
            receipt,
        ),
        ("team_inbox", json!({}), "_acpmux/team/inbox", json!({"unreadOnly": true}), inbox.clone()),
        (
            "team_inbox",
            json!({"unreadOnly": false}),
            "_acpmux/team/inbox",
            json!({"unreadOnly": false}),
            inbox,
        ),
        (
            "team_ack",
            json!({"id": "msg_example"}),
            "_acpmux/team/ack",
            json!({"id": "msg_example"}),
            acknowledged,
        ),
    ];
    let expected = cases
        .iter()
        .map(|(_, _, method, args, result)| (*method, args.clone(), result.clone()))
        .collect::<Vec<_>>();
    let dir = cmux_unix_socket::short_test_dir("acpmux-team-mcp");
    let path = dir.path().join("d.sock");
    let listener = tokio::net::UnixListener::bind(&path).unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (read, mut write) = stream.into_split();
        let mut lines = BufReader::new(read).lines();
        let mut requests = vec![("initialize", None, json!({}))];
        requests.extend(expected.into_iter().map(|(m, a, r)| (m, Some(a), r)));
        for (method, arguments, result) in requests {
            let request: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
            assert_eq!(request["method"], method, "{request}");
            if let Some(arguments) = arguments {
                assert_eq!(request["params"], arguments, "{request}");
            }
            let response = json!({"jsonrpc": "2.0", "id": request["id"], "result": result});
            write.write_all(format!("{response}\n").as_bytes()).await.unwrap();
        }
        let request: Value =
            serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
        assert_eq!(request["method"], "_acpmux/team/send");
        let response = json!({"jsonrpc": "2.0", "id": request["id"],
            "error": {"code": -32602, "message": "team messaging is disabled in Labs"}});
        write.write_all(format!("{response}\n").as_bytes()).await.unwrap();
    });
    let client = Client::connect(&path).await.unwrap();
    for (name, arguments, _, _, expected) in cases {
        let result =
            tokio::time::timeout(Duration::from_secs(5), call(&client, &tool(name, arguments)))
                .await
                .unwrap();
        assert_eq!(result["isError"], false, "{result}");
        assert_eq!(result["structuredContent"], expected, "{result}");
        assert_eq!(serde_json::from_str::<Value>(&text(&result)).unwrap(), expected);
    }
    let result = tokio::time::timeout(
        Duration::from_secs(5),
        call(&client, &tool("team_send", json!({"to": "@team/reviewer", "body": "retry"}))),
    )
    .await
    .unwrap();
    assert_eq!(result["isError"], true, "{result}");
    assert!(text(&result).contains("team messaging is disabled in Labs"), "{result}");
    server.await.unwrap();
}
