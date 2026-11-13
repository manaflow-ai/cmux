//! Immutable sorted records, a fixed head, and sparse seek checkpoints.
//!
//! Snapshot records have a trailing frame length, so a backward page needs no
//! dense row-offset table. Sparse entries have a fixed width and are searched
//! on disk; neither opening nor writing a snapshot materializes its directory.
use super::{RowKey, SortKey, Summary, codec};
use serde::{Deserialize, Serialize};
use std::fs::File;
use std::io::{self, Read};
use std::path::Path;
use std::sync::Arc;

mod read;
#[cfg(test)]
mod scale_tests;
mod seek;
mod write;
pub use write::SortedSnapshot;

pub(super) const HEADER_BYTES: usize = 4096;
const MAGIC: &[u8; 8] = b"ACIDX003";
const CHECKPOINT_BYTES: usize = 552;
const TRAILER_BYTES: usize = 4;
const FIRST_ROWS: usize = 400;
pub const SEEK_BYTES: usize = 64 * 1024;
pub const PAGE_BYTES: usize = 256 * 1024;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Head {
    pub seq: u64,
    pub log_offset: u64,
    pub log_name: Option<String>,
    #[serde(default)]
    pub covered_generation: u64,
    data_end: u64,
    directory_bytes: usize,
    count: u64,
    // A constant-size first-window accelerator, never a dense directory.
    first_lengths: Vec<u16>,
}

#[derive(Debug)]
struct Checkpoint {
    key: SortKey,
    offset: u64,
    ordinal: u64,
    first_len: usize,
}

impl Checkpoint {
    fn encode(&self) -> io::Result<Vec<u8>> {
        self.key.row.validate()?;
        let mut bytes = Vec::with_capacity(CHECKPOINT_BYTES);
        bytes.extend_from_slice(&self.key.last_activity.to_le_bytes());
        bytes.extend_from_slice(&self.offset.to_le_bytes());
        bytes.extend_from_slice(&self.ordinal.to_le_bytes());
        bytes.extend_from_slice(&(self.first_len as u32).to_le_bytes());
        bytes.extend_from_slice(&(self.key.row.origin.len() as u16).to_le_bytes());
        bytes.extend_from_slice(&(self.key.row.chat_id.len() as u16).to_le_bytes());
        bytes.extend_from_slice(self.key.row.origin.as_bytes());
        bytes.extend_from_slice(self.key.row.chat_id.as_bytes());
        bytes.resize(CHECKPOINT_BYTES - 4, 0);
        bytes.extend_from_slice(&crc32fast::hash(&bytes).to_le_bytes());
        Ok(bytes)
    }

    fn decode(bytes: &[u8]) -> io::Result<Self> {
        let body =
            bytes.get(..CHECKPOINT_BYTES - 4).ok_or_else(|| codec::invalid("checkpoint body"))?;
        let crc = read_u32(
            bytes.get(CHECKPOINT_BYTES - 4..).ok_or_else(|| codec::invalid("checkpoint crc"))?,
        )?;
        if crc32fast::hash(body) != crc {
            return Err(codec::invalid("snapshot checkpoint checksum"));
        }
        let mut input = body;
        let last_activity = take_u64(&mut input)?;
        let offset = take_u64(&mut input)?;
        let ordinal = take_u64(&mut input)?;
        let mut length = [0; 4];
        input.read_exact(&mut length)?;
        let first_len = u32::from_le_bytes(length) as usize;
        let origin_len = take_u16(&mut input)? as usize;
        let chat_len = take_u16(&mut input)? as usize;
        if origin_len > 256 || chat_len > 256 {
            return Err(codec::invalid("snapshot checkpoint key"));
        }
        let origin = take_text(&mut input, origin_len)?;
        let chat_id = take_text(&mut input, chat_len)?;
        Ok(Self {
            key: SortKey { last_activity, row: RowKey::new(origin, chat_id) },
            offset,
            ordinal,
            first_len,
        })
    }
}

fn take_u64(input: &mut &[u8]) -> io::Result<u64> {
    let mut value = [0; 8];
    input.read_exact(&mut value)?;
    Ok(u64::from_le_bytes(value))
}

fn take_u16(input: &mut &[u8]) -> io::Result<u16> {
    let mut value = [0; 2];
    input.read_exact(&mut value)?;
    Ok(u16::from_le_bytes(value))
}

fn take_text(input: &mut &[u8], len: usize) -> io::Result<String> {
    let bytes = input.get(..len).ok_or_else(|| codec::invalid("checkpoint key"))?;
    let text =
        std::str::from_utf8(bytes).map_err(|_| codec::invalid("checkpoint key utf8"))?.to_owned();
    *input = input.get(len..).ok_or_else(|| codec::invalid("checkpoint key"))?;
    Ok(text)
}

fn read_u32(bytes: &[u8]) -> io::Result<u32> {
    Ok(u32::from_le_bytes(bytes.try_into().map_err(|_| codec::invalid("snapshot integer"))?))
}

#[derive(Debug)]
pub struct DiskSnapshot {
    file: File,
    pub(super) head: Head,
}

/// One bounded physical piece, including its progress when filtering yields no rows.
pub struct SnapshotPiece {
    pub rows: Vec<Arc<Summary>>,
    pub first_ordinal: u64,
    pub next_offset: u64,
    pub has_before: bool,
    pub has_after: bool,
    /// All physical bytes read by this request, including sparse entries and seek.
    pub bytes_read: usize,
}

