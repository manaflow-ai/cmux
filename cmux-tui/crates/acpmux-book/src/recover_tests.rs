//! A writer killed at any moment: nothing settled is lost, the torn record is cut off, and the
//! next append succeeds.

use crate::log::{Anchor, Error, Log, Options, RECORD_OVERHEAD, RawRange, SEGMENT_HEADER_LEN};
use crate::row::MAX_ROW_TEXT;
use crate::testkit::{assert_rows, copy_book, ids, open, settle, text, texts};
use std::fs::{self, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::Path;

fn segment(book: &Path) -> std::path::PathBuf {
    book.join("rows/000001.seg")
}

/// Zeroes row `id`'s entry in `rows.idx`: the state when the writer died before its index write.
fn forget_index_entry(book: &Path, id: u64) {
    let mut index = OpenOptions::new().write(true).open(book.join("rows.idx")).unwrap();
    index.seek(SeekFrom::Start(id * 16)).unwrap();
    index.write_all(&[0u8; 16]).unwrap();
}

/// Seven rows settle, then the writer dies having written `cut` bytes of the eighth row's
/// record, for every `cut` from 0 to the whole record.
fn killed_at_every_byte_of_a_record(checkpoint_after: Option<u64>) {
    let home = tempfile::tempdir().unwrap();
    let book = home.path().join("book");
    {
        let (mut log, _) = open(&book);
        for id in 1..=7 {
            log.append_settled(id, 1, RawRange::NONE, &text(id)).unwrap();
            if checkpoint_after == Some(id) {
                log.write_checkpoint(b"actor state", &[]).unwrap();
            }
        }
    }
    let settled = fs::metadata(segment(&book)).unwrap().len() as usize;
    {
        let (mut log, _) = open(&book);
        log.append_settled(8, 1, RawRange::NONE, &text(8)).unwrap();
    }
    let whole = fs::read(segment(&book)).unwrap();
    assert_eq!(whole.len(), settled + text(8).len() + RECORD_OVERHEAD);

    for cut in settled..=whole.len() {
        let copy = home.path().join(format!("cut-{cut}"));
        copy_book(&book, &copy);
        fs::write(segment(&copy), &whole[..cut]).unwrap();
        // Byte cuts follow write order. Power-loss tests separately retain newer entries
        // for raw-backed settlements; a synced daemon row cannot leave such an entry.
        if cut < whole.len() {
            forget_index_entry(&copy, 8);
        }

        let (mut log, recovered) = open(&copy);
        let torn = cut < whole.len();
        assert_eq!(recovered.truncated as usize, if torn { cut - settled } else { 0 }, "cut {cut}");
        assert_eq!(recovered.checkpoint, checkpoint_after.is_some());
        if checkpoint_after.is_some() {
            assert_eq!(recovered.state, b"actor state");
        }
        let kept = if torn { 7 } else { 8 };
        assert_eq!((log.last_seq(), log.max_row()), (kept, kept), "cut {cut}");
        assert_rows(&mut log, kept);
        if torn {
            assert_eq!(fs::metadata(segment(&copy)).unwrap().len() as usize, settled);
            assert_eq!(log.append_settled(8, 1, RawRange::NONE, &text(8)).unwrap(), 8, "cut {cut}");
        }
        assert_eq!(log.append_settled(9, 1, RawRange::NONE, &text(9)).unwrap(), 9);
        assert_rows(&mut log, 9);
        drop(log);

        let (mut log, recovered) = open(&copy);
        assert_eq!(recovered.truncated, 0, "a repaired book opens clean");
        assert_rows(&mut log, 9);
        drop(log);
        fs::remove_dir_all(&copy).unwrap();
    }
}

#[test]
fn killed_at_every_byte_of_a_record_with_no_checkpoint() {
    killed_at_every_byte_of_a_record(None);
}

#[test]
fn killed_at_every_byte_of_a_record_after_a_checkpoint() {
    killed_at_every_byte_of_a_record(Some(4));
}

#[test]
fn killed_at_every_byte_of_a_record_right_after_a_checkpoint() {
    killed_at_every_byte_of_a_record(Some(7));
}

/// The largest record (16 KB of row text), in place: every byte of its first and last 128, and
/// every 53rd between. Each kill is followed by a repair and a successful append, and then the
/// next kill.
#[test]
fn killed_across_the_largest_record() {
    let home = tempfile::tempdir().unwrap();
    let book = home.path().join("book");
    let large = vec![b'x'; MAX_ROW_TEXT];
    {
        let (mut log, _) = open(&book);
        settle(&mut log, 1, 3);
        log.write_checkpoint(&[], &[]).unwrap();
    }
    let settled = fs::metadata(segment(&book)).unwrap().len() as usize;
    {
        let (mut log, _) = open(&book);
        log.append_settled(4, 1, RawRange::NONE, &large).unwrap();
    }
    let whole = fs::read(segment(&book)).unwrap();
    assert_eq!(whole.len(), settled + MAX_ROW_TEXT + RECORD_OVERHEAD);
    let near_an_end = |cut: usize| cut < settled + 128 || cut + 128 >= whole.len();
    for cut in (settled..whole.len()).filter(|cut| near_an_end(*cut) || cut.is_multiple_of(53)) {
        fs::write(segment(&book), &whole[..cut]).unwrap();
        forget_index_entry(&book, 4);
        let (mut log, recovered) = open(&book);
        assert_eq!(recovered.truncated as usize, cut - settled, "cut {cut}");
        assert_eq!((log.last_seq(), log.max_row()), (3, 3), "cut {cut}");
        assert!(log.row(4).is_none(), "a row whose record was cut off has not settled");
        assert_eq!(log.append_settled(4, 1, RawRange::NONE, &large).unwrap(), 4, "cut {cut}");
        if cut.is_multiple_of(5) {
            let window = log.window(Anchor::End, 400, 1 << 20).unwrap();
            assert_eq!(ids(&window.rows), vec![1, 2, 3, 4]);
            assert!(texts(&mut log, &window.rows).0[3] == large);
        }
    }
    assert!(fs::read(segment(&book)).unwrap() == whole, "the repaired segment is the whole one");
}

#[test]
fn incomplete_headers_after_the_last_record_are_cut_off() {
    for junk in [vec![0u8; 1], b"not a record at all".to_vec()] {
        let home = tempfile::tempdir().unwrap();
        {
            let (mut log, _) = open(home.path());
            settle(&mut log, 1, 300);
            log.write_checkpoint(&[], &[]).unwrap();
            settle(&mut log, 301, 320);
        }
        let mut file = OpenOptions::new().append(true).open(segment(home.path())).unwrap();
        file.write_all(&junk).unwrap();
        drop(file);
        let (mut log, recovered) = open(home.path());
        assert_eq!((recovered.truncated, recovered.replayed), (junk.len() as u64, 20));
        assert_rows(&mut log, 320);
        settle(&mut log, 321, 330);
        assert_rows(&mut log, 330);
    }
}

#[test]
fn complete_invalid_headers_after_the_mark_are_cut() {
    for junk in [vec![0u8; 4096], vec![0xffu8; 300]] {
        let home = tempfile::tempdir().unwrap();
        {
            let (mut log, _) = open(home.path());
            settle(&mut log, 1, 300);
            log.write_checkpoint(&[], &[]).unwrap();
            settle(&mut log, 301, 320);
        }
        let path = segment(home.path());
        let mut file = OpenOptions::new().append(true).open(&path).unwrap();
        file.write_all(&junk).unwrap();
        let len = file.metadata().unwrap().len();
        drop(file);
        let (mut log, recovered) = open(home.path());
        assert_eq!(recovered.truncated, junk.len() as u64);
        assert_eq!(fs::metadata(path).unwrap().len(), len - junk.len() as u64);
        assert_rows(&mut log, 320);
    }
}

#[test]
fn a_record_whose_seq_does_not_follow_is_torn() {
    // A whole record with a good crc but the wrong seq (a stale block after a power loss) must
    // not be taken for the next row.
    let home = tempfile::tempdir().unwrap();
    let (stale, fresh) = (home.path().join("stale"), home.path().join("fresh"));
    {
        let (mut log, _) = open(&stale);
        settle(&mut log, 1, 5);
    }
    let old = fs::read(segment(&stale)).unwrap();
    {
        let (mut log, _) = open(&fresh);
        settle(&mut log, 1, 2);
    }
    let two = fs::metadata(segment(&fresh)).unwrap().len() as usize;
    // Rows 1 and 2, then the stale book's fifth record (seq 5) where seq 3 belongs.
    let fifth = old.len() - text(5).len() - RECORD_OVERHEAD;
    let mut file = OpenOptions::new().append(true).open(segment(&fresh)).unwrap();
    file.write_all(&old[fifth..]).unwrap();
    drop(file);
    let (mut log, recovered) = open(&fresh);
    assert_eq!(recovered.truncated as usize, old.len() - fifth);
    assert_eq!(fs::metadata(segment(&fresh)).unwrap().len() as usize, two);
    assert_rows(&mut log, 2);
}

#[test]
fn killed_around_a_segment_roll() {
    let options = Options { segment_bytes: 4 * 1024 };
    let home = tempfile::tempdir().unwrap();
    let book = home.path().join("book");
    let mut last = 0;
    {
        let (mut log, _) = Log::open(&book, options).unwrap();
        // Stop right after the roll to segment 2: one record in it.
        while !book.join("rows/000002.seg").exists() {
            last += 1;
            log.append_settled(last, 1, RawRange::NONE, &text(last)).unwrap();
        }
    }
    let second = book.join("rows/000002.seg");
    let whole = fs::read(&second).unwrap();
    // The new segment exists but none, or part, of its first record made it.
    for cut in 0..whole.len() {
        let copy = home.path().join(format!("cut-{cut}"));
        copy_book(&book, &copy);
        fs::write(copy.join("rows/000002.seg"), &whole[..cut]).unwrap();
        forget_index_entry(&copy, last);
        let (mut log, recovered) = Log::open(&copy, options).unwrap();
        let torn_record = cut.saturating_sub(SEGMENT_HEADER_LEN as usize);
        assert_eq!(recovered.truncated as usize, torn_record);
        assert_eq!(&fs::read(copy.join("rows/000002.seg")).unwrap()[..8], b"ABSG\x01\0\0\0");
        assert_rows(&mut log, last - 1);
        settle(&mut log, last, last + 30);
        assert_rows(&mut log, last + 30);
        drop(log);
        let (mut log, recovered) = Log::open(&copy, options).unwrap();
        assert_eq!(recovered.truncated, 0);
        assert_rows(&mut log, last + 30);
        drop(log);
        fs::remove_dir_all(&copy).unwrap();
    }

    // A failed record in an earlier segment cuts every later record too. With no
    // checkpoint, all records are replayable; the raw replay restores both lost rows.
    let first = fs::read(segment(&book)).unwrap();
    fs::write(segment(&book), &first[..first.len() - 1]).unwrap();
    let (mut log, recovered) = Log::open(&book, options).unwrap();
    assert!(recovered.truncated > 0);
    assert!(!second.exists());
    assert_rows(&mut log, last - 2);
    settle(&mut log, last - 1, last);
    assert_rows(&mut log, last);
}

#[test]
fn an_index_entry_after_the_checkpoint_is_cleared_before_replay() {
    let home = tempfile::tempdir().unwrap();
    let book = home.path().join("book");
    {
        let (mut log, _) = open(&book);
        settle(&mut log, 1, 20);
        log.write_checkpoint(&[], &[]).unwrap();
    }
    let index_path = book.join("rows.idx");
    let segment_len = fs::metadata(book.join("rows/000001.seg")).unwrap().len() as u32;
    let mut index = OpenOptions::new().read(true).write(true).open(&index_path).unwrap();
    index.seek(SeekFrom::Start(21 * 16)).unwrap();
    let mut ghost = [0u8; 16];
    ghost[..4].copy_from_slice(&1u32.to_le_bytes());
    ghost[4..8].copy_from_slice(&segment_len.to_le_bytes());
    ghost[8..12].copy_from_slice(&3u32.to_le_bytes());
    ghost[12..].copy_from_slice(&1u32.to_le_bytes());
    index.write_all(&ghost).unwrap();
    drop(index);

    let (mut log, recovered) = open(&book);
    assert_eq!((recovered.checkpoint, recovered.replayed), (true, 0));
    let mut raw = [0u8; 16];
    let mut index = OpenOptions::new().read(true).open(&index_path).unwrap();
    index.seek(SeekFrom::Start(21 * 16)).unwrap();
    index.read_exact(&mut raw).unwrap();
    assert_eq!(raw, [0u8; 16]);
    assert_eq!(log.append_settled(21, 1, RawRange::NONE, &text(21)).unwrap(), 21);
    assert_eq!(log.last_seq(), 21);
}

#[test]
fn a_torn_patch_restores_the_previous_revision() {
    let home = tempfile::tempdir().unwrap();
    let book = home.path().join("book");
    let old = b"old revision".to_vec();
    let next = b"new revision".to_vec();
    let old_index;
    let new_index;
    {
        let (mut log, _) = open(&book);
        log.append_settled(1, 1, RawRange::NONE, &old).unwrap();
        log.write_checkpoint(&[], &[]).unwrap();
        old_index = fs::read(book.join("rows.idx")).unwrap();
        let file = log.append_raw_file(b"events/patch").unwrap();
        log.patch(1, 2, RawRange { file, off: 0, len: 1 }, &next).unwrap();
        new_index = fs::read(book.join("rows.idx")).unwrap();
    }
    let segment = book.join("rows/000001.seg");
    let whole = fs::read(&segment).unwrap();
    let patch_at = SEGMENT_HEADER_LEN as usize + old.len() + RECORD_OVERHEAD;
    for cut in patch_at..=whole.len() + 16 {
        let copy = home.path().join(format!("patch-cut-{cut}"));
        copy_book(&book, &copy);
        let record_end = cut.min(whole.len());
        fs::write(copy.join("rows/000001.seg"), &whole[..record_end]).unwrap();
        // Exercise both sides of the index write ordering. A torn record with the new index
        // already visible must be repaired from rows.undo; a kill before the index write keeps
        // the old entry and needs no undo.
        let mut partial_index = old_index.clone();
        if cut >= whole.len() {
            partial_index[16..32].copy_from_slice(&new_index[16..32]);
        }
        fs::write(copy.join("rows.idx"), &partial_index).unwrap();
        let (mut log, recovered) = open(&copy);
        assert_eq!(recovered.scanned_bytes, (record_end - patch_at) as u64, "cut {cut}");
        if cut < whole.len() {
            let row = log.row(1).expect("the old revision remains settled");
            assert_eq!(row.rev, 1, "cut {cut}");
            assert_eq!(texts(&mut log, &[row]).0[0], old, "cut {cut}");
            assert_eq!(log.patch(1, 2, RawRange::NONE, b"repaired").unwrap(), 2, "cut {cut}");
        } else {
            let row = log.row(1).unwrap();
            assert_eq!(row.rev, 2, "cut {cut}");
            assert_eq!(texts(&mut log, &[row]).0[0], next);
            assert_eq!(log.patch(1, 3, RawRange::NONE, b"third").unwrap(), 3, "cut {cut}");
        }
        drop(log);
        fs::remove_dir_all(copy).unwrap();
    }
}

#[test]
fn a_torn_patch_with_a_durable_new_index_restores_from_undo() {
    let home = tempfile::tempdir().unwrap();
    let book = home.path().join("book");
    let old = b"old revision";
    let next = b"new revision";
    {
        let (mut log, _) = open(&book);
        log.append_settled(1, 1, RawRange::NONE, old).unwrap();
        log.write_checkpoint(&[], &[]).unwrap();
        log.patch(1, 2, RawRange::NONE, next).unwrap();
    }
    let whole = fs::read(segment(&book)).unwrap();
    let new_index = fs::read(book.join("rows.idx")).unwrap();
    let patch_at = SEGMENT_HEADER_LEN as usize + old.len() + RECORD_OVERHEAD;
    let copy = home.path().join("durable-index-cut");
    copy_book(&book, &copy);
    fs::write(segment(&copy), &whole[..patch_at + 1]).unwrap();
    fs::write(copy.join("rows.idx"), new_index).unwrap();

    let (mut log, _) = open(&copy);
    let row = log.row(1).expect("undo restores the prior index");
    assert_eq!(row.rev, 1);
    assert_eq!(texts(&mut log, &[row]).0[0], old);
}

#[test]
fn a_cut_patch_without_undo_requests_rebuild() {
    let home = tempfile::tempdir().unwrap();
    let book = home.path().join("book");
    let mark_len;
    {
        let (mut log, _) = open(&book);
        settle(&mut log, 1, 1);
        log.write_checkpoint(&[], &[]).unwrap();
        mark_len = fs::metadata(segment(&book)).unwrap().len();
        log.patch(1, 2, RawRange::NONE, &text(1)).unwrap();
        log.sync().unwrap();
    }
    let path = segment(&book);
    let mut bytes = fs::read(&path).unwrap();
    bytes.truncate(mark_len as usize);
    fs::write(path, bytes).unwrap();
    fs::write(book.join("rows.undo"), []).unwrap();
    let (mut log, _) = Log::open(&book, Options::default()).unwrap();
    assert!(matches!(log.patch(1, 3, RawRange::NONE, b"replay"), Err(Error::CorruptRow { .. })));
}

#[test]
fn a_source_change_cuts_the_replay_suffix_to_the_checkpoint() {
    let home = tempfile::tempdir().unwrap();
    let book = home.path().join("book");
    let mark_len;
    {
        let (mut log, _) = open(&book);
        settle(&mut log, 1, 1);
        log.write_checkpoint(&[], &[]).unwrap();
        mark_len = fs::metadata(segment(&book)).unwrap().len();
        log.patch(1, 2, RawRange::NONE, b"new revision").unwrap();
        log.append_settled(2, 1, RawRange::NONE, &text(2)).unwrap();
        log.sync().unwrap();
        log.cut_to_checkpoint(&[]).unwrap();
        assert_eq!(log.last_seq(), 1);
        assert_eq!(log.max_row(), 1);
        assert!(log.row(2).is_none());
        let row = log.row(1).expect("the cut restores the checkpoint row");
        assert_eq!(row.rev, 1);
        assert_eq!(texts(&mut log, &[row]).0[0], text(1));
        assert_eq!(fs::metadata(segment(&book)).unwrap().len(), mark_len);
        assert_eq!(log.patch(1, 2, RawRange::NONE, b"patched after cut").unwrap(), 2);
    }
    let (log, recovered) = open(&book);
    assert_eq!(recovered.replayed, 1);
    assert_eq!(log.last_seq(), 2);
    assert_eq!(log.row(1).unwrap().rev, 2);
    assert!(log.row(2).is_none());
}

#[test]
fn a_checkpoint_open_row_can_settle_again_after_a_cut() {
    let home = tempfile::tempdir().unwrap();
    let book = home.path().join("book");
    let (mut log, _) = open(&book);
    log.write_checkpoint(&[], &[1]).unwrap();
    log.append_settled(1, 1, RawRange::NONE, &text(1)).unwrap();
    log.cut_to_checkpoint(&[1]).unwrap();
    assert!(log.row(1).is_none());
    assert_eq!(log.append_settled(1, 1, RawRange::NONE, &text(1)).unwrap(), 1);
    assert_eq!(log.row(1).unwrap().rev, 1);
}

#[test]
fn replayed_indexes_are_synced_by_the_following_checkpoint() {
    let home = tempfile::tempdir().unwrap();
    let book = home.path().join("book");
    {
        let (mut log, _) = open(&book);
        settle(&mut log, 1, 255);
        log.write_checkpoint(&[], &[]).unwrap();
        log.append_settled(256, 1, RawRange::NONE, &text(256)).unwrap();
    }
    let (mut log, recovered) = open(&book);
    assert_eq!(recovered.replayed, 1);
    let before = log.stats().syncs;
    log.write_checkpoint(&[], &[]).unwrap();
    assert_eq!(log.stats().syncs - before, 4, "segment, rows.idx, seq.idx, checkpoint");
    drop(log);
    let (mut log, recovered) = open(&book);
    assert_eq!((recovered.checkpoint, recovered.replayed), (true, 0));
    assert_rows(&mut log, 256);
}

#[test]
fn bad_segment_headers_request_a_rebuild() {
    for (offset, bytes) in [(0, b"NOPE".to_vec()), (4, 2u32.to_le_bytes().to_vec())] {
        let home = tempfile::tempdir().unwrap();
        let book = home.path().join("book");
        let (mut log, _) = open(&book);
        log.append_settled(1, 1, RawRange::NONE, &text(1)).unwrap();
        drop(log);
        let path = book.join("rows/000001.seg");
        let mut file = OpenOptions::new().read(true).write(true).open(&path).unwrap();
        file.seek(SeekFrom::Start(offset)).unwrap();
        file.write_all(&bytes).unwrap();
        drop(file);
        let damaged = fs::read(&path).unwrap();
        assert!(matches!(Log::open(&book, Options::default()), Err(Error::Rebuild(_))));
        assert_eq!(fs::read(&path).unwrap(), damaged, "unsupported formats are never truncated");
    }
}

#[test]
fn raw_map_precedes_records_and_replay_repairs_a_missing_index() {
    let home = tempfile::tempdir().unwrap();
    let book = home.path().join("book");
    let map_line = b"events/one\n";
    {
        let (mut log, _) = open(&book);
        log.write_checkpoint(&[], &[]).unwrap();
        let file = log.append_raw_file(b"events/one").unwrap();
        log.append_settled(1, 1, RawRange { file, off: 0, len: 4 }, b"row1").unwrap();
    }
    let original_map = fs::read(book.join("raw.map")).unwrap();
    assert_eq!(original_map, map_line);

    // A kill after any prefix of the map line but before the first record leaves no record that
    // can name the incomplete file number.
    for cut in 0..=original_map.len() {
        let copy = home.path().join(format!("map-cut-{cut}"));
        copy_book(&book, &copy);
        fs::write(copy.join("raw.map"), &original_map[..cut]).unwrap();
        // The record is from the later phase; remove it so this copy represents the gap.
        let segment_path = copy.join("rows/000001.seg");
        fs::write(&segment_path, &fs::read(&segment_path).unwrap()[..SEGMENT_HEADER_LEN as usize])
            .unwrap();
        fs::write(
            copy.join("rows.idx"),
            vec![0u8; fs::metadata(copy.join("rows.idx")).unwrap().len() as usize],
        )
        .unwrap();
        let (mut log, _) = open(&copy);
        assert_eq!(log.max_row(), 0, "map cut {cut}");
        let file = log.append_raw_file(b"events/next").unwrap();
        assert_eq!(file, if cut == original_map.len() { 2 } else { 1 });
        log.append_settled(1, 1, RawRange { file, off: 0, len: 1 }, b"next").unwrap();
        let row = log.row(1).unwrap();
        assert_eq!(log.raw_range(&row).unwrap().file, file);
        let map = fs::read(copy.join("raw.map")).unwrap();
        assert!(map.ends_with(b"events/next\n"));
        assert_eq!(
            map.len(),
            if file == 2 {
                original_map.len() + b"events/next\n".len()
            } else {
                b"events/next\n".len()
            }
        );
        drop(log);
        fs::remove_dir_all(copy).unwrap();
    }

    // If the record made it but its index entry did not, open replays the record after the
    // checkpoint and restores the entry before the next append.
    let mut index = OpenOptions::new().write(true).open(book.join("rows.idx")).unwrap();
    index.seek(SeekFrom::Start(16)).unwrap();
    index.write_all(&[0u8; 16]).unwrap();
    drop(index);
    let (mut log, recovered) = open(&book);
    assert_eq!(recovered.replayed, 1);
    let row = log.row(1).unwrap();
    assert_eq!(log.raw_range(&row).unwrap(), RawRange { file: 1, off: 0, len: 4 });
}

#[test]
fn a_damaged_checkpoint_requests_a_rebuild_without_reading_history() {
    for damage in ["cut", "flip", "empty", "junk"] {
        let home = tempfile::tempdir().unwrap();
        {
            let (mut log, _) = open(home.path());
            settle(&mut log, 1, 500);
            log.write_checkpoint(b"state", &[]).unwrap();
            settle(&mut log, 501, 520);
        }
        let path = home.path().join("checkpoint");
        let mut bytes = fs::read(&path).unwrap();
        match damage {
            "cut" => bytes.truncate(bytes.len() - 3),
            "flip" => bytes[20] ^= 1,
            "empty" => bytes.clear(),
            _ => bytes = vec![b'?'; 70_000],
        }
        fs::write(&path, &bytes).unwrap();
        // A temporary file a killed checkpoint write left behind is not the checkpoint.
        fs::write(home.path().join(".checkpoint.1.0.tmp"), b"half a checkp").unwrap();
        assert!(matches!(Log::open(home.path(), Options::default()), Err(Error::Rebuild(_))));
        assert_eq!(fs::read(&path).unwrap(), bytes, "damage is preserved: {damage}");
    }
}

/// The writer the kill test runs in a child process: appends rows for ever, reporting each one
/// only after its append returned.
#[cfg(unix)]
#[test]
fn kill9_writer_entry() {
    let Ok(dir) = std::env::var("ACPMUX_BOOK_KILL9_DIR") else {
        return;
    };
    let (mut log, _) = open(Path::new(&dir));
    let mut id = log.max_row() + 1;
    loop {
        log.append_settled(id, 1, RawRange::NONE, &text(id)).unwrap();
        println!("settled {id}");
        if id.is_multiple_of(64) {
            log.write_checkpoint(&id.to_le_bytes(), &[]).unwrap();
        }
        id += 1;
    }
}

/// SIGKILL to a live writer, 40 times over one book, at moments spread over the append, the
/// index write and the checkpoint: every row it reported is there after each reopen, in order,
/// byte for byte, and the next writer carries on from it. Where each kill lands is the
/// scheduler's; the torn tails it happened to leave are printed, and the every-byte tests above
/// are the ones that place a kill exactly.
#[cfg(unix)]
#[test]
fn a_writer_killed_40_times_loses_no_row_it_reported() {
    use std::io::{BufRead, BufReader};
    use std::process::{Command, Stdio};
    let home = tempfile::tempdir().unwrap();
    let book = home.path().join("book");
    let mut reported = 0u64;
    let mut truncations = 0;
    for round in 0..40u64 {
        let mut child = Command::new(std::env::current_exe().unwrap())
            .args(["kill9_writer_entry", "--nocapture", "--test-threads=1"])
            .env("ACPMUX_BOOK_KILL9_DIR", &book)
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let target = reported + 30 + (round * 37) % 300;
        // The pipe stays open until the child is dead, so the kill lands on a writer at work,
        // not on one that stopped at a closed pipe.
        let mut output = BufReader::new(child.stdout.take().unwrap());
        let mut line = String::new();
        while reported < target && output.read_line(&mut line).unwrap() != 0 {
            if let Some(id) = line.trim_end().strip_prefix("settled ") {
                reported = id.parse().unwrap();
            }
            line.clear();
        }
        child.kill().unwrap();
        child.wait().unwrap();
        drop(output);
        assert!(reported >= target, "the writer ended by itself at row {reported}");

        let (mut log, recovered) = open(&book);
        truncations += u64::from(recovered.truncated != 0);
        assert!(log.max_row() >= reported, "round {round}: row {reported} was reported settled");
        assert_eq!(log.last_seq(), log.max_row());
        let last = log.max_row();
        assert_rows(&mut log, last);
        reported = last;
    }
    assert!(reported > 40 * 30);
    println!("kill9: 40 kills, {reported} rows, {truncations} torn tails cut");
}

#[test]
fn a_power_loss_clears_a_checkpoint_open_row_without_reading_older_records() {
    let home = tempfile::tempdir().unwrap();
    let book = home.path();
    let (mut log, _) = open(book);
    settle(&mut log, 2, 300);
    let file = log.append_raw_file(b"raw").unwrap();
    log.write_checkpoint(b"opaque actor state", &[1]).unwrap();
    let mark = fs::metadata(segment(book)).unwrap().len();
    log.append_settled(1, 1, RawRange { file, off: 0, len: 3 }, b"old tool").unwrap();
    drop(log);
    let whole = fs::read(segment(book)).unwrap();
    let indexes = fs::read(book.join("rows.idx")).unwrap();
    for cut in mark..whole.len() as u64 {
        fs::write(segment(book), &whole[..cut as usize]).unwrap();
        // Unlike a patch, this raw-backed new settlement may leave a durable index behind.
        fs::write(book.join("rows.idx"), &indexes).unwrap();
        let (mut log, recovered) = open(book);
        assert_eq!(recovered.scanned_bytes, cut - mark);
        assert!(log.row(1).is_none());
        let row = log.row(300).unwrap();
        assert_eq!(texts(&mut log, &[row]).0[0], text(300));
        assert_eq!(
            log.append_settled(1, 1, RawRange { file, off: 0, len: 3 }, b"old tool").unwrap(),
            300
        );
        assert!(matches!(
            log.append_settled(1, 1, RawRange { file, off: 0, len: 3 }, b"old tool"),
            Err(Error::AlreadySettled { row_id: 1 })
        ));
    }
}

#[test]
fn a_raw_backed_record_and_its_index_can_be_cut_at_every_byte() {
    let home = tempfile::tempdir().unwrap();
    let book = home.path().join("book");
    let (mut log, _) = open(&book);
    log.write_checkpoint(&[], &[]).unwrap();
    let file = log.append_raw_file(b"events/one").unwrap();
    let mark = fs::metadata(segment(&book)).unwrap().len() as usize;
    log.append_settled(1, 1, RawRange { file, off: 0, len: 4 }, b"row1").unwrap();
    drop(log);
    let whole = fs::read(segment(&book)).unwrap();
    let index = fs::read(book.join("rows.idx")).unwrap();
    for cut in mark..=whole.len() + 16 {
        let copy = home.path().join(format!("raw-record-cut-{cut}"));
        copy_book(&book, &copy);
        let record_end = cut.min(whole.len());
        fs::write(segment(&copy), &whole[..record_end]).unwrap();
        let mut partial = vec![0; index.len()];
        let index_bytes = cut.saturating_sub(whole.len());
        partial[16..16 + index_bytes].copy_from_slice(&index[16..16 + index_bytes]);
        fs::write(copy.join("rows.idx"), &partial).unwrap();
        let (mut log, recovered) = open(&copy);
        assert_eq!(recovered.scanned_bytes as usize, record_end - mark);
        if record_end == whole.len() {
            let row = log.row(1).unwrap();
            assert_eq!(log.raw_range(&row).unwrap().file, 1);
            assert_eq!(texts(&mut log, &[row]).0[0], b"row1");
        } else {
            assert!(log.row(1).is_none());
        }
    }
}

#[test]
fn power_loss_clears_a_sparse_seq_entry_beyond_the_checkpoint() {
    let home = tempfile::tempdir().unwrap();
    let book = home.path();
    let (mut log, _) = open(book);
    settle(&mut log, 1, 255);
    let file = log.append_raw_file(b"raw").unwrap();
    log.write_checkpoint(&[], &[]).unwrap();
    let mark = fs::metadata(segment(book)).unwrap().len();
    log.append_settled(256, 1, RawRange { file, off: 0, len: 3 }, b"new").unwrap();
    drop(log);
    OpenOptions::new().write(true).open(segment(book)).unwrap().set_len(mark).unwrap();
    let (mut log, recovered) = open(book);
    assert_eq!(recovered.scanned_bytes, 0);
    assert!(log.row(256).is_none());
    let index = fs::read(book.join("seq.idx")).unwrap();
    assert_eq!(&index[8..16], &[0; 8]);
    assert_eq!(log.append_settled(256, 1, RawRange { file, off: 0, len: 3 }, b"new").unwrap(), 256);
    assert_eq!(ids(&log.since(255, 1000).unwrap().rows), vec![256]);
}

#[test]
fn cut_rejects_each_missing_or_untrusted_undo_before_removing_records() {
    for damage in ["missing", "short-head", "head-crc", "stale-head", "short-entry", "entry-crc"] {
        let home = tempfile::tempdir().unwrap();
        let (mut log, _) = open(home.path());
        settle(&mut log, 1, 1);
        log.write_checkpoint(&[], &[]).unwrap();
        log.patch(1, 2, RawRange::NONE, b"patched").unwrap();
        let path = home.path().join("rows.undo");
        let mut bytes = fs::read(&path).unwrap();
        match damage {
            "missing" => bytes.clear(),
            "short-head" => bytes.truncate(8),
            "head-crc" => bytes[0] ^= 1,
            "stale-head" => {
                bytes[..4].copy_from_slice(&77u32.to_le_bytes());
                let crc = crc32fast::hash(&bytes[..12]);
                bytes[12..16].copy_from_slice(&crc.to_le_bytes());
            }
            "short-entry" => bytes.truncate(28),
            "entry-crc" => bytes[20] ^= 1,
            _ => unreachable!(),
        }
        fs::write(path, bytes).unwrap();
        let before = fs::metadata(segment(home.path())).unwrap().len();
        assert!(matches!(log.cut_to_checkpoint(&[]), Err(Error::Rebuild(_))), "{damage}");
        assert_eq!(fs::metadata(segment(home.path())).unwrap().len(), before);
        assert!(matches!(log.since(0, 100), Err(Error::Stopped)));
        assert!(matches!(log.append_settled(2, 1, RawRange::NONE, b"next"), Err(Error::Stopped)));
    }
}

#[test]
fn failed_cut_index_mutations_stop_reads_and_writes() {
    for fail_after in 0..4 {
        let home = tempfile::tempdir().unwrap();
        let (mut log, _) = open(home.path());
        settle(&mut log, 1, 1);
        log.write_checkpoint(&[], &[2]).unwrap();
        log.patch(1, 2, RawRange::NONE, b"patched").unwrap();
        settle(&mut log, 2, 3);
        log.fail_cut_after(fail_after);
        assert!(log.cut_to_checkpoint(&[2]).is_err());
        assert!(matches!(log.since(0, 100), Err(Error::Stopped)));
        assert!(matches!(log.write_checkpoint(&[], &[]), Err(Error::Stopped)));
        assert!(log.row(1).is_none());
    }
}

#[test]
fn cut_can_return_from_a_shorter_later_segment() {
    let home = tempfile::tempdir().unwrap();
    let options = Options { segment_bytes: 512 };
    let (mut log, _) = Log::open(home.path(), options).unwrap();
    log.append_settled(1, 1, RawRange::NONE, &[b'x'; 400]).unwrap();
    log.write_checkpoint(&[], &[]).unwrap();
    log.append_settled(2, 1, RawRange::NONE, &[b'y'; 40]).unwrap();
    assert!(home.path().join("rows/000002.seg").exists());
    log.cut_to_checkpoint(&[]).unwrap();
    assert_eq!(log.last_seq(), 1);
    assert!(!home.path().join("rows/000002.seg").exists());
}

#[test]
fn resume_missing_segment_is_damage_not_retryable_io() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, _) = Log::open(home.path(), Options { segment_bytes: 100 }).unwrap();
    log.append_settled(1, 1, RawRange::NONE, &[b'x'; 50]).unwrap();
    log.append_settled(2, 1, RawRange::NONE, &[b'y'; 50]).unwrap();
    fs::remove_file(segment(home.path())).unwrap();
    assert!(log.since(0, 1024).unwrap().stopped_on_refusal);
}

