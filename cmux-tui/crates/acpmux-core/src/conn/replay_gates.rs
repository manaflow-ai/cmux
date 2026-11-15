//! Release measurements for the byte-ring replay path.
//!
//! These tests intentionally exercise the public connection source and the real hub writer.
//! They are ignored because they are Linux release gates, not unit tests.

use super::{HubSource, run};
use crate::hub::{Hub, HubWriter, RawRead};
use crate::wire::{DeltaFrame, DeltaOp, Frame, FrameKind, MAX_REPLAY_FRAME_BYTES, Sub};
use acpmux_book::index::{Summary, SummaryIndex};
use serde_json::json;
use std::fs::OpenOptions;
use std::io::Write;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::{Duration, Instant};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::time::timeout;

const ROUNDS: usize = 5;
const SAMPLES: usize = 200;

fn emit(name: &str, small: u128, god: u128, god_all: u128, unit: &str) {
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

fn p95(samples: &[u128]) -> u128 {
    let mut sorted = samples.to_vec();
    sorted.sort_unstable();
    sorted[((sorted.len() * 95).saturating_add(99) / 100).saturating_sub(1)]
}

fn p50(samples: &[u128]) -> u128 {
    let mut sorted = samples.to_vec();
    sorted.sort_unstable();
    sorted[((sorted.len() + 1) / 2).saturating_sub(1)]
}

fn best_p95(rounds: &[Vec<u128>]) -> u128 {
    rounds.iter().map(|round| p95(round)).min().unwrap_or(1)
}

fn summary(id: String, seq: u64, verbose: bool) -> Summary {
    let mut row = Summary::new(id);
    row.last_activity = seq;
    if verbose {
        row.title = "r".repeat(240);
        row.harness = "h".repeat(64);
    }
    row
}

fn fill_ring(hub: &Hub, writer: &mut HubWriter, verbose: bool) -> u64 {
    let mut seq = 0;
    while seq < 50_000 {
        seq += 1;
        writer.apply(summary(format!("replay-{seq}"), seq, verbose)).unwrap();
        if seq > 1_000 && hub.resume_target(0).unwrap().is_none() {
            break;
        }
    }
    assert!(hub.resume_target(0).unwrap().is_none(), "ring did not expire cursor zero");
    seq
}

fn first_retained_cursor(hub: &Hub, target: u64) -> u64 {
    let mut low = 0;
    let mut high = target;
    while low < high {
        let middle = low + (high - low) / 2;
        if hub.resume_target(middle).unwrap().is_some() {
            high = middle;
        } else {
            low = middle + 1;
        }
    }
    assert!(hub.resume_target(low).unwrap().is_some());
    low
}

async fn receive<R: AsyncRead + Unpin>(reader: &mut R) -> Frame {
    timeout(Duration::from_secs(20), async {
        let mut header = [0_u8; 4];
        reader.read_exact(&mut header).await.unwrap();
        let length = u32::from_be_bytes(header) as usize;
        let mut body = vec![0_u8; length];
        reader.read_exact(&mut body).await.unwrap();
        let mut encoded = header.to_vec();
        encoded.extend_from_slice(&body);
        Frame::from_encoded(&encoded).unwrap()
    })
    .await
    .unwrap()
}

async fn send<R: AsyncWrite + Unpin>(writer: &mut R, value: serde_json::Value) {
    writer.write_all(&Frame::json(FrameKind::Request, &value).unwrap().encode()).await.unwrap();
}

async fn hello<W: AsyncWrite + Unpin, R: AsyncRead + Unpin>(writer: &mut W, reader: &mut R) {
    send(writer, json!({"method":"hello","params":{"clientKind":"v2-gate","protocol":2}})).await;
    assert_eq!(receive(reader).await.kind, FrameKind::Hello);
}

async fn read_replay<R: AsyncRead + Unpin>(
    reader: &mut R,
    target: u64,
    cursor: u64,
) -> (usize, usize) {
    let mut next = cursor + 1;
    let mut frames = 0;
    let mut maximum = 0;
    loop {
        let frame = receive(reader).await;
        assert_eq!(frame.kind, FrameKind::Delta);
        assert!(frame.encoded_len() <= MAX_REPLAY_FRAME_BYTES);
        maximum = maximum.max(frame.encoded_len());
        let delta: DeltaFrame<Summary> = frame.decode_json().unwrap();
        for operation in &delta.ops {
            match operation {
                DeltaOp::Summary { seq, .. } | DeltaOp::Gone { seq, .. } => {
                    assert_eq!(*seq, next);
                    next += 1;
                }
                other => panic!("unexpected replay operation: {other:?}"),
            }
        }
        frames += 1;
        if delta.replay == Some(crate::wire::ReplayMark::End) {
            break;
        }
        assert_eq!(delta.replay, Some(crate::wire::ReplayMark::Replay));
    }
    assert_eq!(next, target + 1, "replay did not reach captured target");
    (frames, maximum)
}

async fn replay_once(verbose: bool) -> (usize, usize) {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    let target = fill_ring(&hub, &mut writer, verbose);
    let cursor = first_retained_cursor(&hub, target);
    let source = Arc::new(HubSource::new(Arc::new(hub)));
    let (client, server) = tokio::io::duplex(1024);
    let (server_reader, server_writer) = tokio::io::split(server);
    let scope = cmux_scope::Scope::new("list-replay-gate");
    let server_task = scope.spawn(async move {
        let features = ["list".to_owned()];
        run(server_reader, server_writer, source, "v2-replay-gate", &features, super::Role::Local)
            .await
    });
    let (mut reader, mut writer_io) = tokio::io::split(client);
    hello(&mut writer_io, &mut reader).await;
    send(
        &mut writer_io,
        json!({"method":"sub","params":{"sid":"replay","stream":"list","cursor":cursor,"edition":0}}),
    )
    .await;
    let replay = read_replay(&mut reader, target, cursor).await;
    drop(writer_io);
    drop(reader);
    server_task.await.unwrap().unwrap();
    assert!(scope.close(Duration::from_secs(1)).await.joined());
    (replay.0, replay.1)
}

fn timed_append(
    hub: &Hub,
    mut writer: HubWriter,
    target: u64,
    offset: usize,
    permit: &AtomicBool,
) -> Result<(HubWriter, u128, usize), crate::hub::HubError> {
    // Both sides append on the test's calling thread, as the original
    // baseline did. Moving only the replay writer through a blocking worker
    // measured a different execution path and cache handoff.
    let start = Instant::now();
    permit.store(true, Ordering::Release);
    writer.apply(summary(format!("append-{offset}"), target + 1, true))?;
    // Observe completed copy work before stopping either side's clock.
    let copies_during = hub.history_raw_copies();
    Ok((writer, start.elapsed().as_nanos().max(1), copies_during))
}

fn append_round() -> Vec<u128> {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    let target = fill_ring(&hub, &mut writer, true);
    // Same fan-out as the replay side; no raw copies.
    let _receiver = hub.subscribe_replay(&Sub::new("replay", "list"), target).unwrap();
    let mut samples = Vec::with_capacity(SAMPLES);
    for offset in 0..SAMPLES {
        let permit = AtomicBool::new(false);
        let (next, elapsed, _) =
            timed_append(&hub, writer, target + offset as u64, offset, &permit).unwrap();
        writer = next;
        samples.push(elapsed);
    }
    samples
}

async fn append_replay_sample(
    hub: Arc<Hub>,
    writer: HubWriter,
    target: u64,
    offset: usize,
) -> (HubWriter, u128, usize) {
    let cursor = first_retained_cursor(&hub, target);
    let receiver = hub.subscribe_replay(&Sub::new("replay", "list"), cursor).unwrap();
    let stop = Arc::new(AtomicBool::new(false));
    let (permit, waiting) = hub.history_raw_copy_control();
    permit.store(false, Ordering::Release);
    waiting.store(false, Ordering::Release);
    hub.reset_history_raw_copies();
    let copy_stop = stop.clone();
    let copy_task = tokio::task::spawn_blocking(move || {
        // Use the daemon's frame path, including its reserve and free.
        let mut replay_cursor = cursor;
        while !copy_stop.load(Ordering::Acquire) || replay_cursor != cursor {
            receiver.reposition(replay_cursor);
            let Some(RawRead::Span(span)) =
                receiver.try_next_raw(Some(target), MAX_REPLAY_FRAME_BYTES)
            else {
                panic!("retained replay copy lost its span");
            };
            replay_cursor = if span.last_seq >= target { cursor } else { span.last_seq };
            drop(span);
            std::thread::yield_now();
        }
    });
    // Arm a raw span before starting the timed append. The history-side
    // permit keeps the span's copy inside the measured interval, so every
    // sample proves that the append overlaps a real ring copy.
    let ready_result = timeout(Duration::from_secs(20), async {
        while !waiting.load(Ordering::Acquire) {
            tokio::task::yield_now().await;
        }
    })
    .await;
    if ready_result.is_err() {
        permit.store(true, Ordering::Release);
        stop.store(true, Ordering::Release);
        copy_task.await.unwrap();
        panic!("raw replay copier did not start");
    }
    let result = timed_append(&hub, writer, target, offset, &permit);
    permit.store(true, Ordering::Release);
    stop.store(true, Ordering::Release);
    copy_task.await.unwrap();
    let (writer, elapsed, copies_during) = result.unwrap();
    (writer, elapsed, copies_during)
}

async fn append_replay_round() -> (Vec<u128>, Vec<usize>) {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    let target = fill_ring(&hub, &mut writer, true);
    let hub = Arc::new(hub);
    let mut samples = Vec::with_capacity(SAMPLES);
    let mut copies = Vec::with_capacity(SAMPLES);
    for offset in 0..SAMPLES {
        let current = target + offset as u64;
        let (next, elapsed, copy_count) =
            append_replay_sample(hub.clone(), writer, current, offset).await;
        writer = next;
        samples.push(elapsed);
        copies.push(copy_count);
    }
    (samples, copies)
}

#[derive(Clone, Copy, Debug)]
enum ReplayProbeControl {
    AsIs,
    NoSharedClock,
    PrivateReuse,
    PrivateFresh,
    SpinOnly,
    ForeignHub,
}

impl ReplayProbeControl {
    const ALL: [Self; 6] = [
        Self::AsIs,
        Self::NoSharedClock,
        Self::PrivateReuse,
        Self::PrivateFresh,
        Self::SpinOnly,
        Self::ForeignHub,
    ];

    const fn label(self) -> &'static str {
        match self {
            Self::AsIs => "a_as_is",
            Self::NoSharedClock => "b_no_shared_clock",
            Self::PrivateReuse => "d1_private_reuse",
            Self::PrivateFresh => "d2_private_fresh",
            Self::SpinOnly => "e_spin_only",
            Self::ForeignHub => "f_foreign_hub",
        }
    }
}

