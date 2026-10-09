//! The memory tools over MCP: the `mcp` subcommand against the tools socket
//! of a live test memory.

mod common;

use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};

use common::open_chat;
use optchat_chief::mcp::{SocketBackend, handle};
use optchat_chief::prompt::{DATE_DESCRIPTION, ZOOM_DESCRIPTION};
use optchat_core::Kind;
use serde_json::{Value, json};

#[test]
fn the_mcp_server_answers_zoom_and_date_from_the_live_memory() {
    let dir = tempfile::tempdir().unwrap();
    let chat = open_chat(&dir.path().join("chat"));
    chat.append(Kind::User, "hello\nworld").unwrap();
    chat.append(Kind::Talk, "hi").unwrap();
    assert!(chat.wait_idle(None, Some(common::WAIT)));
    let socket = dir.path().join("tools.sock");
    optchat_chief::tools::serve(&socket, chat.clone()).unwrap();

    let mut child = Command::new(env!("CARGO_BIN_EXE_optchat-chief"))
        .args(["mcp", "--socket"])
        .arg(&socket)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let call = |id: u64, name: &str, args: Value| json!({"jsonrpc": "2.0", "id": id, "method": "tools/call", "params": {"name": name, "arguments": args}});
    let requests = vec![
        json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}}}),
        json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
        json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}),
        call(3, "zoom", json!({"id": 0, "n": 1})),
        call(4, "zoom", json!({"id": 0, "n": 2})),
        call(5, "zoom", json!({"id": 1, "n": 2})),
        call(6, "date", json!({"id": 0})),
        call(7, "date", json!({"id": 99})),
    ];
    for r in &requests {
        writeln!(stdin, "{r}").unwrap();
    }
    drop(stdin);
    let answers: Vec<Value> = BufReader::new(child.stdout.take().unwrap())
        .lines()
        .map(|l| serde_json::from_str(&l.unwrap()).unwrap())
        .collect();
    assert!(child.wait().unwrap().success());
    assert_eq!(answers.len(), 7, "no answer to the notification");
    assert_eq!(answers[0]["result"]["protocolVersion"], "2025-06-18");
    let tools = &answers[1]["result"]["tools"];
    assert_eq!(tools[0]["name"], "zoom");
    // The MCP zoom also opens a subagent's chat.
    assert_eq!(
        tools[0]["description"],
        format!(
            "{ZOOM_DESCRIPTION}{}",
            optchat_chief::prompt::ZOOM_AGENT_DESCRIPTION
        )
    );
    assert_eq!(tools[1]["name"], "date");
    assert_eq!(tools[1]["description"], DATE_DESCRIPTION);
    let text = |i: usize| {
        answers[i]["result"]["content"][0]["text"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    assert_eq!(
        text(2),
        "0+0|user: hello\nworld",
        "n = 1 gives the message whole"
    );
    assert_eq!(text(3), "0+1|user: hello world\n1+1|talk: hi");
    assert_eq!(text(4), "No line 1+2.");
    let date = text(5);
    assert_eq!(date.len(), "2026-10-03 22:21:45 -07:00".len(), "{date}");
    assert_eq!(&date[4..5], "-");
    assert_eq!(text(6), "No message 99.");
}

#[test]
fn without_the_host_a_tool_call_is_an_error_result() {
    let backend = SocketBackend("/nonexistent/tools.sock".into(), false);
    let answer = handle(
        &json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "zoom", "arguments": {"id": 0, "n": 1}}}),
        &backend,
    )
    .unwrap();
    assert_eq!(answer["result"]["isError"], true);
    assert!(
        answer["result"]["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("not running")
    );
    let bad = handle(
        &json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "zoom", "arguments": {"id": -1, "n": 1}}}),
        &backend,
    )
    .unwrap();
    assert_eq!(bad["result"]["isError"], true);
}
