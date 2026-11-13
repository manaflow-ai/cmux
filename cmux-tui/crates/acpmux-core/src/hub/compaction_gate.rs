//! Complete writer-turn cost during real compaction, including sync and install.
use super::*;
use acpmux_book::index::SortedSnapshot;
use std::io::Write;
use std::time::Instant;

const SAMPLES: usize = 200;
const ROUNDS: usize = 5;
const MIN_CHANGES: u64 = 1_000_000;
const MAX_CHANGES: u64 = 10_000_000;
const BATCH: u64 = 256;

fn p95(samples: &[u128]) -> u128 {
    let mut values = samples.to_vec();
    values.sort_unstable();
    let rank = (values.len() * 95).div_ceil(100).saturating_sub(1);
    *values.get(rank).unwrap()
}

fn best(samples: &[u128]) -> u128 {
    samples.chunks_exact(SAMPLES).take(ROUNDS).map(p95).min().unwrap()
}

/// Select evenly spaced turns from one observation stretch. The compaction
/// and non-compaction samples are collected over the same stretch of the
/// run, but the writer can spend a different number of turns in each phase.
/// Sampling both vectors this way makes each 200-turn round cover the same
/// portion of that stretch instead of comparing the run's first outside turns
/// with its last during turns.
fn spread_evenly(samples: &[u128]) -> Vec<u128> {
    if samples.len() <= SAMPLES {
        return samples.to_vec();
    }
    let last = samples.len() - 1;
    (0..SAMPLES).map(|index| samples[index * last / (SAMPLES - 1)]).collect()
}

/// Group one observation stretch into rounds. A round ends at its 200th
/// during turn; all outside turns observed before that boundary belong to the
/// same round. Keeping this as a pure helper makes the equal-stretch rule
/// testable without running the million-change gate.
type RoundSamples = [Vec<u128>; ROUNDS];

fn matched_rounds(observations: &[(bool, u128)]) -> Option<(RoundSamples, RoundSamples)> {
    let mut outside: [Vec<u128>; ROUNDS] = std::array::from_fn(|_| Vec::new());
    let mut during: [Vec<u128>; ROUNDS] = std::array::from_fn(|_| Vec::new());
    let mut round = 0;
    for &(is_during, elapsed) in observations {
        if round == ROUNDS {
            break;
        }
        if is_during {
            during[round].push(elapsed);
            if during[round].len() == SAMPLES {
                round += 1;
            }
        } else {
            outside[round].push(elapsed);
        }
    }
    if round != ROUNDS || outside.iter().any(|values| values.len() < SAMPLES) {
        return None;
    }
    Some((outside, during))
}

fn report_matched_rounds(outside: &[u128], during: &[u128]) {
    for (round, (outside, during)) in
        outside.chunks_exact(SAMPLES).zip(during.chunks_exact(SAMPLES)).take(ROUNDS).enumerate()
    {
        let mut outside = outside.to_vec();
        let mut during = during.to_vec();
        outside.sort_unstable();
        during.sort_unstable();
        eprintln!(
            "PR5b matched_round round={} count={} outside_p50_ns={} outside_p95_ns={} during_p50_ns={} during_p95_ns={}",
            round + 1,
            outside.len(),
            outside[outside.len() / 2],
            p95(&outside),
            during[during.len() / 2],
            p95(&during),
        );
    }
}

fn report_split(label: &str, samples: &mut [u128]) {
    samples.sort_unstable();
    let median = samples.get(samples.len() / 2).copied().unwrap_or(0);
    let tail = if samples.is_empty() { 0 } else { p95(samples) };
    eprintln!(
        "PR5b turn_split label={label} count={} p50_ns={median} p95_ns={tail}",
        samples.len()
    );
}

fn row(id: impl Into<String>, activity: u64) -> Summary {
    let mut row = Summary::new(id);
    row.last_activity = activity;
    row.state = "running".to_owned();
    row
}

#[test]
fn matched_rounds_do_not_compare_different_stretches() {
    let mut observations = Vec::new();
    for round in 0..ROUNDS {
        // Deliberately vary outside density. A global quantile selection would
        // move samples between these intervals; the rounder must keep them
        // attached to the 200 during turns that close each interval.
        for outside in 0..(SAMPLES + round * 37) {
            observations.push((false, (round * 10_000 + outside) as u128));
        }
        for during in 0..SAMPLES {
            observations.push((true, (round * 10_000 + 9_000 + during) as u128));
        }
    }
    let (outside, during) = matched_rounds(&observations).expect("all rounds are complete");
    assert_eq!(during.iter().map(Vec::len).collect::<Vec<_>>(), vec![SAMPLES; ROUNDS]);
    assert_eq!(outside[0][0], 0);
    assert_eq!(outside[1][0], 10_000);
    assert_eq!(outside[ROUNDS - 1][0], (ROUNDS - 1) as u128 * 10_000);
    assert_eq!(during[ROUNDS - 1][0], (ROUNDS - 1) as u128 * 10_000 + 9_000);
}

