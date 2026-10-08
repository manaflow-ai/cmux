use super::*;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, DuplexStream, duplex};

const SECRET: &str = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

/// A fake helper on the far end of `stream`: checks the secret (or refuses),
/// then answers `tools/list` and echoes `tools/call` as an MCP result.
async fn fake_helper(stream: DuplexStream, refuse: bool) {
    let (read, mut write) = tokio::io::split(stream);
    let mut lines = BufReader::new(read).lines();
    let Ok(Some(hello)) = lines.next_line().await else { return };
    let hello: Value = serde_json::from_str(&hello).unwrap();
    if refuse || hello["secret"] != json!(SECRET) {
        let _ = write
            .write_all(b"{\"ok\":false,\"error\":\"refused\",\"reason\":\"outside_acpmux_tree\"}\n")
            .await;
        return;
    }
    write.write_all(b"{\"ok\":true,\"protocol\":1}\n").await.unwrap();
    while let Ok(Some(line)) = lines.next_line().await {
        let request: Value = serde_json::from_str(&line).unwrap();
        let result = match request["method"].as_str() {
            Some("tools/list") => json!([{"name": "click"}, {"name": "get_window_state"}]),
            _ => {
                json!({"content": [{"type": "text", "text": format!("{} {}", request["name"], request["arguments"])}]})
            }
        };
        let reply = json!({"id": request["id"], "ok": true, "result": result});
        write.write_all(format!("{reply}\n").as_bytes()).await.unwrap();
    }
}

/// Runs the bridge over `requests` against a fake helper; returns the replies.
async fn bridge(requests: &[Value], refuse: bool) -> Vec<Value> {
    let input: String = requests.iter().map(|r| format!("{r}\n")).collect();
    let mut output = Vec::new();
    let connect = || async move {
        let (ours, theirs) = duplex(64 * 1024);
        tokio::spawn(fake_helper(theirs, refuse));
        Helper::admit(ours, SECRET).await
    };
    serve(BufReader::new(input.as_bytes()), &mut output, connect).await.unwrap();
    String::from_utf8(output).unwrap().lines().map(|l| serde_json::from_str(l).unwrap()).collect()
}

#[tokio::test]
async fn the_bridge_lists_and_calls_helper_tools() {
    let replies = bridge(
        &[
            json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}}),
            json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
            json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}),
            json!({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                   "params": {"name": "click", "arguments": {"element_token": "s0000000a:3"}}}),
        ],
        false,
    )
    .await;
    assert_eq!(replies.len(), 3, "the notification gets no reply: {replies:?}");
    assert_eq!(replies[0]["result"]["serverInfo"]["name"], "cmux-cua");
    assert_eq!(replies[1]["id"], 2);
    assert_eq!(replies[1]["result"]["tools"][1]["name"], "get_window_state");
    assert_eq!(replies[2]["id"], 3);
    assert_eq!(
        replies[2]["result"]["content"][0]["text"],
        "\"click\" {\"element_token\":\"s0000000a:3\"}"
    );
}

#[tokio::test]
async fn a_refused_bridge_reports_the_refusal_as_a_tool_error() {
    let replies = bridge(
        &[json!({"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": {"name": "click", "arguments": {}}})],
        true,
    )
    .await;
    assert_eq!(replies[0]["result"]["isError"], true);
    let text = replies[0]["result"]["content"][0]["text"].as_str().unwrap();
    assert!(text.contains("refused") && text.contains("outside_acpmux_tree"), "{text}");
}

#[tokio::test]
async fn unknown_methods_are_json_rpc_errors() {
    let replies =
        bridge(&[json!({"jsonrpc": "2.0", "id": 4, "method": "resources/list"})], false).await;
    assert_eq!(replies[0]["error"]["code"], -32601);
}

#[test]
fn the_folder_is_active_only_while_endpoint_json_exists() {
    let dir = std::env::temp_dir().join(format!("acpmux-cua-v2-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    assert_eq!(active_dir(Some(dir.clone())), None);
    assert_eq!(active_dir(None), None);
    std::fs::write(
        dir.join(ENDPOINT_FILE),
        format!("{{\"protocol\":1,\"socket\":\"/tmp/h.sock\",\"secret\":\"{SECRET}\"}}\n"),
    )
    .unwrap();
    assert_eq!(active_dir(Some(dir.clone())), Some(dir.clone()));
    let endpoint = read_endpoint(&dir).unwrap();
    assert_eq!(endpoint.socket, PathBuf::from("/tmp/h.sock"));
    assert_eq!(endpoint.secret, SECRET);
    assert!(!format!("{endpoint:?}").contains(SECRET), "Debug never prints the secret");
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn an_inventory_array_becomes_an_mcp_tools_list() {
    assert_eq!(tools_list_result(json!([{"name": "a"}])), json!({"tools": [{"name": "a"}]}));
    assert_eq!(tools_list_result(json!({"tools": []})), json!({"tools": []}));
    assert_eq!(call_result(json!({"ok": 1}))["content"][0]["text"], "{\"ok\":1}");
}

#[test]
fn agents_never_inherit_the_endpoint_folder() {
    assert!(crate::cua_socket::AGENT_SCRUBBED_ENV.contains(&ENDPOINT_DIR_ENV));
}