fn timed_append_plain(
    mut writer: HubWriter,
    target: u64,
    offset: usize,
    active: &AtomicBool,
) -> Result<(HubWriter, u128), crate::hub::HubError> {
    // The active flag is armed before the clock and cleared after it. Copiers
    // use it only to prove overlap; it is not part of the timed append path.
    active.store(true, Ordering::Release);
    let started = Instant::now();
    let result = writer.apply(summary(format!("probe-append-{offset}"), target + 1, true));
    let elapsed = started.elapsed().as_nanos().max(1);
    active.store(false, Ordering::Release);
    result.map(|_| (writer, elapsed))
}

async fn wait_for_count(count: &AtomicUsize) {
    let started = timeout(Duration::from_secs(20), async {
        while count.load(Ordering::Acquire) == 0 {
            tokio::task::yield_now().await;
        }
    })
    .await;
    assert!(started.is_ok(), "probe copier did not start");
}

async fn append_replay_unobserved_sample(
    hub: Arc<Hub>,
    writer: HubWriter,
    target: u64,
    offset: usize,
) -> (HubWriter, u128, usize) {
    let cursor = first_retained_cursor(&hub, target);
    let receiver = hub.subscribe_replay(&Sub::new("probe", "list"), cursor).unwrap();
    let stop = Arc::new(AtomicBool::new(false));
    let active = Arc::new(AtomicBool::new(false));
    let overlap = Arc::new(AtomicBool::new(false));
    let (permit, waiting) = hub.history_raw_copy_control();
    permit.store(false, Ordering::Release);
    waiting.store(false, Ordering::Release);
    hub.reset_history_raw_copies();
    let copy_stop = stop.clone();
    let copy_active = active.clone();
    let copy_overlap = overlap.clone();
    let copy_task = tokio::task::spawn_blocking(move || {
        let mut replay_cursor = cursor;
        while !copy_stop.load(Ordering::Acquire) || replay_cursor != cursor {
            receiver.reposition(replay_cursor);
            let Some(RawRead::Span(span)) =
                receiver.try_next_raw(Some(target), MAX_REPLAY_FRAME_BYTES)
            else {
                panic!("probe retained replay copy lost its span");
            };
            replay_cursor = if span.last_seq >= target { cursor } else { span.last_seq };
            drop(span);
            if copy_active.load(Ordering::Acquire) {
                copy_overlap.store(true, Ordering::Release);
            }
            std::thread::yield_now();
        }
    });
    let started = timeout(Duration::from_secs(20), async {
        while !waiting.load(Ordering::Acquire) {
            tokio::task::yield_now().await;
        }
    })
    .await;
    assert!(started.is_ok(), "probe raw copier did not enter its copy");
    // The permit is released before the timed interval. The appending thread
    // does not read or write the history's permit/counter while its clock runs.
    hub.reset_history_raw_copies();
    permit.store(true, Ordering::Release);
    let result = timed_append_plain(writer, target, offset, &active).unwrap();
    stop.store(true, Ordering::Release);
    copy_task.await.unwrap();
    let copies = hub.history_raw_copies();
    assert!(
        copies > 0 && overlap.load(Ordering::Acquire),
        "unobserved probe must overlap a raw copy"
    );
    (result.0, result.1, copies)
}

