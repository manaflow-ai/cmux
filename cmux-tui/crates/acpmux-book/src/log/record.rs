//! One segment record: `len u32 | seq u64 | rowId u64 | rev u32 | raw_file u32 |
//! raw_off u64 | raw_len u32 | row text | crc32`, little endian. `len` is the row
//! text's length; the crc covers everything before it.

use super::RawRange;
use crate::row::MAX_ROW_TEXT;

/// The bytes before a record's row text.
pub const HEADER_LEN: usize = 40;
pub(crate) const HEADER_LEN_U32: u32 = 40;
pub(crate) const HEADER_LEN_U64: u64 = 40;
/// The bytes of a record that are not row text: the header and the crc.
pub const RECORD_OVERHEAD: usize = 44;

/// A little-endian u32 at `at`, when `buf` holds it.
pub(crate) fn le_u32(buf: &[u8], at: usize) -> Option<u32> {
    let end = at.checked_add(4)?;
    Some(u32::from_le_bytes(buf.get(at..end)?.try_into().ok()?))
}

/// A little-endian u64 at `at`, when `buf` holds it.
pub(crate) fn le_u64(buf: &[u8], at: usize) -> Option<u64> {
    let end = at.checked_add(8)?;
    Some(u64::from_le_bytes(buf.get(at..end)?.try_into().ok()?))
}

/// A record's header.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Header {
    pub len: u32,
    pub seq: u64,
    pub row_id: u64,
    pub rev: u32,
    pub raw_file: u32,
    pub raw_off: u64,
    pub raw_len: u32,
}

impl Header {
    /// The header at the start of `buf`; `None` when `buf` is shorter than a header or the
    /// length is not a row text's (0, or over 16 KB).
    pub(crate) fn parse(buf: &[u8]) -> Option<Header> {
        let len = le_u32(buf, 0)?;
        let seq = le_u64(buf, 4)?;
        let row_id = le_u64(buf, 12)?;
        let rev = le_u32(buf, 20)?;
        let raw_file = le_u32(buf, 24)?;
        let raw_off = le_u64(buf, 28)?;
        let raw_len = le_u32(buf, 36)?;
        if len == 0 || len as usize > MAX_ROW_TEXT || row_id == 0 {
            return None;
        }
        Some(Header { len, seq, row_id, rev, raw_file, raw_off, raw_len })
    }

    /// The whole record's length.
    pub(crate) fn record_len(&self) -> usize {
        (self.len as usize).saturating_add(RECORD_OVERHEAD)
    }
}

/// Writes one record into `out` (cleared first). `text` is 1..=16384 bytes (the caller checked).
pub(crate) fn encode(
    out: &mut Vec<u8>,
    seq: u64,
    row_id: u64,
    rev: u32,
    raw: RawRange,
    text: &[u8],
) {
    out.clear();
    out.reserve(text.len().saturating_add(RECORD_OVERHEAD));
    out.extend_from_slice(&u32::try_from(text.len()).unwrap_or(u32::MAX).to_le_bytes());
    out.extend_from_slice(&seq.to_le_bytes());
    out.extend_from_slice(&row_id.to_le_bytes());
    out.extend_from_slice(&rev.to_le_bytes());
    out.extend_from_slice(&raw.file.to_le_bytes());
    out.extend_from_slice(&raw.off.to_le_bytes());
    out.extend_from_slice(&raw.len.to_le_bytes());
    out.extend_from_slice(text);
    let crc = crc32fast::hash(out);
    out.extend_from_slice(&crc.to_le_bytes());
}

/// What the bytes at a record's place are.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Check {
    /// A whole record whose crc matches.
    Whole(Header),
    /// Too few bytes to tell: the header or the record runs past the end of `buf`.
    Short,
    /// Not a record: an impossible length or a crc that does not match.
    Bad,
}

/// Checks the record at the start of `buf`.
pub(crate) fn check(buf: &[u8]) -> Check {
    if buf.len() < HEADER_LEN {
        return Check::Short;
    }
    let Some(header) = Header::parse(buf) else {
        return Check::Bad;
    };
    let text_end = HEADER_LEN.saturating_add(header.len as usize);
    let (Some(covered), Some(stored)) = (buf.get(..text_end), le_u32(buf, text_end)) else {
        return Check::Short;
    };
    if crc32fast::hash(covered) == stored { Check::Whole(header) } else { Check::Bad }
}
