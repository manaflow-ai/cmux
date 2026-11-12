use crate::log::{
    Anchor, Edge, Error, Log, MAX_CHECKPOINT, MAX_PAGE_BYTES, Options, Patch, RECORD_OVERHEAD,
    ROW_ENTRY_LEN, RawRange, SEQ_STRIDE, Side, StateWriter, section, sections,
};
use crate::row::{MAX_ROW_TEXT, Placement, Row, RowKind};
use crate::testkit::{assert_rows, ids, open, settle, text, texts, whole_book};
use std::io::{Read, Seek, SeekFrom, Write};

fn small_segments() -> Options {
    Options { segment_bytes: 8 * 1024 }
}

#[test]
fn rows_come_back_in_book_order_as_the_bytes_that_went_in() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, recovered) = open(home.path());
    assert_eq!((recovered.checkpoint, recovered.replayed, recovered.truncated), (false, 0, 0));
    assert_eq!((log.last_seq(), log.min_row(), log.max_row()), (0, 0, 0));
    let empty = log.window(Anchor::End, 400, 1 << 20);
    assert!(empty.rows.is_empty() && !empty.has_before && !empty.has_after);

    for id in 1..=40 {
        assert_eq!(log.append_settled(id, 1, RawRange::NONE, &text(id)).unwrap(), id);
    }
    assert_eq!((log.last_seq(), log.min_row(), log.max_row()), (40, 1, 40));
    let window = log.window(Anchor::End, 400, 1 << 20);
    assert_eq!(ids(&window.rows), (1..=40).collect::<Vec<_>>());
    assert_eq!((window.lo, window.hi, window.has_before, window.has_after), (1, 40, false, false));
    let (read, reads) = texts(&mut log, &window.rows);
    assert_eq!(reads, 1, "neighbouring records come in one read");
    for (id, read) in (1..=40).zip(read) {
        assert_eq!(read, text(id));
    }
    assert_eq!(log.row(7).unwrap().len as usize, text(7).len());
    assert!(log.row(41).is_none() && log.row(0).is_none());
}

#[test]
fn an_append_writes_the_row_and_a_constant() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, _) = open(home.path());
    let mut expected = 0u64;
    for id in 1..=600u64 {
        let before = log.stats();
        log.append_settled(id, 1, RawRange::NONE, &text(id)).unwrap();
        let after = log.stats();
        let seq_entry = if id.is_multiple_of(SEQ_STRIDE) { 8 } else { 0 };
        let wrote = text(id).len() as u64 + RECORD_OVERHEAD as u64 + ROW_ENTRY_LEN + seq_entry;
        assert_eq!(after.bytes_written - before.bytes_written, wrote, "row {id}");
        assert_eq!(after.writes - before.writes, if seq_entry == 0 { 2 } else { 3 });
        assert_eq!(after.syncs - before.syncs, 1, "a daemon-created row syncs before its index");
        expected += wrote;
    }
    assert_eq!(log.stats().bytes_written, expected);
    assert_eq!(log.stats().reads, 0);
}

#[test]
fn rows_settle_out_of_order_and_both_orders_hold() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, _) = open(home.path());
    // A group row (1) and a slow tool (3) settle after rows that began later.
    for id in [2, 4, 5, 3, 6, 1] {
        log.append_settled(id, 1, RawRange::NONE, &text(id)).unwrap();
    }
    let window = log.window(Anchor::End, 400, 1 << 20);
    assert_eq!(ids(&window.rows), vec![1, 2, 3, 4, 5, 6], "book order is rowId order");
    let (read, reads) = texts(&mut log, &window.rows);
    assert_eq!(reads, 1);
    assert_eq!(read, (1..=6).map(text).collect::<Vec<_>>());

    let since = log.since(0, 1 << 20).unwrap();
    assert_eq!(ids(&since.rows), vec![2, 4, 5, 3, 6, 1], "change order is settle order");
    assert_eq!(since.rows.iter().map(|row| row.seq).collect::<Vec<_>>(), vec![1, 2, 3, 4, 5, 6]);
    assert_eq!((since.cursor, since.more), (6, false));
    let (read, _) = texts(&mut log, &since.rows);
    assert_eq!(read, [2, 4, 5, 3, 6, 1].map(text).to_vec());

    assert!(matches!(
        log.append_settled(3, 1, RawRange::NONE, b"x"),
        Err(Error::AlreadySettled { row_id: 3 })
    ));
    assert!(matches!(log.append_settled(0, 1, RawRange::NONE, b"x"), Err(Error::ZeroRowId)));
}

