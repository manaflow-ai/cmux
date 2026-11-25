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
    spawn_tasks(h, vec!["say hello".into()])
}

fn spawn_tasks(h: &mut Harness, tasks: Vec<String>) -> Result<String, String> {
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
            spawner.spawn(tasks, None)
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
fn a_third_failure_is_reported_not_retried_forever() {
    let mut h = Harness::new(default_script());
    {
        let mut inner = h.agents.inner.lock().unwrap();
        for _ in 0..3 {
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

/// acp-chief-issues.md #3: "session/new: agent process closed" (a96, a198,
/// 22 compactor and subagent starts on 2026-10-19) is sr2 or Claude Code
/// exiting while it starts, mostly while the sr2 gateway is slow (its stderr:
/// "read rotation: ... context deadline exceeded", "connection refused").
/// The same spawn a moment later starts. It is tried again, with a pause,
/// up to three tries in all.
#[test]
fn a_harness_that_dies_while_it_starts_is_started_again() {
    let mut h = Harness::new(default_script());
    {
        let mut inner = h.agents.inner.lock().unwrap();
        inner
            .session_errors_once
            .push_back("session/new: agent process closed".into());
        inner.session_errors_once.push_back(
            "session/new: agent process closed (claude-sr2): claude2: read rotation: context deadline exceeded".into(),
        );
    }
    let answer = spawn_one(&mut h).expect("the spawn answers");
    assert!(answer.contains("Started a1"), "{answer}");
    assert_eq!(subagent_sessions(&h), 1);
}

#[test]
fn a_harness_that_dies_three_times_is_reported() {
    let mut h = Harness::new(default_script());
    {
        let mut inner = h.agents.inner.lock().unwrap();
        for _ in 0..3 {
            inner
                .session_errors_once
                .push_back("session/new: agent process closed".into());
        }
    }
    let answer = spawn_one(&mut h).expect("the spawn answers");
    assert!(answer.contains("a1: did not start"), "{answer}");
    assert_eq!(subagent_sessions(&h), 0);
}

#[test]
fn a_harness_that_closes_for_want_of_a_login_is_not_retried() {
    assert!(is_transient_start_failure(
        "session/new: agent process closed"
    ));
    assert!(!is_transient_start_failure(
        "session/new: agent process closed (claude): Not logged in · Please run /login"
    ));
    assert!(!is_transient_start_failure(
        "session/new: agent process closed (codex): unknown option --foo"
    ));
}

/// A spawn's sessions start side by side, not one after another (a session
/// start was the spawn's longest stage, 1.7-2.8 s with Claude Code), and the
/// answer keeps the tasks' order.
#[test]
fn a_spawns_sessions_start_side_by_side() {
    let mut h = Harness::new(default_script());
    h.agents.inner.lock().unwrap().slow_session =
        Some(("optchat-sub".into(), Duration::from_millis(400)));
    let answer = spawn_tasks(
        &mut h,
        vec![
            "count a.md".into(),
            "count b.md".into(),
            "count c.md".into(),
        ],
    )
    .expect("the spawn answers");
    assert!(answer.contains("Started a1, a2, a3"), "{answer}");
    let (a1, a2, a3) = (
        answer.find("- a1:").expect("a1's line"),
        answer.find("- a2:").expect("a2's line"),
        answer.find("- a3:").expect("a3's line"),
    );
    assert!(a1 < a2 && a2 < a3, "{answer}");
    assert_eq!(subagent_sessions(&h), 3);
    let at_once = h.agents.inner.lock().unwrap().slow_starting_max;
    assert!(at_once >= 2, "the three sessions started one at a time");
}

#[test]
fn in_order_keeps_the_order_and_runs_each_once() {
    use optchat_chief::subagents::in_order;
    let out = in_order(9, 4, |k| {
        std::thread::sleep(Duration::from_millis((9 - k as u64) * 5));
        k * 10
    });
    assert_eq!(out, (0..9).map(|k| k * 10).collect::<Vec<_>>());
    assert_eq!(in_order(0, 4, |k| k), Vec::<usize>::new());
    assert_eq!(in_order(3, 1, |k| k), vec![0, 1, 2]);
}
