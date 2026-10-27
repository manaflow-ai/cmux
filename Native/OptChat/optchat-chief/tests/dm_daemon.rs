//! A Chief that is not the default one keeps its DM when the DM gains a
//! participant (a paired device joins every conversation of the person; the
//! person can add someone) and the Chief is renamed. The real brain, with a
//! fake harness, runs over the real daemon link against a real headless
//! cmux-tui daemon (`CMUX_TUI_BIN`), bound as `agent_scout` with
//! `GroupWake::Every` on the local owner:
//!
//! - its first start creates its DM (key `home-chief-agent_scout`) and
//!   answers there, writing the run of its turn;
//! - the DM gains a participant; the brain restarts under a new title (a
//!   rename restarts it with `MUX_CHIEF_TITLE` = the new name). The
//!   two-person match misses the DM and the create under the same key is
//!   refused as `idempotency_conflict`; the brain connects to that DM (not
//!   to an older channel it is in), with no second DM, the DM's stored title
//!   (hq-6d 2026-10-14) and its earlier run;
//! - it answers in the DM again, and a person's message in the channel still
//!   wakes it, with the reply in that message's thread;
//! - when the DM's title changed too (the person renamed the conversation),
//!   no request replays the key, but the owner names the conversation the
//!   key made in the refusal (`error_details.conversation`, hq-6d
//!   2026-10-14): the brain reconnects to that DM, never to an older channel
//!   (the guess), and makes no new one.
//!
//! Not covered here: a paired device in the DM (no client path adds one;
//! only the daemon's pairing does, remote_relay/participants.rs). The DM
//! match skips a participant whose `person` is user_local.
//!
//! Run: `CMUX_TUI_BIN=<cmux-tui target>/debug/cmux-tui cargo test --test
//! dm_daemon -- --ignored`.

mod common;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc::{Receiver, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_chief::rules::GroupWake;
use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::brain::{Input, Settings};
use optchat_chief::daemon::{DaemonEvent, LinkConfig, spawn_link};
use optchat_chief::membership::Membership;
use serde_json::{Value, json};

const CHIEF: &str = "agent_scout";

fn bin() -> PathBuf {
    PathBuf::from(std::env::var("CMUX_TUI_BIN").expect("CMUX_TUI_BIN names a cmux-tui binary"))
}

/// One JSON-lines connection to the daemon (the person's: unbound, local).
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
            .prefix("ocr")
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

/// The Chief's messages in `conversation`, oldest first.
fn by_chief(conn: &mut Conn, conversation: &str) -> Vec<Value> {
    conn.req(json!({"cmd": "conversation-snapshot", "conversation": conversation, "tail": 200}))
        ["messages"]
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter(|m| m["author"] == CHIEF)
        .collect()
}

/// The finished runs of `conversation`.
fn done_runs(conn: &mut Conn, conversation: &str) -> Vec<Value> {
    conn.req(json!({"cmd": "conversation-runs", "conversation": conversation}))["runs"]
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter(|r| r["status"] == "done")
        .collect()
}

/// The conversations the Chief takes part in.
fn of_chief(conn: &mut Conn) -> Vec<Value> {
    conn.req(json!({"cmd": "conversation-list"}))["conversations"]
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter(|c| {
            c["participants"]
                .as_array()
                .is_some_and(|ps| ps.iter().any(|p| p["id"] == CHIEF))
        })
        .collect()
}

/// A turn with one shell call (so the turn has a run) and a short answer.
fn script() -> Script {
    Box::new(|_, _| {
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "tool_call",
                json!({"toolCallId": "toolu_sh", "title": "git status", "kind": "execute",
                       "rawInput": {"command": "git status"},
                       "_meta": {"claude": {"tool": "Bash"}}}),
            ),
            update(
                "tool_call_update",
                json!({"toolCallId": "toolu_sh", "status": "completed",
                       "content": [{"type": "content", "content": {"type": "text", "text": "clean"}}]}),
            ),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": "On it."}}),
            ),
            json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
        ]
    })
}

