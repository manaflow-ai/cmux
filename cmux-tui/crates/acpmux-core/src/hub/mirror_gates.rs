//! Ignored release measurement for the mirror's unit: one frame's changes and
//! its mark, from the queue through the writer's append, sync and publish.

use super::*;
use acpmux_book::gate_rounds;
use std::fs::OpenOptions;
use std::io::Write;
use std::time::Instant;

const ROUNDS: usize = 10;
const SAMPLES: usize = 200;
const UNIT_CHANGES: usize = 10;

fn p95(values: &mut [u128]) -> u128 {
    values.sort_unstable();
    let rank = (values.len() * 95).div_ceil(100).saturating_sub(1);
    values.get(rank).copied().unwrap_or(1)
}

fn row(origin: &str, id: String, activity: u64) -> Summary {
    let mut summary = Summary::new(id);
    summary.origin = origin.to_owned();
    summary.state = "running".to_owned();
    summary.title = format!("row at {activity}");
    summary.last_activity = activity;
    summary
}

struct Fixture {
    _directory: tempfile::TempDir,
    hub: Hub,
    writer: HubWriter,
    next: u64,
    parts: [u128; 4],
    samples: u128,
    compacting: u64,
}

/// `local` chats of this machine, and `origins` mirrored origins holding
/// `held` rows between them.
fn fixture(local: usize, origins: usize, held: usize) -> Fixture {
    let directory = tempfile::tempdir().expect("mirror gate directory");
    let (hub, mut writer) = Hub::open(directory.path(), 101, || 7).expect("open mirror gate");
    for n in 0..local {
        writer.apply(row("local", format!("local-{n:05}"), n as u64 + 1)).expect("seed local");
    }
    let per_origin = held / origins;
    for origin in 0..origins {
        let name = format!("peer-{origin:02}");
        let mut after = None;
        for start in (0..per_origin).step_by(MAX_UNIT_CHANGES) {
            let changes = (start..per_origin.min(start + MAX_UNIT_CHANGES))
                .map(|n| UnitChange::Summary(Box::new(row(&name, format!("chat-{n:05}"), 1))))
                .collect();
            let mark = MirrorMark { cursor: 1, edition: 3, whole: true };
            hub.submit_unit(
                Source::Mirror,
                MirrorUnit { origin: name.clone(), after, changes, mark },
            )
            .expect("seed unit");
            after = Some(mark);
            writer.process_batch();
        }
    }
    assert_eq!(hub.snapshot().len(), local + per_origin * origins);
    Fixture {
        _directory: directory,
        hub,
        writer,
        next: 2,
        parts: [0; 4],
        samples: 0,
        compacting: 0,
    }
}

/// One sample: a unit changing 10 of the first origin's first 20 rows, queued, then
/// written and published by one writer turn.
fn sample(fixture: &mut Fixture, sync: &mut Vec<u128>) -> u128 {
    let cursor = fixture.next;
    fixture.next += 1;
    let changes = (0..UNIT_CHANGES)
        .map(|n| {
            let id = format!("chat-{:05}", (cursor as usize * UNIT_CHANGES + n) % 20);
            UnitChange::Summary(Box::new(row("peer-00", id, cursor)))
        })
        .collect();
    let unit = MirrorUnit {
        origin: "peer-00".to_owned(),
        after: Some(MirrorMark { cursor: cursor - 1, edition: 3, whole: true }),
        changes,
        mark: MirrorMark { cursor, edition: 3, whole: true },
    };
    let started = Instant::now();
    fixture.hub.submit_unit(Source::Mirror, unit).expect("unit");
    fixture.writer.process_batch();
    let elapsed = started.elapsed().as_nanos().max(1);
    sync.push(fixture.writer.turn_measure.sync_ns);
    let parts = fixture.writer.turn_measure.unit_ns;
    for (sum, part) in fixture.parts.iter_mut().zip(parts) {
        *sum += part;
    }
    fixture.samples += 1;
    fixture.compacting += u64::from(fixture.writer.compaction.is_some());
    assert_eq!(fixture.hub.mirror_mark("peer-00").map(|mark| mark.cursor), Some(cursor));
    elapsed
}

