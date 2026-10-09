//! Interruptions (decision 2026-10-09, parity with the reference client): a
//! message never stops a turn, on any engine. It is steered in between tool
//! calls when the harness steers (Claude Code, codex-acp); a steer that
//! fails goes back to the head of the queue and the next turn starts the
//! moment this one ends; messages that arrive while a turn waits for settle
//! go into that same call. Only chief.stop stops a turn (engine_control.rs).

mod common;

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use common::*;
use optchat_chief::acpmux::Family;
use optchat_chief::brain::Settings;
use serde_json::{Value, json};

/// A turn that is still at work (its end comes from the test).
fn working() -> Vec<Value> {
    vec![
        json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
        update(
            "agent_message_chunk",
            json!({"content": {"type": "text", "text": "Working."}}),
        ),
    ]
}

fn ends(reply: &str) -> Vec<Value> {
    vec![
        update(
            "agent_message_chunk",
            json!({"content": {"type": "text", "text": reply}}),
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

/// Lawrence's sidebar engine: a Chief on codex (codex-acp steers).
fn codex() -> Harness {
    let dir = tempfile::tempdir().unwrap();
    let settings = Settings {
        harness: "codex".into(),
        families: BTreeMap::from([
            ("claude-sr".to_owned(), Family::Claude),
            ("codex".to_owned(), Family::Codex),
        ]),
        codex_preset: Some("optchat-chief-codex-h0me".into()),
        ..settings(dir.path())
    };
    let owner = Arc::new(Mutex::new(Owner {
        summary: Some(summary()),
        ..Owner::default()
    }));
    Harness::configured(
        dir,
        Box::new(|turn, _| {
            assert_eq!(turn, 0, "one turn answers both");
            working()
        }),
        owner,
        settings,
        Arc::new(|_: &str| {}),
    )
}

#[test]
fn a_message_during_a_codex_turn_is_steered_never_a_stop() {
    let mut h = codex();
    h.agents.inner.lock().unwrap().steering = true;
    h.agents.hold(true);
    h.connect();
    h.say("user_local", "A: count the files");
    h.step(); // settled: the turn starts
    h.step(); // the turn's session exists
    h.agents.wait_prompts(1);
    h.say("user_local", "B: also the lines");
    h.agents.wait_steers(1);
    h.agents.push_events("s1", ends("12 files, 340 lines."));
    h.agents.hold(false);
    h.agents.release();
    h.settle();
    let inner = h.agents.inner.lock().unwrap();
    assert!(inner.cancels.is_empty(), "no session/cancel");
    assert_eq!(inner.specs[0].harness, "codex");
    assert_eq!(inner.prompts.len(), 1);
    drop(inner);
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(sends.len(), 1, "{sends:?}");
}

#[test]
fn a_failed_steer_never_stops_the_turn_and_the_next_turn_answers() {
    let mut h = Harness::new(Box::new(|turn, _| {
        if turn == 0 {
            working()
        } else {
            ends("B answered.")
        }
    }));
    {
        let mut inner = h.agents.inner.lock().unwrap();
        inner.steering = true;
        inner.steer_errors = 1;
    }
    h.agents.hold(true);
    h.connect();
    h.say("user_local", "A");
    h.step();
    h.step();
    h.agents.wait_prompts(1);
    h.say("user_local", "B");
    // The failed steer comes back to the brain.
    let deadline = std::time::Instant::now() + WAIT;
    while h.agents.inner.lock().unwrap().failed_steers == 0 {
        assert!(std::time::Instant::now() < deadline, "no steer was tried");
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
    }
    for _ in 0..10 {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(30)) {
            h.brain.step(input);
        }
    }
    assert!(
        h.agents.inner.lock().unwrap().cancels.is_empty(),
        "a failed steer is no stop"
    );
    h.agents.push_events("s1", ends("A answered."));
    h.agents.hold(false);
    h.agents.release();
    h.agents.release();
    h.settle_posts();
    assert!(h.agents.inner.lock().unwrap().cancels.is_empty());
    assert_eq!(
        new_messages(&h),
        vec!["A", "B"],
        "B is the next turn's head"
    );
    let sends: Vec<String> = h
        .owner
        .lock()
        .unwrap()
        .sends()
        .into_iter()
        .map(|(_, t)| t)
        .collect();
    assert_eq!(sends, vec!["Working.A answered.", "B answered."]);
}

#[test]
fn messages_during_settle_go_into_one_call() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "A");
    h.say("user_local", "B");
    h.say("user_local", "C");
    h.settle();
    assert_eq!(
        new_messages(&h),
        vec!["A\n\nB\n\nC"],
        "one call answers all"
    );
    assert!(h.agents.inner.lock().unwrap().cancels.is_empty());
}