#[test]
fn a_patch_is_a_new_record_and_the_row_reads_as_its_newest_rev() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, _) = open(home.path());
    settle(&mut log, 1, 5);
    assert!(matches!(log.patch(9, 2, RawRange::NONE, b"x"), Err(Error::NotSettled { row_id: 9 })));
    assert!(matches!(
        log.patch(3, 1, RawRange::NONE, b"x"),
        Err(Error::StaleRev { row_id: 3, have: 1, got: 1 })
    ));
    assert_eq!(log.patch(3, 2, RawRange::NONE, b"{\"answered\":true}").unwrap(), 6);
    assert!(matches!(log.patch(3, 2, RawRange::NONE, b"x"), Err(Error::StaleRev { have: 2, .. })));

    let window = log.window(Anchor::End, 400, 1 << 20);
    assert_eq!(ids(&window.rows), vec![1, 2, 3, 4, 5]);
    assert_eq!(window.rows[2].rev, 2);
    let (read, _) = texts(&mut log, &window.rows);
    assert_eq!(read[2], b"{\"answered\":true}");
    assert_eq!(read[3], text(4));

    // A cursor from before the patch gets it as a change; one from before the row gets both.
    let since = log.since(5, 1 << 20).unwrap();
    assert_eq!((ids(&since.rows), since.rows[0].rev, since.cursor), (vec![3], 2, 6));
    let since = log.since(2, 1 << 20).unwrap();
    assert_eq!(ids(&since.rows), vec![3, 4, 5, 3]);
    assert_eq!(since.rows.iter().map(|row| row.rev).collect::<Vec<_>>(), vec![1, 1, 1, 2]);

    // The patch survives a reopen, with and without a checkpoint.
    drop(log);
    let (mut log, recovered) = open(home.path());
    assert_eq!((recovered.checkpoint, recovered.replayed), (false, 6));
    assert_eq!(log.row(3).unwrap().rev, 2);
    log.write_checkpoint(&[], &[]).unwrap();
    log.patch(3, 5, RawRange::NONE, b"{\"answered\":false}").unwrap();
    drop(log);
    let (mut log, recovered) = open(home.path());
    assert_eq!((recovered.checkpoint, recovered.replayed), (true, 1));
    let row = log.row(3).unwrap();
    assert_eq!(texts(&mut log, &[row]).0[0], b"{\"answered\":false}");
    assert_eq!(log.last_seq(), 7);
}

#[test]
fn a_record_carries_and_returns_its_raw_range() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, _) = open(home.path());
    let file = log.append_raw_file(b"events/000001.ndjson").unwrap();
    let raw = RawRange { file, off: 17, len: 23 };
    log.append_settled(1, 1, raw, b"row").unwrap();
    let since = log.since(0, 1 << 20).unwrap();
    assert_eq!(since.rows[0].raw, raw);
    let window = log.window(Anchor::End, 1, 1 << 20);
    assert_eq!(log.raw_range(&window.rows[0]).unwrap(), raw);
    let bytes = std::fs::read(home.path().join("rows/000001.seg")).unwrap();
    assert_eq!(&bytes[32..36], &file.to_le_bytes());
    assert_eq!(&bytes[36..44], &17u64.to_le_bytes());
    assert_eq!(&bytes[44..48], &23u32.to_le_bytes());
}

#[test]
fn a_raw_file_must_be_mapped_before_a_record_can_name_it() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, _) = open(home.path());
    assert!(matches!(
        log.append_settled(1, 1, RawRange { file: 1, off: 0, len: 1 }, b"row"),
        Err(Error::InvalidInput(_))
    ));
    let file = log.append_raw_file(b"events/one").unwrap();
    log.append_settled(1, 1, RawRange { file, off: 0, len: 1 }, b"row").unwrap();
}

