//! The mirror's mark: its record, its order against the unit's rows when a
//! write is cut, and its place in compaction.
use super::*;
use std::collections::HashMap;
use std::fs;

const ORIGIN: &str = "peer-a";
const ROWS: usize = 500;
const UNITS: u64 = 1_000;

/// The source's frames: unit `k` changes one to three of 500 rows, and every
/// seventh change is a removal. The same input every run.
fn unit_changes(unit: u64) -> Vec<(String, Option<Summary>)> {
    let count = 1 + (unit % 3) as usize;
    (0..count)
        .map(|n| {
            let row = (unit as usize * 7 + n * 131) % ROWS;
            let chat_id = format!("chat-{row:03}");
            if (unit + n as u64).is_multiple_of(7) {
                (chat_id, None)
            } else {
                let mut summary = Summary::new(chat_id.clone());
                summary.origin = ORIGIN.to_owned();
                summary.state = "running".to_owned();
                summary.title = format!("unit {unit} change {n}");
                summary.last_activity = unit * 10 + n as u64;
                (chat_id, Some(summary.prepare().unwrap()))
            }
        })
        .collect()
}

fn mark(unit: u64) -> MirrorMark {
    MirrorMark { cursor: unit, edition: 9, whole: unit >= 10 }
}

/// What the hub's writer does with one unit: rows with the next sequences,
/// the mark after them carrying the last row's sequence, one append.
fn write_unit(log: &mut IndexLog, index: SummaryIndex, unit: u64) -> SummaryIndex {
    let mut seq = index.seq();
    let mut records = Vec::new();
    for (chat_id, summary) in unit_changes(unit) {
        seq += 1;
        records.push(IndexRecord {
            seq,
            origin: ORIGIN.to_owned(),
            chat_id: chat_id.clone(),
            gone: summary.is_none(),
            summary: summary.unwrap_or_else(|| Summary::new(chat_id)),
        });
    }
    let record = MarkRecord { seq, origin: ORIGIN.to_owned(), mark: Some(mark(unit)) };
    log.append_unit(&records, &record).unwrap();
    let mut index = index;
    for record in records {
        index = if record.gone {
            let key = RowKey::new(record.origin, record.chat_id);
            index.remove_row(record.seq, &key).unwrap_or(index).advance_seq(record.seq)
        } else {
            index.apply_summary(record.seq, record.summary)
        };
    }
    index.apply_mark(&record)
}

fn rows(index: &SummaryIndex) -> Vec<(String, String, u64)> {
    let mut rows: Vec<_> = index
        .iter()
        .map(|row| (row.chat_id.clone(), row.title.clone(), row.last_activity))
        .collect();
    rows.sort();
    rows
}

/// Each row's value after every unit that changed it, `None` for removed.
fn row_history() -> HashMap<String, Vec<(u64, Option<String>)>> {
    let mut history: HashMap<String, Vec<(u64, Option<String>)>> = HashMap::new();
    for unit in 1..=UNITS {
        for (chat_id, summary) in unit_changes(unit) {
            history.entry(chat_id).or_default().push((unit, summary.map(|row| row.title)));
        }
    }
    history
}

#[test]
fn mark_record_round_trips_and_states_its_bytes() {
    for record in [
        MarkRecord { seq: 41, origin: ORIGIN.to_owned(), mark: Some(mark(12)) },
        MarkRecord { seq: 42, origin: "x".repeat(256), mark: None },
    ] {
        let bytes = codec::encode_mark(&record).unwrap();
        assert_eq!(bytes.len() as u64, record.encoded_len());
        let (decoded, len) = codec::read_any(&mut bytes.as_slice()).unwrap().unwrap();
        assert_eq!(len, bytes.len());
        let codec::LogRecord::Mark(decoded) = decoded else { panic!("not a mark") };
        assert_eq!(decoded, record);
    }
    // A mark is never a snapshot row.
    let bytes =
        codec::encode_mark(&MarkRecord { seq: 1, origin: ORIGIN.to_owned(), mark: Some(mark(1)) })
            .unwrap();
    assert!(codec::read(&mut bytes.as_slice()).is_err());
}