#[test]
#[ignore = "release measurement; run with --ignored --release --nocapture"]
fn pr08_mirror_apply() {
    let mut small = fixture(20, 1, 20);
    let mut god = fixture(11_000, 30, 16_000);
    let marks_before = god.hub.mirror_counts();
    let mut small_rounds = Vec::new();
    let mut god_rounds = Vec::new();
    let (mut small_kept, mut god_kept) = (Vec::new(), Vec::new());
    let mut pooled = Vec::new();
    let (mut small_sync, mut god_sync) = (Vec::new(), Vec::new());
    let (mut small_all, mut god_all_samples) = (Vec::new(), Vec::new());
    for _ in 0..ROUNDS {
        // Rounds alternate so a noisy stretch of the machine hits both sides.
        let mut samples: Vec<u128> =
            (0..SAMPLES).map(|_| sample(&mut small, &mut small_sync)).collect();
        small_all.extend_from_slice(&samples);
        small_kept.push(samples.clone());
        small_rounds.push(p95(&mut samples));
        let mut samples: Vec<u128> =
            (0..SAMPLES).map(|_| sample(&mut god, &mut god_sync)).collect();
        god_all_samples.extend_from_slice(&samples);
        pooled.extend_from_slice(&samples);
        god_kept.push(samples.clone());
        god_rounds.push(p95(&mut samples));
    }
    gate_rounds::report("v2.pr08.mirror_apply", &[("small", &small_kept), ("god", &god_kept)]);
    let small_p95 = small_rounds.into_iter().min().unwrap_or(1);
    let god_p95 = god_rounds.into_iter().min().unwrap_or(1);
    let god_all = p95(&mut pooled);
    // Where a turn's time goes: the log's sync, and the rest (apply, append, publish).
    let p50 = |values: &mut Vec<u128>| {
        values.sort_unstable();
        values.get(values.len() / 2).copied().unwrap_or(0)
    };
    let rest = |all: &[u128], sync: &[u128]| -> Vec<u128> {
        all.iter().zip(sync).map(|(all, sync)| all.saturating_sub(*sync)).collect()
    };
    let mut small_rest = rest(&small_all, &small_sync);
    let mut god_rest = rest(&god_all_samples, &god_sync);
    for (side, fixture) in [("small", &small), ("god", &god)] {
        let mean: Vec<u128> =
            fixture.parts.iter().map(|part| part / fixture.samples.max(1)).collect();
        eprintln!(
            "mirror_apply parts mean ns {side}: build {} append {} apply {} publish {}; turns compacting {}",
            mean[0], mean[1], mean[2], mean[3], fixture.compacting
        );
    }
    eprintln!(
        "mirror_apply split p50 ns: sync small {} god {}; rest small {} god {}",
        p50(&mut small_sync),
        p50(&mut god_sync),
        p50(&mut small_rest),
        p50(&mut god_rest)
    );
    let counts = god.hub.mirror_counts();
    let units = counts.applied - marks_before.applied;
    let mark_bytes = (counts.mark_bytes - marks_before.mark_bytes) / units.max(1);
    assert_eq!(
        counts.full
            + counts.not_owner
            + counts.forged
            + counts.storage
            + counts.held
            + counts.out_of_order
            + counts.join_refused,
        0
    );
    let line = format!(
        "{{\"name\":\"v2.pr08.mirror_apply\",\"small_p95\":{small_p95},\"god_p95\":{god_p95},\"god_p95_all\":{god_all},\"mark_bytes\":{mark_bytes},\"unit\":\"ns\"}}"
    );
    eprintln!("{line}");
    if let Ok(path) = std::env::var("V2_GATE_OUT")
        && let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path)
    {
        let _ = writeln!(file, "{line}");
    }
    assert!(god_p95 * 10 <= small_p95 * 12, "unit p95 exceeded 1.2x: {small_p95} -> {god_p95} ns");
}

