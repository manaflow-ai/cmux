//! A Chief that is not the default one acts on its own in a channel
//! (membership.rs). The real brain, with a fake harness, runs over the real
//! daemon link against a real headless cmux-tui daemon (`CMUX_TUI_BIN`),
//! bound as `agent_release` with `GroupWake::Every` on the local owner:
//!
//! - its own DM is its main conversation, and it answers there as itself;
//! - a person's message in a channel it takes part in wakes it with no
//!   mention, and the reply goes into that message's thread;
//! - a reply of exactly NO_REPLY posts nothing;
//! - an agent that is not a Chief never wakes it.
//!
//! And the loop guard (the owner's per-thread budget,
//! cmux_conversation::MAX_AGENT_TURNS): two Chiefs in one channel wake each
//! other and stop at the budget of their thread; a person's post in another
//! thread starts a new budget there and leaves the spent thread quiet; a
//! person's post in the spent thread starts them again.
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

fn agent(id: &str, name: &str) -> Value {
    json!({"id": id, "kind": "agent", "display_name": name, "agent_class": "agent"})
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
            agent("agent_builder", "Builder"),
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
            owner: cmux_chief::rules::USER_LOCAL.into(),
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
        &optchat_chief::supervisor::exiting(),
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

    // 2. An agent that is not a Chief never wakes it.
    let mut builder = Conn::open(&daemon.socket);
    let builder_token = me
        .req(json!({"cmd": "conversation-agent-token", "participant": "agent_builder"}))["token"]
        .as_str()
        .unwrap()
        .to_owned();
    builder.req(
        json!({"cmd": "conversation-bind", "participant": "agent_builder", "token": builder_token}),
    );
    send(
        &mut builder,
        &channel_id,
        "builder-1",
        "Runner tokens rotated.",
    );

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

/// A Chief brain bound as `participant` over the real link; its host.log
/// lines are collected.
struct Chief {
    h: Harness,
    lines: Arc<Mutex<Vec<String>>>,
}

fn start_chief(daemon: &Daemon, me: &mut Conn, participant: &str, title: &str) -> Chief {
    let token =
        me.req(json!({"cmd": "conversation-agent-token", "participant": participant}))["token"]
            .as_str()
            .unwrap()
            .to_owned();
    let token_file = daemon.dir.path().join(format!("{participant}.token"));
    std::fs::write(&token_file, format!("{token}\n")).unwrap();
    let dir = tempfile::tempdir().unwrap();
    let settings = Settings {
        membership: Membership {
            participant: participant.into(),
            owner: cmux_chief::rules::USER_LOCAL.into(),
            group_wake: GroupWake::Every,
            local_side: true,
        },
        ..settings(dir.path())
    };
    let lines = Arc::new(Mutex::new(Vec::<String>::new()));
    let sink = lines.clone();
    // Every turn answers: the Chiefs never choose to stop on their own.
    let always = Box::new(|_: usize, _: &[Value]| {
        let reply = "Noted, over to you.";
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": reply}}),
            ),
            json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
        ]
    });
    let mut h = Harness::configured(
        dir,
        always,
        Arc::new(Mutex::new(Owner::default())),
        settings,
        Arc::new(move |line: &str| sink.lock().unwrap().push(line.to_owned())),
    );
    h.brain.step(Input::from(AgentEvent::Up(Vec::new())));
    let (events_tx, events_rx) = channel::<DaemonEvent>();
    let events_tx = Mutex::new(events_tx);
    spawn_link(
        &optchat_chief::supervisor::exiting(),
        LinkConfig {
            socket: daemon.socket.clone(),
            token_file: Some(token_file),
            display_name: "Ada".into(),
            title: title.into(),
            participant: participant.into(),
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
    Chief { h, lines }
}

/// Runs every Chief's brain for `how_long`, or until `done` holds.
fn pump_all(chiefs: &mut [Chief], how_long: Duration, mut done: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + how_long;
    while Instant::now() < deadline {
        if done() {
            return true;
        }
        for c in chiefs.iter_mut() {
            while let Ok(input) = c.h.rx.try_recv() {
                c.h.brain.step(input);
            }
            if c.h
                .brain
                .next_timer()
                .is_some_and(|at| at <= Instant::now())
            {
                c.h.brain.on_timer();
            }
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    done()
}

/// The Chief messages of thread `root` (replies only), oldest first.
fn chief_replies(me: &mut Conn, conversation: &str, root: &str) -> Vec<Value> {
    messages(me, conversation)
        .into_iter()
        .filter(|m| m["thread_root"] == root)
        .filter(|m| m["author"] == "agent_release" || m["author"] == "agent_infra")
        .collect()
}

#[test]
#[ignore = "needs CMUX_TUI_BIN"]
fn two_chiefs_wake_each_other_stop_at_the_thread_budget_and_a_person_resumes_them() {
    // The owner's per-thread budget (cmux_conversation::MAX_AGENT_TURNS).
    let cap = cmux_conversation::MAX_AGENT_TURNS;
    let daemon = Daemon::start();
    let mut me = Conn::open(&daemon.socket);
    for (key, id, name) in [
        ("dm-release", "agent_release", "Release Chief"),
        ("dm-infra", "agent_infra", "Infra Chief"),
    ] {
        create(
            &mut me,
            key,
            name,
            vec![person("user_local", "Ada"), chief(id, name)],
        );
    }
    let channel_id = create(
        &mut me,
        "ch-ops",
        "ops",
        vec![
            person("user_local", "Ada"),
            chief("agent_release", "Release Chief"),
            chief("agent_infra", "Infra Chief"),
        ],
    );
    let mut chiefs = vec![
        start_chief(&daemon, &mut me, "agent_release", "Release Chief"),
        start_chief(&daemon, &mut me, "agent_infra", "Infra Chief"),
    ];

    // A person's top-level message: both Chiefs answer in its thread, then
    // answer each other until the thread holds the budget of Chief messages.
    let root = send(&mut me, &channel_id, "ops-1", "the release runner is down");
    let reached = pump_all(&mut chiefs, Duration::from_secs(60), || {
        chief_replies(&mut me, &channel_id, &root).len() >= cap
    });
    assert!(
        reached,
        "the Chiefs never reached the budget: {:?}",
        chief_replies(&mut me, &channel_id, &root)
    );
    let authors: std::collections::BTreeSet<String> = chief_replies(&mut me, &channel_id, &root)
        .iter()
        .map(|m| m["author"].as_str().unwrap_or_default().to_owned())
        .collect();
    assert_eq!(authors.len(), 2, "both Chiefs spoke: {authors:?}");
    // Then they stop: nothing more for a while, and at least one says it is paused.
    pump_all(&mut chiefs, Duration::from_secs(5), || false);
    let paused = chief_replies(&mut me, &channel_id, &root).len();
    pump_all(&mut chiefs, Duration::from_secs(5), || false);
    let after = chief_replies(&mut me, &channel_id, &root).len();
    assert_eq!(paused, after, "the Chiefs kept talking after the budget");
    // The owner refuses a reply past the budget, so never more than it.
    assert_eq!(after, cap, "Chief messages in the thread");
    assert!(
        chiefs.iter().any(|c| c
            .lines
            .lock()
            .unwrap()
            .iter()
            .any(|l| l.contains("Chiefs paused"))),
        "no Chief logged the pause"
    );

    // The budget is per thread: a person's new top-level message gets the
    // Chiefs talking in its own thread, up to its own budget, while the spent
    // thread stays quiet (a person's text elsewhere does not reset it).
    let other = send(
        &mut me,
        &channel_id,
        "ops-3",
        "and the cache bucket is full",
    );
    let other_full = pump_all(&mut chiefs, Duration::from_secs(60), || {
        chief_replies(&mut me, &channel_id, &other).len() >= cap
    });
    assert!(
        other_full,
        "the Chiefs did not use the second thread's budget"
    );
    pump_all(&mut chiefs, Duration::from_secs(5), || false);
    assert_eq!(
        chief_replies(&mut me, &channel_id, &other).len(),
        cap,
        "second thread"
    );
    assert_eq!(
        chief_replies(&mut me, &channel_id, &root).len(),
        after,
        "the spent thread stayed quiet after a person wrote elsewhere"
    );

    // A person's message in the spent thread resets it: they talk again
    // there, and stop again.
    let nudge = me.req(json!({"cmd": "conversation-op", "conversation": channel_id,
        "idempotency_key": "ops-2",
        "op": {"kind": "message.send", "client_msg_id": "ops-2", "thread_root": root,
               "reply_to": {"message_id": root, "part_index": 0},
               "parts": [{"type": "text", "text": "still down, keep going"}]}}))["change"]["message"]
        ["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let resumed = pump_all(&mut chiefs, Duration::from_secs(60), || {
        chief_replies(&mut me, &channel_id, &root).len() >= after + cap
    });
    assert!(resumed, "the Chiefs did not resume after {nudge}");
    pump_all(&mut chiefs, Duration::from_secs(5), || false);
    let settled = chief_replies(&mut me, &channel_id, &root).len();
    pump_all(&mut chiefs, Duration::from_secs(5), || false);
    assert_eq!(
        settled,
        chief_replies(&mut me, &channel_id, &root).len(),
        "no second stop"
    );
    assert_eq!(settled, after + cap, "after the nudge");
}