#[test]
fn a_unit_append_refuses_a_mark_ahead_of_or_behind_its_rows() {
    let dir = tempfile::tempdir().unwrap();
    let mut log = IndexLog::open(dir.path().join("index.log")).unwrap();
    let row = IndexRecord {
        seq: 1,
        origin: ORIGIN.to_owned(),
        chat_id: "a".to_owned(),
        summary: Summary::new("a"),
        gone: false,
    };
    let ahead = MarkRecord { seq: 2, origin: ORIGIN.to_owned(), mark: Some(mark(1)) };
    assert!(log.append_unit(std::slice::from_ref(&row), &ahead).is_err());
    let other = MarkRecord { seq: 1, origin: "peer-b".to_owned(), mark: Some(mark(1)) };
    assert!(log.append_unit(std::slice::from_ref(&row), &other).is_err());
    assert_eq!(log.offset(), 0);
}

/// 500 rows through 1,000 units, the log cut at every record boundary and
/// inside every record. After each reopen the mark's cursor is at or behind
/// the rows on disk, and writing the units after the mark ends equal to the
/// uncut run.
#[test]
fn every_cut_leaves_the_mark_at_or_behind_its_rows() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("index.log");
    let mut log = IndexLog::open(&path).unwrap();
    let mut whole = SummaryIndex::new();
    for unit in 1..=UNITS {
        whole = write_unit(&mut log, whole, unit);
    }
    log.sync().unwrap();
    drop(log);
    assert_eq!(whole.mirror_mark(ORIGIN), Some(mark(UNITS)));
    let expected = rows(&whole);
    let bytes = fs::read(&path).unwrap();
    let mut boundaries = vec![0];
    let mut reader = bytes.as_slice();
    while let Some((_, len)) = codec::read_any(&mut reader).unwrap() {
        boundaries.push(boundaries.last().unwrap() + len);
    }
    assert_eq!(*boundaries.last().unwrap(), bytes.len());
    let mut cuts = Vec::new();
    for pair in boundaries.windows(2) {
        cuts.push(pair[0]);
        cuts.push((pair[0] + pair[1]) / 2);
    }
    cuts.push(bytes.len());
    let history = row_history();
    let cut_dir = tempfile::tempdir().unwrap();
    let cut_path = cut_dir.path().join("index.log");
    for (n, cut) in cuts.into_iter().enumerate() {
        fs::write(&cut_path, &bytes[..cut]).unwrap();
        let mut log = IndexLog::open(&cut_path).unwrap();
        let reopened = replay_log(&cut_path, SummaryIndex::new()).unwrap();
        let cursor = reopened.mirror_mark(ORIGIN).map_or(0, |mark| mark.cursor);
        // At or behind: every row holds the value of its last change at or
        // before the cursor, or of a later one.
        for (chat_id, changes) in &history {
            let floor = changes.iter().rposition(|(unit, _)| *unit <= cursor);
            let row = reopened.get_row(&RowKey::new(ORIGIN, chat_id.as_str()));
            let found = row.as_ref().map(|row| row.title.clone());
            let allowed = match floor {
                None => found.is_none() || changes.iter().any(|(_, title)| *title == found),
                Some(at) => changes[at..].iter().any(|(_, title)| *title == found),
            };
            assert!(allowed, "cut {cut}: {chat_id} is behind mark {cursor}: {found:?}");
        }
        assert_eq!(log.next_seq(), reopened.seq(), "cut {cut}");
        let mut resumed = reopened;
        for unit in cursor + 1..=UNITS {
            resumed = write_unit(&mut log, resumed, unit);
        }
        log.sync().unwrap();
        drop(log);
        assert_eq!(rows(&resumed), expected, "cut {cut}");
        assert_eq!(resumed.mirror_mark(ORIGIN), Some(mark(UNITS)), "cut {cut}");
        if n % 97 != 0 {
            continue;
        }
        let again = replay_log(&cut_path, SummaryIndex::new()).unwrap();
        assert_eq!(rows(&again), expected, "cut {cut} after a second reopen");
        assert_eq!(again.mirror_mark(ORIGIN), Some(mark(UNITS)), "cut {cut}");
    }
}