const LOCAL_ROUNDS: usize = 6;
const LOCAL_SAMPLES: usize = 30;

/// One sample: a unit of [`MAX_UNIT_CHANGES`] changes queued for the first
/// origin, then a local row; the time from the local row's submit to the end
/// of the writer turn that writes and publishes both. Without `unit`, the
/// local row alone.
fn local_sample(fixture: &mut Fixture, unit: bool) -> u128 {
    let cursor = fixture.next;
    fixture.next += 1;
    if !unit {
        let started = Instant::now();
        fixture
            .hub
            .submit(row("local", format!("local-{:05}", cursor % 20), cursor))
            .expect("local row");
        fixture.writer.process_batch();
        return started.elapsed().as_nanos().max(1);
    }
    let changes = (0..MAX_UNIT_CHANGES)
        .map(|n| UnitChange::Summary(Box::new(row("peer-00", format!("big-{n:05}"), cursor))))
        .collect();
    let unit = MirrorUnit {
        origin: "peer-00".to_owned(),
        after: fixture.hub.mirror_mark("peer-00"),
        changes,
        mark: MirrorMark { cursor, edition: 3, whole: true },
    };
    fixture.hub.submit_unit(Source::Mirror, unit).expect("unit");
    let started = Instant::now();
    fixture
        .hub
        .submit(row("local", format!("local-{:05}", cursor % 20), cursor))
        .expect("local row");
    fixture.writer.process_batch();
    let elapsed = started.elapsed().as_nanos().max(1);
    assert_eq!(fixture.hub.mirror_mark("peer-00").map(|mark| mark.cursor), Some(cursor));
    elapsed
}

/// A local row's submit-to-publish while the largest units a peer can send
/// apply beside it. The mirrored origin holds the unit's rows on both sides
/// (the first sample writes them); the rest is the two fixtures of
/// `pr08_mirror_apply`.
#[test]
#[ignore = "release measurement; run with --ignored --release --nocapture"]
fn pr08_mirror_local_row() {
    let mut small = fixture(20, 1, 20);
    let mut god = fixture(11_000, 30, 16_000);
    local_sample(&mut small, true);
    local_sample(&mut god, true);
    let mut small_rounds = Vec::new();
    let mut god_rounds = Vec::new();
    let mut alone_rounds = Vec::new();
    let (mut small_kept, mut god_kept, mut alone_kept) = (Vec::new(), Vec::new(), Vec::new());
    let mut pooled = Vec::new();
    for _ in 0..LOCAL_ROUNDS {
        let mut samples: Vec<u128> =
            (0..LOCAL_SAMPLES).map(|_| local_sample(&mut small, true)).collect();
        small_kept.push(samples.clone());
        small_rounds.push(p95(&mut samples));
        let mut samples: Vec<u128> =
            (0..LOCAL_SAMPLES).map(|_| local_sample(&mut god, true)).collect();
        pooled.extend_from_slice(&samples);
        god_kept.push(samples.clone());
        god_rounds.push(p95(&mut samples));
        let mut samples: Vec<u128> =
            (0..LOCAL_SAMPLES).map(|_| local_sample(&mut god, false)).collect();
        alone_kept.push(samples.clone());
        alone_rounds.push(p95(&mut samples));
    }
    gate_rounds::report(
        "v2.pr08.mirror_local_row",
        &[("small", &small_kept), ("god", &god_kept), ("alone", &alone_kept)],
    );
    let small_p95 = small_rounds.into_iter().min().unwrap_or(1);
    let god_p95 = god_rounds.into_iter().min().unwrap_or(1);
    let god_all = p95(&mut pooled);
    let alone_p95 = alone_rounds.into_iter().min().unwrap_or(1);
    let counts = god.hub.mirror_counts();
    assert_eq!(counts.full + counts.held + counts.out_of_order + counts.join_refused, 0);
    let line = format!(
        "{{\"name\":\"v2.pr08.mirror_local_row\",\"small_p95\":{small_p95},\"god_p95\":{god_p95},\"god_p95_all\":{god_all},\"alone_p95\":{alone_p95},\"unit_changes\":{MAX_UNIT_CHANGES},\"unit\":\"ns\"}}"
    );
    eprintln!("{line}");
    if let Ok(path) = std::env::var("V2_GATE_OUT")
        && let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path)
    {
        let _ = writeln!(file, "{line}");
    }
    assert!(
        god_p95 * 10 <= small_p95 * 12,
        "local row p95 under units exceeded 1.2x: {small_p95} -> {god_p95} ns"
    );
}