#[tokio::test(flavor = "current_thread")]
#[ignore = "1M changes and timing; run in release with --ignored --nocapture"]
async fn pr05b_compaction_keeps_writing_through_one_million_changes() {
    let dir = tempfile::tempdir().unwrap();
    let mut index = SummaryIndex::new();
    for n in 0..11_000 {
        index = index.apply(n + 1, row(format!("row-{n:05}"), 11_000 - n));
    }
    SortedSnapshot::write(dir.path().join("index.snap"), &index).unwrap();
    drop(index);
    let (hub, mut writer) = Hub::open(dir.path(), 19, || 17).unwrap();
    let subscription = hub.subscribe(&Sub::new("measure", "list")).unwrap();
    // Finish the real startup load on this writer. Every steady-state sample
    // then changes the same live 11k rows, before and during compaction.
    writer.start_hydration();
    let mut hydration = Vec::new();
    while writer.hydration.is_some() {
        let (next, elapsed) = tokio::task::spawn_blocking(move || {
            let started = Instant::now();
            writer.process_batch();
            (writer, started.elapsed().as_nanos().max(1))
        })
        .await
        .unwrap();
        writer = next;
        hydration.push(elapsed);
    }
    assert_eq!(hub.snapshot().len(), 11_000);
    eprintln!("PR5b startup_writer_turns: batches={} p95_ns={}", hydration.len(), p95(&hydration));
    let mut during = Vec::new();
    let mut changes = 0_u64;
    let mut first_million_peak = 0;
    let mut split: [Vec<u128>; 6] = std::array::from_fn(|_| Vec::new());
    let mut sync_split: [Vec<u128>; 6] = std::array::from_fn(|_| Vec::new());
    let mut observations = Vec::new();
    let mut overlays = Vec::new();
    let mut changed_counts = Vec::new();
    let mut rotations = Vec::new();
    // Fast compactions may finish in fewer than 1,000 turns through 1M changes.
    // Continue the same workload to collect five rounds, never slow a worker
    // or hold an artificial compaction open to manufacture samples. Both phase
    // vectors below cover this same stretch: each round closes on its 200th
    // during turn, and its outside turns are selected only from that interval.
    while changes < MAX_CHANGES && (changes < MIN_CHANGES || during.len() < ROUNDS * SAMPLES) {
        writer.finish_compaction(false).await;
        let count = if changes < MIN_CHANGES {
            BATCH.min(MIN_CHANGES - changes)
        } else {
            BATCH.min(MAX_CHANGES - changes)
        };
        for n in 0..count {
            hub.submit(row(format!("row-{:05}", (changes + n) % 11_000), 1_000_000 + changes + n))
                .unwrap();
        }
        let (next, running, phase, elapsed) = tokio::task::spawn_blocking(move || {
            let running = writer.compaction.is_some()
                || writer.maintenance.is_some()
                || writer.retirement.is_some();
            let mut phase = if writer.compaction.is_some() {
                1
            } else if writer.retirement.is_some() {
                2
            } else if writer.maintenance.is_some() {
                5
            } else {
                0
            };
            let old_offset = writer.log.as_ref().unwrap().offset();
            let started = Instant::now();
            writer.process_batch();
            let elapsed = started.elapsed().as_nanos().max(1);
            if writer.turn_measure.overlay_ns > 0 {
                phase = 3;
            } else if writer.turn_measure.rotate_ns > 0 {
                phase = 4;
            }
            let log = writer.log.as_ref().unwrap();
            let trigger = writer.published.load().disk().unwrap().bytes().max(1024 * 1024);
            if writer.compaction.is_none()
                && writer.maintenance.is_none()
                && writer.retirement.is_none()
            {
                assert!(
                    log.offset()
                        <= trigger + BATCH * acpmux_book::index::MAX_INDEX_RECORD_BYTES as u64
                );
            }
            if writer.turn_measure.overlay_ns > 0 {
                // Installation leaves the active suffix untouched.
                assert!(log.offset() >= old_offset);
                assert_eq!(log.retained_bytes(), log.offset());
            }
            if let Some(bytes) = writer.turn_measure.completed_log_bytes {
                // Maintenance also preserves the suffix. A new capture may
                // rotate it in this turn, but never copies or loses its bytes.
                assert_eq!(bytes, old_offset);
                assert!(log.retained_bytes() >= bytes);
            }
            assert_eq!(writer.log_errors(), 0);
            (writer, running, phase, elapsed)
        })
        .await
        .unwrap();
        writer = next;
        assert!(writer.turn_measure.maintenance_keys <= 256);
        split.get_mut(phase).unwrap().push(elapsed);
        sync_split.get_mut(phase).unwrap().push(writer.turn_measure.sync_ns);
        if writer.turn_measure.overlay_ns > 0 {
            overlays.push(writer.turn_measure.overlay_ns);
            changed_counts.push(writer.turn_measure.changed as u128);
        }
        if writer.turn_measure.rotate_ns > 0 {
            rotations.push(writer.turn_measure.rotate_ns);
        }
        for _ in 0..count {
            let item = tokio::time::timeout(
                std::time::Duration::from_secs(1),
                subscription.receiver.recv(),
            )
            .await
            .unwrap();
            assert!(matches!(item, Some(ListItem::Summary(_))));
        }
        if count == BATCH {
            if running {
                during.push(elapsed);
            }
            observations.push((running, elapsed));
        }
        changes += count;
        if changes == MIN_CHANGES {
            first_million_peak = hub.compaction_stats().peak_excess_bytes;
        }
    }
    // Finish the captured work and reclaim its old maps, with no further
    // arrivals. A suffix over its trigger starts the next compaction at once.
    for _ in 0..200 {
        writer.finish_compaction(true).await;
        writer = tokio::task::spawn_blocking(move || {
            writer.process_batch();
            writer
        })
        .await
        .unwrap();
        if writer.compaction.is_none()
            && writer.maintenance.is_none()
            && writer.retirement.is_none()
        {
            break;
        }
    }
    assert!(
        writer.compaction.is_none() && writer.maintenance.is_none() && writer.retirement.is_none()
    );
    let stats = hub.compaction_stats();
    assert_eq!(stats.failed, 0);
    assert!(stats.completed > 0);
    assert!(changes >= MIN_CHANGES);
    assert!(during.len() >= ROUNDS * SAMPLES, "not enough actual in-flight writer turns");
    let (round_outside, round_during) =
        matched_rounds(&observations).expect("not enough completed matched rounds");
    let matched_outside: Vec<_> = round_outside
        .iter()
        .flat_map(|round| {
            assert!(round.len() >= SAMPLES, "not enough outside turns in matched interval");
            spread_evenly(round)
        })
        .collect();
    let matched_during: Vec<_> = round_during.iter().flatten().copied().collect();
    assert_eq!(matched_outside.len(), ROUNDS * SAMPLES);
    assert_eq!(matched_during.len(), ROUNDS * SAMPLES);
    report_matched_rounds(&matched_outside, &matched_during);
    let outside_rounds: Vec<_> = matched_outside.chunks_exact(SAMPLES).map(p95).collect();
    assert_eq!(outside_rounds.len(), ROUNDS);
    let small = best(&matched_outside);
    let god = best(&matched_during);
    let all = p95(&matched_during);
    report_split("during_gate_samples", &mut during);
    for (n, label) in [
        "outside",
        "compaction_running",
        "retirement_running",
        "install",
        "start_compaction",
        "maintenance",
    ]
    .iter()
    .enumerate()
    {
        report_split(label, split.get_mut(n).unwrap());
        report_split(&format!("{label}_sync"), sync_split.get_mut(n).unwrap());
    }
    report_split("install_overlay", &mut overlays);
    changed_counts.sort_unstable();
    eprintln!(
        "PR5b install_changed count={} p50={} p95={} max={}",
        changed_counts.len(),
        changed_counts.get(changed_counts.len() / 2).unwrap_or(&0),
        if changed_counts.is_empty() { 0 } else { p95(&changed_counts) },
        changed_counts.last().unwrap_or(&0)
    );
    report_split("rotation", &mut rotations);
    let line = format!(
        "{{\"name\":\"v2.pr05b.apply_during_compaction\",\"small_p95\":{small},\"god_p95\":{god},\"god_p95_all\":{all},\"unit\":\"ns\",\"changes\":{changes},\"compactions\":{},\"peak_excess_bytes\":{},\"first_million_peak_excess_bytes\":{first_million_peak},\"last_duration_ns\":{}}}",
        stats.completed, stats.peak_excess_bytes, stats.duration_ns,
    );
    eprintln!("{line}");
    if let Ok(path) = std::env::var("V2_GATE_OUT") {
        writeln!(
            std::fs::OpenOptions::new().create(true).append(true).open(path).unwrap(),
            "{line}"
        )
        .unwrap();
    }
    assert!(
        outside_rounds[ROUNDS - 1] <= outside_rounds[0].saturating_mul(12) / 10,
        "outside rounds slowed: first={}ns fifth={}ns rounds={outside_rounds:?}",
        outside_rounds[0],
        outside_rounds[ROUNDS - 1]
    );
    assert!(god <= small.saturating_mul(12) / 10, "during={god}ns outside={small}ns");
    assert!(all <= small.saturating_mul(2), "all during={all}ns outside={small}ns");
    drop((hub, writer));
    let (restored, _) = Hub::open(dir.path(), 19, || 17).unwrap();
    assert_eq!(restored.snapshot().seq(), 11_000 + changes);
    assert_eq!(restored.snapshot().merged_rows().count(), 11_000);
}
