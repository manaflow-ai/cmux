//! A subagent's spend keeps its harness and session across a Chief host
//! restart (the Chief spend view, 2026-11-02). The fold learned both only
//! from `subagent.start`, held in memory; subagents run for hours, so a host
//! restart before their first answer wrote every later ledger line with no
//! harness and no session: on Leo's Mac, $666 of $712 over 7 days showed as
//! harness "unknown" in `cmux chief usage --by harness`. The brain's durable
//! subagent record now keeps the harness, and `subagent.answer` names both.

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::*;
use optchat_chief::brain::Input;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;
use optchat_chief::trace::Trace;
use optchat_chief::usage;
use serde_json::{Value, json};

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

fn pump<T>(h: &mut Harness, worker: std::thread::JoinHandle<T>) -> T {
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

/// Every trace event named `ev` under `dir`.
fn events(dir: &std::path::Path, ev: &str) -> Vec<Value> {
    let mut out = Vec::new();
    for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let text = std::fs::read_to_string(entry.path()).unwrap_or_default();
        out.extend(
            text.lines()
                .filter_map(|l| serde_json::from_str::<Value>(l).ok())
                .filter(|v| v["ev"] == ev),
        );
    }
    out
}

#[test]
fn a_subagent_answer_names_its_harness_and_session() {
    let mut h = Harness::new(default_script());
    h.brain
        .set_trace(Trace::open(&h.dir.path().join("traces"), false).unwrap());
    h.agents.hold(true);
    let a = spawner(&h);
    let spawned = pump(
        &mut h,
        std::thread::spawn(move || a.spawn(vec!["one".into()], None)),
    )
    .unwrap();
    assert!(spawned.contains("Started a1"), "{spawned}");
    let record = h.brain.state().sub("a1").expect("a1").1.clone();
    assert_eq!(
        record.harness.as_deref(),
        Some("claude"),
        "the durable record keeps the harness a restart would forget"
    );
    let session = record.session_id.clone().expect("a1 has its session");

    h.brain.step(Input::SubagentAnswer {
        id: "a1".into(),
        answer: Ok(json!({"stopReason": "end_turn", "total_cost_usd": 1.25,
            "usage": {"inputTokens": 3, "outputTokens": 4}})),
    });
    let answers = events(&h.dir.path().join("traces"), "subagent.answer");
    let answer = answers.last().expect("the brain traced the answer");
    assert_eq!(answer["harness"], "claude", "{answer}");
    assert_eq!(answer["session"], session.as_str(), "{answer}");
    h.agents.release();
}

#[test]
fn an_answer_after_a_host_restart_keeps_its_harness_and_session() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("traces");
    {
        let trace = Trace::open(&path, false).unwrap();
        trace.emit(
            "subagent.start",
            json!({"id":"a47","session":"sess-47","harness":"claude-sr2-pipe"}),
        );
    }
    // The host restarted: a new trace, whose fold never saw the start.
    let trace = Trace::open(&path, false).unwrap();
    trace.emit(
        "subagent.answer",
        json!({"id":"a47","cost_usd":7.25,"usage":{"input":20,"output":2219},
            "harness":"claude-sr2-pipe","session":"sess-47"}),
    );
    let rows = usage::read(&usage::dir(tmp.path()), 0, u64::MAX).unwrap();
    let row = rows.last().expect("the answer is a ledger line");
    assert_eq!(row.harness.as_deref(), Some("claude-sr2-pipe"));
    assert_eq!(row.session.as_deref(), Some("sess-47"));
    assert_eq!(row.usd, Some(7.25));
}
