use crate::folds::Folds;
use crate::log::{
    Anchor, Edge, MAX_BLOB_READ, MAX_FRAME_BYTES, MAX_ROWS, RECORD_OVERHEAD, RawRange, Side,
};
use crate::testkit::{folded_book, ids, open};
use std::io::{Read, Seek, SeekFrom, Write};

#[test]
fn backward_closed_fold_keeps_group_when_first_out_is_not_adjacent() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, _) = open(home.path());
    log.append_settled(1, 1, RawRange::NONE, br#"{"body":{"out":[[5,6]]}}"#).unwrap();
    for id in 2..=20 {
        log.append_settled(id, 1, RawRange::NONE, b"{}").unwrap();
    }
    let mut folds = Folds::open(&home.path().join("folds.idx"), 0).unwrap();
    folds.append(1, 20).unwrap();
    let before = log.stats().walk_entries;
    let window = log.read_window(Anchor::End, 400, MAX_FRAME_BYTES, Some(&folds), &[]).unwrap();
    assert_eq!(ids(&window.rows), [1, 5, 6]);
    assert_eq!(log.stats().walk_entries - before, 3);
    assert!(!window.has_before && !window.has_after);
    for id in [2, 4, 7, 20] {
        let window = log
            .read_window(
                Anchor::Row { id, side: Side::After },
                1,
                MAX_FRAME_BYTES,
                Some(&folds),
                &[],
            )
            .unwrap();
        assert_eq!(ids(&window.rows), [1]);
    }
    let window = log
        .read_window(
            Anchor::Row { id: 5, side: Side::After },
            1,
            MAX_FRAME_BYTES,
            Some(&folds),
            &[],
        )
        .unwrap();
    assert_eq!(ids(&window.rows), [5]);
    // Reading through the writer must not move its append cursor.
    folds.append(30, 40).unwrap();
    assert_eq!(folds.containing(35).unwrap().unwrap().group, 30);
}

#[test]
fn open_fold_large_pages_read_only_400_entries_in_each_direction() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, folds) = folded_book(home.path(), 100_000);
    for (edge, expected) in [
        (Edge::After(1), 2..=401),
        (Edge::Before(1), 99_601..=100_000),
        (Edge::After(50_000), 50_001..=50_400),
    ] {
        let before = log.stats().walk_entries;
        let page = log.read_page(edge, usize::MAX, Some(1), Some(&folds), &[]).unwrap();
        assert_eq!(ids(&page.rows), expected.collect::<Vec<_>>());
        assert_eq!(log.stats().walk_entries - before, MAX_ROWS as u64);
    }
    let page = log.read_page(Edge::After(100_000), usize::MAX, Some(1), Some(&folds), &[]).unwrap();
    assert!(page.rows.is_empty() && !page.has_after);
    let page = log.read_page(Edge::After(1), usize::MAX, None, Some(&folds), &[1]).unwrap();
    assert_eq!(ids(&page.rows), (2..=401).collect::<Vec<_>>());
}