/// A brain bound as [`CHIEF`] whose link sends `title` in its create
/// request. Returns the brain and the conversation the link came up with.
fn start_brain(daemon: &Daemon, token_file: &Path, title: &str) -> (Harness, String) {
    let dir = tempfile::tempdir().unwrap();
    let settings = Settings {
        membership: Membership {
            participant: CHIEF.into(),
            owner: cmux_chief::rules::USER_LOCAL.into(),
            group_wake: GroupWake::Every,
            local_side: true,
        },
        ..settings(dir.path())
    };
    let mut h = Harness::configured(
        dir,
        script(),
        Arc::new(Mutex::new(Owner::default())),
        settings,
        Arc::new(|_: &str| {}),
    );
    h.brain.step(Input::from(AgentEvent::Up(Vec::new())));
    let (events_rx, lines) = link(daemon, token_file, title);
    let up = first_up(&events_rx, &lines);
    let DaemonEvent::Up { conversation, .. } = &up else {
        unreachable!()
    };
    let id = conversation.id.clone();
    h.brain.step(Input::from(up));
    let tx = h.tx.clone();
    std::thread::spawn(move || {
        for event in events_rx {
            if tx.send(Input::from(event)).is_err() {
                return;
            }
        }
    });
    (h, id)
}

/// A link bound as [`CHIEF`] whose create request has `title`: its events
/// and its log lines. The link thread runs until the test process ends (the
/// link has no stop); a dropped receiver only drops its events.
fn link(
    daemon: &Daemon,
    token_file: &Path,
    title: &str,
) -> (Receiver<DaemonEvent>, Arc<Mutex<Vec<String>>>) {
    let (events_tx, events_rx) = channel::<DaemonEvent>();
    let events_tx = Mutex::new(events_tx);
    let lines = Arc::new(Mutex::new(Vec::<String>::new()));
    let sink = lines.clone();
    spawn_link(
        &optchat_chief::supervisor::exiting(),
        LinkConfig {
            socket: daemon.socket.clone(),
            token_file: Some(token_file.to_owned()),
            display_name: "Ada".into(),
            title: title.into(),
            participant: CHIEF.into(),
        },
        Arc::new(move |event| {
            let _ = events_tx.lock().unwrap().send(event);
        }),
        Arc::new(move |line: &str| sink.lock().unwrap().push(line.to_owned())),
    );
    (events_rx, lines)
}