/// The origins each queueing a unit: 30, or `V2_THIRTY_ORIGINS`.
fn origins() -> usize {
    std::env::var("V2_THIRTY_ORIGINS").ok().and_then(|value| value.parse().ok()).unwrap_or(30)
}

/// One sample: a unit of [`MAX_UNIT_CHANGES`] changes queued for each of the
/// origins, then a local row. Two clocks start at the local row's submit: one
/// stops at the end of the writer turn that publishes it, the other when that
/// turn publishes it. The turns after it, which write the units the cap left,
/// are not timed. The origins' queued units are counted before the clocks start.
fn thirty_sample(fixture: &mut Fixture, origins: usize) -> ThirtySample {
    let cursor = fixture.next;
    fixture.next += 1;
    for origin in 0..origins {
        let name = format!("peer-{origin:02}");
        let changes = (0..MAX_UNIT_CHANGES)
            .map(|n| UnitChange::Summary(Box::new(row(&name, format!("big-{n:05}"), cursor))))
            .collect();
        let unit = MirrorUnit {
            origin: name.clone(),
            after: fixture.hub.mirror_mark(&name),
            changes,
            mark: MirrorMark { cursor, edition: 3, whole: true },
        };
        fixture.hub.submit_unit(Source::Mirror, unit).expect("unit");
    }
    let key = RowKey::new("local", format!("local-{:05}", cursor % 20));
    let published =
        |hub: &Hub| hub.snapshot().get_row(&key).is_some_and(|row| row.last_activity == cursor);
    let queued = fixture.hub.updates.pending.lock().map_or(0, |pending| pending.controls.len());
    assert_eq!(queued, origins, "each origin's unit is queued before the clocks start");
    let started = Instant::now();
    fixture.hub.submit(row("local", key.chat_id.to_string(), cursor)).expect("local row");
    while !published(&fixture.hub) {
        fixture.writer.process_batch();
    }
    let turn_end = started.elapsed().as_nanos().max(1);
    let turn = fixture.writer.turn_measure;
    let publish =
        turn.local_published.map_or(turn_end, |at| at.duration_since(started).as_nanos().max(1));
    while (0..origins).any(|origin| {
        fixture.hub.mirror_mark(&format!("peer-{origin:02}")).map(|mark| mark.cursor)
            != Some(cursor)
    }) {
        fixture.writer.process_batch();
    }
    ThirtySample { turn_end, publish, turn }
}

/// A thirty sample's two clocks and the split of the turn that published the local row.
struct ThirtySample {
    turn_end: u128,
    publish: u128,
    turn: disk::TurnMeasure,
}