#[test]
fn zero_edition_is_only_opened_and_written_in_staging_mode() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, _) = Log::open_staging(home.path(), Options::default(), |_, _| Ok(true)).unwrap();
    log.write_checkpoint_in_edition(&[], &[], 0).unwrap();
    drop(log);
    assert!(matches!(Log::open(home.path(), Options::default()), Err(Error::Rebuild(_))));
    let (mut log, recovered) =
        Log::open_staging(home.path(), Options::default(), |_, _| Ok(true)).unwrap();
    assert_eq!(recovered.edition, 0);
    log.write_checkpoint_in_edition(&[], &[], 3).unwrap();
    drop(log);
    let (mut log, recovered) = Log::open(home.path(), Options::default()).unwrap();
    assert_eq!(recovered.edition, 3);
    assert!(log.write_checkpoint_in_edition(&[], &[], 0).is_err());
}

#[test]
fn lost_undo_head_or_entry_never_exposes_a_cut_patch_in_either_segment() {
    for later_segment in [false, true] {
        for corrupt_head in [false, true] {
            let home = tempfile::tempdir().unwrap();
            // One header plus one 50-byte record fits; the patch rolls to segment two.
            let options = Options { segment_bytes: if later_segment { 102 } else { 10_000 } };
            let (mut log, _) = Log::open(home.path(), options).unwrap();
            log.append_settled(1, 1, RawRange::NONE, &[b'a'; 50]).unwrap();
            log.write_checkpoint(&[], &[]).unwrap();
            let mark = fs::metadata(segment(home.path())).unwrap().len();
            log.patch(1, 2, RawRange::NONE, &[b'b'; 50]).unwrap();
            assert_eq!(log.row(1).unwrap().seg, if later_segment { 2 } else { 1 });
            drop(log);
            let undo = home.path().join("rows.undo");
            let mut bytes = fs::read(&undo).unwrap();
            bytes[if corrupt_head { 0 } else { 20 }] ^= 1;
            fs::write(undo, bytes).unwrap();
            if later_segment {
                fs::remove_file(home.path().join("rows/000002.seg")).unwrap();
            } else {
                OpenOptions::new()
                    .write(true)
                    .open(segment(home.path()))
                    .unwrap()
                    .set_len(mark)
                    .unwrap();
            }
            let (mut log, _) = Log::open(home.path(), options).unwrap();
            let row = log.row(1).unwrap();
            assert!(matches!(
                log.fill(&[row], &mut Vec::new(), &mut Vec::new()),
                Err(Error::CorruptRow { .. })
            ));
            assert!(matches!(
                log.patch(1, 2, RawRange::NONE, b"replay"),
                Err(Error::CorruptRow { .. })
            ));
        }
    }
}

