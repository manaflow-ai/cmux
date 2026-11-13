//! Long-running rotation and writer-cost gate; release-only, explicitly invoked.
use super::*;
use acpmux_book::index::SortedSnapshot;
use std::io::Write;
use std::time::Instant;

fn p95(samples: &[u128]) -> u128 {
    let mut values = samples.to_vec();
    values.sort_unstable();
    let rank = (values.len() * 95).div_ceil(100).saturating_sub(1);
    *values.get(rank).unwrap()
}

fn best(samples: &[u128]) -> u128 {
    samples.chunks_exact(200).take(5).map(p95).min().unwrap()
}

#[tokio::test(flavor = "current_thread")]
#[ignore = "1M changes and timing; run in release with --ignored --nocapture"]
async fn pr05b_compaction_keeps_writing_through_one_million_changes() {
    let dir = tempfile::tempdir().unwrap();
    let mut index = SummaryIndex::new();
    for n in 0..11_000 {
        let mut row = Summary::new(format!("row-{n:05}"));
        row.last_activity = 11_000 - n;
        row.state = "closed".into();
        index = index.apply(n + 1, row);
    }
    SortedSnapshot::write(dir.path().join("index.snap"), &index).unwrap();
    drop(index);
    let (hub, mut writer) = Hub::open(dir.path(), 91, || 17).unwrap();
    let _subscription = hub.subscribe(&Sub::new("measure", "list")).unwrap();
    let mut during = Vec::new();
    let mut outside = Vec::new();
    let mut completions = 0;
    for start in (0..1_000_000_u64).step_by(256) {
        let (next, measured) = tokio::task::spawn_blocking(move || {
            let mut measured = Vec::with_capacity(256);
            for n in start..(start + 256).min(1_000_000) {
                let mut row = Summary::new(format!("row-{:05}", n % 11_000));
                row.last_activity = 100_000 + n;
                row.state = "closed".into();
                let running = writer.compaction.as_ref().is_some_and(|job| {
                    job.handle.as_ref().is_some_and(|handle| !handle.is_finished())
                });
                let began = Instant::now();
                writer.apply(row).unwrap();
                measured.push((running, began.elapsed().as_nanos().max(1)));
            }
            writer.sync_batch().unwrap();
            writer.maybe_compact();
            if writer.compaction.is_none() {
                let trigger = writer.published.load().disk().unwrap().bytes().max(1024 * 1024);
                assert!(writer.log.as_ref().unwrap().retained_bytes() < trigger);
            }
            (writer, measured)
        })
        .await
        .unwrap();
        writer = next;
        for (running, sample) in measured {
            let samples = if running { &mut during } else { &mut outside };
            if samples.len() < 1000 {
                samples.push(sample);
            }
        }
        let before_bytes = writer.log.as_ref().unwrap().offset();
        writer.finish_compaction(false).await;
        if hub.compaction_stats().completed != completions {
            completions = hub.compaction_stats().completed;
            // Installation never copies, rewrites, or loses the post-capture tail.
            assert_eq!(writer.log.as_ref().unwrap().offset(), before_bytes);
            assert_eq!(writer.log.as_ref().unwrap().retained_bytes(), before_bytes);
        }
    }
    writer.finish_compaction(true).await;
    let stats = hub.compaction_stats();
    assert_eq!(stats.failed, 0);
    assert!(stats.completed > 0);
    assert_eq!(during.len(), 1000, "not enough real in-flight samples");
    assert_eq!(outside.len(), 1000, "not enough outside-compaction samples");
    let small = best(&outside);
    let god = best(&during);
    let all = p95(&during);
    let line = format!(
        "{{\"name\":\"v2.pr05b.apply_during_compaction\",\"small_p95\":{small},\"god_p95\":{god},\"god_p95_all\":{all},\"unit\":\"ns\",\"changes\":1000000,\"compactions\":{},\"peak_excess_bytes\":{},\"last_duration_ns\":{}}}",
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
    assert!(god <= small * 12 / 10, "during={god}ns outside={small}ns");
    assert!(all <= small * 2, "all during={all}ns outside={small}ns");
    drop((hub, writer));
    let (restored, _) = Hub::open(dir.path(), 91, || 17).unwrap();
    assert_eq!(restored.snapshot().seq(), 1_011_000);
    assert_eq!(restored.snapshot().merged_rows().count(), 11_000);
}
