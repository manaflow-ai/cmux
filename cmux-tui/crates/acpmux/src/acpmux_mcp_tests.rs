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
    assert_eq!(names, ["send", "ls", "last", "info"]);
    let send = tools[0]["description"].as_str().unwrap();
    assert!(send.contains("Message another agent session"), "{send}");
    assert!(send.contains("instead of running `acpmux send` in a shell"), "{send}");
    assert_eq!(tools[0]["inputSchema"]["required"], json!(["to", "text"]));
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
