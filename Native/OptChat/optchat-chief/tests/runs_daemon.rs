//! Chief trajectories (cx-traj, 2026-10-14): the Chief writes the run of its
//! turn to the conversation owner as it works (`conversation-runs-v1`). The
//! real brain, with a fake harness that runs a shell call and a file edit,
//! runs over the real daemon link against a real headless cmux-tui daemon
//! (`CMUX_TUI_BIN`); a client reads the run the way the Channels page does
//! (`conversation-runs`, `conversation-run`). The run carries the reply's
//! key, the tool calls with their input, output and changed file, the
//! reply segment, and ends `done` with the session that ran it.
//!
//! Run: `CMUX_TUI_BIN=<cmux-tui target>/debug/cmux-tui cargo test --test
//! runs_daemon -- --ignored`.

mod common;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
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
    stream
        .set_read_timeout(Some(Duration::from_secs(20)))
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
            .prefix("odr")
            .tempdir_in("/tmp")
            .unwrap();
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

/// A 2x2 PNG, the picture a tool call returns.
const PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4z8AARAwQCgAf7gP9i18U1AAAAABJRU5ErkJggg==";

fn working_turn() -> Script {
    Box::new(|_, _| {
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "tool_call",
                json!({"toolCallId": "toolu_sh", "title": "git log -1", "kind": "execute",
                       "rawInput": {"command": "git log -1 --oneline"},
                       "_meta": {"claude": {"tool": "Bash"}}}),
            ),
            update(
                "tool_call_update",
                json!({"toolCallId": "toolu_sh", "status": "completed",
                       "content": [{"type": "content", "content": {"type": "text", "text": "3158c157a2 base autofix"}}]}),
            ),
            update(
                "tool_call",
                json!({"toolCallId": "toolu_edit", "title": "Edit notes.md", "kind": "edit",
                       "rawInput": {"file_path": "/tmp/notes.md", "old_string": "a", "new_string": "b"},
                       "locations": [{"path": "/tmp/notes.md", "line": 3}],
                       "_meta": {"claude": {"tool": "Edit"}}}),
            ),
            update(
                "tool_call_update",
                json!({"toolCallId": "toolu_edit", "status": "completed",
                       "content": [{"type": "diff", "path": "/tmp/notes.md",
                                    "oldText": "one\ntwo\n", "newText": "one\nthree\nfour\n"}]}),
            ),
            update(
                "tool_call",
                json!({"toolCallId": "toolu_shot", "title": "Screenshot", "kind": "read",
                       "rawInput": {"file_path": "/tmp/shot.png"},
                       "_meta": {"claude": {"tool": "Read"}}}),
            ),
            update(
                "tool_call_update",
                json!({"toolCallId": "toolu_shot", "status": "completed",
                       "content": [{"type": "content", "content": {"type": "image", "mimeType": "image/png",
                                    "data": PNG}}]}),
            ),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": "The last commit is 3158c157a2."}}),
            ),
            json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
        ]
    })
}

