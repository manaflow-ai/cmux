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
    let result = job.run(Arc::new(captured)).unwrap();
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
        Vec::new(),
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
    let result = job.run(Arc::new(captured)).unwrap();
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

fn file_names(directory: &std::path::Path) -> Vec<String> {
    let mut names: Vec<_> = fs::read_dir(directory)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    names
}

#[test]
fn a_thousand_failed_compactions_reuse_one_empty_generation_and_clean_their_stages() {
    let dir = tempdir().unwrap();
    let mut log = IndexLog::open(dir.path().join("index.log")).unwrap();
    let record = log.append(row("kept", 1)).unwrap();
    let captured = Arc::new(SummaryIndex::new().apply(record.seq, record.summary));
    // This failure happens after both snapshot side files have been created,
    // when the writer reaches an invalid raw identity in the captured index.
    let invalid = Arc::new(captured.apply(1, row(&"x".repeat(257), 0)));
    for _ in 0..1000 {
        let plan = log.rotate(1).unwrap();
        assert_eq!(plan.covered_generation(), 1);
        assert_eq!(plan.run(invalid.clone()).unwrap_err().kind(), io::ErrorKind::InvalidInput);
        assert_eq!(log.generation(), 2);
        assert_eq!(file_names(dir.path()), ["index.log.1", "index.log.2"]);
    }
    let result = log.rotate(1).unwrap().run(captured).unwrap();
    log.compacted(result.covered_generation, result.seq);
    assert_eq!(file_names(dir.path()), ["index.log.2", "index.snap"]);
    drop(log);
    let mut log = IndexLog::open(dir.path().join("index.log")).unwrap();
    assert_eq!(log.next_seq(), 1);
    assert_eq!(log.append(row("after", 2)).unwrap().seq, 2);
    log.sync().unwrap();
    let snapshot = DiskSnapshot::open(dir.path().join("index.snap")).unwrap().unwrap();
    let restored = replay_generation_logs(
        dir.path(),
        snapshot.covered_generation(),
        SummaryIndex::from_disk(Some(snapshot), 1),
    )
    .unwrap();
    assert_eq!(restored.seq(), 2);
    assert_eq!(
        restored.merged_rows().map(|row| row.unwrap().chat_id.clone()).collect::<Vec<_>>(),
        ["after", "kept"]
    );
}

#[test]
fn failed_initial_rotation_can_retry_without_another_append() {
    let dir = tempdir().unwrap();
    let mut log = IndexLog::open(dir.path().join("index.log")).unwrap();
    let record = log.append(row("kept", 1)).unwrap();
    let captured = Arc::new(SummaryIndex::new().apply(record.seq, record.summary));
    // Initial-log rename succeeds, but creating the successor fails.
    let obstruction = dir.path().join("index.log.2");
    fs::create_dir(&obstruction).unwrap();
    assert!(log.rotate(1).is_err());
    assert_eq!(log.generation(), 1);
    assert_eq!(log.path(), dir.path().join("index.log.1"));
    fs::remove_dir(&obstruction).unwrap();
    let result = log.rotate(1).unwrap().run(captured).unwrap();
    log.compacted(result.covered_generation, result.seq);
    assert_eq!(file_names(dir.path()), ["index.log.2", "index.snap"]);
}

#[test]
fn a_failed_snapshot_rename_cleans_every_staging_file() {
    let dir = tempdir().unwrap();
    let mut log = IndexLog::open(dir.path().join("index.log")).unwrap();
    let record = log.append(row("kept", 1)).unwrap();
    let captured = Arc::new(SummaryIndex::new().apply(record.seq, record.summary));
    let obstruction = dir.path().join("index.snap");
    fs::create_dir(&obstruction).unwrap();
    assert!(log.rotate(1).unwrap().run(captured.clone()).is_err());
    assert_eq!(file_names(dir.path()), ["index.log.1", "index.log.2", "index.snap"]);
    fs::remove_dir(&obstruction).unwrap();
    assert!(log.rotate(1).unwrap().run(captured).is_ok());
    assert_eq!(file_names(dir.path()), ["index.log.2", "index.snap"]);
}

#[test]
fn cancelled_compaction_creates_no_stages_or_successor_generations_on_retry() {
    use std::sync::atomic::AtomicBool;
    let dir = tempdir().unwrap();
    let mut log = IndexLog::open(dir.path().join("index.log")).unwrap();
    let record = log.append(row("kept", 1)).unwrap();
    let captured = Arc::new(SummaryIndex::new().apply(record.seq, record.summary));
    let cancelled = Arc::new(AtomicBool::new(true));
    for _ in 0..3 {
        assert_eq!(
            log.rotate(1)
                .unwrap()
                .run_cancellable(captured.clone(), cancelled.clone())
                .unwrap_err()
                .kind(),
            io::ErrorKind::Interrupted
        );
        assert_eq!(file_names(dir.path()), ["index.log.1", "index.log.2"]);
    }
}

