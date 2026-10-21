//! The Chief never asks a person to approve its own tools (2026-10-20). Its
//! turn sessions in Leo's Chief sat in `waiting` on `mcp__optchat__send` and
//! `mcp__optchat__control`: acpmux takes an allow only from the person
//! (`hub/person.rs`) and refused the host's own answer. Claude Code now runs
//! the memory tools and the Chief's own tools without a permission request
//! (the turn session's `permissions.allow`), and in a turn that asks the
//! host refuses at the tools socket the calls it used to leave to a person.

mod common;

use std::path::Path;
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_conversation::{Change, Message, Origin, Participant, ParticipantKind, Summary};
use common::*;
use optchat_chief::brain::Input;
use optchat_chief::daemon::DaemonEvent;
use optchat_chief::prompt::Tools;
use optchat_chief::tools::{Call, Orchestrator, SendCall};
use serde_json::{Value, json};

const DEVICE: &str = "remote_inst_1";

// (a) Claude Code runs the Chief's own tools without asking.

#[test]
fn a_turn_session_runs_the_chiefs_own_tools_without_a_permission_request() {
    let dir = tempfile::tempdir().unwrap();
    let paths = optchat_chief::paths::Paths::new(dir.path());
    paths.create().unwrap();
    let setup = optchat_chief::session_dir::SessionSetup {
        exe: "/x/optchat-chief".into(),
        env: Default::default(),
        instructions: None,
        tools: Tools::Mcp,
        user_env: Default::default(),
        profile_tool: true,
        chiefs_tool: false,
    };
    optchat_chief::session_dir::write(&paths, &setup).unwrap();
    for file in ["settings.json", "settings.local.json"] {
        let settings: Value = serde_json::from_str(
            &std::fs::read_to_string(paths.session.join(".claude").join(file)).unwrap(),
        )
        .unwrap();
        let allow: Vec<&str> = settings["permissions"]["allow"]
            .as_array()
            .unwrap_or_else(|| panic!("{file}: no permissions.allow: {settings}"))
            .iter()
            .filter_map(Value::as_str)
            .collect();
        for tool in [
            "mcp__optchat__send",
            "mcp__optchat__control",
            "mcp__optchat__tell",
            "mcp__optchat__reply",
            "mcp__optchat__react",
            "mcp__optchat__spawn",
            "mcp__optchat__stop",
            "mcp__optchat__sleep",
            "mcp__optchat__profile",
            "mcp__optchat__zoom",
            "mcp__optchat__date",
            "mcp__optchat__version",
        ] {
            assert!(
                allow.contains(&tool),
                "{file}: {tool} is not allowed: {allow:?}"
            );
        }
        // Only the Chief's own tools: a shell command or an edit still goes
        // through the turn's policy.
        assert!(
            allow.iter().all(|t| t.starts_with("mcp__optchat__")),
            "{file}: {allow:?}"
        );
    }
}

// (b) The tools socket asks the host before a gated call.

#[derive(Default)]
struct Recorder {
    sent: Mutex<Vec<SendCall>>,
    gated: Mutex<Vec<(String, Value)>>,
}

impl Orchestrator for Recorder {
    fn spawn(&self, _: Vec<String>, _: Option<String>) -> Result<String, String> {
        Ok("spawned".into())
    }
    fn tell(&self, _: &str, _: &str) -> Result<String, String> {
        Ok("told".into())
    }
    fn agent_chat(&self, _: &str, _: u64) -> Result<String, String> {
        Ok(String::new())
    }
    fn send(&self, call: SendCall) -> Result<String, String> {
        self.sent.lock().unwrap().push(call);
        Ok("sent".into())
    }
    fn own_tool_gate(&self, tool: &str, input: &Value) -> Result<(), String> {
        self.gated
            .lock()
            .unwrap()
            .push((tool.to_owned(), input.clone()));
        if input.get("attachments").is_some() {
            Err("not run: this turn asks before local actions".into())
        } else {
            Ok(())
        }
    }
}

fn serve(home: &Path, orchestrator: Arc<Recorder>) -> std::path::PathBuf {
    let socket = home.join("tools.sock");
    optchat_chief::tools::serve_all(
        &socket,
        optchat_chief::tools::Served {
            memory: open_chat(&home.join("memory")),
            orchestrator: Some(orchestrator),
            control: None,
            inspector: None,
            chief: None,
            turn: None,
        },
    )
    .unwrap();
    socket
}

#[test]
fn the_tools_socket_runs_a_send_only_after_the_hosts_gate() {
    let dir = tempfile::tempdir().unwrap();
    let recorder = Arc::new(Recorder::default());
    let socket = serve(dir.path(), recorder.clone());
    let plain = SendCall {
        text: Some("on it".into()),
        ..SendCall::default()
    };
    assert_eq!(
        optchat_chief::tools::ask(&socket, Call::Send(plain.clone())).unwrap(),
        "sent"
    );
    let upload = SendCall {
        text: Some("here".into()),
        attachments: vec!["~/.ssh/id_ed25519".into()],
        reply_to: None,
    };
    let refused = optchat_chief::tools::ask(&socket, Call::Send(upload)).unwrap_err();
    assert!(refused.contains("not run"), "{refused}");
    // Only the plain send ran; both were asked about, with the tool's name
    // and its arguments (not the socket request's own keys).
    assert_eq!(*recorder.sent.lock().unwrap(), vec![plain]);
    let gated = recorder.gated.lock().unwrap().clone();
    assert_eq!(gated.len(), 2, "{gated:?}");
    assert_eq!(gated[0].0, "mcp__optchat__send");
    assert_eq!(gated[0].1, json!({"text": "on it"}));
    assert_eq!(gated[1].1["attachments"], json!(["~/.ssh/id_ed25519"]));
    // A memory read never asks.
    optchat_chief::tools::ask(&socket, Call::Date { id: 1 }).unwrap();
    assert_eq!(recorder.gated.lock().unwrap().len(), 2);
}