#[test]
fn caller_input_errors_are_not_rebuild_corruption() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, _) = open(home.path());
    assert!(matches!(log.append_raw_file(b"bad\nline"), Err(Error::InvalidInput(_))));
    settle(&mut log, 1, 2);
    assert!(matches!(
        log.patch_many(&[
            Patch { row_id: 1, rev: 2, raw: RawRange::NONE, text: b"one" },
            Patch { row_id: 1, rev: 3, raw: RawRange::NONE, text: b"two" },
        ]),
        Err(Error::InvalidInput(_))
    ));
    assert!(matches!(
        log.append_settled(3, 1, RawRange { file: 1, off: 0, len: 1 }, b"row"),
        Err(Error::InvalidInput(_))
    ));
    assert!(matches!(log.write_checkpoint(&[], &[2]), Err(Error::InvalidInput(_))));
}

#[test]
fn a_row_text_is_1_to_16384_bytes() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, _) = open(home.path());
    assert!(matches!(
        log.append_settled(1, 1, RawRange::NONE, b""),
        Err(Error::RowText { len: 0 })
    ));
    let over = vec![b'x'; MAX_ROW_TEXT + 1];
    assert!(matches!(
        log.append_settled(1, 1, RawRange::NONE, &over),
        Err(Error::RowText { len: 16385 })
    ));
    assert_eq!(log.last_seq(), 0, "a refused row takes no seq");
    log.append_settled(1, 1, RawRange::NONE, &over[..MAX_ROW_TEXT]).unwrap();
    log.append_settled(2, 1, RawRange::NONE, b"x").unwrap();
    let window = log.window(Anchor::End, 400, 1 << 20);
    let (read, _) = texts(&mut log, &window.rows);
    assert_eq!((read[0].len(), read[1].as_slice()), (MAX_ROW_TEXT, &b"x"[..]));
}

#[test]
fn segments_roll_and_every_read_crosses_them() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, _) = Log::open(home.path(), small_segments()).unwrap();
    settle(&mut log, 1, 600);
    let segments = std::fs::read_dir(home.path().join("rows")).unwrap().count();
    assert!(segments > 20, "{segments} segments");
    for entry in std::fs::read_dir(home.path().join("rows")).unwrap() {
        let entry = entry.unwrap();
        let bytes = std::fs::read(entry.path()).unwrap();
        assert!(bytes.len() <= 8 * 1024);
        assert_eq!(&bytes[..8], b"ABSG\x01\0\0\0", "{}", entry.path().display());
    }
    assert_rows(&mut log, 600);
    assert!(log.stats().open_readers <= 4, "old segments are read through at most four handles");

    // A resume walks the segments in change order, in bounded replies.
    let (mut cursor, mut seen) = (0, Vec::new());
    loop {
        let since = log.since(cursor, 4 * 1024).unwrap();
        assert!(since.rows.iter().map(|row| row.len as usize).sum::<usize>() <= 4 * 1024);
        seen.extend(ids(&since.rows));
        cursor = since.cursor;
        if !since.more {
            break;
        }
    }
    assert_eq!(seen, (1..=600).collect::<Vec<_>>());
    for cursor in [1, 255, 256, 257, 511, 512, 599] {
        let since = log.since(cursor, 1 << 20).unwrap();
        assert_eq!(ids(&since.rows), (cursor + 1..=600).collect::<Vec<_>>(), "from {cursor}");
    }
    assert_eq!(log.since(600, 1 << 20).unwrap().rows, vec![]);
    assert_eq!(log.since(9999, 1 << 20).unwrap().cursor, 600);

    // Reopened with no checkpoint, the indexes are rebuilt from the segments.
    drop(log);
    std::fs::remove_file(home.path().join("rows.idx")).unwrap();
    std::fs::remove_file(home.path().join("seq.idx")).unwrap();
    let (mut log, recovered) = Log::open(home.path(), small_segments()).unwrap();
    assert_eq!((recovered.checkpoint, recovered.replayed, recovered.truncated), (false, 600, 0));
    assert_rows(&mut log, 600);
    assert_eq!(ids(&log.since(511, 1 << 20).unwrap().rows), (512..=600).collect::<Vec<_>>());

    // With a checkpoint, only what came after it is read.
    log.write_checkpoint(b"state", &[]).unwrap();
    settle(&mut log, 601, 640);
    drop(log);
    let (mut log, recovered) = Log::open(home.path(), small_segments()).unwrap();
    assert_eq!((recovered.checkpoint, recovered.replayed), (true, 40));
    assert_eq!(recovered.state, b"state");
    assert_rows(&mut log, 640);
    settle(&mut log, 641, 700);
    assert_rows(&mut log, 700);
}