#[test]
fn corrupt_headers_and_crcs_are_holes_and_stop_resume_before_the_hole() {
    for header in [false, true] {
        let home = tempfile::tempdir().unwrap();
        let (mut log, _) = open(home.path());
        for id in 1..=5 {
            log.append_settled(id, 1, RawRange::NONE, b"{\"ok\":true}").unwrap();
        }
        let sound = log.window(Anchor::End, MAX_ROWS, MAX_FRAME_BYTES).unwrap();
        let row = log.row(3).unwrap();
        let mut file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(home.path().join(format!("rows/{:06}.seg", row.seg)))
            .unwrap();
        let offset = u64::from(row.off) - if header { crate::log::HEADER_LEN as u64 } else { 0 };
        file.seek(SeekFrom::Start(offset)).unwrap();
        let mut byte = [0];
        file.read_exact(&mut byte).unwrap();
        byte[0] ^= if header { 255 } else { 1 };
        file.seek(SeekFrom::Start(offset)).unwrap();
        file.write_all(&byte).unwrap();
        let window = log.window(Anchor::End, MAX_ROWS, MAX_FRAME_BYTES).unwrap();
        assert_eq!(ids(&window.rows), [1, 2, 4, 5]);
        assert_eq!(window.refused, [3]);
        assert_eq!(
            (window.lo, window.hi, window.has_before, window.has_after),
            (sound.lo, sound.hi, sound.has_before, sound.has_after)
        );
        let page = log.page(Edge::After(0), MAX_FRAME_BYTES).unwrap();
        assert_eq!(ids(&page.rows), [1, 2, 4, 5]);
        assert_eq!(page.refused, [3]);
        let since = log.since(0, MAX_FRAME_BYTES).unwrap();
        assert_eq!(ids(&since.rows), [1, 2]);
        assert_eq!(since.cursor, 2);
        assert!(since.stopped_on_refusal);
        let (mut bytes, mut ranges, mut refused) = (Vec::new(), Vec::new(), Vec::new());
        assert_eq!(
            log.fill_checked(&sound.rows, &mut bytes, &mut ranges, &mut refused).unwrap(),
            1
        );
        assert_eq!(ranges.len(), 4);
        assert_eq!(refused, [3]);
        // The hole still spends the row slot: a one-row window does not pull in row 4.
        let one = log.window(Anchor::Row { id: 3, side: Side::After }, 1, MAX_FRAME_BYTES).unwrap();
        assert!(one.rows.is_empty());
        assert_eq!(one.refused, [3]);
        assert_eq!((one.lo, one.hi), (3, 3));
    }
}

#[test]
fn window_page_resume_and_blob_use_the_shared_bound() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, _) = open(home.path());
    for id in 1..=1000 {
        log.append_settled(id, 1, RawRange::NONE, &[b'x'; 1024]).unwrap();
    }
    for reply in [
        log.window(Anchor::End, usize::MAX, usize::MAX).unwrap(),
        log.page(Edge::After(0), usize::MAX).unwrap(),
    ] {
        assert!(reply.rows.len() <= MAX_ROWS);
        assert!(
            reply.rows.iter().map(|r| r.len as usize + RECORD_OVERHEAD).sum::<usize>()
                <= MAX_FRAME_BYTES
        );
    }
    let resume = log.since(0, usize::MAX).unwrap();
    assert!(resume.more);
    assert!(
        resume.rows.iter().map(|r| r.len as usize + RECORD_OVERHEAD).sum::<usize>()
            <= MAX_FRAME_BYTES
    );
    log.write_blob(1001, &vec![b'x'; MAX_BLOB_READ * 2]).unwrap();
    let mut bytes = Vec::new();
    let reply = log.read_blob_range(1001, 10, usize::MAX, &mut bytes).unwrap();
    assert_eq!(bytes.len(), MAX_BLOB_READ);
    assert_eq!(
        (reply.start, reply.end, reply.total),
        (10, 10 + MAX_BLOB_READ as u64, 2 * MAX_BLOB_READ as u64)
    );
}

#[test]
fn resume_size_uses_sparse_offsets_and_at_most_one_segment_length() {
    use crate::log::{Log, Options, ResumeSize, SEGMENT_HEADER_LEN};
    for (segment_bytes, expected_segments) in [(1_000_000, 1), (20_000, 2), (10_000, 3)] {
        let home = tempfile::tempdir().unwrap();
        let (mut log, _) = Log::open(home.path(), Options { segment_bytes }).unwrap();
        let file = log.append_raw_file(b"fixture").unwrap();
        for id in 1..=600 {
            log.append_settled(id, 1, RawRange { file, off: id, len: 1 }, b"{}").unwrap();
        }
        assert_eq!(log.row(600).unwrap().seg, expected_segments);
        let before = log.stats();
        // Both cursors start at the record with seq 256. Their actual missed records differ.
        let first = log.resume_size(260, u64::MAX).unwrap();
        let second = log.resume_size(300, u64::MAX).unwrap();
        assert_eq!(first, second);
        let ResumeSize::Within(bytes) = first else { panic!("at most two segments from seq 256") };
        assert_eq!(bytes, (600 - 256 + 1) * (RECORD_OVERHEAD + 2) as u64);
        for cursor in [260, 300] {
            let true_missed = (600 - cursor) * (RECORD_OVERHEAD + 2) as u64;
            assert!(bytes >= true_missed);
        }
        assert_eq!(log.resume_size(600, 0).unwrap(), ResumeSize::Within(0));
        assert_eq!(log.resume_size(u64::MAX, 0).unwrap(), ResumeSize::Within(0));
        assert_eq!(log.resume_size(260, bytes - 1).unwrap(), ResumeSize::Over);
        let all = log.resume_size(0, u64::MAX).unwrap();
        if expected_segments >= 3 {
            assert_eq!(all, ResumeSize::Over);
        } else {
            assert_eq!(all, ResumeSize::Within(600 * (RECORD_OVERHEAD + 2) as u64));
        }
        assert_eq!(log.stats().bytes_read, before.bytes_read);
        assert_eq!(log.stats().reads, before.reads);
        assert_eq!(
            log.row(1).unwrap().off as u64,
            SEGMENT_HEADER_LEN + crate::log::HEADER_LEN as u64
        );
    }
}