async fn append_foreign_hub_sample(
    writer: HubWriter,
    target: u64,
    offset: usize,
    foreign: Arc<Hub>,
    foreign_target: u64,
) -> (HubWriter, u128, usize) {
    let cursor = first_retained_cursor(&foreign, foreign_target);
    let receiver = foreign.subscribe_replay(&Sub::new("foreign-probe", "list"), cursor).unwrap();
    let stop = Arc::new(AtomicBool::new(false));
    let active = Arc::new(AtomicBool::new(false));
    let overlap = Arc::new(AtomicBool::new(false));
    let (permit, waiting) = foreign.history_raw_copy_control();
    permit.store(false, Ordering::Release);
    waiting.store(false, Ordering::Release);
    foreign.reset_history_raw_copies();
    let copy_stop = stop.clone();
    let copy_active = active.clone();
    let copy_overlap = overlap.clone();
    let copy_task = tokio::task::spawn_blocking(move || {
        let mut replay_cursor = cursor;
        while !copy_stop.load(Ordering::Acquire) || replay_cursor != cursor {
            receiver.reposition(replay_cursor);
            let Some(RawRead::Span(span)) =
                receiver.try_next_raw(Some(foreign_target), MAX_REPLAY_FRAME_BYTES)
            else {
                panic!("foreign probe retained replay copy lost its span");
            };
            replay_cursor = if span.last_seq >= foreign_target { cursor } else { span.last_seq };
            drop(span);
            if copy_active.load(Ordering::Acquire) {
                copy_overlap.store(true, Ordering::Release);
            }
            std::thread::yield_now();
        }
    });
    let started = timeout(Duration::from_secs(20), async {
        while !waiting.load(Ordering::Acquire) {
            tokio::task::yield_now().await;
        }
    })
    .await;
    assert!(started.is_ok(), "foreign probe copier did not enter its copy");
    foreign.reset_history_raw_copies();
    permit.store(true, Ordering::Release);
    let result = timed_append_plain(writer, target, offset, &active).unwrap();
    stop.store(true, Ordering::Release);
    copy_task.await.unwrap();
    let copies = foreign.history_raw_copies();
    assert!(copies > 0 && overlap.load(Ordering::Acquire), "foreign probe must overlap a raw copy");
    (result.0, result.1, copies)
}

