//! Regressions from audit round 3 and the interrupt decision (m6): each
//! test failed before its fix.

mod common;

use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_chief::acp::SessionSummary;
use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::brain::Input;
use optchat_chief::state::{HostState, PendingTurn, StateFile};
use serde_json::{Value, json};

/// A turn that says something and then runs a tool that has not finished.
fn tool_in_flight() -> Vec<Value> {
    vec![
        json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
        update(
            "agent_message_chunk",
            json!({"content": {"type": "text", "text": "Running the build."}}),
        ),
        update(
            "tool_call",
            json!({"toolCallId": "t0", "title": "Bash", "status": "in_progress", "rawInput": {"command": "make"}, "_meta": {"claude": {"tool": "Bash"}}}),
        ),
    ]
}

fn tool_done() -> Vec<Value> {
    vec![update(
        "tool_call_update",
        json!({"toolCallId": "t0", "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": "build ok"}}]}),
    )]
}

fn plain(text: &str) -> Vec<Value> {
    vec![
        json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
        update(
            "agent_message_chunk",
            json!({"content": {"type": "text", "text": text}}),
        ),
        json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
    ]
}

fn new_messages(h: &Harness) -> Vec<String> {
    h.agents
        .inner
        .lock()
        .unwrap()
        .prompts
        .iter()
        .map(|p| p.last().unwrap()["text"].as_str().unwrap().to_owned())
        .collect()
}

/// Lets the held turns run once `cancels` cancels are in.
fn release_after_cancel(agents: &Arc<FakeAgents>, cancels: usize) {
    let agents = agents.clone();
    std::thread::spawn(move || {
        agents.wait_cancels(cancels);
        agents.hold(false);
        agents.release();
    });
}

// M4: turn sessions are named per home, so two tagged homes on one acpmux
// daemon never remove each other's turns.
#[test]
fn turn_session_names_carry_the_home_id() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "hi");
    h.settle();
    let inner = h.agents.inner.lock().unwrap();
    assert_eq!(inner.specs[0].name, format!("{TURN_PREFIX}-0"));
    assert_eq!(inner.finds, vec![format!("{TURN_PREFIX}-0")]);
}

fn restart_with_pending(session: &str) -> Harness {
    let dir = tempfile::tempdir().unwrap();
    StateFile::new(&dir.path().join("host.json"))
        .save(&HostState {
            conversation: Some(CONV.into()),
            turn: Some(PendingTurn {
                key: String::new(),
                conversation: Some(CONV.into()),
                session: session.into(),
                first_id: Some(0),
                ..Default::default()
            }),
            ..Default::default()
        })
        .unwrap();
    let owner = Arc::new(Mutex::new(Owner {
        summary: Some(summary()),
        ..Owner::default()
    }));
    let mut h = Harness::in_dir(dir, default_script(), owner);
    h.connect();
    h
}

#[test]
fn recovery_removes_only_this_homes_turn_sessions() {
    let h = restart_with_pending(&format!("{TURN_PREFIX}-3"));
    assert_eq!(
        h.agents.inner.lock().unwrap().finds,
        vec![format!("{TURN_PREFIX}-3")]
    );
    // A name without this home's id (a host before the fix, or another
    // home's) is never looked up, so never killed.
    let h = restart_with_pending("optchat-3");
    assert!(h.agents.inner.lock().unwrap().finds.is_empty());
}

// m7: the brain keeps only its own children's sessions.
#[test]
fn the_brain_does_not_keep_every_session_it_hears_about() {
    let mut h = Harness::new(default_script());
    h.connect();
    for i in 0..200 {
        let s: SessionSummary = serde_json::from_value(json!({
            "sessionId": format!("c{i}"), "name": format!("optchat-compact-x-0-{i}"),
            "status": "closed"
        }))
        .unwrap();
        h.brain.step(Input::from(AgentEvent::SessionChanged(s)));
    }
    assert_eq!(h.brain.known_sessions(), 0);
}

// Decision 2026-10-09 (replaces m6 of 2026-10-04): a message never stops
// a turn. This fake session does not steer, so "thanks" waits for the turn
// to end and the next turn answers it.
#[test]
fn thanks_during_a_tool_waits_for_the_turn_and_the_next_turn_answers() {
    let mut h = Harness::new(Box::new(|turn, _| {
        if turn == 0 {
            tool_in_flight()
        } else {
            plain("You're welcome.")
        }
    }));
    h.agents.hold(true);
    h.connect();
    h.say("user_local", "build it");
    h.step(); // settled: the turn starts
    h.agents.wait_prompts(1);
    h.say("user_local", "thanks");
    std::thread::sleep(Duration::from_millis(400));
    assert!(
        h.agents.inner.lock().unwrap().cancels.is_empty(),
        "the turn is not stopped"
    );
    h.agents.push_events("s1", tool_done());
    h.agents.hold(false);
    h.agents.release();
    h.agents.release();
    h.settle_posts();
    assert!(h.agents.inner.lock().unwrap().cancels.is_empty());
    assert_eq!(new_messages(&h), vec!["build it", "thanks"]);
    let log: Vec<(String, String)> = h.log();
    let kinds: Vec<&str> = log.iter().map(|(k, _)| k.as_str()).collect();
    assert_eq!(
        &kinds[..5],
        &["user", "talk", "tool", "echo", "user"],
        "the tool's result is logged before the new message: {log:?}"
    );
    assert_eq!(log[3].1, "build ok");
    let sends: Vec<String> = h
        .owner
        .lock()
        .unwrap()
        .sends()
        .into_iter()
        .map(|(_, t)| t)
        .collect();
    assert_eq!(sends, vec!["Running the build.", "You're welcome."]);
}

#[test]
fn thanks_while_the_model_writes_never_stops_it() {
    let mut h = Harness::new(Box::new(|turn, _| {
        if turn == 0 {
            vec![
                json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
                update(
                    "agent_thought_chunk",
                    json!({"content": {"type": "text", "text": "thinking"}}),
                ),
            ]
        } else {
            plain("You're welcome.")
        }
    }));
    h.agents.hold(true);
    h.connect();
    h.say("user_local", "plan the release");
    h.step();
    h.agents.wait_prompts(1);
    h.say("user_local", "thanks");
    h.agents.hold(false);
    h.agents.release();
    h.agents.release();
    h.settle();
    assert!(h.agents.inner.lock().unwrap().cancels.is_empty());
    assert_eq!(new_messages(&h), vec!["plan the release", "thanks"]);
}

// Audit round 2 race: a cancel (chief.stop) that reached acpmux before its
// prompt is lost; the runner sends it again until the turn ends.
#[test]
fn a_lost_cancel_is_sent_again_until_the_turn_ends() {
    let mut h = Harness::new(Box::new(|turn, _| {
        if turn == 0 {
            vec![json!({"dir": "mux", "kind": "turn_started", "msg": {}})]
        } else {
            plain("ok")
        }
    }));
    h.agents.hold(true);
    h.agents.inner.lock().unwrap().ignore_cancels = 1;
    h.connect();
    h.say("user_local", "first");
    h.step();
    h.agents.wait_prompts(1);
    release_after_cancel(&h.agents, 2);
    // Only an explicit stop stops a turn (decision 2026-10-09).
    let (reply, answer) = std::sync::mpsc::channel();
    h.brain.step(Input::Stop { reply });
    assert_eq!(answer.recv().unwrap(), json!({"stopped": true}));
    h.settle();
    assert_eq!(h.agents.inner.lock().unwrap().cancels, vec!["s1", "s1"]);
    assert_eq!(new_messages(&h), vec!["first"]);
}