#[test]
fn a_window_is_bounded_in_rows_and_bytes_and_says_what_lies_beyond() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, _) = open(home.path());
    settle(&mut log, 1, 1000);

    let end = log.window(Anchor::End, 400, 1 << 20);
    assert_eq!(ids(&end.rows), (601..=1000).collect::<Vec<_>>());
    assert_eq!((end.lo, end.hi, end.has_before, end.has_after), (601, 1000, true, false));

    let bytes =
        |rows: &[crate::log::RowRef]| rows.iter().map(|row| row.len as usize).sum::<usize>();
    let tight = log.window(Anchor::End, 400, 4096);
    assert!(bytes(&tight.rows) <= 4096 && tight.rows.len() < 40 && !tight.rows.is_empty());
    assert_eq!(tight.rows.last().unwrap().row_id, 1000);
    assert_eq!(log.window(Anchor::End, 400, 0).rows.len(), 1, "never empty for its size");
    assert_eq!(log.window(Anchor::End, 0, 1 << 20).rows.len(), 0);
    assert_eq!(log.window(Anchor::End, usize::MAX, usize::MAX).rows.len(), 1000);

    let before = log.window(Anchor::Row { id: 500, side: Side::Before }, 100, 1 << 20);
    assert_eq!(ids(&before.rows), (401..=500).collect::<Vec<_>>());
    assert!(before.has_before && before.has_after);
    let after = log.window(Anchor::Row { id: 500, side: Side::After }, 100, 1 << 20);
    assert_eq!(ids(&after.rows), (500..=599).collect::<Vec<_>>());
    assert_eq!((after.lo, after.hi), (500, 599));
    let around = log.window(Anchor::Row { id: 500, side: Side::Around }, 100, 1 << 20);
    assert_eq!(ids(&around.rows), (450..=549).collect::<Vec<_>>());
    assert_eq!((around.lo, around.hi, around.has_before, around.has_after), (450, 549, true, true));

    // Near an end, the side with nothing left gives its share to the other.
    let first = log.window(Anchor::Row { id: 3, side: Side::Around }, 100, 1 << 20);
    assert_eq!(ids(&first.rows), (1..=100).collect::<Vec<_>>());
    assert!(!first.has_before && first.has_after);
    let last = log.window(Anchor::Row { id: 998, side: Side::Around }, 100, 1 << 20);
    assert_eq!(ids(&last.rows), (901..=1000).collect::<Vec<_>>());
    assert!(last.has_before && !last.has_after);
    let past = log.window(Anchor::Row { id: 5000, side: Side::Around }, 100, 1 << 20);
    assert_eq!(ids(&past.rows), (901..=1000).collect::<Vec<_>>());
    let past = log.window(Anchor::Row { id: 5000, side: Side::Before }, 10, 1 << 20);
    assert_eq!(ids(&past.rows), (991..=1000).collect::<Vec<_>>());
    let past = log.window(Anchor::Row { id: 5000, side: Side::After }, 10, 1 << 20);
    assert!(past.rows.is_empty() && past.has_before && !past.has_after);

    let (read, reads) = texts(&mut log, &around.rows);
    assert_eq!((reads, read.len()), (1, 100));
    assert_eq!(read[0], text(450));
}

#[test]
fn an_around_window_charges_rows_against_one_byte_budget() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, _) = open(home.path());
    log.append_settled(1, 1, RawRange::NONE, &vec![b'b'; 5_000]).unwrap();
    log.append_settled(2, 1, RawRange::NONE, &vec![b'a'; 8_000]).unwrap();
    let window = log.window(Anchor::Row { id: 2, side: Side::Around }, 3, 10_000);
    assert_eq!(ids(&window.rows), vec![2]);
    assert_eq!(window.rows[0].len, 8_000);
}

