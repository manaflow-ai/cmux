//! Ignored release measurements for the v2 origin record and ownership gates.
//!
//! These gates deliberately exercise the public hub queue and the writer.  They are
//! release-only measurements; ordinary unit tests in `origin_tests` cover the same
//! state transitions with deterministic assertions.

use super::*;
use std::fs::OpenOptions;
use std::io::Write;
use std::time::Instant;

const SUBMIT_ROUNDS: usize = 5;
const SUBMIT_SAMPLES: usize = 200;

fn p95(values: &mut [u128]) -> u128 {
    values.sort_unstable();
    let rank = (values.len() * 95).div_ceil(100).saturating_sub(1);
    values.get(rank).copied().unwrap_or(1)
}

fn gate(name: &str, small: u128, god: u128, god_all: u128, unit: &str) {
    let line = format!(
        "{{\"name\":\"{name}\",\"small_p95\":{small},\"god_p95\":{god},\"god_p95_all\":{god_all},\"unit\":\"{unit}\"}}"
    );
    eprintln!("{line}");
    if let Ok(path) = std::env::var("V2_GATE_OUT")
        && let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path)
    {
        let _ = writeln!(file, "{line}");
    }
}

fn submit_samples(rows: usize) -> (u128, u128) {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    writer.origin("peer", OriginState::Connected, 1).expect("initial origin");
    for n in 0..rows {
        writer.apply(row(format!("fixture-{n:05}"), n as u64 + 1)).expect("seed row");
    }
    let mut rounds = Vec::with_capacity(SUBMIT_ROUNDS);
    let mut pooled = Vec::with_capacity(SUBMIT_ROUNDS * SUBMIT_SAMPLES);
    for round in 0..SUBMIT_ROUNDS {
        let mut samples = Vec::with_capacity(SUBMIT_SAMPLES);
        for sample in 0..SUBMIT_SAMPLES {
            let summary = row("timed", (round * SUBMIT_SAMPLES + sample + 10_000) as u64);
            let started = Instant::now();
            hub.submit(summary).expect("enqueue submit");
            let elapsed = started.elapsed().as_nanos().max(1);
            samples.push(elapsed);
            pooled.push(elapsed);
            // Keep queue work outside the measured submit path. The same key is
            // reused so the fixture does not grow with the number of samples.
            writer.process_batch();
        }
        rounds.push(p95(&mut samples));
    }
    let best = rounds.into_iter().min().unwrap_or(1);
    let all = p95(&mut pooled);
    (best, all)
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
        if hub.snapshot().is_empty() {
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
    let small = run_origin_states(20);
    let god = run_origin_states(500);
    gate("v2.pr05d.origin_state_ops", small, god, god, "ops");
}

#[test]
#[ignore = "release measurement; run with --ignored --release --nocapture"]
fn pr05d_removed_origin_batch() {
    let small = run_removed_origin(20);
    let god = run_removed_origin(500);
    gate("v2.pr05d.removed_origin_batch", small, god, god, "ops");
}

#[test]
#[ignore = "release measurement; run with --ignored --release --nocapture"]
fn pr05d_submit_time() {
    let (small, _) = submit_samples(20);
    let (god, god_all) = submit_samples(11_000);
    gate("v2.pr05d.submit_time", small, god, god_all, "ns");
}
