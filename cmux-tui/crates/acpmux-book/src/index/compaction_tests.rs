use super::*;
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
