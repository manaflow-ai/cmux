//! The Chief sends a file over the owner's old 100 MB limit through the real
//! owner (review of #26518: "a 101 MB attachment now reports success, fails
//! upload with too_large, and posts fallback text"; Leo, 2026-10-26: "I
//! ALREADY SAID WE NEED ARBITARRILY LARGE FILES OF ANY TYPE"). The real
//! brain, with a fake harness whose reply names a 150 MB video, runs over the
//! real daemon link against a real headless cmux-tui daemon (`CMUX_TUI_BIN`):
//! its preview thread uploads the file through `conversation-attachment-upload`
//! (begin, 4 MiB chunks read from disk, commit), the reply carries the
//! `attachment` part, and the owner serves the stored bytes back. The file is
//! sparse, so the test holds nothing of it in memory.
//!
//! Run: `CMUX_TUI_BIN=<cmux-tui target>/debug/cmux-tui cargo test --test
//! chief_media_daemon -- --ignored`.

mod common;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::Engine;
use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::brain::Input;
use optchat_chief::daemon::{DaemonEvent, LinkConfig, spawn_link};
use serde_json::{Value, json};
use sha2::Digest;

/// Over the owner's old 100 MB limit (MAX_ATTACHMENT_BYTES) and the Chief's
/// old 50 MB one (MAX_MEDIA_BYTES).
const VIDEO_BYTES: u64 = 150_000_000;

fn bin() -> PathBuf {
    PathBuf::from(std::env::var("CMUX_TUI_BIN").expect("CMUX_TUI_BIN names a cmux-tui binary"))
}

/// One JSON-lines request on a fresh connection; its `data`.
fn request(socket: &Path, body: Value) -> Value {
    let stream = UnixStream::connect(socket).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(60)))
        .unwrap();
    let mut writer = stream.try_clone().unwrap();
    writeln!(writer, "{body}").unwrap();
    let mut reader = BufReader::new(stream);
    loop {
        let mut line = String::new();
        assert!(
            reader.read_line(&mut line).unwrap() > 0,
            "the daemon closed: {body}"
        );
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
        let dir = tempfile::Builder::new()
            .prefix("ocm")
            .tempdir_in("/tmp")
            .unwrap();
        let socket = dir.path().join("d.sock");
        let status = cli(dir.path())
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

fn reply_script(text: String) -> Script {
    let text: &'static str = Box::leak(text.into_boxed_str());
    Box::new(move |_, _| {
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": text}}),
            ),
            json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
        ]
    })
}

/// The SHA-256 (lowercase hex) of the file, read a block at a time.
fn sha256(path: &Path) -> String {
    let mut hasher = sha2::Sha256::new();
    std::io::copy(&mut std::fs::File::open(path).unwrap(), &mut hasher).unwrap();
    hasher
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

#[test]
#[ignore = "needs CMUX_TUI_BIN"]
fn the_chief_sends_a_video_over_100_mb_through_the_real_owner() {
    let daemon = Daemon::start();
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

    // A sparse 150 MB video: nothing of it is held in memory or written out.
    let media = tempfile::tempdir().unwrap();
    let clip = media.path().join("long.mp4");
    std::fs::File::create(&clip)
        .unwrap()
        .set_len(VIDEO_BYTES)
        .unwrap();

    let mut h = Harness::new(reply_script(format!(
        "Here it is: ![long]({})",
        clip.display()
    )));
    h.brain.step(Input::from(AgentEvent::Up(Vec::new())));
    let (events_tx, events_rx) = channel::<DaemonEvent>();
    let events_tx = Mutex::new(events_tx);
    spawn_link(
        LinkConfig {
            socket: daemon.socket.clone(),
            token_file: Some(token_file),
            display_name: "Ada".into(),
            title: "Chief".into(),
            participant: "agent_mux".into(),
        },
        Arc::new(move |event| {
            let _ = events_tx.lock().unwrap().send(event);
        }),
        Arc::new(|_: &str| {}),
    );
    let up = events_rx
        .recv_timeout(Duration::from_secs(30))
        .expect("the link came up");
    assert!(
        matches!(up, DaemonEvent::Up { .. }),
        "the first link event is Up"
    );
    h.brain.step(Input::from(up));
    let tx = h.tx.clone();
    std::thread::spawn(move || {
        for event in events_rx {
            if tx.send(Input::from(event)).is_err() {
                return;
            }
        }
    });

    request(
        &daemon.socket,
        json!({"id": 3, "cmd": "conversation-op", "conversation": conversation,
               "idempotency_key": "ask-1", "actor": "user_local",
               "op": {"kind": "message.send", "client_msg_id": "ask-1",
                      "parts": [{"type": "text", "text": "send me the long video"}]}}),
    );

    // The brain hears the message over the link, runs the turn, uploads the
    // video through the owner and posts the reply.
    let mut id = 10;
    let mut snapshot = || {
        id += 1;
        request(
            &daemon.socket,
            json!({"id": id, "cmd": "conversation-snapshot",
                   "conversation": conversation, "tail": 10}),
        )
    };
    let deadline = Instant::now() + Duration::from_secs(600);
    let mut checked = Instant::now();
    let reply = loop {
        if checked.elapsed() >= Duration::from_millis(250) {
            checked = Instant::now();
            let messages = snapshot()["messages"].clone();
            let reply = messages
                .as_array()
                .into_iter()
                .flatten()
                .find(|m| m.pointer("/author").and_then(Value::as_str) == Some("agent_mux"));
            if let Some(reply) = reply {
                break reply.clone();
            }
            assert!(
                Instant::now() < deadline,
                "no reply from the Chief: {messages}"
            );
        }
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(50)) {
            h.brain.step(input);
        }
        if h.brain.next_timer().is_some_and(|at| at <= Instant::now()) {
            h.brain.on_timer();
        }
    };

    let parts = reply["parts"].as_array().cloned().unwrap_or_default();
    let attachment = parts
        .iter()
        .find(|p| p["type"] == "attachment")
        .unwrap_or_else(|| panic!("the reply carries no attachment part: {reply}"));
    let hash = sha256(&clip);
    assert_eq!(attachment["hash"], hash.as_str(), "{attachment}");
    assert_eq!(attachment["name"], "long.mp4", "{attachment}");
    assert_eq!(attachment["mime_type"], "video/mp4", "{attachment}");
    assert_eq!(attachment["byte_count"], VIDEO_BYTES, "{attachment}");

    // The owner stored the whole file (begin, every chunk and the commit
    // succeeded): its last bytes read back, with the full length.
    let tail = request(
        &daemon.socket,
        json!({"id": 4, "cmd": "conversation-attachment-read", "conversation": conversation,
               "hash": hash, "variant": "original", "offset": VIDEO_BYTES - 16, "length": 16}),
    );
    assert_eq!(tail["byte_count"], VIDEO_BYTES, "{tail}");
    assert_eq!(tail["mime_type"], "video/mp4", "{tail}");
    assert_eq!(tail["eof"], true, "{tail}");
    let data = base64::engine::general_purpose::STANDARD
        .decode(tail["data"].as_str().unwrap())
        .unwrap();
    assert_eq!(data, vec![0u8; 16]);
}
