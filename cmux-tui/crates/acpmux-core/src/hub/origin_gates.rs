//! Ignored release measurements for the v2 origin record and ownership gates.
//!
//! These gates deliberately exercise the public hub queue and the writer.  They are
//! release-only measurements; ordinary unit tests in `origin_tests` cover the same
//! state transitions with deterministic assertions.

use super::*;
use std::fs::OpenOptions;
use std::io::Write;
fn gate(name: &str, small: u128, god: u128, unit: &str) {
    let line = format!(
        "{{\"name\":\"{name}\",\"small_p95\":{small},\"god_p95\":{god},\"god_p95_all\":{god},\"unit\":\"{unit}\"}}"
    );
    eprintln!("{line}");
    if let Ok(path) = std::env::var("V2_GATE_OUT")
        && let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path)
    {
        let _ = writeln!(file, "{line}");
    }
}

fn row(id: impl Into<String>, activity: u64) -> Summary {
    let mut summary = Summary::new(id);
    summary.origin = "peer".to_owned();
    summary.state = "running".to_owned();
    summary.last_activity = activity;
    summary
}

fn run_origin_states(rows: usize) -> u128 {
    let directory = tempfile::tempdir().expect("origin gate directory");
    let (hub, mut writer) = Hub::open(directory.path(), 101, || 7).expect("open origin gate");
    writer.origin("peer", OriginState::Connected, 1).expect("initial origin");
    for n in 0..rows {
        writer.apply(row(format!("row-{n:05}"), n as u64 + 1)).expect("seed row");
    }
    let before = writer.log.as_ref().expect("origin log").next_seq();
    let subscription = hub.subscribe(&Sub::new("origin-gate", "list")).expect("subscribe");
    for (state, since) in
        [(OriginState::Down, 10), (OriginState::Stale, 20), (OriginState::Connected, 30)]
    {
        hub.origin("peer", state, since).expect("queue origin");
        writer.process_batch();
    }
    let mut origin_ops = 0;
    while let Some(item) = subscription.receiver.try_next() {
        match item {
            ListItem::Origin { .. } => origin_ops += 1,
            other => panic!("origin state gate emitted row op: {other:?}"),
        }
    }
    assert_eq!(origin_ops, 3);
    assert_eq!(writer.log.as_ref().expect("origin log").next_seq() - before, 3);
    assert_eq!(hub.snapshot().len(), rows);
    origin_ops
}

fn run_removed_origin(rows: usize) -> u128 {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    writer.origin("peer", OriginState::Connected, 1).expect("initial origin");
    for n in 0..rows {
        writer.apply(row(format!("row-{n:05}"), n as u64 + 1)).expect("seed row");
    }
    let subscription = hub.subscribe(&Sub::new("remove-gate", "list")).expect("subscribe");
    hub.origin("peer", OriginState::Removed, 2).expect("queue removal");
    let mut batches = 0;
    for _ in 0..(rows / 256 + 8) {
        writer.process_batch();
        batches += 1;
        if hub.snapshot().len() == 0 {
            break;
        }
    }
    assert_eq!(hub.snapshot().len(), 0);
    assert!(matches!(subscription.receiver.try_next(), Some(ListItem::Origin { .. })));
    assert!(subscription.receiver.try_next().is_none());
    assert!(batches <= rows.saturating_add(255) / 256 + 1, "cleanup exceeded bounded batches");
    1
}

#[test]
#[ignore = "release measurement; run with --ignored --release --nocapture"]
fn pr05d_origin_state_ops() {
    gate("v2.pr05d.origin_state_ops", run_origin_states(20), run_origin_states(500), "ops");
}

#[test]
#[ignore = "release measurement; run with --ignored --release --nocapture"]
fn pr05d_removed_origin_batch() {
    gate("v2.pr05d.removed_origin_batch", run_removed_origin(20), run_removed_origin(500), "ops");
}
