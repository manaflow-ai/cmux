//! Reading a segment's records in order, for recovery: every record is checked by its crc, and
//! the scan stops at the first place that is not a whole record.

use super::Error;
use super::record::{self, Check, Header};
use crate::fsio;
use std::fs::File;

/// The scan reads this much at a time. Over four of the largest records, so a refill at a
/// record's start always holds the whole record when the file does.
const CHUNK: usize = 128 * 1024;

/// How a scan ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Scan {
    /// The offset just past the last whole record.
    pub end: u64,
    /// Whether bytes that are not a whole record follow `end` (a torn write).
    pub torn: bool,
    pub bytes_read: u64,
}

/// Reads the records of `file` from `from`, handing each whole one to `apply` with its offset.
/// `apply` returns false for a record that cannot follow the one before (its seq is not the
/// next one); the scan treats it as torn, like a bad crc.
pub(crate) fn scan(
    file: &File,
    from: u64,
    mut apply: impl FnMut(u64, &Header) -> Result<bool, Error>,
) -> Result<Scan, Error> {
    let mut chunk = vec![0u8; CHUNK];
    let mut offset = from;
    let mut bytes_read = 0u64;
    loop {
        let read = fsio::read_at(file, &mut chunk, offset)?;
        bytes_read = bytes_read.saturating_add(read as u64);
        if read == 0 {
            return Ok(Scan { end: offset, torn: false, bytes_read });
        }
        let at_file_end = read < chunk.len();
        let mut at = 0usize;
        loop {
            let rest = chunk.get(at..read).unwrap_or_default();
            if rest.is_empty() {
                break;
            }
            match record::check(rest) {
                Check::Whole(header) => {
                    let record_at = offset.saturating_add(at as u64);
                    if !apply(record_at, &header)? {
                        return Ok(Scan { end: record_at, torn: true, bytes_read });
                    }
                    at = at.saturating_add(header.record_len());
                }
                // The record runs past what was read. With more of the file to come, read
                // again from the record's start; at the file's end it is a torn write.
                Check::Short if !at_file_end && at > 0 => break,
                Check::Bad => return Err(Error::Corrupt("a complete record failed its check")),
                Check::Short => {
                    return Ok(Scan {
                        end: offset.saturating_add(at as u64),
                        torn: true,
                        bytes_read,
                    });
                }
            }
        }
        offset = offset.saturating_add(at as u64);
    }
}