#[test]
fn every_torn_undo_append_keeps_a_whole_replayed_patch() {
    for cut in 0..44 {
        let home = tempfile::tempdir().unwrap();
        let (mut log, _) = open(home.path());
        settle(&mut log, 1, 1);
        log.write_checkpoint(&[], &[]).unwrap();
        log.patch(1, 2, RawRange::NONE, b"new revision").unwrap();
        drop(log);
        OpenOptions::new()
            .write(true)
            .open(home.path().join("rows.undo"))
            .unwrap()
            .set_len(cut)
            .unwrap();
        let (mut log, _) = open(home.path());
        let row = log.row(1).unwrap();
        assert_eq!(row.rev, 2, "undo cut at byte {cut}");
        assert_eq!(texts(&mut log, &[row]).0[0], b"new revision");
    }
}

#[test]
fn stale_undo_interval_cannot_restore_a_revision_older_than_the_checkpoint() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, _) = open(home.path());
    settle(&mut log, 1, 1);
    log.write_checkpoint(&[], &[]).unwrap();
    log.patch(1, 2, RawRange::NONE, b"checkpoint revision").unwrap();
    let stale = fs::read(home.path().join("rows.undo")).unwrap();
    log.write_checkpoint(&[], &[]).unwrap();
    let mark = fs::metadata(segment(home.path())).unwrap().len();
    log.patch(1, 3, RawRange::NONE, b"cut revision").unwrap();
    drop(log);
    fs::write(home.path().join("rows.undo"), stale).unwrap();
    OpenOptions::new().write(true).open(segment(home.path())).unwrap().set_len(mark).unwrap();
    let (mut log, _) = open(home.path());
    let row = log.row(1).unwrap();
    assert_ne!(row.rev, 1);
    assert!(matches!(
        log.fill(&[row], &mut Vec::new(), &mut Vec::new()),
        Err(Error::CorruptRow { .. })
    ));
}
