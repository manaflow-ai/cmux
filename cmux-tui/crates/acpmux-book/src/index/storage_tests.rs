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
    let last = index.get("row-10999").unwrap();
    assert_eq!(
        disk.seek(&SortKey::of(&last), false).unwrap(),
        (disk.bytes() - disk.head.directory_bytes as u64, disk.len())
    );
}

#[test]
fn physical_progress_survives_a_wholly_shadowed_piece() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("index.snap");
    let mut full = SummaryIndex::new();
    for n in 0..60 {
        let mut row = Summary::new(format!("row-{n:03}"));
        row.last_activity = 60 - n;
        row.state = "closed".to_owned();
        full = full.apply(n + 1, row);
    }
    SortedSnapshot::write(&path, &full).unwrap();
    let disk = DiskSnapshot::open(&path).unwrap();
    let mut index = SummaryIndex::from_disk(disk, 1);
    for n in 0..20 {
        index = index.remove_row(61 + n, &RowKey::new("local", format!("row-{n:03}"))).unwrap();
    }
    let page = index.read_page(None, ReadSide::After, true, 20, 256 * 1024, None).unwrap();
    assert!(page.rows.is_empty());
    assert!(page.has_after);
    let continuation = page.after_key.unwrap();
    assert_eq!(continuation.row.chat_id.as_ref(), "row-019");
    let next =
        index.read_page(Some(&continuation), ReadSide::After, false, 20, 256 * 1024, None).unwrap();
    assert_eq!(next.rows.len(), 20);
    assert_eq!(next.rows.first().unwrap().chat_id, "row-020");
}

#[test]
fn anchors_include_the_row_and_around_redistributes_spare_capacity() {
    let mut index = SummaryIndex::new();
    for n in 0..10 {
        let mut row = Summary::new(format!("r{n}"));
        row.last_activity = 10 - n;
        index = index.apply(n + 1, row);
    }
    let anchor = SortKey::of(&index.get("r5").unwrap());
    for (side, expected) in [
        (ReadSide::Before, vec!["r2", "r3", "r4", "r5"]),
        (ReadSide::After, vec!["r5", "r6", "r7", "r8"]),
        (ReadSide::Around, vec!["r3", "r4", "r5", "r6"]),
    ] {
        let page = index.read_page(Some(&anchor), side, true, 4, 8192, None).unwrap();
        assert_eq!(page.rows.iter().map(|row| row.chat_id.as_str()).collect::<Vec<_>>(), expected);
    }
    for (id, expected) in
        [("r0", vec!["r0", "r1", "r2", "r3"]), ("r9", vec!["r6", "r7", "r8", "r9"])]
    {
        let key = SortKey::of(&index.get(id).unwrap());
        let page = index.read_page(Some(&key), ReadSide::Around, true, 4, 8192, None).unwrap();
        assert_eq!(page.rows.iter().map(|row| row.chat_id.as_str()).collect::<Vec<_>>(), expected);
    }
}

#[test]
fn after_anchor_keeps_hot_rows_before_the_first_cold_candidate() {
    let dir = tempfile::tempdir().unwrap();
    let mut index = SummaryIndex::new();
    for time in [100, 80, 60] {
        let mut row = Summary::new(time.to_string());
        row.last_activity = time;
        index = index.apply(time, row);
    }
    let anchor = SortKey::of(&index.get("100").unwrap());
    let path = dir.path().join("index.snap");
    SortedSnapshot::write(&path, &index).unwrap();
    let mut hot = Summary::new("90");
    hot.last_activity = 90;
    let index = SummaryIndex::from_disk(DiskSnapshot::open(path).unwrap(), 1).apply(101, hot);
    let page = index.read_page(Some(&anchor), ReadSide::After, false, 2, 8192, None).unwrap();
    assert_eq!(page.rows.iter().map(|row| row.chat_id.as_str()).collect::<Vec<_>>(), ["90", "80"]);
}

#[test]
fn byte_limited_before_and_around_keep_nearest_rows_on_disk_and_in_memory() {
    let dir = tempfile::tempdir().unwrap();
    let mut index = SummaryIndex::new();
    for n in 0..10 {
        let mut row = Summary::new(format!("r{n}"));
        row.last_activity = 10 - n;
        row.title = "x".repeat(200);
        index = index.apply(n + 1, row);
    }
    let anchor_row = index.get("r5").unwrap();
    let anchor = SortKey::of(&anchor_row);
    let budget = anchor_row.encoded_len() + 1;
    let path = dir.path().join("index.snap");
    SortedSnapshot::write(&path, &index).unwrap();
    let disk_index = SummaryIndex::from_disk(DiskSnapshot::open(path).unwrap(), 1);
    for index in [&index, &disk_index] {
        for (side, inclusive, expected) in [
            (ReadSide::Before, false, "r4"),
            (ReadSide::Before, true, "r5"),
            (ReadSide::Around, true, "r5"),
        ] {
            let page = index.read_page(Some(&anchor), side, inclusive, 4, budget, None).unwrap();
            assert_eq!(page.rows.len(), 1, "{side:?}");
            assert_eq!(page.rows.first().unwrap().chat_id, expected);
        }
        assert!(index.read_page(Some(&anchor), ReadSide::After, true, 4, 1, None).is_err());
    }
}