#[test]
fn startup_removes_only_owned_snapshot_stage_files() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("index.log");
    let mut log = IndexLog::open(&path).unwrap();
    log.append(row("kept", 1)).unwrap();
    log.sync().unwrap();
    drop(log);
    for name in [
        "index.snap.stage.1",
        "index.snap.stage.2.new",
        "index.snap.stage.3.directory.new",
        "index.snap.stage.4.stage",
        "index.snap.stage.5.stage.new",
        "index.snap.stage.6.stage.directory.new",
    ] {
        fs::write(dir.path().join(name), b"interrupted attempt").unwrap();
    }
    let unrelated = "index.snap.stage.notes";
    fs::write(dir.path().join(unrelated), b"not an owned stage").unwrap();
    let log = IndexLog::open(&path).unwrap();
    assert_eq!(log.next_seq(), 1);
    assert_eq!(file_names(dir.path()), ["index.log", unrelated]);
    assert_eq!(
        replay_generation_logs(dir.path(), 0, SummaryIndex::new())
            .unwrap()
            .get("kept")
            .unwrap()
            .chat_id,
        "kept"
    );
}

#[test]
fn compaction_retains_hot_snapshot_rows_before_hydration_finishes() {
    let dir = tempdir().unwrap();
    let mut full = SummaryIndex::new();
    for (seq, id, state, activity, pinned) in [
        (1, "cold", "closed", 0, false),
        (2, "pinned", "closed", 0, true),
        (3, "live", "running", 0, false),
        (4, "recent", "closed", u64::MAX, false),
    ] {
        let mut summary = row(id, activity);
        summary.state = state.to_owned();
        summary.pinned = pinned;
        full = full.apply(seq, summary);
    }
    let path = dir.path().join("index.snap");
    SortedSnapshot::write(&path, &full).unwrap();
    let captured = Arc::new(SummaryIndex::from_disk(DiskSnapshot::open(&path).unwrap(), 1));
    assert_eq!(captured.len(), 0);
    let mut log = IndexLog::open(dir.path().join("index.log")).unwrap();
    let result = log.rotate(captured.seq()).unwrap().run(captured).unwrap();
    let hot = result.missing_hot;
    assert_eq!(hot.len(), 3);
    assert!(!hot.iter().any(|row| row.chat_id == "cold"));
    for id in ["pinned", "live", "recent"] {
        assert!(hot.iter().any(|row| row.chat_id == id), "{id}");
    }
    assert_eq!(result.snapshot.len(), 4);
}

#[test]
fn retry_cleans_stages_left_by_a_temporary_cleanup_failure_without_restart() {
    let dir = tempdir().unwrap();
    let mut log = IndexLog::open(dir.path().join("index.log")).unwrap();
    let record = log.append(row("kept", 1)).unwrap();
    let captured = Arc::new(SummaryIndex::new().apply(record.seq, record.summary));
    let invalid = Arc::new(captured.apply(1, row(&"x".repeat(257), 0)));
    assert!(log.rotate(1).unwrap().run(invalid).is_err());
    // Reconstruct the exact on-disk outcome if the failed attempt's unlinks
    // also failed. Storage is writable again, but neither opener nor append
    // runs between this state and the retry.
    for name in [
        "index.snap.stage.1",
        "index.snap.stage.1.new",
        "index.snap.stage.1.directory.new",
        "index.snap.stage.0.new",
    ] {
        fs::write(dir.path().join(name), b"left by failed cleanup").unwrap();
    }
    let unrelated = dir.path().join("index.snap.stage.notes");
    fs::write(&unrelated, b"not owned by the compactor").unwrap();
    assert_eq!(log.generation(), 2);
    assert_eq!(log.next_seq(), 1);
    let result = log.rotate(1).unwrap().run(captured).unwrap();
    log.compacted(result.covered_generation, result.seq);
    assert_eq!(result.cleanup_errors, 0);
    assert_eq!(log.generation(), 2);
    assert_eq!(file_names(dir.path()), ["index.log.2", "index.snap", "index.snap.stage.notes"]);
    assert_eq!(fs::read(&unrelated).unwrap(), b"not owned by the compactor");
    let rows: Vec<_> = result.snapshot.rows().map(|row| row.unwrap().chat_id.clone()).collect();
    assert_eq!(rows, ["kept"]);
    assert_eq!(result.snapshot.seq(), 1);
}