#[test]
fn truncated_resume_record_names_a_stop_instead_of_a_clean_end() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, _) = open(home.path());
    for id in 1..=3 {
        log.append_settled(id, 1, RawRange::NONE, b"{}").unwrap();
    }
    let row = log.row(3).unwrap();
    std::fs::OpenOptions::new()
        .write(true)
        .open(home.path().join(format!("rows/{:06}.seg", row.seg)))
        .unwrap()
        .set_len(u64::from(row.off) - crate::log::HEADER_LEN as u64)
        .unwrap();
    let result = log.since(0, MAX_FRAME_BYTES).unwrap();
    assert_eq!(ids(&result.rows), [1, 2]);
    assert_eq!(result.cursor, 2);
    assert!(result.stopped_on_refusal);
}

#[test]
fn closed_fold_pagination_never_uses_a_hidden_gap_as_its_cursor() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, _) = open(home.path());
    log.append_settled(1, 1, RawRange::NONE, br#"{"body":{"out":[[2,3],[5,6]]}}"#).unwrap();
    for id in 2..=10 {
        log.append_settled(id, 1, RawRange::NONE, b"{}").unwrap();
    }
    let mut folds = Folds::open(&home.path().join("folds.idx"), 0).unwrap();
    folds.append(1, 10).unwrap();
    let bytes = 2 * (RECORD_OVERHEAD + 2);
    let first = log.read_page(Edge::After(1), bytes, None, Some(&folds), &[]).unwrap();
    assert_eq!(ids(&first.rows), [2, 3]);
    assert_eq!(first.hi, 3);
    assert!(first.has_after);
    let second = log.read_page(Edge::After(first.hi), bytes, None, Some(&folds), &[]).unwrap();
    assert_eq!(ids(&second.rows), [5, 6]);
    assert!(!second.has_after);
    let back = log.read_page(Edge::Before(11), bytes, None, Some(&folds), &[]).unwrap();
    assert_eq!(ids(&back.rows), [5, 6]);
    assert_eq!(back.lo, 5);
    let back = log.read_page(Edge::Before(back.lo), bytes, None, Some(&folds), &[]).unwrap();
    assert_eq!(ids(&back.rows), [2, 3]);
    assert_eq!(back.lo, 2);
    let before = log.read_page(Edge::Before(2), bytes, Some(1), Some(&folds), &[]).unwrap();
    assert!(before.rows.is_empty() && !before.has_before && before.has_after);
    let after = log.read_page(Edge::After(10), bytes, Some(1), Some(&folds), &[]).unwrap();
    assert!(after.rows.is_empty() && after.has_before && !after.has_after);
}

#[test]
fn fold_group_crc_is_reused_only_within_the_same_request() {
    for rows in [10, 100_000] {
        let home = tempfile::tempdir().unwrap();
        let (mut log, folds) = folded_book(home.path(), rows);
        for anchor in [Anchor::End, Anchor::Row { id: rows, side: Side::After }] {
            let reads = log.stats().reads;
            let window =
                log.read_window(anchor, MAX_ROWS, MAX_FRAME_BYTES, Some(&folds), &[]).unwrap();
            assert_eq!(ids(&window.rows), [1, 2, 3]);
            assert_eq!(log.stats().reads - reads, 2, "one group read and one out read at {rows}");
        }
        let group = log.row(1).unwrap();
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .open(home.path().join(format!("rows/{:06}.seg", group.seg)))
            .unwrap();
        file.seek(SeekFrom::Start(u64::from(group.off))).unwrap();
        file.write_all(b"!").unwrap();
        let window =
            log.read_window(Anchor::End, MAX_ROWS, MAX_FRAME_BYTES, Some(&folds), &[]).unwrap();
        assert!(window.rows.is_empty());
        assert_eq!(window.refused, [1], "the previous request's check must not be reused");
    }
}

