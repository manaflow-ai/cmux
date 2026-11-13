//! Ignored release measurements for the v2 origin record and ownership gates.
//!
//! These gates deliberately exercise the public hub queue and the writer.  They are
//! release-only measurements; ordinary unit tests in `origin_tests` cover the same
//! state transitions with deterministic assertions.

use super::*;
use std::fs::OpenOptions;
use std::io::Write;
use std::time::Instant;

const ROUNDS: usize = 5;

fn p95(values: &mut [u128]) -> u128 {
    values.sort_unstable();
    let rank = (values.len() * 95).div_ceil(100).saturating_sub(1);
    values.get(rank).copied().unwrap_or(1)
}

fn gate(name: &str, small: &[u128], god: &[u128]) {
    let mut small_sorted = small.to_vec();
    let mut god_sorted = god.to_vec();
    let small_p95 = p95(&mut small_sorted);
    let god_p95 = p95(&mut god_sorted);
    let line = format!(
        "{{\"name\":\"{name}\",\"small_p95\":{small_p95},\"god_p95\":{god_p95},\"god_p95_all\":{god_p95},\"unit\":\"ns\"}}"
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
    let subscription = hub.subscribe(&Sub::new("origin-gate", "list")).expect("subscribe");
    let started = Instant::now();
    for (state, since) in
        [(OriginState::Down, 10), (OriginState::Stale, 20), (OriginState::Connected, 30)]
    {
        hub.origin("peer", state, since).expect("queue origin");
        writer.process_batch();
    }
    let elapsed = started.elapsed().as_nanos().max(1);
    let mut origin_ops = 0;
    while let Some(item) = subscription.receiver.try_next() {
        match item {
            ListItem::Origin { .. } => origin_ops += 1,
            other => panic!("origin state gate emitted row op: {other:?}"),
        }
    }
    assert_eq!(origin_ops, 3);
    assert_eq!(hub.snapshot().len(), rows);
    elapsed
}

fn run_removed_origin(rows: usize) -> u128 {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    writer.origin("peer", OriginState::Connected, 1).expect("initial origin");
    for n in 0..rows {
        writer.apply(row(format!("row-{n:05}"), n as u64 + 1)).expect("seed row");
    }
    let subscription = hub.subscribe(&Sub::new("remove-gate", "list")).expect("subscribe");
    let started = Instant::now();
    hub.origin("peer", OriginState::Removed, 2).expect("queue removal");
    for _ in 0..(rows / 256 + 8) {
        writer.process_batch();
        if hub.snapshot().len() == 0 {
            break;
        }
    }
    let elapsed = started.elapsed().as_nanos().max(1);
    assert_eq!(hub.snapshot().len(), 0);
    assert!(matches!(subscription.receiver.try_next(), Some(ListItem::Origin { .. })));
    assert!(subscription.receiver.try_next().is_none());
    elapsed
}

#[test]
#[ignore = "release measurement; run with --ignored --release --nocapture"]
fn pr05d_origin_state_ops() {
    let mut small = Vec::with_capacity(ROUNDS);
    let mut god = Vec::with_capacity(ROUNDS);
    for _ in 0..ROUNDS {
        small.push(run_origin_states(20));
        god.push(run_origin_states(500));
    }
    gate("v2.pr05d.origin_state_ops", &small, &god);
}

#[test]
#[ignore = "release measurement; run with --ignored --release --nocapture"]
fn pr05d_removed_origin_batch() {
    let mut small = Vec::with_capacity(ROUNDS);
    let mut god = Vec::with_capacity(ROUNDS);
    for _ in 0..ROUNDS {
        small.push(run_removed_origin(20));
        god.push(run_removed_origin(500));
    }
    gate("v2.pr05d.removed_origin_batch", &small, &god);
}

#[test]
#[ignore = "release measurement; run with --ignored --release --nocapture"]
fn pr05d_origin_limit() {
    let mut small = Vec::with_capacity(ROUNDS);
    let mut god = Vec::with_capacity(ROUNDS);
    for count in [20, 256] {
        for _ in 0..ROUNDS {
            let (hub, mut writer) = Hub::new(SummaryIndex::new());
            let started = Instant::now();
            for n in 0..count {
                writer.origin(&format!("peer-{n:03}"), OriginState::Connected, 1).expect("origin");
            }
            writer.process_batch();
            hub.origin("overflow", OriginState::Down, 2).expect("queue overflow");
            writer.process_batch();
            assert!(hub.snapshot().origin("overflow").is_none());
            let elapsed = started.elapsed().as_nanos().max(1);
            if count == 20 {
                small.push(elapsed);
            } else {
                god.push(elapsed);
            }
        }
    }
    gate("v2.pr05d.origin_limit", &small, &god);
}

#[test]
#[ignore = "release measurement; run with --ignored --release --nocapture"]
fn pr05d_source_refusal() {
    let mut small = Vec::with_capacity(ROUNDS);
    let mut god = Vec::with_capacity(ROUNDS);
    for count in [20, 500] {
        for _ in 0..ROUNDS {
            let (hub, mut writer) = Hub::new(SummaryIndex::new());
            writer.takeover("peer", Source::Mirror).expect("takeover");
            writer.apply_from(Source::Mirror, row("seed", 1)).expect("seed");
            let started = Instant::now();
            for n in 0..count {
                let id = format!("wrong-{n:05}");
                hub.submit_from(Source::V1, row(id.clone(), 2)).expect("enqueue submit");
                hub.remove_from(Source::V1, "peer", &id).expect("enqueue remove");
                writer.process_batch();
            }
            let elapsed = started.elapsed().as_nanos().max(1);
            assert_eq!(hub.snapshot().len(), 1);
            if count == 20 {
                small.push(elapsed);
            } else {
                god.push(elapsed);
            }
        }
    }
    gate("v2.pr05d.source_refusal", &small, &god);
}