#[test]
fn unsettled_ids_between_settled_rows_are_stepped_over() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, _) = open(home.path());
    for id in (10..=200u64).filter(|id| !id.is_multiple_of(3)) {
        log.append_settled(id, 1, RawRange::NONE, &text(id)).unwrap();
    }
    let window = log.window(Anchor::Row { id: 99, side: Side::Around }, 20, 1 << 20);
    assert_eq!(window.rows.len(), 20);
    assert!(window.rows.iter().all(|row| !row.row_id.is_multiple_of(3)));
    assert!(window.rows.windows(2).all(|pair| pair[0].row_id < pair[1].row_id));
    assert_eq!((log.min_row(), log.max_row()), (10, 200));
    let all = whole_book(&mut log);
    assert_eq!(all.len(), (10..=200u64).filter(|id| !id.is_multiple_of(3)).count());
    let first = log.page(Edge::Before(12), MAX_PAGE_BYTES);
    assert_eq!((ids(&first.rows), first.has_before), (vec![10, 11], false));
}

#[test]
fn a_page_is_one_read_and_pages_tile_the_book() {
    let home = tempfile::tempdir().unwrap();
    // Segments small enough that pages meet their ends, and rows that settle out of order.
    let (mut log, _) = Log::open(home.path(), Options { segment_bytes: 96 * 1024 }).unwrap();
    for chunk in (1..=3000u64).collect::<Vec<_>>().chunks(8) {
        // Each turn's first row (its group) settles last.
        for id in chunk.iter().skip(1).chain(chunk.first()) {
            log.append_settled(*id, 1, RawRange::NONE, &text(*id)).unwrap();
        }
    }
    let mut seen = Vec::new();
    let mut edge = Edge::Before(u64::MAX);
    let mut pages = 0;
    loop {
        let page = log.page(edge, MAX_PAGE_BYTES);
        let before = log.stats().reads;
        let (read, reads) = texts(&mut log, &page.rows);
        assert_eq!(reads, 1, "a page is one read");
        assert_eq!(log.stats().reads - before, 1);
        assert!(read.iter().map(Vec::len).sum::<usize>() <= MAX_PAGE_BYTES);
        for (row, read) in page.rows.iter().zip(&read).rev() {
            assert!(*read == text(row.row_id));
            seen.push(row.row_id);
        }
        pages += 1;
        if !page.has_before {
            break;
        }
        edge = Edge::Before(page.lo);
    }
    assert_eq!(seen, (1..=3000).rev().collect::<Vec<_>>(), "pages tile the book, none twice");
    let segments = std::fs::read_dir(home.path().join("rows")).unwrap().count();
    // A page ends at a segment's end; a turn that straddles one costs two short pages more.
    assert!(pages <= segments * 3, "{pages} pages over {segments} segments");

    // Forward the same, and a small page is small.
    let mut seen = Vec::new();
    let mut edge = Edge::After(0);
    loop {
        let page = log.page(edge, 2000);
        assert!(page.rows.iter().skip(1).map(|row| row.len).sum::<u32>() <= 2000);
        assert_eq!(texts(&mut log, &page.rows).1, 1);
        seen.extend(ids(&page.rows));
        if !page.has_after {
            break;
        }
        edge = Edge::After(page.hi);
    }
    assert_eq!(seen, (1..=3000).collect::<Vec<_>>());
    assert!(log.page(Edge::Before(1), MAX_PAGE_BYTES).rows.is_empty());
    assert!(log.page(Edge::After(3000), MAX_PAGE_BYTES).rows.is_empty());
}

#[test]
fn a_resume_reads_what_was_missed_not_the_book() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, _) = open(home.path());
    settle(&mut log, 1, 5000);
    let before = log.stats();
    let since = log.since(4990, 1 << 20).unwrap();
    assert_eq!(ids(&since.rows), (4991..=5000).collect::<Vec<_>>());
    let cost = log.stats().bytes_read - before.bytes_read;
    // At most 255 records before the cursor, and the ten after it.
    assert!(cost < 300 * 1024, "{cost} bytes read for ten rows");
    let cut = log.since(100, 1000).unwrap();
    assert!(cut.more && !cut.rows.is_empty() && cut.cursor < 5000);
    assert_eq!(cut.rows[0].seq, 101);
    assert_eq!(cut.cursor, cut.rows.last().unwrap().seq);
    let all = log.since(0, usize::MAX).unwrap();
    assert!(all.more && all.rows.iter().map(|row| row.len as usize).sum::<usize>() <= 1 << 20);
}