#[test]
#[ignore = "needs CMUX_TUI_BIN"]
fn the_chief_writes_its_run_to_the_conversation_as_it_works() {
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

    let mut h = Harness::new(working_turn());
    h.brain.step(Input::from(AgentEvent::Up(Vec::new())));
    let (events_tx, events_rx) = channel::<DaemonEvent>();
    let events_tx = Mutex::new(events_tx);
    spawn_link(
        &optchat_chief::supervisor::exiting(),
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

    let asked = request(
        &daemon.socket,
        json!({"id": 3, "cmd": "conversation-op", "conversation": conversation,
               "idempotency_key": "ask-1", "actor": "user_local",
               "op": {"kind": "message.send", "client_msg_id": "ask-1",
                      "parts": [{"type": "text", "text": "what is the last commit?"}]}}),
    );
    assert!(asked["seq"].as_u64().is_some(), "{asked}");
    // The brain hears the message, runs the turn, writes its run and posts.
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut id = 10;
    let (run, reply) = loop {
        assert!(Instant::now() < deadline, "no finished run and reply");
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(50)) {
            h.brain.step(input);
        }
        if h.brain.next_timer().is_some_and(|at| at <= Instant::now()) {
            h.brain.on_timer();
        }
        id += 1;
        let snapshot = request(
            &daemon.socket,
            json!({"id": id, "cmd": "conversation-snapshot", "conversation": conversation, "tail": 10}),
        );
        let reply = snapshot["messages"]
            .as_array()
            .unwrap()
            .iter()
            .find(|m| m["author"] == "agent_mux")
            .cloned();
        id += 1;
        let runs = request(
            &daemon.socket,
            json!({"id": id, "cmd": "conversation-runs", "conversation": conversation}),
        );
        let done = runs["runs"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["status"] == "done")
            .cloned();
        if let (Some(run), Some(reply)) = (done, reply) {
            break (run, reply);
        }
    };
    // The run is the reply's: the page puts it on that message.
    assert_eq!(run["author"], "agent_mux", "{run}");
    assert_eq!(run["turn"], reply["client_msg_id"], "{run} {reply}");
    assert_eq!(run["id"], reply["client_msg_id"], "{run}");
    assert_eq!(run["session"]["kind"], "acpmux", "{run}");
    assert!(run["ended_at"].as_u64().is_some(), "{run}");
    assert!(
        run["answers"].as_array().is_some_and(|a| !a.is_empty()),
        "{run}"
    );

    id += 1;
    let page = request(
        &daemon.socket,
        json!({"id": id, "cmd": "conversation-run", "conversation": conversation,
               "run": run["id"]}),
    );
    let steps = page["steps"].as_array().unwrap();
    let step = |key: &str| {
        steps
            .iter()
            .find(|s| s["id"] == key)
            .unwrap_or_else(|| panic!("no step {key}: {page}"))
    };
    let shell = step("tool:toolu_sh");
    assert_eq!(shell["status"], "done", "{shell}");
    assert_eq!(shell["tool"]["name"], "Bash", "{shell}");
    assert_eq!(
        shell["tool"]["input"]["command"], "git log -1 --oneline",
        "{shell}"
    );
    assert_eq!(
        shell["tool"]["output"], "3158c157a2 base autofix",
        "{shell}"
    );
    let edit = step("tool:toolu_edit");
    assert_eq!(edit["tool"]["files"][0]["path"], "/tmp/notes.md", "{edit}");
    assert_eq!(edit["tool"]["files"][0]["added"], 2, "{edit}");
    assert_eq!(edit["tool"]["files"][0]["removed"], 1, "{edit}");
    assert_eq!(
        edit["tool"]["files"][0]["new_text"], "one\nthree\nfour\n",
        "{edit}"
    );
    let talk = steps
        .iter()
        .find(|s| s["kind"] == "talk")
        .unwrap_or_else(|| panic!("no talk step: {page}"));
    assert_eq!(talk["text"], "The last commit is 3158c157a2.", "{talk}");
    // The picture a tool call returned is an attachment of the conversation its step names.
    let shot = step("tool:toolu_shot");
    let picture = &shot["attachments"][0];
    assert_eq!(picture["mime_type"], "image/png", "{shot}");
    assert_eq!(picture["width"], 2, "{shot}");
    assert_eq!(picture["hash"].as_str().map(str::len), Some(64), "{shot}");
    // In the order the Chief did it.
    assert!(shell["seq"].as_u64() < edit["seq"].as_u64(), "{page}");
    assert!(edit["seq"].as_u64() < talk["seq"].as_u64(), "{page}");
}

/// A Unix client that heard `subscribe` with `chief-live-v1`, as the
/// Channels page does: each `conversation-live`, `conversation-run-changed`
/// and `conversation-changed` event on a channel, in the order it heard them.
fn live_listener(socket: &Path) -> std::sync::mpsc::Receiver<Value> {
    let stream = UnixStream::connect(socket).unwrap();
    let mut writer = stream.try_clone().unwrap();
    writeln!(
        writer,
        "{}",
        json!({"id": 1, "cmd": "set-client-info", "name": "page",
               "capabilities": ["conversation-runs-v1", "chief-live-v1"]})
    )
    .unwrap();
    writeln!(writer, "{}", json!({"id": 2, "cmd": "subscribe"})).unwrap();
    let (tx, rx) = channel();
    std::thread::spawn(move || {
        let _writer = writer;
        for line in BufReader::new(stream).lines() {
            let Ok(line) = line else { return };
            let Ok(value) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            let wanted = matches!(
                value["event"].as_str(),
                Some("conversation-live" | "conversation-run-changed" | "conversation-changed")
            );
            if wanted && tx.send(value).is_err() {
                return;
            }
        }
    });
    rx
}

/// Drives the brain until `done` holds over the live frames heard so far.
fn drive(
    h: &mut Harness,
    live: &std::sync::mpsc::Receiver<Value>,
    conversation: &str,
    frames: &mut Vec<Value>,
    what: &str,
    done: impl Fn(&[Value]) -> bool,
) {
    let deadline = Instant::now() + Duration::from_secs(30);
    while !done(frames) {
        assert!(Instant::now() < deadline, "no {what}: {frames:#?}");
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
        if h.brain.next_timer().is_some_and(|at| at <= Instant::now()) {
            h.brain.on_timer();
        }
        heard(live, conversation, frames);
    }
}