#[test]
fn replay_reports_corruption_instead_of_returning_a_partial_index() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("index.log");
    let mut log = IndexLog::open(&path).unwrap();
    log.append(Summary::new("first")).unwrap();
    log.sync().unwrap();
    drop(log);
    use std::io::Write;
    fs::OpenOptions::new().append(true).open(&path).unwrap().write_all(b"torn").unwrap();
    assert_eq!(
        replay_log(&path, SummaryIndex::new()).err().unwrap().kind(),
        io::ErrorKind::UnexpectedEof
    );
    // The opener owns repair. Only after repair may a replay succeed.
    IndexLog::open(&path).unwrap();
    assert_eq!(replay_log(&path, SummaryIndex::new()).unwrap().len(), 1);
}

#[test]
fn codec_keeps_filesystem_errors_distinct_from_malformed_records() {
    use std::io::Read;
    struct FailedRead;
    impl Read for FailedRead {
        fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
            Err(io::Error::other("injected filesystem failure"))
        }
    }
    let error = codec::read(&mut FailedRead).err().unwrap();
    assert_eq!(error.kind(), io::ErrorKind::Other);
    let mut log_record = IndexRecord {
        seq: 1,
        origin: "local".into(),
        chat_id: "a".into(),
        summary: Summary::new("a"),
        gone: false,
    };
    log_record.summary.title = "marker".into();
    let mut bytes = codec::encode(&log_record).unwrap();
    // Preserve a valid CRC around invalid JSON, so the decoder owns the error.
    *bytes.last_mut().unwrap() = b'!';
    let crc = crc32fast::hash(bytes.get(8..).unwrap());
    bytes.get_mut(4..8).unwrap().copy_from_slice(&crc.to_le_bytes());
    assert_eq!(
        codec::read(&mut bytes.as_slice()).err().unwrap().kind(),
        io::ErrorKind::InvalidData
    );
}

#[test]
fn a_row_cap_resumes_after_the_last_taken_merged_candidate_not_prefetch() {
    let dir = tempfile::tempdir().unwrap();
    let mut cold = SummaryIndex::new();
    for n in 0..20 {
        let mut row = Summary::new(format!("cold-{n:02}"));
        row.last_activity = 100 - n * 2;
        cold = cold.apply(n + 1, row);
    }
    let path = dir.path().join("index.snap");
    SortedSnapshot::write(&path, &cold).unwrap();
    let mut index = SummaryIndex::from_disk(DiskSnapshot::open(path).unwrap(), 1);
    for n in 0..10 {
        let mut row = Summary::new(format!("hot-{n:02}"));
        row.last_activity = 99 - n * 2;
        index = index.apply(21 + n, row);
    }
    let first = index.read_page(None, ReadSide::After, true, 20, 256 * 1024, None).unwrap();
    assert_eq!(first.rows.len(), 20);
    assert!(first.has_after);
    let continuation = first.after_key.unwrap();
    assert_eq!(continuation.row.chat_id.as_ref(), "hot-09");
    let next =
        index.read_page(Some(&continuation), ReadSide::After, false, 20, 256 * 1024, None).unwrap();
    assert_eq!(next.rows.len(), 10);
    assert!(!next.has_after);
    let all: Vec<_> =
        first.rows.iter().chain(next.rows.iter()).map(|row| row.chat_id.clone()).collect();
    let unique: std::collections::HashSet<_> = all.iter().collect();
    assert_eq!(unique.len(), 30);
    for n in 0..20 {
        assert!(unique.contains(&format!("cold-{n:02}")));
    }
}

#[test]
fn a_one_row_around_window_keeps_a_hot_anchor_between_cold_rows() {
    let dir = tempfile::tempdir().unwrap();
    let mut index = SummaryIndex::new();
    for time in [100, 80, 60] {
        let mut row = Summary::new(time.to_string());
        row.last_activity = time;
        index = index.apply(time, row);
    }
    let path = dir.path().join("index.snap");
    SortedSnapshot::write(&path, &index).unwrap();
    let mut hot = Summary::new("90");
    hot.last_activity = 90;
    let anchor = SortKey::of(&hot);
    let index = SummaryIndex::from_disk(DiskSnapshot::open(path).unwrap(), 1).apply(101, hot);
    let page = index.read_page(Some(&anchor), ReadSide::Around, true, 1, 8192, None).unwrap();
    assert_eq!(page.rows.len(), 1);
    assert_eq!(page.rows.first().unwrap().chat_id, "90");
}

#[test]
fn empty_hot_boundary_pages_keep_the_opposite_direction_flag() {
    let row = Summary::new("only");
    let anchor = SortKey::of(&row);
    let index = SummaryIndex::new().apply(1, row);
    let before = index.read_page(Some(&anchor), ReadSide::Before, false, 20, 8192, None).unwrap();
    assert!(before.rows.is_empty());
    assert!(!before.has_before);
    assert!(before.has_after);
    let after = index.read_page(Some(&anchor), ReadSide::After, false, 20, 8192, None).unwrap();
    assert!(after.rows.is_empty());
    assert!(after.has_before);
    assert!(!after.has_after);
}