async fn append_private_sample(
    hub: Arc<Hub>,
    writer: HubWriter,
    target: u64,
    offset: usize,
    reuse: bool,
) -> (HubWriter, u128, usize) {
    let stop = Arc::new(AtomicBool::new(false));
    let active = Arc::new(AtomicBool::new(false));
    let overlap = Arc::new(AtomicBool::new(false));
    let copies = Arc::new(AtomicUsize::new(0));
    let copy_stop = stop.clone();
    let copy_count = copies.clone();
    let copy_active = active.clone();
    let copy_overlap = overlap.clone();
    let copy_task = tokio::task::spawn_blocking(move || {
        let source = vec![0x5a_u8; 1024 * 1024];
        let mut reused = Vec::with_capacity(64 * 1024);
        while !copy_stop.load(Ordering::Acquire) {
            if reuse {
                reused.clear();
                reused.extend_from_slice(&source[..64 * 1024]);
                std::hint::black_box(&reused);
            } else {
                let mut fresh = Vec::with_capacity(64 * 1024);
                fresh.extend_from_slice(&source[..64 * 1024]);
                std::hint::black_box(&fresh);
            }
            copy_count.fetch_add(1, Ordering::Release);
            if copy_active.load(Ordering::Acquire) {
                copy_overlap.store(true, Ordering::Release);
            }
            std::thread::yield_now();
        }
    });
    wait_for_count(&copies).await;
    copies.store(0, Ordering::Release);
    let result = timed_append_plain(writer, target, offset, &active).unwrap();
    stop.store(true, Ordering::Release);
    copy_task.await.unwrap();
    let count = copies.load(Ordering::Acquire);
    assert!(count > 0 && overlap.load(Ordering::Acquire), "private probe must overlap its copier");
    let _ = hub;
    (result.0, result.1, count)
}

