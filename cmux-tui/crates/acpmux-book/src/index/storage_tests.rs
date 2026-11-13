use super::*;
use std::fs;

#[test]
fn largest_raw_keys_are_whole_and_the_record_has_one_exact_bound() {
    let dir = tempfile::tempdir().unwrap();
    let mut summary = Summary::new("\u{0001}".repeat(256));
    summary.origin = "\u{0002}".repeat(256);
    summary.parent = Some(summary.key());
    summary.fork_of = Some(ForkOf { key: summary.key(), seq: u64::MAX });
    summary.folder = Some("\u{0003}".repeat(1024));
    summary.title = "title".repeat(256);
    summary.extra = RawValue::from_string(format!("\"{}\"", "x".repeat(1600))).unwrap();
    let expected = summary.prepare().unwrap();
    let mut log = IndexLog::open(dir.path().join("index.log")).unwrap();
    let record = log.append(expected.clone()).unwrap();
    log.sync().unwrap();
    assert!(log.offset() <= MAX_INDEX_RECORD_BYTES as u64);
    assert_eq!(record.summary.key(), expected.key());
    let restored = replay_log(log.path(), SummaryIndex::new()).unwrap();
    let restored = restored.get_row(&expected.key()).unwrap();
    assert_eq!(
        serde_json::to_string(&restored).unwrap(),
        serde_json::to_string(&expected).unwrap()
    );
    assert!(expected.encoded_len() > MAX_SUMMARY_BYTES);
}

#[test]
fn every_torn_record_boundary_can_append_and_reopen() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("index.log");
    let mut log = IndexLog::open(&path).unwrap();
    log.append(Summary::new("first")).unwrap();
    let boundary = log.offset();
    log.append(Summary::new("last")).unwrap();
    log.sync().unwrap();
    let bytes = fs::read(&path).unwrap();
    drop(log);
    for cut in boundary as usize..bytes.len() {
        fs::write(&path, bytes.get(..cut).unwrap()).unwrap();
        let mut log = IndexLog::open(&path).unwrap();
        assert_eq!(log.offset(), boundary);
        assert_eq!(log.append(Summary::new("next")).unwrap().seq, 2);
        log.sync().unwrap();
        drop(log);
        let log = IndexLog::open(&path).unwrap();
        let index = replay_log(log.path(), SummaryIndex::new()).unwrap();
        assert_eq!(index.len(), 2);
        assert!(index.get("first").is_some());
        assert!(index.get("next").is_some());
    }
}

#[test]
fn snapshot_head_does_not_materialize_rows_and_sparse_seek_is_bounded() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("index.snap");
    let mut index = SummaryIndex::new();
    for n in 0..11_000 {
        let mut row = Summary::new(format!("row-{n:05}"));
        row.last_activity = 11_000 - n;
        row.state = "closed".to_owned();
        index = index.apply(n + 1, row);
    }
    SortedSnapshot::write(&path, &index).unwrap();
    let disk = DiskSnapshot::open(&path).unwrap().unwrap();
    assert_eq!(disk.seq(), 11_000);
    assert_eq!(disk.len(), 11_000);
    let head = disk.first_page(4096).unwrap();
    assert!(head.bytes_read <= 4096);
    assert_eq!(head.rows.first().unwrap().chat_id, "row-00000");
    assert!(head.has_after);
    for n in [0, 5_500, 10_999] {
        let row = index.get(&format!("row-{n:05}")).unwrap();
        let (offset, ordinal) = disk.seek(&SortKey::of(&row), true).unwrap();
        assert_eq!(ordinal, n);
        let page = disk.piece(offset, ordinal, 8192).unwrap();
        assert!(page.bytes_read <= 8192);
        assert_eq!(page.rows.first().unwrap().chat_id, row.chat_id);
        assert_eq!(page.has_before, n != 0);
        assert_eq!(page.has_after, n != 10_999);
    }
}