#[test]
fn the_checkpoint_keeps_the_actors_state_under_64_kb() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, _) = open(home.path());
    settle(&mut log, 1, 10);
    let mut state = StateWriter::new();
    state.push(section::OPEN_ROWS, &text(11)).push(section::RAW_CURSOR, b"file\0inode\0offset");
    state.push(section::TRANSLATOR, &7u32.to_le_bytes());
    log.write_checkpoint(state.as_bytes(), &[]).unwrap();
    assert_eq!(log.stats().checkpoints, 1);
    assert!(std::fs::metadata(home.path().join("checkpoint")).unwrap().len() < 64 * 1024);

    let too_large = vec![0u8; MAX_CHECKPOINT];
    assert!(matches!(
        log.write_checkpoint(&too_large, &[]),
        Err(Error::CheckpointTooLarge { bytes }) if bytes > MAX_CHECKPOINT
    ));
    let largest = vec![7u8; MAX_CHECKPOINT - 68];
    log.write_checkpoint(&largest, &[]).unwrap();
    assert_eq!(std::fs::metadata(home.path().join("checkpoint")).unwrap().len(), 65535);
    log.write_checkpoint(state.as_bytes(), &[]).unwrap();
    drop(log);

    let (log, recovered) = open(home.path());
    assert_eq!((recovered.checkpoint, recovered.replayed, recovered.truncated), (true, 0, 0));
    let read: Vec<_> = sections(&recovered.state).collect();
    assert_eq!(read.len(), 3);
    assert_eq!(read[0], (section::OPEN_ROWS, text(11).as_slice()));
    assert_eq!(read[1], (section::RAW_CURSOR, &b"file\0inode\0offset"[..]));
    assert_eq!(read[2], (section::TRANSLATOR, &7u32.to_le_bytes()[..]));
    assert_eq!((log.last_seq(), log.min_row(), log.max_row()), (10, 1, 10));
    // No temporary file is left beside the checkpoint.
    let names: Vec<_> = std::fs::read_dir(home.path())
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    assert!(names.iter().all(|name| !name.ends_with(".tmp")), "{names:?}");
    assert_eq!(sections(&[section::SUMMARY, 9, 0, 0, 0, 1]).count(), 0, "a cut section ends it");
}

#[test]
fn a_book_has_one_owner() {
    let home = tempfile::tempdir().unwrap();
    let (log, _) = open(home.path());
    assert!(matches!(Log::open(home.path(), Options::default()), Err(Error::Busy)));
    drop(log);
    let (_log, _) = open(home.path());
}

#[test]
fn a_large_body_goes_to_a_blob_and_is_read_by_range() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, _) = open(home.path());
    let body = format!("{{\"out\":\"{}\"}}", "0123456789".repeat(300_000));
    let row = Row {
        id: 1,
        rev: 1,
        kind: RowKind::Tool,
        turn: None,
        group: None,
        at: 1,
        open: false,
        body: &body,
        est: 40,
    };
    let mut out = Vec::new();
    let Placement::Blob { bytes } = row.encode(None, &mut out).unwrap() else {
        panic!("a 3 MB body is out of line");
    };
    log.write_blob(1, body.as_bytes()).unwrap();
    log.append_settled(1, 1, RawRange::NONE, &out).unwrap();

    let mut read = Vec::new();
    assert_eq!(log.read_blob(1, 0, 16, &mut read).unwrap(), bytes);
    assert_eq!(read, b"{\"out\":\"01234567");
    assert_eq!(log.read_blob(1, bytes - 4, 100, &mut read).unwrap(), bytes);
    assert_eq!(read, b"89\"}");
    log.read_blob(1, 0, usize::MAX, &mut read).unwrap();
    assert_eq!(read.len(), 1 << 20, "one read is at most one frame");
    log.read_blob(1, bytes + 5, 100, &mut read).unwrap();
    assert!(read.is_empty());
    assert!(matches!(log.read_blob(2, 0, 1, &mut read), Err(Error::Io(_))));
    assert!(matches!(log.write_blob(0, b"x"), Err(Error::ZeroRowId)));
}