async fn append_spin_sample(
    hub: Arc<Hub>,
    writer: HubWriter,
    target: u64,
    offset: usize,
) -> (HubWriter, u128, usize) {
    let stop = Arc::new(AtomicBool::new(false));
    let active = Arc::new(AtomicBool::new(false));
    let overlap = Arc::new(AtomicBool::new(false));
    let spins = Arc::new(AtomicUsize::new(0));
    let spin_stop = stop.clone();
    let spin_count = spins.clone();
    let spin_active = active.clone();
    let spin_overlap = overlap.clone();
    let spin_task = tokio::task::spawn_blocking(move || {
        while !spin_stop.load(Ordering::Acquire) {
            std::hint::spin_loop();
            spin_count.fetch_add(1, Ordering::Release);
            if spin_active.load(Ordering::Acquire) {
                spin_overlap.store(true, Ordering::Release);
            }
        }
    });
    wait_for_count(&spins).await;
    spins.store(0, Ordering::Release);
    let result = timed_append_plain(writer, target, offset, &active).unwrap();
    stop.store(true, Ordering::Release);
    spin_task.await.unwrap();
    let count = spins.load(Ordering::Acquire);
    assert!(count > 0 && overlap.load(Ordering::Acquire), "spin probe must overlap its spinner");
    let _ = hub;
    (result.0, result.1, count)
}

async fn append_probe_round(control: ReplayProbeControl) -> (Vec<u128>, Vec<usize>) {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    let target = fill_ring(&hub, &mut writer, true);
    let hub = Arc::new(hub);
    let foreign = if matches!(control, ReplayProbeControl::ForeignHub) {
        let (foreign, mut foreign_writer) = Hub::new(SummaryIndex::new());
        let foreign_target = fill_ring(&foreign, &mut foreign_writer, true);
        Some((Arc::new(foreign), foreign_target))
    } else {
        None
    };
    let mut samples = Vec::with_capacity(SAMPLES);
    let mut proof = Vec::with_capacity(SAMPLES);
    for offset in 0..SAMPLES {
        let current = target + offset as u64;
        let (next, elapsed, observed) = match control {
            ReplayProbeControl::AsIs => {
                append_replay_sample(hub.clone(), writer, current, offset).await
            }
            ReplayProbeControl::NoSharedClock => {
                append_replay_unobserved_sample(hub.clone(), writer, current, offset).await
            }
            ReplayProbeControl::PrivateReuse => {
                append_private_sample(hub.clone(), writer, current, offset, true).await
            }
            ReplayProbeControl::PrivateFresh => {
                append_private_sample(hub.clone(), writer, current, offset, false).await
            }
            ReplayProbeControl::SpinOnly => {
                append_spin_sample(hub.clone(), writer, current, offset).await
            }
            ReplayProbeControl::ForeignHub => {
                let Some((foreign, foreign_target)) = foreign.as_ref() else {
                    assert!(false, "foreign probe setup");
                    return (Vec::new(), Vec::new());
                };
                append_foreign_hub_sample(writer, current, offset, foreign.clone(), *foreign_target)
                    .await
            }
        };
        writer = next;
        samples.push(elapsed);
        proof.push(observed);
    }
    (samples, proof)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "release probe; run with --profile gate --ignored --nocapture"]
