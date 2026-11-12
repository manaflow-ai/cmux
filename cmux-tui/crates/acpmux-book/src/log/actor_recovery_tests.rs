//! Recovery cuts the first failed record after the mark, including every later segment.
#![deny(clippy::indexing_slicing, clippy::string_slice, clippy::expect_used)]

use super::{HEADER_LEN, Log, Options, RawRange, SEGMENT_HEADER_LEN};
use std::fs::OpenOptions;
use std::io::{Read, Seek, SeekFrom, Write};

type Result = std::result::Result<(), Box<dyn std::error::Error>>;

#[test]
fn failed_record_in_an_earlier_segment_cuts_the_entire_suffix() -> Result {
    for failure in ["crc", "short", "raw"] {
        let home = tempfile::tempdir()?;
        let dir = home.path();
        // One record per segment: the failed record is followed by two whole segments.
        let options = Options { segment_bytes: SEGMENT_HEADER_LEN + 45 };
        let (mut log, _) = Log::open(dir, options)?;
        let file = log.append_raw_file(b"gapped-source")?;
        log.append_settled(1, 1, RawRange { file, off: 10, len: 1 }, b"a")?;
        log.write_checkpoint(b"cursor=11", &[])?;
        for id in 2..=4 {
            log.append_settled(id, 1, RawRange { file, off: id * 100, len: 1 }, b"b")?;
        }
        log.sync()?;
        drop(log);
        let path = dir.join("rows/000002.seg");
        if failure == "short" {
            OpenOptions::new().write(true).open(&path)?.set_len(SEGMENT_HEADER_LEN + 3)?;
        } else if failure == "crc" {
            let mut segment = OpenOptions::new().read(true).write(true).open(&path)?;
            let at = SEGMENT_HEADER_LEN + HEADER_LEN as u64;
            segment.seek(SeekFrom::Start(at))?;
            let mut byte = [0];
            segment.read_exact(&mut byte)?;
            for value in &mut byte {
                *value ^= 1;
            }
            segment.seek(SeekFrom::Start(at))?;
            segment.write_all(&byte)?;
        }
        let end = if failure == "raw" { 200 } else { 401 };
        let (mut log, recovered) = Log::open_with_raw_end(dir, options, |_| Some(end))?;
        assert!(recovered.checkpoint);
        assert!(recovered.truncated > 0);
        assert_eq!(log.last_seq(), 1, "{failure}");
        assert_eq!(std::fs::metadata(&path)?.len(), SEGMENT_HEADER_LEN);
        assert!(!dir.join("rows/000003.seg").exists());
        assert!(!dir.join("rows/000004.seg").exists());
        for id in 2..=4 {
            assert!(log.row(id).is_none(), "stale index for {id}: {failure}");
            assert_eq!(
                log.append_settled(id, 1, RawRange { file, off: 10 + id, len: 1 }, b"c")?,
                id
            );
        }
        log.write_checkpoint(b"cursor=15", &[])?;
        drop(log);
        let (log, recovered) = Log::open_with_raw_end(dir, options, |_| Some(15))?;
        assert!(recovered.checkpoint);
        assert_eq!(recovered.replayed, 0);
        assert_eq!(log.last_seq(), 4);
    }
    Ok(())
}

#[test]
fn unknown_long_raw_end_is_not_checked_as_a_known_end() -> Result {
    let home = tempfile::tempdir()?;
    let (mut log, _) = Log::open(home.path(), Options::default())?;
    let file = log.append_raw_file(b"gapped-source")?;
    log.write_checkpoint(b"cursor=0", &[])?;
    log.append_settled(1, 1, RawRange { file, off: 100, len: u32::MAX }, b"long")?;
    log.sync()?;
    drop(log);
    let (log, recovered) = Log::open_with_raw_end(home.path(), Options::default(), |_| Some(101))?;
    assert_eq!(log.last_seq(), 1);
    assert_eq!(recovered.replayed, 1);
    assert_eq!(recovered.truncated, 0);
    Ok(())
}