struct Position {
    offset: u64,
    ordinal: u64,
    record_len: Option<usize>,
    bytes_read: usize,
}

struct BufferedRow {
    summary: Arc<Summary>,
    end: u64,
}
pub struct SnapshotRows {
    snapshot: Arc<DiskSnapshot>,
    offset: u64,
    ordinal: u64,
    rows: std::vec::IntoIter<Arc<Summary>>,
    failed: bool,
}

impl Iterator for SnapshotRows {
    type Item = io::Result<Arc<Summary>>;
    fn next(&mut self) -> Option<Self::Item> {
        if let Some(row) = self.rows.next() {
            return Some(Ok(row));
        }
        if self.failed || self.offset >= self.snapshot.head.data_end {
            return None;
        }
        // Hydration and compaction stream only a small decoded batch. Reading
        // a full 256 KiB page of tiny records would retain thousands of heap
        // allocations between writer batches, even when every row is cold.
        match self.snapshot.rows_at(self.offset, self.ordinal, 64, 32 * 1024) {
            Ok(piece) if piece.next_offset > self.offset => {
                self.offset = piece.next_offset;
                self.ordinal += piece.rows.len() as u64;
                self.rows = piece.rows.into_iter();
                self.rows.next().map(Ok)
            }
            result => {
                self.failed = true;
                Some(Err(result
                    .err()
                    .unwrap_or_else(|| codec::invalid("snapshot made no progress"))))
            }
        }
    }
}

impl DiskSnapshot {
    pub fn rows(self: &Arc<Self>) -> SnapshotRows {
        SnapshotRows {
            snapshot: self.clone(),
            offset: HEADER_BYTES as u64,
            ordinal: 0,
            rows: Vec::new().into_iter(),
            failed: false,
        }
    }

    /// Reads only the fixed head, never the sparse table or the rows.
    pub fn open(path: impl AsRef<Path>) -> io::Result<Option<Arc<Self>>> {
        let file = match File::open(path) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        let mut bytes = [0; HEADER_BYTES];
        read_at(&file, &mut bytes, 0)?;
        if bytes.get(..8) != Some(MAGIC.as_slice()) {
            return Err(codec::invalid("unknown index snapshot version; rebuild required"));
        }
        let len =
            read_u32(bytes.get(8..12).ok_or_else(|| codec::invalid("head length"))?)? as usize;
        let crc =
            read_u32(bytes.get(HEADER_BYTES - 4..).ok_or_else(|| codec::invalid("head crc"))?)?;
        if len > HEADER_BYTES - 16
            || crc32fast::hash(bytes.get(..HEADER_BYTES - 4).ok_or_else(|| codec::invalid("head"))?)
                != crc
        {
            return Err(codec::invalid("index snapshot head checksum"));
        }
        let head: Head = serde_json::from_slice(
            bytes.get(12..12 + len).ok_or_else(|| codec::invalid("head body"))?,
        )
        .map_err(|_| codec::invalid("snapshot head json"))?;
        if head.data_end < HEADER_BYTES as u64
            || head.data_end.checked_add(head.directory_bytes as u64)
                != Some(file.metadata()?.len())
            || !head.directory_bytes.is_multiple_of(CHECKPOINT_BYTES)
            || (head.count == 0) != (head.directory_bytes == 0)
            || (head.count == 0) != (head.data_end == HEADER_BYTES as u64)
            || head.first_lengths.len() != head.count.min(FIRST_ROWS as u64) as usize
            || head.first_lengths.iter().any(|len| {
                usize::from(*len) < 12
                    || usize::from(*len) > super::MAX_INDEX_RECORD_BYTES + TRAILER_BYTES
            })
            || head.first_lengths.iter().map(|len| u64::from(*len)).sum::<u64>()
                > head.data_end - HEADER_BYTES as u64
        {
            return Err(codec::invalid("snapshot extent"));
        }
        Ok(Some(Arc::new(Self { file, head })))
    }

    pub fn log_offset(&self) -> u64 {
        self.head.log_offset
    }
    pub fn covered_generation(&self) -> u64 {
        self.head.covered_generation
    }
    pub fn seq(&self) -> u64 {
        self.head.seq
    }
    pub fn len(&self) -> u64 {
        self.head.count
    }
    pub fn is_empty(&self) -> bool {
        self.head.count == 0
    }
    pub fn bytes(&self) -> u64 {
        self.head.data_end + self.head.directory_bytes as u64
    }
}

#[cfg(unix)]
fn read_at(file: &File, bytes: &mut [u8], offset: u64) -> io::Result<()> {
    use std::os::unix::fs::FileExt;
    file.read_exact_at(bytes, offset)
}

#[cfg(windows)]
fn read_at(file: &File, mut bytes: &mut [u8], mut offset: u64) -> io::Result<()> {
    use std::os::windows::fs::FileExt;
    while !bytes.is_empty() {
        let read = file.seek_read(bytes, offset)?;
        if read == 0 {
            return Err(io::Error::from(io::ErrorKind::UnexpectedEof));
        }
        offset += read as u64;
        bytes = bytes.get_mut(read..).ok_or_else(|| codec::invalid("short read"))?;
    }
    Ok(())
}