async fn replay_append_cause_probe() {
    // Controls are intentionally run in one process with baseline/control
    // rounds alternating. (a) is the current gate. (b) moves the permit and
    // counter observation outside the clock. (d1)/(d2) isolate copy traffic
    // from fresh-allocation cost using private memory. (e) leaves only a
    // spinner. (f) copies a second hub's snapshot, avoiding shared data.
    for control in ReplayProbeControl::ALL {
        let mut baseline = Vec::with_capacity(ROUNDS);
        let mut god = Vec::with_capacity(ROUNDS);
        let mut proof = Vec::with_capacity(ROUNDS);
        for round in 0..ROUNDS {
            let outside = append_round();
            let (inside, evidence) = append_probe_round(control).await;
            eprintln!(
                "REPLAY_APPEND_PROBE control={} round={} small_p50={} small_p95={} god_p50={} god_p95={} proof_min={} proof_total={}",
                control.label(),
                round + 1,
                p50(&outside),
                p95(&outside),
                p50(&inside),
                p95(&inside),
                evidence.iter().copied().min().unwrap_or(0),
                evidence.iter().sum::<usize>()
            );
            baseline.push(outside);
            god.push(inside);
            proof.push(evidence);
        }
        let small_p50 = p50(&baseline.iter().flatten().copied().collect::<Vec<_>>());
        let god_p50 = p50(&god.iter().flatten().copied().collect::<Vec<_>>());
        let small_p95 = best_p95(&baseline);
        let god_p95 = best_p95(&god);
        let ratio = (god_p95 as f64) / (small_p95.max(1) as f64);
        eprintln!(
            "REPLAY_APPEND_PROBE_SUMMARY control={} small_p50={} small_p95={} god_p50={} god_p95={} best_ratio={ratio:.3}",
            control.label(),
            small_p50,
            small_p95,
            god_p50,
            god_p95
        );
        assert!(proof.iter().all(|round| round.iter().sum::<usize>() > 0));
    }
}

async fn replay_open_round(verbose: bool) -> Vec<u128> {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    let target = fill_ring(&hub, &mut writer, verbose);
    let hub = Arc::new(hub);
    let mut samples = Vec::with_capacity(SAMPLES);
    for offset in 0..SAMPLES {
        let (permit, waiting) = hub.history_snapshot_control();
        permit.store(false, Ordering::Release);
        waiting.store(false, Ordering::Release);
        let open_hub = hub.clone();
        let open_task = tokio::task::spawn_blocking(move || {
            open_hub.subscribe_replay(&Sub::new("open", "list"), 0).unwrap()
        });
        let ready = timeout(Duration::from_secs(20), async {
            while !waiting.load(Ordering::Acquire) {
                tokio::task::yield_now().await;
            }
        })
        .await;
        if ready.is_err() {
            permit.store(true, Ordering::Release);
            drop(open_task.await.unwrap());
            panic!("replay open did not enter the snapshot copy");
        }
        let started = Instant::now();
        permit.store(true, Ordering::Release);
        writer
            .apply(summary(format!("open-{offset}"), target + offset as u64 + 1, verbose))
            .unwrap();
        samples.push(started.elapsed().as_nanos().max(1));
        drop(open_task.await.unwrap());
    }
    samples
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "release gate; run with --release --ignored --nocapture"]
async fn replay_frame_gate() {
    let small = replay_once(false).await;
    let god = replay_once(true).await;
    assert!(small.0 > 1 && god.0 > 1, "full replay must use multiple frames");
    assert!(small.1 <= MAX_REPLAY_FRAME_BYTES && god.1 <= MAX_REPLAY_FRAME_BYTES);
    emit("v2.pr05c.replay_frame", small.1 as u128, god.1 as u128, god.1 as u128, "bytes");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "release gate; run with --release --ignored --nocapture"]