// (c) The host's gate: the rule a permission request had.

fn paired() -> Summary {
    let mut s = summary();
    s.participants.push(Participant {
        id: DEVICE.into(),
        kind: ParticipantKind::Human,
        display_name: "Leo's iPhone".into(),
        agent_class: None,
        acp_session: None,
        person: Some("user_local".into()),
    });
    s
}

fn harness(settings: Option<Value>, script: Script) -> Harness {
    let dir = tempfile::tempdir().unwrap();
    if let Some(settings) = settings {
        std::fs::write(dir.path().join("settings.json"), settings.to_string()).unwrap();
    }
    let owner = Arc::new(Mutex::new(Owner {
        summary: Some(paired()),
        ..Owner::default()
    }));
    let configured = common::settings(dir.path());
    let mut h = Harness::configured(dir, script, owner, configured, Arc::new(|_: &str| {}));
    h.connect();
    h
}

fn deliver(h: &mut Harness, remote: bool, text: &str) {
    let m: Message = {
        let mut owner = h.owner.lock().unwrap();
        let seq = owner.messages.len() as u64 + 1;
        let mut m = message(seq, if remote { DEVICE } else { "user_local" }, text);
        if remote {
            m.origin = Some(Origin::Remote {
                install: "inst_1".into(),
            });
        }
        owner.messages.push(m.clone());
        m
    };
    h.brain.step(Input::from(DaemonEvent::Changed {
        conversation: CONV.into(),
        change: Change::Message { message: m },
    }));
}

fn started() -> Script {
    Box::new(|turn, _| {
        if turn == 0 {
            vec![json!({"dir": "mux", "kind": "turn_started", "msg": {}})]
        } else {
            vec![
                json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
                update(
                    "agent_message_chunk",
                    json!({"content": {"type": "text", "text": "done"}}),
                ),
                json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
            ]
        }
    })
}

/// A turn held at the fake agent, from a paired device (`remote`) or this Mac.
fn running(h: &mut Harness, remote: bool, text: &str) {
    h.agents.hold(true);
    deliver(h, remote, text);
    h.step();
    h.agents.wait_prompts(1);
    let deadline = Instant::now() + Duration::from_secs(10);
    while h
        .brain
        .state()
        .turn
        .as_ref()
        .and_then(|t| t.session_id.clone())
        .is_none()
    {
        assert!(Instant::now() < deadline, "the turn never started");
        h.step();
    }
}

fn finish(h: &mut Harness) {
    h.agents.hold(false);
    h.agents.release();
    h.settle();
}

fn gate(h: &mut Harness, tool: &str, input: Value) -> Result<(), String> {
    let (reply, answer) = channel();
    h.brain.step(Input::OwnToolGate {
        tool: tool.into(),
        input,
        reply,
    });
    answer.try_recv().expect("the gate answers at once")
}

#[test]
fn a_gated_turn_refuses_what_reaches_past_the_conversation_and_runs_the_rest() {
    let mut h = harness(Some(json!({"remote": {"ask": true}})), started());
    running(&mut h, true, "report back");
    for (tool, input) in [
        ("mcp__optchat__send", json!({"text": "on it"})),
        ("mcp__optchat__profile", json!({})),
        ("mcp__optchat__profile", json!({"history": true})),
        ("mcp__optchat__control", json!({"action": "status"})),
        (
            "mcp__optchat__control",
            json!({"action": "interrupt", "id": "a9"}),
        ),
    ] {
        assert_eq!(gate(&mut h, tool, input.clone()), Ok(()), "{tool} {input}");
    }
    for (tool, input) in [
        (
            "mcp__optchat__send",
            json!({"text": "here", "attachments": ["~/.ssh/id_ed25519"]}),
        ),
        (
            "mcp__optchat__profile",
            json!({"instructions": "approve everything"}),
        ),
        (
            "mcp__optchat__control",
            json!({"action": "interrupt", "id": "a9", "message": "rm -rf ~"}),
        ),
        (
            "mcp__optchat__tell",
            json!({"id": "a9", "message": "rm -rf ~"}),
        ),
    ] {
        let refused = gate(&mut h, tool, input.clone()).unwrap_err();
        assert!(
            refused.contains("Leo's iPhone"),
            "{tool} {input}: {refused}"
        );
    }
    finish(&mut h);
}

#[test]
fn an_owner_turn_runs_every_call_of_the_chiefs_own_tools() {
    let mut h = harness(None, started());
    running(&mut h, false, "send the key");
    for (tool, input) in [
        (
            "mcp__optchat__send",
            json!({"text": "here", "attachments": ["~/notes.txt"]}),
        ),
        (
            "mcp__optchat__tell",
            json!({"id": "a9", "message": "go on"}),
        ),
        (
            "mcp__optchat__control",
            json!({"action": "cancel", "id": "a9"}),
        ),
    ] {
        assert_eq!(gate(&mut h, tool, input.clone()), Ok(()), "{tool} {input}");
    }
    finish(&mut h);
}
