//! A Chief that is not the default one acts on its own in a channel
//! (membership.rs). The real brain, with a fake harness, runs over the real
//! daemon link against a real headless cmux-tui daemon (`CMUX_TUI_BIN`),
//! bound as `agent_release` with `GroupWake::Every` on the local owner:
//!
//! - its own DM is its main conversation, and it answers there as itself;
//! - a person's message in a channel it takes part in wakes it with no
//!   mention, and the reply goes into that message's thread;
//! - a reply of exactly NO_REPLY posts nothing;
//! - another agent's channel message never wakes it.
//!
//! Run: `CMUX_TUI_BIN=<cmux-tui target>/debug/cmux-tui cargo test --test
//! channels_daemon -- --ignored`.

mod common;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_chief::rules::GroupWake;
use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::brain::{Input, Settings};
use optchat_chief::daemon::{DaemonEvent, LinkConfig, spawn_link};
use optchat_chief::membership::Membership;
use serde_json::{Value, json};

const CHIEF: &str = "agent_release";

fn bin() -> PathBuf {
    PathBuf::from(std::env::var("CMUX_TUI_BIN").expect("CMUX_TUI_BIN names a cmux-tui binary"))
}

/// One JSON-lines connection to the daemon.
struct Conn {
    writer: UnixStream,
    reader: BufReader<UnixStream>,
    next: u64,
}

impl Conn {
    fn open(socket: &Path) -> Conn {
        let stream = UnixStream::connect(socket).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(20)))
            .unwrap();
        Conn {
            writer: stream.try_clone().unwrap(),
            reader: BufReader::new(stream),
            next: 0,
        }
    }

    /// One request; its `data`.
    fn req(&mut self, mut body: Value) -> Value {
        self.next += 1;
        body["id"] = json!(self.next);
        writeln!(self.writer, "{body}").unwrap();
        loop {
            let mut line = String::new();
            assert!(
                self.reader.read_line(&mut line).unwrap() > 0,
                "the daemon closed: {body}"
            );
            let value: Value = serde_json::from_str(&line).unwrap();
            if value["id"] == body["id"] {
                assert_eq!(value["ok"], true, "{body} failed: {value}");
                return value["data"].clone();
            }
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
            .prefix("och")
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

fn person(id: &str, name: &str) -> Value {
    json!({"id": id, "kind": "human", "display_name": name})
}

fn chief(id: &str, name: &str) -> Value {
    json!({"id": id, "kind": "agent", "display_name": name, "agent_class": "mux"})
}

fn create(conn: &mut Conn, key: &str, title: &str, participants: Vec<Value>) -> String {
    conn.req(json!({"cmd": "conversation-create", "idempotency_key": key,
                    "actor": "user_local", "title": title, "participants": participants}))
        ["conversation"]["id"]
        .as_str()
        .unwrap()
        .to_owned()
}

fn send(conn: &mut Conn, conversation: &str, key: &str, text: &str) -> String {
    conn.req(
        json!({"cmd": "conversation-op", "conversation": conversation,
                    "idempotency_key": key,
                    "op": {"kind": "message.send", "client_msg_id": key,
                           "parts": [{"type": "text", "text": text}]}}),
    )["change"]["message"]["id"]
        .as_str()
        .unwrap()
        .to_owned()
}

/// Every message of `conversation`, oldest first.
fn messages(conn: &mut Conn, conversation: &str) -> Vec<Value> {
    conn.req(json!({"cmd": "conversation-snapshot", "conversation": conversation, "tail": 200}))
        ["messages"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn by_chief(messages: &[Value]) -> Vec<Value> {
    messages
        .iter()
        .filter(|m| m["author"] == CHIEF)
        .cloned()
        .collect()
}

/// The fake harness: "NO_REPLY" when the newest message says the Chief is
/// not needed, else a short answer.
fn script() -> Script {
    Box::new(|_, blocks| {
        let last = blocks
            .last()
            .and_then(|b| b["text"].as_str())
            .unwrap_or_default()
            .to_owned();
        let reply = if last.contains("nothing for you") {
            "NO_REPLY"
        } else {
            "On it."
        };
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": reply}}),
            ),
            json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
        ]
    })
}

/// Runs the brain until `done` holds (at most 30 s).
fn pump(h: &mut Harness, what: &str, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(30);
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(50)) {
            h.brain.step(input);
        }
        if h.brain.next_timer().is_some_and(|at| at <= Instant::now()) {
            h.brain.on_timer();
        }
    }
}