async fn replay_append_gate() {
    let mut baseline = Vec::with_capacity(ROUNDS);
    let mut during = Vec::with_capacity(ROUNDS);
    let mut copy_counts = Vec::with_capacity(ROUNDS);
    for _ in 0..ROUNDS {
        baseline.push(append_round());
        let (samples, copies) = append_replay_round().await;
        during.push(samples);
        copy_counts.push(copies);
    }
    let small = best_p95(&baseline);
    let god = best_p95(&during);
    let all = p95(&during.iter().flatten().copied().collect::<Vec<_>>());
    for (round, (outside, inside)) in baseline.iter().zip(&during).enumerate() {
        eprintln!(
            "REPLAY_APPEND_ROUND round={} outside_p95={} during_p95={} raw_copies_min={} raw_copies_total={}",
            round + 1,
            p95(outside),
            p95(inside),
            copy_counts[round].iter().copied().min().unwrap_or(0),
            copy_counts[round].iter().sum::<usize>()
        );
    }
    assert!(
        copy_counts.iter().all(|round| round.iter().sum::<usize>() > 0),
        "every measured round must overlap a raw history copy"
    );
    emit("v2.pr05c.replay_append", small, god, all, "ns");
    assert!(
        god <= small.saturating_mul(12) / 10,
        "replay append p95 exceeded 1.2x: {small}ns vs {god}ns"
    );
    assert!(
        all <= small.saturating_mul(2),
        "replay append all-sample p95 exceeded 2x: {small}ns vs {all}ns"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "release gate; run with --profile gate --ignored --nocapture"]
async fn replay_open_hold_gate() {
    let god_rounds = [replay_open_round(true).await];
    let god = best_p95(&god_rounds);
    let all = p95(&god_rounds[0]);
    // This row has an absolute 1 ms bound, not a small/god ratio.
    emit("v2.pr05c.replay_open_hold", god, god, all, "ns");
    assert!(god <= 1_000_000, "replay open hold exceeded 1ms p95: {god}ns");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "release gate; run with --release --ignored --nocapture"]
async fn single_encode_gate() {
    fn measure_delivery(subscribers: usize) -> usize {
        let (hub, mut writer) = Hub::new(SummaryIndex::new());
        let mut receivers = Vec::with_capacity(subscribers);
        for index in 0..subscribers {
            receivers
                .push(hub.subscribe_replay(&Sub::new(format!("sub-{index}"), "list"), 0).unwrap());
        }
        hub.reset_history_encoded_ops();
        writer.apply(summary("one-change".to_owned(), 1, true)).unwrap();
        let mut bytes = None;
        for receiver in &receivers {
            let Some(RawRead::Span(span)) = receiver.try_next_raw(None, MAX_REPLAY_FRAME_BYTES)
            else {
                panic!("subscriber did not receive the raw operation");
            };
            if let Some(expected) = &bytes {
                assert_eq!(expected, &span.bytes);
            } else {
                bytes = Some(span.bytes);
            }
        }
        hub.history_encoded_ops()
    }

    let one = measure_delivery(1);
    let hundred = measure_delivery(100);
    eprintln!("REPLAY_SINGLE_ENCODE subscribers=1 encodes={one}");
    eprintln!("REPLAY_SINGLE_ENCODE subscribers=100 encodes={hundred}");
    emit("v2.pr05c.single_encode", one as u128, hundred as u128, hundred as u128, "encodes");
    assert_eq!(one, 1, "single subscriber change should encode once");
    assert_eq!(hundred, 1, "100 subscribers must share one encoded operation");
}