/// What the listener heard so far, in order: each live frame as it is, a run
/// change as `{type: "run.changed", run, status}`, a posted message as
/// `{type: "message", author, client_msg_id}`.
fn heard(live: &std::sync::mpsc::Receiver<Value>, conversation: &str, frames: &mut Vec<Value>) {
    while let Ok(event) = live.try_recv() {
        if event["conversation"] != conversation {
            continue;
        }
        match event["event"].as_str() {
            Some("conversation-live") => frames.push(event["frame"].clone()),
            Some("conversation-run-changed") => frames.push(json!({
                "type": "run.changed", "run": event["run"]["id"], "status": event["run"]["status"]})),
            Some("conversation-changed") if event["change"]["kind"] == "message" => {
                let message = &event["change"]["message"];
                frames.push(json!({"type": "message", "author": message["author"],
                    "client_msg_id": message["client_msg_id"]}));
            }
            _ => {}
        }
    }
}

#[test]
#[ignore = "needs CMUX_TUI_BIN"]
fn the_chief_streams_its_run_live_while_it_works() {
    let daemon = Daemon::start();
    let live = live_listener(&daemon.socket);
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

    // The test hands the turn its events as the model would stream them.
    let mut h = Harness::new(Box::new(|_, _| {
        vec![json!({"dir": "mux", "kind": "turn_started", "msg": {}})]
    }));
    h.agents.hold(true);
    h.brain.step(Input::from(AgentEvent::Up(Vec::new())));
    let (events_tx, events_rx) = channel::<DaemonEvent>();
    let events_tx = Mutex::new(events_tx);
    spawn_link(
        &optchat_chief::supervisor::exiting(),
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
               "idempotency_key": "ask-live", "actor": "user_local",
               "op": {"kind": "message.send", "client_msg_id": "ask-live",
                      "parts": [{"type": "text", "text": "what is the last commit?"}]}}),
    );

    let mut frames: Vec<Value> = Vec::new();
    let has = |frames: &[Value], kind: &str, key: &str, value: &str| {
        frames.iter().any(|f| f["type"] == kind && f[key] == value)
    };
    // The turn starts; its session is the one its prompt went to.
    let deadline = Instant::now() + Duration::from_secs(30);
    let session = loop {
        if let Some(session) = h
            .agents
            .inner
            .lock()
            .unwrap()
            .prompt_sessions
            .last()
            .cloned()
        {
            break session;
        }
        assert!(Instant::now() < deadline, "the turn never started");
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
        if h.brain.next_timer().is_some_and(|at| at <= Instant::now()) {
            h.brain.on_timer();
        }
    };
    // It thinks first.
    h.agents.push_events(
        &session,
        vec![update(
            "agent_thought_chunk",
            json!({"content": {"type": "text", "text": "Looking at the log."}}),
        )],
    );
    drive(
        &mut h,
        &live,
        &conversation,
        &mut frames,
        "thought delta and its line",
        |f| has(f, "step.delta", "step", "thought:0") && has(f, "run.activity", "line", "Thinking"),
    );
    h.agents.push_events(
        &session,
        vec![update(
            "agent_message_chunk",
            json!({"content": {"type": "text", "text": "The last commit"}}),
        )],
    );
    drive(
        &mut h,
        &live,
        &conversation,
        &mut frames,
        "talk delta",
        |f| has(f, "step.delta", "step", "talk:0"),
    );
    h.agents.push_events(
        &session,
        vec![
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": " is 3158c157a2."}}),
            ),
            update(
                "tool_call",
                json!({"toolCallId": "toolu_sh", "title": "git log -1", "kind": "execute",
                       "rawInput": {"command": "git log -1 --oneline"},
                       "_meta": {"claude": {"tool": "Bash"}}}),
            ),
        ],
    );
    drive(
        &mut h,
        &live,
        &conversation,
        &mut frames,
        "the tool's activity",
        |f| has(f, "run.activity", "line", "Running git log -1"),
    );
    // The tool ends and the turn thinks again; it ends while that thought is
    // still open, so the thought's last frame must still come before the end.
    h.agents.push_events(
        &session,
        vec![
            update(
                "tool_call_update",
                json!({"toolCallId": "toolu_sh", "status": "completed",
                       "content": [{"type": "content", "content": {"type": "text", "text": "3158c157a2 base"}}]}),
            ),
            update(
                "agent_thought_chunk",
                json!({"content": {"type": "text", "text": "That is the newest commit."}}),
            ),
        ],
    );
    drive(
        &mut h,
        &live,
        &conversation,
        &mut frames,
        "the second thought",
        |f| has(f, "step.delta", "step", "thought:1"),
    );
    h.agents.push_events(
        &session,
        vec![json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}})],
    );
    h.agents.release();

    // The run ends: the reply is posted and nothing is live any more.
    let mut id = 10;
    let deadline = Instant::now() + Duration::from_secs(30);
    let run = loop {
        assert!(Instant::now() < deadline, "no finished run");
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
        if h.brain.next_timer().is_some_and(|at| at <= Instant::now()) {
            h.brain.on_timer();
        }
        id += 1;
        let runs = request(
            &daemon.socket,
            json!({"id": id, "cmd": "conversation-runs", "conversation": conversation}),
        );
        if let Some(run) = runs["runs"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["status"] == "done")
        {
            break run.clone();
        }
    };
    id += 1;
    let snapshot = request(
        &daemon.socket,
        json!({"id": id, "cmd": "conversation-live", "conversation": conversation}),
    );
    assert_eq!(snapshot["runs"], json!([]), "{snapshot}");

    // The order a page sees: the reply's last live frame, then the run's end,
    // then the reply message (it replaces the streaming text with no jump).
    let deadline = Instant::now() + Duration::from_secs(30);
    let position = |frames: &[Value], test: &dyn Fn(&Value) -> bool| frames.iter().position(test);
    let is_reply = |f: &Value| f["type"] == "message" && f["author"] == "agent_mux";
    while position(&frames, &is_reply).is_none() {
        assert!(Instant::now() < deadline, "no reply message: {frames:#?}");
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
        if h.brain.next_timer().is_some_and(|at| at <= Instant::now()) {
            h.brain.on_timer();
        }
        heard(&live, &conversation, &mut frames);
    }
    let last_frame = position(&frames, &|f| {
        f["type"] == "step.delta" && f["step"] == "talk:0" && f["final"] == true
    })
    .unwrap_or_else(|| panic!("no final reply frame: {frames:#?}"));
    let run_id = frames[last_frame]["run"].clone();
    let ended = position(&frames, &|f| {
        f["type"] == "run.changed" && f["status"] == "done" && f["run"] == run_id
    })
    .unwrap_or_else(|| panic!("no run end: {frames:#?}"));
    let reply = position(&frames, &is_reply).unwrap();
    assert!(
        last_frame < ended && ended < reply,
        "order {last_frame} {ended} {reply}: {frames:#?}"
    );
    // The thought still open when the turn ended got its last frame first too.
    let thought_end = position(&frames, &|f| {
        f["type"] == "step.delta" && f["step"] == "thought:1" && f["final"] == true
    })
    .unwrap_or_else(|| panic!("the open thought got no final frame: {frames:#?}"));
    assert!(
        thought_end < ended,
        "order {thought_end} {ended}: {frames:#?}"
    );
    let frames: Vec<Value> = frames
        .into_iter()
        .filter(|f| f["type"] == "step.delta" || f["type"] == "run.activity")
        .collect();

    // Every frame is the run's; the reply streamed in order, its last frame final.
    assert!(
        frames
            .iter()
            .all(|f| f["run"] == run["id"] && f["conversation"] == conversation.as_str())
    );
    let talk: Vec<&Value> = frames
        .iter()
        .filter(|f| f["type"] == "step.delta" && f["step"] == "talk:0")
        .collect();
    let seqs: Vec<u64> = talk.iter().map(|f| f["seq"].as_u64().unwrap()).collect();
    assert_eq!(
        seqs,
        (0..talk.len() as u64).collect::<Vec<_>>(),
        "{talk:#?}"
    );
    let text: String = talk.iter().map(|f| f["text"].as_str().unwrap()).collect();
    assert_eq!(text, "The last commit is 3158c157a2.");
    assert_eq!(talk.last().unwrap()["final"], true, "{talk:#?}");
    assert_eq!(talk[0]["kind"], "talk");
    // The thought streamed too (never shown by default), ended by its last frame.
    let thought: Vec<&Value> = frames
        .iter()
        .filter(|f| f["type"] == "step.delta" && f["step"] == "thought:0")
        .collect();
    assert!(
        thought.iter().all(|f| f["kind"] == "thought"),
        "{thought:#?}"
    );
    let text: String = thought
        .iter()
        .map(|f| f["text"].as_str().unwrap())
        .collect();
    assert_eq!(text, "Looking at the log.");
    assert_eq!(thought.last().unwrap()["final"], true, "{thought:#?}");
    let activity = frames.iter().find(|f| f["type"] == "run.activity").unwrap();
    assert!(
        activity["since"].as_u64() <= activity["at"].as_u64(),
        "{activity}"
    );
}
