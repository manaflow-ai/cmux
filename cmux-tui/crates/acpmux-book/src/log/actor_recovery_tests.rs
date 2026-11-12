//! Actor recovery must distinguish damage from a killed writer's incomplete tail.
#![deny(clippy::indexing_slicing, clippy::string_slice, clippy::expect_used)]

use super::{Error, HEADER_LEN, Log, Options, RawRange, SEGMENT_HEADER_LEN};
use std::fs::OpenOptions;
use std::io::{Read, Seek, SeekFrom, Write};

#[test]
fn complete_record_with_bad_crc_is_damage_not_a_torn_tail() -> Result<(), Box<dyn std::error::Error>>
{
    let home = tempfile::tempdir()?;
    let dir = home.path();
    let (mut log, _) = Log::open(dir, Options::default())?;
    let file = log.append_raw_file(b"source")?;
    log.write_checkpoint(b"checkpoint", &[])?;
    log.append_settled(1, 1, RawRange { file, off: 0, len: 10 }, b"{\"id\":1}")?;
    log.sync()?;
    drop(log);
    let path = dir.join("rows/000001.seg");
    let mut segment = OpenOptions::new().read(true).write(true).open(&path)?;
    let original_len = segment.metadata()?.len();
    let at = SEGMENT_HEADER_LEN + HEADER_LEN as u64;
    segment.seek(SeekFrom::Start(at))?;
    let mut byte = [0];
    segment.read_exact(&mut byte)?;
    if let Some(value) = byte.first_mut() {
        *value ^= 1;
    }
    segment.seek(SeekFrom::Start(at))?;
    segment.write_all(&byte)?;
    drop(segment);
    assert!(matches!(Log::open(dir, Options::default()), Err(Error::Corrupt(_))));
    assert_eq!(
        std::fs::metadata(path)?.len(),
        original_len,
        "damage must be preserved for rebuild"
    );
    Ok(())
}