/// A local row's submit-to-publish while 30 origins (or `V2_THIRTY_ORIGINS`) each queue the largest
/// unit in one turn, under [`MAX_TURN_UNIT_CHANGES`] and with the cap lifted.
#[test]
#[ignore = "release measurement; run with --ignored --release --nocapture"]
fn pr08_mirror_local_row_thirty() {
    let mut god = fixture(11_000, origins(), 16_000);
    thirty_sample(&mut god, origins());
    let mut capped_rounds = Vec::new();
    let mut lifted_rounds = Vec::new();
    let (mut capped_kept, mut lifted_kept) = (Vec::new(), Vec::new());
    let mut pooled = Vec::new();
    let mut publish_rounds = Vec::new();
    for _ in 0..LOCAL_ROUNDS {
        god.writer.mirror.turn_changes = MAX_TURN_UNIT_CHANGES;
        let (mut samples, mut published): (Vec<u128>, Vec<u128>) = (0..LOCAL_SAMPLES)
            .map(|_| thirty_sample(&mut god, origins()))
            .map(|sample| (sample.turn_end, sample.publish))
            .unzip();
        publish_rounds.push(p95(&mut published));
        pooled.extend_from_slice(&samples);
        capped_kept.push(samples.clone());
        capped_rounds.push(p95(&mut samples));
        god.writer.mirror.turn_changes = usize::MAX;
        let mut samples: Vec<u128> =
            (0..LOCAL_SAMPLES).map(|_| thirty_sample(&mut god, origins()).turn_end).collect();
        lifted_kept.push(samples.clone());
        lifted_rounds.push(p95(&mut samples));
    }
    gate_rounds::report(
        "v2.pr08.mirror_local_row_thirty",
        &[("capped", &capped_kept), ("lifted", &lifted_kept)],
    );
    let capped_p95 = capped_rounds.into_iter().min().unwrap_or(1);
    let capped_all = p95(&mut pooled);
    let lifted_p95 = lifted_rounds.into_iter().min().unwrap_or(1);
    let publish_p95 = publish_rounds.into_iter().min().unwrap_or(1);
    let counts = god.hub.mirror_counts();
    assert_eq!(counts.full + counts.held + counts.out_of_order + counts.join_refused, 0);
    let line = format!(
        "{{\"name\":\"v2.pr08.mirror_local_row_thirty\",\"publish_p95\":{publish_p95},\"small_p95\":0,\"god_p95\":{capped_p95},\"god_p95_all\":{capped_all},\"capped_p95\":{capped_p95},\"capped_p95_all\":{capped_all},\"lifted_p95\":{lifted_p95},\"origins\":{},\"unit_changes\":{MAX_UNIT_CHANGES},\"turn_changes\":{MAX_TURN_UNIT_CHANGES},\"unit\":\"ns\"}}",
        origins()
    );
    eprintln!("{line}");
    if let Ok(path) = std::env::var("V2_GATE_OUT")
        && let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path)
    {
        let _ = writeln!(file, "{line}");
    }
    assert!(capped_p95 <= 10_000_000, "local row p95 under 30 units over 10 ms: {capped_p95} ns");
}

/// Decision 451 (c): the turn that publishes the local row, split into taking the batch,
/// rows, origin slots (units) and the sync, with its index publishes, under both orders in
/// one build: units first (the order before decision 300) and rows first. One line for
/// each order and size, at 30 and at 256 origins.
#[test]
#[ignore = "release measurement; run with --ignored --release --nocapture"]
fn pr08_mirror_turn_split() {
    const ROUNDS: usize = 3;
    for origins in [30, 256] {
        let mut god = fixture(11_000, origins, 16_000);
        thirty_sample(&mut god, origins);
        let mut sides: [Vec<ThirtySample>; 2] = [Vec::new(), Vec::new()];
        for round in 0..ROUNDS {
            // Alternate which order goes first each round.
            for step in 0..2 {
                let units_first = (round + step) % 2 == 0;
                god.hub.updates.units_first.store(units_first, Ordering::Relaxed);
                let side = &mut sides[usize::from(!units_first)];
                side.extend((0..LOCAL_SAMPLES).map(|_| thirty_sample(&mut god, origins)));
            }
        }
        god.hub.updates.units_first.store(false, Ordering::Relaxed);
        for (order, samples) in ["units_first", "rows_first"].iter().zip(&sides) {
            let mut pick = |f: &dyn Fn(&ThirtySample) -> u128| {
                let mut values: Vec<u128> = samples.iter().map(f).collect();
                p95(&mut values)
            };
            let publish = pick(&|s| s.publish);
            let turn_end = pick(&|s| s.turn_end);
            let take = pick(&|s| s.turn.take_ns);
            let rows = pick(&|s| s.turn.kind_ns[0]);
            let units = pick(&|s| s.turn.kind_ns[1]);
            let records = pick(&|s| s.turn.kind_ns[2]);
            let sync = pick(&|s| s.turn.sync_ns);
            let mut publishes: Vec<usize> = samples.iter().map(|s| s.turn.publishes).collect();
            publishes.sort_unstable();
            let (least, most) =
                (publishes.first().copied().unwrap_or(0), publishes.last().copied().unwrap_or(0));
            let line = format!(
                "{{\"name\":\"v2.pr08.mirror_turn_split\",\"order\":\"{order}\",\"origins\":{origins},\"publish_p95\":{publish},\"turn_end_p95\":{turn_end},\"take_p95\":{take},\"rows_p95\":{rows},\"units_p95\":{units},\"records_p95\":{records},\"sync_p95\":{sync},\"publishes_min\":{least},\"publishes_max\":{most},\"samples\":{},\"unit\":\"ns\"}}",
                samples.len()
            );
            eprintln!("{line}");
        }
    }
}

