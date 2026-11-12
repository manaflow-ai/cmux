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
                log.write_checkpoint(b"actor state").unwrap();
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
        // The index write comes after the record's. Half the time the entry is not there (the
        // kill came first); half the time it is, pointing past the end (a stale page).
        if cut.is_multiple_of(2) && cut < whole.len() {
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
        log.write_checkpoint(&[]).unwrap();
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
        let (mut log, recovered) = open(&book);
        assert_eq!(recovered.truncated as usize, cut - settled, "cut {cut}");
        assert_eq!((log.last_seq(), log.max_row()), (3, 3), "cut {cut}");
        assert!(log.row(4).is_none(), "a row whose record was cut off has not settled");
        assert_eq!(log.append_settled(4, 1, RawRange::NONE, &large).unwrap(), 4, "cut {cut}");
        if cut.is_multiple_of(5) {
            let window = log.window(Anchor::End, 400, 1 << 20);
            assert_eq!(ids(&window.rows), vec![1, 2, 3, 4]);
            assert!(texts(&mut log, &window.rows).0[3] == large);
        }
    }
    assert!(fs::read(segment(&book)).unwrap() == whole, "the repaired segment is the whole one");
}

#[test]
fn bytes_after_the_last_record_that_are_not_a_record_are_cut_off() {
    for junk in [vec![0u8; 1], vec![0u8; 4096], vec![0xffu8; 300], b"not a record at all".to_vec()]
    {
        let home = tempfile::tempdir().unwrap();
        {
            let (mut log, _) = open(home.path());
            settle(&mut log, 1, 300);
            log.write_checkpoint(&[]).unwrap();
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
    for cut in SEGMENT_HEADER_LEN as usize..whole.len() {
        let copy = home.path().join(format!("cut-{cut}"));
        copy_book(&book, &copy);
        fs::write(copy.join("rows/000002.seg"), &whole[..cut]).unwrap();
        let (mut log, recovered) = Log::open(&copy, options).unwrap();
        assert_eq!(recovered.truncated as usize, cut - SEGMENT_HEADER_LEN as usize);
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

    // A torn record in a segment that is not the last cannot come from a kill (a segment is
    // synced before the next is made). It is reported; the owner rebuilds the book from raw.
    let first = fs::read(segment(&book)).unwrap();
    fs::write(segment(&book), &first[..first.len() - 1]).unwrap();
    assert!(matches!(Log::open(&book, options), Err(Error::Corrupt(_))));
}

#[test]
fn an_index_entry_after_the_checkpoint_is_cleared_before_replay() {
    let home = tempfile::tempdir().unwrap();
    let book = home.path().join("book");
    {
        let (mut log, _) = open(&book);
        settle(&mut log, 1, 20);
        log.write_checkpoint(&[]).unwrap();
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
        assert!(matches!(Log::open(&book, Options::default()), Err(Error::Rebuild(_))));
    }
}

#[test]
fn raw_map_precedes_records_and_replay_repairs_a_missing_index() {
    let home = tempfile::tempdir().unwrap();
    let book = home.path().join("book");
    let map_line = b"events/one\n";
    {
        let (mut log, _) = open(&book);
        let file = log.append_raw_file(b"events/one").unwrap();
        log.write_checkpoint(&[]).unwrap();
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
        let (log, _) = open(&copy);
        assert_eq!(log.max_row(), 0, "map cut {cut}");
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
fn a_damaged_checkpoint_costs_a_rebuild_not_the_book() {
    for damage in ["cut", "flip", "empty", "junk"] {
        let home = tempfile::tempdir().unwrap();
        {
            let (mut log, _) = open(home.path());
            settle(&mut log, 1, 500);
            log.write_checkpoint(b"state").unwrap();
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
        let (mut log, recovered) = open(home.path());
        assert_eq!((recovered.checkpoint, recovered.replayed), (false, 520), "{damage}");
        assert!(recovered.state.is_empty());
        assert_rows(&mut log, 520);
        assert_eq!(ids(&log.since(511, 1 << 20).unwrap().rows), (512..=520).collect::<Vec<_>>());
        log.write_checkpoint(b"again").unwrap();
        drop(log);
        let (_, recovered) = open(home.path());
        assert_eq!((recovered.checkpoint, recovered.replayed), (true, 0));
        assert_eq!(recovered.state, b"again");
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
            log.write_checkpoint(&id.to_le_bytes()).unwrap();
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