#[test]
#[ignore = "needs CMUX_TUI_BIN"]
fn a_second_chief_answers_its_dm_and_acts_on_its_own_in_a_channel_thread() {
    let daemon = Daemon::start();
    let mut me = Conn::open(&daemon.socket);
    let dm = create(
        &mut me,
        "dm-release",
        "Release Chief",
        vec![person("user_local", "Ada"), chief(CHIEF, "Release Chief")],
    );
    let channel_id = create(
        &mut me,
        "ch-release",
        "release",
        vec![
            person("user_local", "Ada"),
            person("user_bob", "Bob"),
            chief(CHIEF, "Release Chief"),
            chief("agent_infra", "Infra Chief"),
        ],
    );
    let token = me.req(json!({"cmd": "conversation-agent-token", "participant": CHIEF}))["token"]
        .as_str()
        .unwrap()
        .to_owned();
    let token_file = daemon.dir.path().join("agent-token");
    std::fs::write(&token_file, format!("{token}\n")).unwrap();

    let dir = tempfile::tempdir().unwrap();
    let settings = Settings {
        membership: Membership {
            participant: CHIEF.into(),
            group_wake: GroupWake::Every,
            local_side: true,
        },
        ..settings(dir.path())
    };
    let owner = Arc::new(Mutex::new(Owner::default()));
    let lines = Arc::new(Mutex::new(Vec::<String>::new()));
    let sink = lines.clone();
    let mut h = Harness::configured(
        dir,
        script(),
        owner,
        settings,
        Arc::new(move |line: &str| sink.lock().unwrap().push(line.to_owned())),
    );
    h.brain.step(Input::from(AgentEvent::Up(Vec::new())));
    let (events_tx, events_rx) = channel::<DaemonEvent>();
    let events_tx = Mutex::new(events_tx);
    spawn_link(
        LinkConfig {
            socket: daemon.socket.clone(),
            token_file: Some(token_file),
            display_name: "Ada".into(),
            title: "Release Chief".into(),
            participant: CHIEF.into(),
        },
        Arc::new(move |event| {
            let _ = events_tx.lock().unwrap().send(event);
        }),
        Arc::new(|_: &str| {}),
    );
    let up = events_rx
        .recv_timeout(Duration::from_secs(30))
        .expect("the link came up");
    let DaemonEvent::Up { conversation, .. } = &up else {
        panic!("the first link event is Up");
    };
    assert_eq!(
        conversation.id, dm,
        "the Chief's own DM is its main conversation"
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

    // 1. Its DM: it answers as itself.
    send(&mut me, &dm, "dm-1", "status of the release?");
    pump(&mut h, "the DM reply", || {
        !by_chief(&messages(&mut me, &dm)).is_empty()
    });
    let reply = &by_chief(&messages(&mut me, &dm))[0];
    assert_eq!(reply["parts"][0]["text"], "On it.");
    assert!(
        reply["thread_root"].is_null(),
        "a DM reply stays top level: {reply}"
    );

    // 2. Another agent's channel message never wakes it.
    let mut infra = Conn::open(&daemon.socket);
    let infra_token = me
        .req(json!({"cmd": "conversation-agent-token", "participant": "agent_infra"}))["token"]
        .as_str()
        .unwrap()
        .to_owned();
    infra.req(
        json!({"cmd": "conversation-bind", "participant": "agent_infra", "token": infra_token}),
    );
    send(&mut infra, &channel_id, "infra-1", "Runner tokens rotated.");

    // 3. A person's message with no mention: a reply in its thread.
    let red = send(
        &mut me,
        &channel_id,
        "ch-1",
        "main is red since the last merge",
    );
    pump(&mut h, "the channel reply", || {
        !by_chief(&messages(&mut me, &channel_id)).is_empty()
    });
    let answers = by_chief(&messages(&mut me, &channel_id));
    assert_eq!(
        answers.len(),
        1,
        "one reply, none to the agent: {answers:?}"
    );
    assert_eq!(answers[0]["parts"][0]["text"], "On it.");
    assert_eq!(
        answers[0]["thread_root"], red,
        "the reply is in the message's thread"
    );
    assert_eq!(answers[0]["reply_to"]["message_id"], red);

    // 4. NO_REPLY posts nothing: the next message's answer comes, and
    // nothing answers this one.
    let quiet = send(
        &mut me,
        &channel_id,
        "ch-2",
        "lunch at noon, nothing for you",
    );
    pump(&mut h, "the quiet turn's end", || {
        lines
            .lock()
            .unwrap()
            .iter()
            .any(|l| l.contains("nothing posted"))
    });
    let deploy = send(
        &mut me,
        &channel_id,
        "ch-3",
        "please cut 0.43 when main is green",
    );
    pump(&mut h, "the reply after the quiet one", || {
        by_chief(&messages(&mut me, &channel_id))
            .iter()
            .any(|m| m["reply_to"]["message_id"] == deploy)
    });
    let answers = by_chief(&messages(&mut me, &channel_id));
    assert!(
        answers
            .iter()
            .all(|m| m["reply_to"]["message_id"] != quiet && m["parts"][0]["text"] != "NO_REPLY"),
        "NO_REPLY posted something: {answers:?}"
    );
    assert_eq!(answers.len(), 2, "{answers:?}");
}