/// The link's first Up, within 30 s; else the link's log lines.
fn first_up(events: &Receiver<DaemonEvent>, lines: &Mutex<Vec<String>>) -> DaemonEvent {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        match events.recv_timeout(left) {
            Ok(up @ DaemonEvent::Up { .. }) => return up,
            Ok(_) => {}
            Err(_) => panic!(
                "the link did not come up in 30 s; link log:\n{}",
                lines.lock().unwrap().join("\n")
            ),
        }
    }
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
fn a_renamed_chief_whose_dm_gained_a_participant_keeps_that_dm_and_its_channels() {
    let daemon = Daemon::start();
    let mut me = Conn::open(&daemon.socket);
    // A channel with the Chief, older than its DM: never taken for the DM.
    let channel_id = me.req(
        json!({"cmd": "conversation-create", "idempotency_key": "ch-scout",
        "actor": "user_local", "title": "release", "participants": [
            {"id": "user_local", "kind": "human", "display_name": "Ada"},
            {"id": "user_bob", "kind": "human", "display_name": "Bob"},
            {"id": CHIEF, "kind": "agent", "display_name": "Scout", "agent_class": "mux"}]}),
    )["conversation"]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let token = me.req(json!({"cmd": "conversation-agent-token", "participant": CHIEF}))["token"]
        .as_str()
        .unwrap()
        .to_owned();
    let token_file = daemon.dir.path().join("agent-token");
    std::fs::write(&token_file, format!("{token}\n")).unwrap();

    // 1. The first start creates the DM and answers there with a run.
    let (mut first, dm) = start_brain(&daemon, &token_file, "Scout");
    assert_ne!(dm, channel_id, "a channel never becomes the Chief's DM");
    send(&mut me, &dm, "dm-1", "status?");
    pump(&mut first, "the first DM reply and its run", || {
        !by_chief(&mut me, &dm).is_empty() && !done_runs(&mut me, &dm).is_empty()
    });
    let runs_before = done_runs(&mut me, &dm);
    assert_eq!(runs_before.len(), 1, "{runs_before:?}");
    // The first brain stops; its link stays bound (it has no stop) but no
    // brain reads it, so it answers nothing.
    drop(first);

    // 2. The DM gains a participant; the Chief is renamed and its brain restarts.
    me.req(
        json!({"cmd": "conversation-op", "conversation": dm, "idempotency_key": "add-two",
                  "op": {"kind": "participants.add", "participant":
                         {"id": "agent_two", "kind": "agent", "display_name": "Two"}}}),
    );
    let (mut renamed, again) = start_brain(&daemon, &token_file, "Night Scout");
    assert_eq!(again, dm, "the renamed brain answers in its DM");
    let conversations = of_chief(&mut me);
    assert_eq!(conversations.len(), 2, "no second DM: {conversations:?}");
    let stored = conversations.iter().find(|c| c["id"] == json!(dm)).unwrap();
    assert_eq!(stored["title"], "Scout", "the DM keeps its stored title");
    assert_eq!(done_runs(&mut me, &dm), runs_before, "the DM keeps its run");

    // 3. It answers in the DM again; its runs add up in the same DM.
    send(&mut me, &dm, "dm-2", "and now?");
    pump(&mut renamed, "the second DM reply and its run", || {
        by_chief(&mut me, &dm).len() == 2 && done_runs(&mut me, &dm).len() == 2
    });
    let runs = done_runs(&mut me, &dm);
    assert!(
        runs.iter().any(|r| r["id"] == runs_before[0]["id"]),
        "{runs:?}"
    );

    // 4. A person's message in the channel still wakes it, in that thread.
    let red = send(&mut me, &channel_id, "ch-1", "main is red");
    pump(&mut renamed, "the channel reply", || {
        !by_chief(&mut me, &channel_id).is_empty()
    });
    let answers = by_chief(&mut me, &channel_id);
    assert_eq!(answers.len(), 1, "{answers:?}");
    assert_eq!(answers[0]["thread_root"], red, "{answers:?}");
}

#[test]
#[ignore = "needs CMUX_TUI_BIN"]
fn a_renamed_chief_whose_grown_dm_was_retitled_reconnects_to_it_not_to_a_channel() {
    let daemon = Daemon::start();
    let mut me = Conn::open(&daemon.socket);
    let channel_id = me.req(
        json!({"cmd": "conversation-create", "idempotency_key": "ch-scout",
        "actor": "user_local", "title": "release", "participants": [
            {"id": "user_local", "kind": "human", "display_name": "Ada"},
            {"id": "user_bob", "kind": "human", "display_name": "Bob"},
            {"id": CHIEF, "kind": "agent", "display_name": "Scout", "agent_class": "mux"}]}),
    )["conversation"]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let token = me.req(json!({"cmd": "conversation-agent-token", "participant": CHIEF}))["token"]
        .as_str()
        .unwrap()
        .to_owned();
    let token_file = daemon.dir.path().join("agent-token");
    std::fs::write(&token_file, format!("{token}\n")).unwrap();
    let (first, dm) = start_brain(&daemon, &token_file, "Scout");
    drop(first);
    for (key, op) in [
        (
            "add-two",
            json!({"kind": "participants.add", "participant":
                   {"id": "agent_two", "kind": "agent", "display_name": "Two"}}),
        ),
        (
            "retitle",
            json!({"kind": "title.set", "title": "Scout notes"}),
        ),
    ] {
        me.req(json!({"cmd": "conversation-op", "conversation": dm,
                      "idempotency_key": key, "op": op}));
    }

    let (events, lines) = link(&daemon, &token_file, "Night Scout");
    let DaemonEvent::Up { conversation, .. } = first_up(&events, &lines) else {
        unreachable!()
    };
    assert_eq!(
        conversation.id,
        dm,
        "the link came up with {} (channel {channel_id}); link log:\n{}",
        conversation.id,
        lines.lock().unwrap().join("\n")
    );
    assert_eq!(of_chief(&mut me).len(), 2, "no new conversation");
}