/// What a read costs: its searches and steps in `folds.idx`, and its bytes from the segments.
mod read_costs {
    use crate::folds::Folds;
    use crate::log::{
        Anchor, Edge, Log, MAX_FRAME_BYTES, MAX_PAGE_BYTES, RECORD_OVERHEAD, RawRange,
        SEGMENT_HEADER_LEN, Side, Window,
    };
    use crate::testkit::{
        REPLY, TURN_ROWS, folded_turns, ids, open, text, texts, turn_group, turn_group_text,
    };

    type Read = Box<dyn Fn(&mut Log, &Folds) -> Window>;

    /// The texts a reply carries in its own buffer.
    fn carried(window: &Window) -> Vec<Vec<u8>> {
        assert_eq!(window.at.len(), window.rows.len());
        window.at.iter().map(|range| window.bytes.get(range.clone()).unwrap().to_vec()).collect()
    }

    fn reply(turn: u64) -> u64 {
        turn_group(turn) + TURN_ROWS - 1
    }

    /// Fold-aware reads near the end of a book whose last turn is `last`.
    fn fold_reads(last: u64) -> Vec<(&'static str, Read)> {
        let two_turns = 2 * (RECORD_OVERHEAD + turn_group_text(last).len())
            + 2 * (RECORD_OVERHEAD + REPLY.len());
        let window = |anchor: Anchor, rows: usize| -> Read {
            Box::new(move |log: &mut Log, folds: &Folds| {
                log.read_window(anchor, rows, MAX_FRAME_BYTES, Some(folds), &[]).unwrap()
            })
        };
        let page = |edge: Edge, bytes: usize, fold: Option<u64>| -> Read {
            Box::new(move |log: &mut Log, folds: &Folds| {
                log.read_page(edge, bytes, fold, Some(folds), &[]).unwrap()
            })
        };
        vec![
            ("end", window(Anchor::End, 16)),
            ("before", window(Anchor::Row { id: reply(last - 3), side: Side::Before }, 6)),
            ("after", window(Anchor::Row { id: reply(last - 6), side: Side::After }, 6)),
            ("around", window(Anchor::Row { id: reply(last - 4), side: Side::Around }, 8)),
            (
                "around a hidden row",
                window(Anchor::Row { id: turn_group(last - 4) + 1, side: Side::Around }, 8),
            ),
            ("page before", page(Edge::Before(turn_group(last - 1)), two_turns, None)),
            ("page after", page(Edge::After(reply(last - 5)), two_turns, None)),
            (
                "fold page",
                page(Edge::After(turn_group(last - 2)), MAX_PAGE_BYTES, Some(turn_group(last - 2))),
            ),
        ]
    }

