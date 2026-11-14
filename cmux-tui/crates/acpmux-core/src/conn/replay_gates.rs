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
use std::sync::atomic::{AtomicBool, Ordering};
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

async fn timed_append(
    mut writer: HubWriter,
    target: u64,
    offset: usize,
    permit: Arc<AtomicBool>,
) -> Result<(HubWriter, u128), tokio::task::JoinError> {
    // Both sides move the writer through the same worker boundary and time
    // exactly the same construction, append, and permit store.
    tokio::task::spawn_blocking(move || {
        let start = Instant::now();
        permit.store(true, Ordering::Release);
        writer.apply(summary(format!("append-{offset}"), target + 1, true)).unwrap();
        (writer, start.elapsed().as_nanos().max(1))
    })
    .await
}

async fn append_round() -> Vec<u128> {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    let target = fill_ring(&hub, &mut writer, true);
    // Same fan-out and worker handoff as the replay side; no raw copies.
    let _receiver = hub.subscribe_replay(&Sub::new("replay", "list"), target).unwrap();
    let mut samples = Vec::with_capacity(SAMPLES);
    for offset in 0..SAMPLES {
        let permit = Arc::new(AtomicBool::new(false));
        let (next, elapsed) =
            timed_append(writer, target + offset as u64, offset, permit).await.unwrap();
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
        // Reserve and touch once before arming. Reuse storage while the
        // measured append runs; free it after the writer stops its clock.
        let mut buffer = vec![0; MAX_REPLAY_FRAME_BYTES];
        let mut replay_cursor = cursor;
        while !copy_stop.load(Ordering::Acquire) || replay_cursor != cursor {
            receiver.reposition(replay_cursor);
            let Some(RawRead::Span(span)) =
                receiver.try_next_raw_with_buffer(Some(target), MAX_REPLAY_FRAME_BYTES, buffer)
            else {
                panic!("retained replay copy lost its span");
            };
            replay_cursor = if span.last_seq >= target { cursor } else { span.last_seq };
            buffer = span.bytes;
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
    let result = timed_append(writer, target, offset, permit.clone()).await;
    let copies_during = hub.history_raw_copies();
    permit.store(true, Ordering::Release);
    stop.store(true, Ordering::Release);
    copy_task.await.unwrap();
    let (writer, elapsed) = result.unwrap();
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
        baseline.push(append_round().await);
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