/// One drain: a unit of [`MAX_UNIT_CHANGES`] changes queued for each of the 30 origins, and
/// the time from the last unit's submit to the turn that writes the last origin's mark.
fn drain_sample(fixture: &mut Fixture) -> u128 {
    let cursor = fixture.next;
    fixture.next += 1;
    let mut submitted = Instant::now();
    for origin in 0..origins() {
        let name = format!("peer-{origin:02}");
        let changes = (0..MAX_UNIT_CHANGES)
            .map(|n| UnitChange::Summary(Box::new(row(&name, format!("big-{n:05}"), cursor))))
            .collect();
        let unit = MirrorUnit {
            origin: name.clone(),
            after: fixture.hub.mirror_mark(&name),
            changes,
            mark: MirrorMark { cursor, edition: 3, whole: true },
        };
        fixture.hub.submit_unit(Source::Mirror, unit).expect("unit");
        submitted = Instant::now();
    }
    while (0..origins()).any(|origin| {
        fixture.hub.mirror_mark(&format!("peer-{origin:02}")).map(|mark| mark.cursor)
            != Some(cursor)
    }) {
        fixture.writer.process_batch();
    }
    submitted.elapsed().as_nanos().max(1)
}

/// Decision 298's before and after from one harness: the thirty row's capped p95 and the
/// drain of the whole 30-unit backlog (15,360 changes), at four units a turn and at
/// [`MAX_TURN_UNIT_CHANGES`], rounds alternating.
#[test]
#[ignore = "release measurement; run with --ignored --release --nocapture"]
fn turn_cap_compare() {
    let mut god = fixture(11_000, origins(), 16_000);
    thirty_sample(&mut god, origins());
    let caps = [4 * MAX_UNIT_CHANGES, MAX_TURN_UNIT_CHANGES];
    let mut capped: [Vec<u128>; 2] = Default::default();
    let mut drains: [Vec<u128>; 2] = Default::default();
    for _ in 0..LOCAL_ROUNDS {
        for (side, cap) in caps.iter().enumerate() {
            god.writer.mirror.turn_changes = *cap;
            let mut samples: Vec<u128> =
                (0..LOCAL_SAMPLES).map(|_| thirty_sample(&mut god, origins()).turn_end).collect();
            capped[side].push(p95(&mut samples));
            drains[side].extend((0..10).map(|_| drain_sample(&mut god)));
        }
    }
    for (side, cap) in caps.iter().enumerate() {
        let best = capped[side].iter().min().copied().unwrap_or(1);
        let mut drain = drains[side].clone();
        drain.sort_unstable();
        let drain_p50 = drain[drain.len() / 2];
        let drain_p95 = p95(&mut drain);
        eprintln!(
            "turn_cap_compare cap {cap}: capped p95 best of rounds {best} rounds {:?}; drain p50 {} p95 {} ns",
            capped[side], drain_p50, drain_p95
        );
    }
}
