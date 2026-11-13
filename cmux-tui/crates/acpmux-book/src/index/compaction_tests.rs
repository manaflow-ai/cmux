use super::*;
use std::fs;
use std::sync::Arc;
use tempfile::tempdir;

fn row(id: &str, activity: u64) -> Summary {
    let mut summary = Summary::new(id);
    summary.last_activity = activity;
    summary
}

#[test]
fn rotation_keeps_arrivals_in_the_new_generation_across_restart() {
    let dir = tempdir().unwrap();
    let log_path = dir.path().join("index.log");
    let snapshot_path = dir.path().join("index.snap");
    let mut log = IndexLog::open(&log_path).unwrap();
    let first = log.append(row("first", 2)).unwrap();
    log.sync().unwrap();
    let captured = SummaryIndex::new().apply(first.seq, first.summary);
    let job = log.rotate(captured.seq()).unwrap();
    let second = log.append(row("second", 1)).unwrap();
    log.sync().unwrap();
    let result = job.run(Arc::new(captured.clone())).unwrap();
    log.compacted(result.covered_generation, result.seq);
    drop(log);

    let disk = DiskSnapshot::open(&snapshot_path).unwrap().unwrap();
    assert_eq!(disk.covered_generation(), result.covered_generation);
    let restored = replay_generation_logs(
        dir.path(),
        disk.covered_generation(),
        SummaryIndex::from_disk(Some(disk), 1),
    )
    .unwrap();
    assert_eq!(restored.seq(), second.seq);
    let names: Vec<_> = restored.merged_rows().map(|row| row.unwrap().chat_id.clone()).collect();
    assert_eq!(names, ["first", "second"]);
}

#[test]
fn an_uninstalled_rotation_is_recovered_from_both_generations() {
    let dir = tempdir().unwrap();
    let log_path = dir.path().join("index.log");
    let mut log = IndexLog::open(&log_path).unwrap();
    let first = log.append(row("first", 2)).unwrap();
    log.sync().unwrap();
    let captured = SummaryIndex::new().apply(first.seq, first.summary);
    let _job = log.rotate(captured.seq()).unwrap();
    let second = log.append(row("second", 1)).unwrap();
    log.sync().unwrap();
    drop(log);

    let restored = replay_generation_logs(dir.path(), 0, SummaryIndex::new()).unwrap();
    assert_eq!(restored.seq(), second.seq);
    let names: Vec<_> = restored.merged_rows().map(|row| row.unwrap().chat_id.clone()).collect();
    assert_eq!(names, ["first", "second"]);
}

#[test]
fn an_empty_rotated_active_log_keeps_the_closed_generations_sequence() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("index.log");
    let mut log = IndexLog::open(&path).unwrap();
    for n in 0..9 {
        log.append(row(&format!("r{n}"), n)).unwrap();
    }
    let _unfinished = log.rotate(9).unwrap();
    drop(log);
    let mut log = IndexLog::open(&path).unwrap();
    assert_eq!(log.next_seq(), 9);
    assert_eq!(log.append(row("after", 10)).unwrap().seq, 10);
    log.sync().unwrap();
    assert_eq!(replay_generation_logs(dir.path(), 0, SummaryIndex::new()).unwrap().len(), 10);
}

#[test]
fn a_partial_snapshot_stage_is_ignored_until_the_atomic_rename() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("index.log");
    let mut log = IndexLog::open(&path).unwrap();
    let first = log.append(row("first", 2)).unwrap();
    log.sync().unwrap();
    let captured = SummaryIndex::new().apply(first.seq, first.summary);
    let job = log.rotate(captured.seq()).unwrap();
    let second = log.append(row("second", 1)).unwrap();
    log.sync().unwrap();
    drop(log);

    fs::write(dir.path().join("index.snap.stage.1.new"), b"partial").unwrap();
    let before = replay_generation_logs(dir.path(), 0, SummaryIndex::new()).unwrap();
    assert_eq!(before.seq(), second.seq);
    assert_eq!(before.merged_rows().count(), 2);

    // A completed staged snapshot is durable before the canonical rename.
    let staged = dir.path().join("index.snap.pending");
    SortedSnapshot::write_stream_generation(
        &staged,
        captured.seq(),
        0,
        None,
        job.covered_generation(),
        captured.merged_rows(),
    )
    .unwrap();
    fs::rename(&staged, dir.path().join("index.snap")).unwrap();
    let disk = DiskSnapshot::open(dir.path().join("index.snap")).unwrap().unwrap();
    let after = replay_generation_logs(
        dir.path(),
        disk.covered_generation(),
        SummaryIndex::from_disk(Some(disk), 1),
    )
    .unwrap();
    assert_eq!(after.seq(), second.seq);
    assert_eq!(after.merged_rows().count(), 2);
}

#[test]
fn an_old_generation_left_after_snapshot_rename_is_cleaned_on_open() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("index.log");
    let mut log = IndexLog::open(&path).unwrap();
    let first = log.append(row("first", 2)).unwrap();
    log.sync().unwrap();
    let captured = SummaryIndex::new().apply(first.seq, first.summary);
    let job = log.rotate(captured.seq()).unwrap();
    let second = log.append(row("second", 1)).unwrap();
    log.sync().unwrap();
    let old = fs::read(dir.path().join("index.log.1")).unwrap();
    let result = job.run(Arc::new(captured.clone())).unwrap();
    assert_eq!(result.covered_generation, 1);
    // Simulate a crash before the old-generation unlink completed.
    fs::write(dir.path().join("index.log.1"), old).unwrap();
    drop(log);
    let reopened = IndexLog::open(&path).unwrap();
    assert_eq!(reopened.next_seq(), second.seq);
    assert!(!dir.path().join("index.log.1").exists());
}

#[test]
fn every_rotated_tail_cut_repairs_before_append_and_restart() {
    let seed = tempdir().unwrap();
    let seed_path = seed.path().join("index.log");
    let mut seed_log = IndexLog::open(&seed_path).unwrap();
    seed_log.append(row("first", 2)).unwrap();
    seed_log.sync().unwrap();
    let _ = seed_log.rotate(1).unwrap();
    drop(seed_log);
    let bytes = fs::read(seed.path().join("index.log.1")).unwrap();

    for cut in 0..=bytes.len() {
        let dir = tempdir().unwrap();
        fs::write(dir.path().join("index.log.1"), &bytes[..cut]).unwrap();
        fs::File::create(dir.path().join("index.log.2")).unwrap();
        let mut log = IndexLog::open(dir.path().join("index.log")).unwrap();
        let after = log.append(row("after", 1)).unwrap();
        log.sync().unwrap();
        drop(log);
        let restored = replay_generation_logs(dir.path(), 0, SummaryIndex::new()).unwrap();
        assert_eq!(restored.seq(), after.seq);
        let expected = usize::from(cut == bytes.len()) + 1;
        assert_eq!(restored.merged_rows().count(), expected, "cut={cut}");
    }
}