#[test]
fn a_mark_written_off_replays_as_no_cursor() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("index.log");
    let mut log = IndexLog::open(&path).unwrap();
    let index = write_unit(&mut log, SummaryIndex::new(), 1);
    let off = MarkRecord { seq: index.seq(), origin: ORIGIN.to_owned(), mark: None };
    log.append_mark(&off).unwrap();
    let index = index.apply_mark(&off);
    assert_eq!(index.mirror_mark(ORIGIN), None);
    log.sync().unwrap();
    drop(log);
    let log = IndexLog::open(&path).unwrap();
    assert_eq!(log.offset(), fs::metadata(&path).unwrap().len(), "the off mark was cut");
    let replayed = replay_log(&path, SummaryIndex::new()).unwrap();
    assert_eq!(replayed.mirror_mark(ORIGIN), None);
    assert_eq!(rows(&replayed), rows(&index));
}

#[test]
fn compaction_keeps_the_newest_mark_per_origin_and_none_written_off() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("index.log");
    let mut log = IndexLog::open(&path).unwrap();
    let mut index = SummaryIndex::new();
    for unit in 1..=40 {
        index = write_unit(&mut log, index, unit);
    }
    let other = MarkRecord { seq: index.seq(), origin: "peer-b".to_owned(), mark: Some(mark(3)) };
    log.append_mark(&other).unwrap();
    index = index.apply_mark(&other);
    let gone = MarkRecord { seq: index.seq(), origin: "peer-c".to_owned(), mark: Some(mark(5)) };
    log.append_mark(&gone).unwrap();
    index = index.apply_mark(&gone);
    let off = MarkRecord { mark: None, ..gone };
    log.append_mark(&off).unwrap();
    index = index.apply_mark(&off);
    let before = log.retained_bytes();
    log.compact(path.with_extension("snap"), &index).unwrap();
    // A mark written after the capture, in the new generation.
    index = write_unit(&mut log, index, 41);
    log.sync().unwrap();
    drop(log);
    let disk = DiskSnapshot::open(path.with_extension("snap")).unwrap().unwrap();
    assert_eq!(disk.marks().count(), 2, "one mark per origin held, none written off");
    let opened = SummaryIndex::from_disk(Some(disk.clone()), 1);
    assert_eq!(opened.mirror_mark(ORIGIN), Some(mark(40)));
    assert_eq!(opened.mirror_mark("peer-b"), Some(mark(3)));
    assert_eq!(opened.mirror_mark("peer-c"), None);
    let log = IndexLog::open(&path).unwrap();
    assert!(log.retained_bytes() < before, "compaction bounded the marks' growth");
    let replayed = replay_generation_logs(dir.path(), disk.covered_generation(), opened).unwrap();
    assert_eq!(replayed.mirror_mark(ORIGIN), Some(mark(41)));
    assert_eq!(replayed.mirror_mark("peer-b"), Some(mark(3)));
    assert_eq!(replayed.mirror_mark("peer-c"), None);
    assert_eq!(index.mirror_mark(ORIGIN), Some(mark(41)));
}

#[test]
fn a_removed_origin_drops_its_mark() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("index.log");
    let mut log = IndexLog::open(&path).unwrap();
    let index = write_unit(&mut log, SummaryIndex::new(), 1);
    let removed = OriginRecord {
        seq: index.seq() + 1,
        id: ORIGIN.to_owned(),
        state: OriginState::Removed,
        since: 1,
        extra: None,
    };
    log.append_origin(&removed).unwrap();
    let index = index.apply_origin(removed.seq, removed);
    assert_eq!(index.mirror_mark(ORIGIN), None);
    log.sync().unwrap();
    drop(log);
    assert_eq!(replay_log(&path, SummaryIndex::new()).unwrap().mirror_mark(ORIGIN), None);
}
