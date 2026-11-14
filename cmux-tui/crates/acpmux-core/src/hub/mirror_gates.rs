//! Ignored release measurement for the mirror's unit: one frame's changes and
//! its mark, from the queue through the writer's append, sync and publish.

use super::*;
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
    let mut pooled = Vec::new();
    let (mut small_sync, mut god_sync) = (Vec::new(), Vec::new());
    let (mut small_all, mut god_all_samples) = (Vec::new(), Vec::new());
    for _ in 0..ROUNDS {
        // Rounds alternate so a noisy stretch of the machine hits both sides.
        let mut samples: Vec<u128> =
            (0..SAMPLES).map(|_| sample(&mut small, &mut small_sync)).collect();
        small_all.extend_from_slice(&samples);
        small_rounds.push(p95(&mut samples));
        let mut samples: Vec<u128> =
            (0..SAMPLES).map(|_| sample(&mut god, &mut god_sync)).collect();
        god_all_samples.extend_from_slice(&samples);
        pooled.extend_from_slice(&samples);
        god_rounds.push(p95(&mut samples));
    }
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
