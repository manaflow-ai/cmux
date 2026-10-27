//! Chief fast eval, group `acp` (deterministic, no model call): what the Chief sends an agent
//! reaches that agent's ACP chat in cmux-next as a turn there, live, and a tell interrupts by
//! default (Lawrence, 2026-10-26: "Chief must send messages to ACP GUIs"; "with interrupt by
//! default"; the person opens the chat from the link).
//!
//! The chat a subagent's workspace shows is the SAME acpmux session the Chief drives
//! (`workspaces.rs`), so every check here is on what the Chief sends that session:
//! - the task and every tell carry an `optchat-<kind>:` prompt id, which the pane draws as the
//!   Chief's message (webviews agent-session/acpmux/direct.ts, `from: "chief"`);
//! - a tell into a running turn is a steer sent now (`_meta.acpmux.steerNow`): the agent's current
//!   step stops and it reads the message at once, as the pane's Send now does. acpmux never stops a
//!   running subagent or background shell for it (claude_stdio steer_now_tests.rs);
//! - another subagent's message (`peer_tell`) never cuts the turn: it waits for the step;
//! - the steer goes over the wire with `steerNow` (acpmux hub `steer_turn`; acpmux_wire.rs
//!   `a_steer_sent_now_carries_steer_now_over_the_wire`).

mod common;

use std::sync::Arc;
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;

fn spawner(h: &Harness) -> Arc<Spawner> {
    Arc::new(Spawner::new(
        h.chat.clone(),
        h.agents.clone(),
        SubagentSettings {
            harness: "claude".into(),
            policy: "approve-all".into(),
            model: None,
            effort: None,
            preset: Some("optchat-sub-h0me".into()),
            cwd: h.dir.path().join("subagent"),
            prefix: "optchat-sub-h0me".into(),
            parent: optchat_chief::brain::PARENT.into(),
            claude_md: None,
        },
        h.tx.clone(),
        Arc::new(|_: &str| {}),
    ))
}

/// Runs `f` on its own thread while the brain takes its inputs.
fn run<T: Send + 'static>(h: &mut Harness, f: impl FnOnce() -> T + Send + 'static) -> T {
    let worker = std::thread::spawn(f);
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    while let Ok(input) = h.rx.recv_timeout(Duration::from_millis(80)) {
        h.brain.step(input);
    }
    worker.join().unwrap()
}

fn wait_for(h: &mut Harness, what: impl Fn(&Harness) -> bool) {
    let until = Instant::now() + Duration::from_secs(5);
    while !what(h) && Instant::now() < until {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    assert!(what(h), "timed out");
}

/// Two running subagents (their turns held), steering on.
fn two_running() -> (Harness, Arc<Spawner>) {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let sp = spawner(&h);
    let a = sp.clone();
    let spawned = run(&mut h, move || {
        a.spawn(
            vec![
                "Tab mute click path\n\nthe speaker".into(),
                "Pane tab mute button\n\nmake it clickable".into(),
            ],
            None,
        )
    })
    .unwrap();
    assert!(spawned.contains("a2"), "{spawned}");
    wait_for(&mut h, |h| {
        let inner = h.agents.inner.lock().unwrap();
        inner
            .prompt_ids
            .iter()
            .filter(|p| p.starts_with("optchat-sub:"))
            .count()
            >= 2
    });
    h.agents.inner.lock().unwrap().steering = true;
    (h, sp)
}

fn steer_with(h: &Harness, needle: &str) -> Option<(String, bool)> {
    let inner = h.agents.inner.lock().unwrap();
    inner
        .steers
        .iter()
        .zip(&inner.steer_ids)
        .find(|((_, b), _)| serde_json::to_string(b).unwrap().contains(needle))
        .map(|(_, id)| id.clone())
}

/// The task is the chat's first turn, marked as the Chief's.
#[test]
fn a_spawned_task_is_the_agent_chats_first_turn_from_the_chief() {
    let (h, _sp) = two_running();
    let inner = h.agents.inner.lock().unwrap();
    let subs: Vec<&String> = inner
        .prompt_ids
        .iter()
        .filter(|p| p.starts_with("optchat-sub:a"))
        .collect();
    assert_eq!(subs.len(), 2, "{:?}", inner.prompt_ids);
    assert!(subs[0].starts_with("optchat-sub:a1:"), "{subs:?}");
}

/// The Chief's tell into a running turn is steered in and sent now: the step stops, the agent
/// reads it at once, and the pane draws it as the Chief's message.
#[test]
fn a_chief_tell_into_a_running_turn_interrupts_the_step_by_default() {
    let (mut h, sp) = two_running();
    let a = sp.clone();
    let told = run(&mut h, move || {
        a.tell("a1", "stop: the user changed the scope")
    })
    .unwrap();
    assert!(told.starts_with("outcome: done"), "{told}");
    wait_for(&mut h, |h| {
        steer_with(h, "the user changed the scope").is_some()
    });
    let (id, now) = steer_with(&h, "the user changed the scope").unwrap();
    assert!(id.starts_with("optchat-tell:a1:"), "{id}");
    assert!(
        now,
        "the Chief's tell waited for the agent's step instead of stopping it"
    );
}

/// Another subagent's message never cuts the receiver's step: it is read when the step ends.
#[test]
fn a_peer_tell_waits_for_the_step() {
    let (mut h, sp) = two_running();
    let a = sp.clone();
    run(&mut h, move || {
        a.peer_tell(
            "a1",
            "a2",
            "the click path is TabCell.audioButtonRect",
            None,
        )
    })
    .unwrap();
    wait_for(&mut h, |h| {
        steer_with(h, "TabCell.audioButtonRect").is_some()
    });
    let (id, now) = steer_with(&h, "TabCell.audioButtonRect").unwrap();
    assert!(id.starts_with("optchat-fyi:a2:"), "{id}");
    assert!(!now, "a peer's message stopped the receiver's step");
}