    #[test]
    fn one_fold_search_a_read_and_the_same_steps_at_both_sizes() {
        const LAST: u64 = 999;
        let home = tempfile::tempdir().unwrap();
        let (mut small, small_folds) = folded_turns(&home.path().join("small"), LAST - 9, 10);
        let (mut large, large_folds) = folded_turns(&home.path().join("large"), 0, LAST + 1);
        for (name, read) in fold_reads(LAST) {
            let mut seen = Vec::new();
            for (log, folds) in [(&mut small, &small_folds), (&mut large, &large_folds)] {
                let before = folds.stats();
                let window = read(log, folds);
                let after = folds.stats();
                assert_eq!(after.searches - before.searches, 1, "{name}: one search a read");
                assert!(!window.rows.is_empty() && window.refused.is_empty(), "{name}");
                let cost = (
                    after.search_reads - before.search_reads,
                    after.entry_reads - before.entry_reads,
                );
                seen.push((ids(&window.rows), carried(&window), cost));
            }
            assert_eq!(seen.first(), seen.get(1), "{name}: the same rows, texts and steps");
        }
        // The end is in memory: a window there reads one entry a turn it steps back over.
        let before = large_folds.stats();
        let window =
            large.read_window(Anchor::End, 16, MAX_FRAME_BYTES, Some(&large_folds), &[]).unwrap();
        let after = large_folds.stats();
        let expected: Vec<u64> =
            (LAST - 7..=LAST).flat_map(|turn| [turn_group(turn), reply(turn)]).collect();
        assert_eq!(ids(&window.rows), expected);
        assert_eq!(after.search_reads - before.search_reads, 0);
        assert_eq!(after.entry_reads - before.entry_reads, 7);
        for (row, text) in window.rows.iter().zip(carried(&window)) {
            if row.row_id == reply((row.row_id - 1) / TURN_ROWS) {
                assert_eq!(text, REPLY);
            } else {
                assert_eq!(text, turn_group_text((row.row_id - 1) / TURN_ROWS));
            }
        }
    }

    /// Asserts a reply read each of its records once and nothing else (the segment's head is
    /// the slack), and carries the same texts [`Log::fill`] reads.
    fn read_once(log: &mut Log, name: &str, read: impl FnOnce(&mut Log) -> Window) {
        let before = log.stats().bytes_read;
        let window = read(log);
        let bytes_read = log.stats().bytes_read - before;
        let records: u64 =
            window.rows.iter().map(|row| u64::from(row.len) + RECORD_OVERHEAD as u64).sum();
        assert!(!window.rows.is_empty() && window.refused.is_empty(), "{name}");
        assert!(
            bytes_read <= records + SEGMENT_HEADER_LEN,
            "{name}: read {bytes_read} bytes for {records} bytes of records"
        );
        assert_eq!(carried(&window), texts(log, &window.rows).0, "{name}");
    }

    #[test]
    fn a_reply_reads_each_record_once() {
        let home = tempfile::tempdir().unwrap();
        for rows in [100u64, 3_000] {
            let (mut log, _) = open(&home.path().join(format!("plain-{rows}")));
            let file = log.append_raw_file(b"fixture/plain.ndjson").unwrap();
            for id in 1..=rows {
                log.append_settled(id, 1, RawRange { file, off: id, len: 1 }, &text(id)).unwrap();
            }
            log.sync().unwrap();
            let middle = rows / 2;
            read_once(&mut log, "window end", |log| {
                log.read_window(Anchor::End, 400, MAX_FRAME_BYTES, None, &[]).unwrap()
            });
            read_once(&mut log, "window around", |log| {
                let anchor = Anchor::Row { id: middle, side: Side::Around };
                log.read_window(anchor, 400, MAX_FRAME_BYTES, None, &[]).unwrap()
            });
            read_once(&mut log, "page before", |log| {
                log.read_page(Edge::Before(rows + 1), MAX_PAGE_BYTES, None, None, &[]).unwrap()
            });
            read_once(&mut log, "page after", |log| {
                log.read_page(Edge::After(middle), MAX_PAGE_BYTES, None, None, &[]).unwrap()
            });
        }
        for turns in [10u64, 1_000] {
            let (mut log, folds) =
                folded_turns(&home.path().join(format!("folded-{turns}")), 0, turns);
            let max = reply(turns - 1);
            read_once(&mut log, "folded window end", |log| {
                log.read_window(Anchor::End, 400, MAX_FRAME_BYTES, Some(&folds), &[]).unwrap()
            });
            read_once(&mut log, "folded page before", |log| {
                log.read_page(Edge::Before(max + 1), MAX_PAGE_BYTES, None, Some(&folds), &[])
                    .unwrap()
            });
            read_once(&mut log, "folded page after", |log| {
                log.read_page(Edge::After(0), MAX_PAGE_BYTES, None, Some(&folds), &[]).unwrap()
            });
            let group = turn_group(turns / 2);
            read_once(&mut log, "open fold page", |log| {
                log.read_page(Edge::After(group), MAX_PAGE_BYTES, Some(group), Some(&folds), &[])
                    .unwrap()
            });
        }
    }
}
