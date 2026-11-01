//! The Chief's own `stop` tool (end the turn, `Call::Stop`) and the owner's
//! chief.stop reach the tools socket with the same tool name. Since the
//! model's tool came (9894286f1fc), every turn that ended with it was taken
//! for the owner's stop: "the owner stopped the running turn", nothing
//! posted, and (before 2026-10-20) every subagent stopped "by the user".

mod common;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use common::open_chat;
use optchat_chief::tools::{Call, ControlRequest};

fn serve(home: &Path, seen: Arc<Mutex<Vec<ControlRequest>>>) -> PathBuf {
    let socket = home.join("tools.sock");
    std::fs::create_dir_all(home).unwrap();
    optchat_chief::tools::serve_all(
        &socket,
        optchat_chief::tools::Served {
            memory: open_chat(&home.join("memory")),
            orchestrator: None,
            control: Some(Arc::new(move |ask| {
                seen.lock().unwrap().push(ask);
                Ok("{\"stopped\":true}".to_owned())
            })),
            inspector: None,
            chief: None,
            turn: None,
            peers: None,
        },
    )
    .unwrap();
    socket
}

#[test]
fn the_models_stop_tool_is_not_the_owners_stop() {
    let dir = tempfile::tempdir().unwrap();
    let seen = Arc::new(Mutex::new(Vec::new()));
    let socket = serve(&dir.path().join("chief"), seen.clone());
    // As the Chief's MCP server sends it.
    let answer = optchat_chief::tools::ask_as(&socket, Call::Stop, false);
    assert_eq!(
        answer,
        Err("this Chief host runs no turns".to_owned()),
        "the turn tool goes to the orchestrator"
    );
    assert!(
        seen.lock().unwrap().is_empty(),
        "{:?}",
        seen.lock().unwrap()
    );
}

#[test]
fn the_owners_stop_line_still_stops_the_chief() {
    let dir = tempfile::tempdir().unwrap();
    let seen = Arc::new(Mutex::new(Vec::new()));
    let socket = serve(&dir.path().join("chief"), seen.clone());
    // As the daemon's chief.stop forwards it (cmux-tui chief_control.rs).
    let mut conn = UnixStream::connect(&socket).unwrap();
    writeln!(conn, "{}", serde_json::json!({"tool": "stop"})).unwrap();
    let mut answer = String::new();
    BufReader::new(conn).read_line(&mut answer).unwrap();
    assert!(answer.contains("stopped"), "{answer}");
    assert_eq!(*seen.lock().unwrap(), vec![ControlRequest::Stop]);
}

#[test]
fn owner_continue_and_retry_lines_reach_the_control_layer() {
    let dir = tempfile::tempdir().unwrap();
    let seen = Arc::new(Mutex::new(Vec::new()));
    let socket = serve(&dir.path().join("chief"), seen.clone());
    for request in [
        serde_json::json!({"tool": "continue"}),
        serde_json::json!({"tool": "retry", "message": "msg_1"}),
    ] {
        let mut conn = UnixStream::connect(&socket).unwrap();
        writeln!(conn, "{request}").unwrap();
        let mut answer = String::new();
        BufReader::new(conn).read_line(&mut answer).unwrap();
        assert!(!answer.contains("error"), "{answer}");
    }
    assert_eq!(
        *seen.lock().unwrap(),
        vec![
            ControlRequest::Continue,
            ControlRequest::Retry("msg_1".into())
        ]
    );
}

#[test]
fn retry_without_a_message_never_reaches_the_brain() {
    let dir = tempfile::tempdir().unwrap();
    let seen = Arc::new(Mutex::new(Vec::new()));
    let socket = serve(&dir.path().join("chief"), seen.clone());
    for request in [
        serde_json::json!({"tool": "retry"}),
        serde_json::json!({"tool": "retry", "message": "  "}),
    ] {
        let mut conn = UnixStream::connect(&socket).unwrap();
        writeln!(conn, "{request}").unwrap();
        let mut answer = String::new();
        BufReader::new(conn).read_line(&mut answer).unwrap();
        assert!(answer.contains("bad_request"), "{answer}");
    }
    assert!(seen.lock().unwrap().is_empty());
}
