//! A subagent whose agent host misses acpmux's startup handshake is started
//! once more instead of failing the spawn (a10, 2026-10-13: "did not start
//! (session/new: agent host did not answer hello within 5s)"; the same
//! spawn right after started).

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::*;
use optchat_chief::subagents::{Spawner, SubagentSettings, is_transient_start_failure};

fn spawn_one(h: &mut Harness) -> Result<String, String> {
    let spawner = Arc::new(Spawner::new(
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
    ));
    let worker = {
        let spawner = spawner.clone();
        std::thread::spawn(move || {
            use optchat_chief::tools::Orchestrator;
            spawner.spawn(vec!["say hello".into()], None)
        })
    };
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
    }
    while let Ok(input) = h.rx.recv_timeout(Duration::from_millis(50)) {
        h.brain.step(input);
    }
    worker.join().unwrap()
}

fn subagent_sessions(h: &Harness) -> usize {
    h.agents
        .inner
        .lock()
        .unwrap()
        .specs
        .iter()
        .filter(|s| s.tags.contains_key("optchat.subagent"))
        .count()
}

#[test]
fn a_host_that_misses_its_hello_is_started_once_more() {
    let mut h = Harness::new(default_script());
    h.agents
        .inner
        .lock()
        .unwrap()
        .session_errors_once
        .push_back("session/new: agent host did not answer hello within 5s".into());
    let answer = spawn_one(&mut h).expect("the spawn answers");
    assert!(answer.contains("Started a1"), "{answer}");
    assert!(!answer.contains("did not start"), "{answer}");
    assert_eq!(subagent_sessions(&h), 1);
}

#[test]
fn a_second_failure_is_reported_not_retried_forever() {
    let mut h = Harness::new(default_script());
    {
        let mut inner = h.agents.inner.lock().unwrap();
        for _ in 0..2 {
            inner
                .session_errors_once
                .push_back("session/new: agent host did not answer hello within 5s".into());
        }
    }
    let answer = spawn_one(&mut h).expect("the spawn answers");
    assert!(answer.contains("a1: did not start"), "{answer}");
    assert_eq!(subagent_sessions(&h), 0);
}

#[test]
fn only_host_start_failures_are_transient() {
    assert!(is_transient_start_failure(
        "session/new: agent host did not answer hello within 5s"
    ));
    assert!(is_transient_start_failure(
        "agent host exited before it was ready"
    ));
    assert!(!is_transient_start_failure(
        "Not logged in · Please run /login"
    ));
    assert!(!is_transient_start_failure(
        "session/new: env key X is not one a session may set"
    ));
}