#[test]
fn an_index_entry_that_does_not_match_its_record_is_reported_not_served() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, _) = open(home.path());
    settle(&mut log, 1, 20);
    log.write_checkpoint(&[], &[]).unwrap();
    drop(log);
    // Point row 5 at row 6's record, and leave an entry for a row whose record was never
    // written (what a power loss between the two writes can leave).
    let mut index = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(home.path().join("rows.idx"))
        .unwrap();
    let mut entry = [0u8; 16];
    index.seek(SeekFrom::Start(6 * 16)).unwrap();
    index.read_exact(&mut entry).unwrap();
    index.seek(SeekFrom::Start(5 * 16)).unwrap();
    index.write_all(&entry).unwrap();
    let segment_len = std::fs::metadata(home.path().join("rows/000001.seg")).unwrap().len() as u32;
    let mut ghost = [0u8; 16];
    ghost[..4].copy_from_slice(&1u32.to_le_bytes());
    ghost[4..8].copy_from_slice(&segment_len.to_le_bytes());
    ghost[8..12].copy_from_slice(&100u32.to_le_bytes());
    ghost[12..].copy_from_slice(&1u32.to_le_bytes());
    index.seek(SeekFrom::Start(21 * 16)).unwrap();
    index.write_all(&ghost).unwrap();
    drop(index);

    let (mut log, _) = open(home.path());
    let window = log.window(Anchor::End, 400, 1 << 20);
    assert_eq!(ids(&window.rows), (1..=20).collect::<Vec<_>>(), "the ghost entry is not a row");
    let (mut buf, mut at) = (Vec::new(), Vec::new());
    assert!(matches!(
        log.fill(&window.rows, &mut buf, &mut at),
        Err(Error::CorruptRow { row_id: 5, .. })
    ));
    assert!(matches!(
        log.patch(5, 2, RawRange::NONE, b"patch"),
        Err(Error::CorruptRow { row_id: 5, .. })
    ));
    let good = log.row(6).unwrap();
    assert_eq!(texts(&mut log, &[good]).0[0], text(6));
    // The ghost's id can settle, and then it is a row like any other.
    log.append_settled(21, 1, RawRange::NONE, &text(21)).unwrap();
    let row = log.row(21).unwrap();
    assert_eq!(texts(&mut log, &[row]).0[0], text(21));
}

#[test]
fn a_log_can_move_to_its_actors_thread() {
    fn is_send<T: Send>() {}
    is_send::<Log>();
}

#[test]
fn a_clean_reopen_writes_nothing_and_a_short_index_is_rebuilt() {
    let home = tempfile::tempdir().unwrap();
    {
        let (mut log, _) = open(home.path());
        settle(&mut log, 1, 700);
        log.write_checkpoint(&[], &[]).unwrap();
        settle(&mut log, 701, 720);
    }
    let (log, recovered) = open(home.path());
    assert_eq!((recovered.checkpoint, recovered.replayed), (true, 20));
    assert_eq!(log.stats().bytes_written, 0, "the entries were already there");
    drop(log);
    // An index file shorter than the checkpoint says it was is not trusted.
    for name in ["rows.idx", "seq.idx"] {
        let index = std::fs::OpenOptions::new().write(true).open(home.path().join(name)).unwrap();
        index.set_len(8).unwrap();
        drop(index);
        let (mut log, recovered) = open(home.path());
        assert_eq!((recovered.checkpoint, recovered.replayed), (false, 720), "{name}");
        assert_rows(&mut log, 720);
        assert_eq!(ids(&log.since(700, 1 << 20).unwrap().rows), (701..=720).collect::<Vec<_>>());
        log.write_checkpoint(&[], &[]).unwrap();
    }
}

#[test]
fn patches_from_one_line_sync_once_before_their_indexes() {
    use crate::log::Patch;
    let home = tempfile::tempdir().unwrap();
    let (mut log, _) = open(home.path());
    settle(&mut log, 1, 3);
    let file = log.append_raw_file(b"events/patch").unwrap();
    log.write_checkpoint(&[], &[]).unwrap();
    let syncs = log.stats().syncs;
    let raw = RawRange { file, off: 0, len: 8 };
    log.patch_many(&[
        Patch { row_id: 1, rev: 2, raw, text: b"one" },
        Patch { row_id: 2, rev: 2, raw, text: b"two" },
        Patch { row_id: 3, rev: 2, raw: RawRange::NONE, text: b"three" },
    ])
    .unwrap();
    assert_eq!(log.stats().syncs - syncs, 1);
    drop(log);
    let (log, recovered) = open(home.path());
    assert_eq!(recovered.replayed, 3);
    for id in 1..=3 {
        assert_eq!(log.row(id).unwrap().rev, 2);
    }
}
