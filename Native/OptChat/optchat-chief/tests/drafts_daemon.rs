//! Streaming parity (hq-6d, 2026-10-10): the Chief's reply text reaches the
//! conversation while the Chief writes it. The real brain, with a fake
//! harness that streams three chunks, runs over the real daemon link
//! against a real headless cmux-tui daemon (`CMUX_TUI_BIN`); a second
//! client follows the conversation's `conversation.events` stream (the
//! only stream that carries drafts) with the real CLI. Draft items must
//! arrive before the posted reply.
//!
//! Run: `CMUX_TUI_BIN=<cmux-tui target>/debug/cmux-tui cargo test --test
//! drafts_daemon -- --ignored`.

mod common;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::brain::Input;
use optchat_chief::daemon::{DaemonEvent, LinkConfig, spawn_link};
use serde_json::{Value, json};

fn bin() -> PathBuf {
    PathBuf::from(std::env::var("CMUX_TUI_BIN").expect("CMUX_TUI_BIN names a cmux-tui binary"))
}

/// One JSON-lines request on a fresh connection; its `data`.
fn request(socket: &Path, body: Value) -> Value {
    let stream = UnixStream::connect(socket).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    let mut writer = stream.try_clone().unwrap();
    writeln!(writer, "{body}").unwrap();
    let mut reader = BufReader::new(stream);
    loop {
        let mut line = String::new();
        assert!(reader.read_line(&mut line).unwrap() > 0, "the daemon closed: {body}");
        let value: Value = serde_json::from_str(&line).unwrap();
        if value["id"] == body["id"] {
            assert_eq!(value["ok"], true, "{body} failed: {value}");
            return value["data"].clone();
        }
    }
}

/// A headless daemon in its own home; stopped (by its own CLI) on drop.
struct Daemon {
    dir: tempfile::TempDir,
    socket: PathBuf,
}

impl Daemon {
    fn start() -> Daemon {
        let dir = tempfile::Builder::new().prefix("odr").tempdir_in("/tmp").unwrap();
        let socket = dir.path().join("d.sock");
        let status = self::cli(dir.path())
            .arg("--socket")
            .arg(&socket)
            .args(["daemon", "ensure"])
            .stdout(Stdio::null())
            .status()
            .unwrap();
        assert!(status.success(), "daemon ensure: {status}");
        Daemon { dir, socket }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = cli(self.dir.path())
            .arg("--socket")
            .arg(&self.socket)
            .args(["daemon", "stop", "--end-terminals"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
}

fn cli(home: &Path) -> Command {
    let mut command = Command::new(bin());
    command
        .env("HOME", home)
        .env("TMPDIR", home)
        .env("CMUX_TUI_STATE_DIR", home.join("state"))
        .env_remove("CMUX_TUI_SOCKET")
        .env("LC_ALL", "C");
    command
}

/// The real CLI following `conversation`'s events; every line with the
/// time it arrived.
fn follow(daemon: &Daemon, conversation: &str) -> (Child, Arc<Mutex<Vec<(Instant, Value)>>>) {
    let mut child = cli(daemon.dir.path())
        .arg("--socket")
        .arg(&daemon.socket)
        .args(["--jsonl", "conversation", conversation, "events", "--tail", "0"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let lines = Arc::new(Mutex::new(Vec::new()));
    let stdout = child.stdout.take().unwrap();
    let seen = lines.clone();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if let Ok(value) = serde_json::from_str::<Value>(&line) {
                seen.lock().unwrap().push((Instant::now(), value));
            }
        }
    });
    (child, lines)
}

fn streaming_turn() -> Script {
    Box::new(|_, _| {
        let chunk = |text: &str| {
            update("agent_message_chunk", json!({"content": {"type": "text", "text": text}}))
        };
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            chunk("Streaming "),
            chunk("reaches "),
            chunk("Home."),
            json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
        ]
    })
}

#[test]
#[ignore = "needs CMUX_TUI_BIN"]
fn the_reply_streams_to_the_conversation_before_it_is_posted() {
    let daemon = Daemon::start();
    // The Chief conversation as the app makes it, and the brain's token.
    let created = request(
        &daemon.socket,
        json!({"id": 1, "cmd": "conversation-create", "idempotency_key": "home-chief",
               "actor": "user_local", "title": "Chief",
               "participants": [
                   {"id": "user_local", "kind": "human", "display_name": "Ada"},
                   {"id": "agent_mux", "kind": "agent", "display_name": "Chief",
                    "agent_class": "mux", "acp_session": "mux"}]}),
    );
    let conversation = created["conversation"]["id"].as_str().unwrap().to_owned();
    let token = request(
        &daemon.socket,
        json!({"id": 2, "cmd": "conversation-agent-token", "participant": "agent_mux"}),
    )["token"]
        .as_str()
        .unwrap()
        .to_owned();
    let token_file = daemon.dir.path().join("agent-token");
    std::fs::write(&token_file, format!("{token}\n")).unwrap();

    let mut h = Harness::new(streaming_turn());
    h.brain.step(Input::from(AgentEvent::Up(Vec::new())));
    let (events_tx, events_rx) = channel::<DaemonEvent>();
    let events_tx = Mutex::new(events_tx);
    spawn_link(
        LinkConfig {
            socket: daemon.socket.clone(),
            token_file: Some(token_file),
            display_name: "Ada".into(),
            title: "Chief".into(),
        },
        Arc::new(move |event| {
            let _ = events_tx.lock().unwrap().send(event);
        }),
        Arc::new(|_: &str| {}),
    );
    let up = events_rx.recv_timeout(Duration::from_secs(30)).expect("the link came up");
    assert!(matches!(up, DaemonEvent::Up { .. }), "the first link event is Up");
    h.brain.step(Input::from(up));
    let tx = h.tx.clone();
    std::thread::spawn(move || {
        for event in events_rx {
            if tx.send(Input::from(event)).is_err() {
                return;
            }
        }
    });

    let (mut follower, lines) = follow(&daemon, &conversation);
    std::thread::sleep(Duration::from_millis(500));
    request(
        &daemon.socket,
        json!({"id": 3, "cmd": "conversation-op", "conversation": conversation,
               "idempotency_key": "ask-1", "actor": "user_local",
               "op": {"kind": "message.send", "client_msg_id": "ask-1",
                      "parts": [{"type": "text", "text": "stream please"}]}}),
    );
    h.settle_posts();

    // The posted reply, and every draft item before it.
    let is_reply = |v: &Value| {
        v.pointer("/item/message/author").and_then(Value::as_str) == Some("agent_mux")
    };
    let deadline = Instant::now() + Duration::from_secs(20);
    while !lines.lock().unwrap().iter().any(|(_, v)| is_reply(v)) {
        assert!(Instant::now() < deadline, "no reply on the stream: {:?}", lines.lock().unwrap());
        std::thread::sleep(Duration::from_millis(50));
    }
    let _ = follower.kill();
    let _ = follower.wait();
    let lines = lines.lock().unwrap();
    let reply_at = lines.iter().position(|(_, v)| is_reply(v)).unwrap();
    let drafts: Vec<&Value> = lines[..reply_at]
        .iter()
        .map(|(_, v)| v)
        .filter(|v| v.pointer("/item/type").and_then(Value::as_str) == Some("draft"))
        .collect();
    assert!(!drafts.is_empty(), "no draft before the reply: {lines:?}");
    let text: String = drafts
        .iter()
        .filter_map(|v| v.pointer("/item/text").and_then(Value::as_str))
        .collect();
    assert!(text.contains("Streaming"), "draft text {text:?}");
}
