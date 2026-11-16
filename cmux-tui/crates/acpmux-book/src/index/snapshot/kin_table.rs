//! Optional cold kin sidecar for a sorted snapshot.
//!
//! The sidecar is deliberately independent from `index.snap`: older binaries
//! can continue to open the snapshot, while newer binaries can set a damaged
//! or mismatched table aside and use the ordinary pager.  PR 1 writes and
//! validates the file; the family reader is added separately.

use crate::index::{ForkOf, RowKey, Summary};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::Path;

pub(crate) const ENTRY_BYTES: usize = 32;
const TABLE_HEADER_BYTES: usize = 4096;
const PAGE_CRC_BYTES: usize = 4;
const ENTRY_PAGE_BYTES: usize = 4096;
const ENTRIES_PER_PAGE: usize = 127;
const SLOTS_PER_PAGE: usize = 511;
const TABLE_MAGIC: &[u8; 8] = b"ACKIN001";
const TABLE_VERSION: u32 = 1;
const FAMILY_KIND: u8 = 1;
const FORK_KIND: u8 = 2;
const PAD_KIND: u8 = 0;
const MAX_DEPTH: u8 = 64;

const _: [(); 1] = [(); (crate::index::MAX_INDEX_RECORD_BYTES < u16::MAX as usize) as usize];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct Entry {
    pub hash: u64,
    pub activity: u64,
    pub offset: u64,
    pub check: u32,
    pub len: u16,
    pub depth: u8,
    pub kind: u8,
}

impl Entry {
    fn padding() -> Self {
        Self { hash: 0, activity: 0, offset: 0, check: 0, len: 0, depth: 0, kind: PAD_KIND }
    }

    fn encode(self, out: &mut [u8]) {
        out[..8].copy_from_slice(&self.hash.to_le_bytes());
        out[8..16].copy_from_slice(&self.activity.to_le_bytes());
        out[16..24].copy_from_slice(&self.offset.to_le_bytes());
        out[24..28].copy_from_slice(&self.check.to_le_bytes());
        out[28..30].copy_from_slice(&self.len.to_le_bytes());
        out[30] = self.depth;
        out[31] = self.kind;
    }

    fn decode(bytes: &[u8]) -> io::Result<Self> {
        if bytes.len() != ENTRY_BYTES {
            return Err(invalid("kin entry length"));
        }
        Ok(Self {
            hash: u64::from_le_bytes(bytes[0..8].try_into().map_err(|_| invalid("kin hash"))?),
            activity: u64::from_le_bytes(
                bytes[8..16].try_into().map_err(|_| invalid("kin activity"))?,
            ),
            offset: u64::from_le_bytes(
                bytes[16..24].try_into().map_err(|_| invalid("kin offset"))?,
            ),
            check: u32::from_le_bytes(bytes[24..28].try_into().map_err(|_| invalid("kin check"))?),
            len: u16::from_le_bytes(bytes[28..30].try_into().map_err(|_| invalid("kin len"))?),
            depth: bytes[30],
            kind: bytes[31],
        })
    }
}

#[derive(Clone, Debug)]
struct OwnedRow {
    key: RowKey,
    parent: Option<RowKey>,
    fork_of: Option<ForkOf>,
    activity: u64,
    pinned: bool,
    live: bool,
    offset: u64,
    len: u16,
}

/// Bounded-at-the-output closure builder.  The rows are kept as fixed-size
/// records until the sidecar is written; no snapshot bytes or summaries are
/// retained.  The spill budget is explicit so the next PR can replace the
/// in-memory closure pass with the same run format without changing the file.
pub(crate) struct Builder {
    rows: Vec<OwnedRow>,
}

impl Builder {
    pub(crate) fn new() -> Self {
        Self { rows: Vec::new() }
    }

    pub(crate) fn push(&mut self, summary: &Summary, offset: u64, len: usize) -> io::Result<()> {
        summary.key().validate()?;
        let len = u16::try_from(len).map_err(|_| invalid("kin frame length"))?;
        self.rows.push(OwnedRow {
            key: summary.key(),
            parent: summary.parent.clone(),
            fork_of: summary.fork_of.clone(),
            activity: summary.last_activity,
            pinned: summary.pinned,
            live: summary.is_live(),
            offset,
            len,
        });
        Ok(())
    }

    pub(crate) fn write(
        self,
        path: &Path,
        snapshot_head_crc: u32,
        seq: u64,
        data_end: u64,
    ) -> io::Result<u64> {
        let mut by_key = std::collections::HashMap::with_capacity(self.rows.len());
        for row in &self.rows {
            by_key.insert(row.key.clone(), row);
        }
        let mut entries = Vec::new();
        for row in &self.rows {
            if !row.pinned && !row.live {
                let mut ancestor = row.parent.clone();
                let mut seen = std::collections::HashSet::new();
                for depth in 1..=MAX_DEPTH {
                    let Some(key) = ancestor.take() else { break };
                    if !seen.insert(key.clone()) {
                        break;
                    }
                    entries.push(make_entry(&key, row, depth, FAMILY_KIND));
                    ancestor = by_key.get(&key).and_then(|parent| parent.parent.clone());
                }
                if let Some(fork) = &row.fork_of {
                    entries.push(make_entry(&fork.key, row, 1, FORK_KIND));
                }
            }
        }
        entries.sort_unstable_by(|left, right| {
            left.hash.cmp(&right.hash).then_with(|| left.offset.cmp(&right.offset))
        });
        write_table(path, snapshot_head_crc, seq, data_end, entries)
    }
}

fn make_entry(key: &RowKey, row: &OwnedRow, depth: u8, kind: u8) -> Entry {
    let (hash, check) = key_fingerprint(key, kind);
    Entry { hash, activity: row.activity, offset: row.offset, check, len: row.len, depth, kind }
}

pub(crate) fn key_fingerprint(key: &RowKey, kind: u8) -> (u64, u32) {
    let mut bytes = Vec::with_capacity(1 + 4 + key.origin.len() + key.chat_id.len());
    bytes.push(kind);
    bytes.extend_from_slice(&(key.origin.len() as u32).to_le_bytes());
    bytes.extend_from_slice(key.origin.as_bytes());
    bytes.extend_from_slice(key.chat_id.as_bytes());
    let check = crc32fast::hash(&bytes);
    let mut hash = 0xcbf29ce484222325u64;
    for byte in bytes {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash ^= hash >> 33;
    hash = hash.wrapping_mul(0xff51afd7ed558ccd);
    hash ^= hash >> 33;
    hash = hash.wrapping_mul(0xc4ceb9fe1a85ec53);
    hash ^= hash >> 33;
    (hash, check)
}

fn write_table(
    path: &Path,
    snapshot_head_crc: u32,
    seq: u64,
    data_end: u64,
    entries: Vec<Entry>,
) -> io::Result<u64> {
    let slots = entries.len().div_ceil(64).next_power_of_two().max(1);
    let mut slot_ranges = vec![(0u32, 0u32); slots];
    let mut packed = Vec::with_capacity(entries.len() + entries.len() / ENTRIES_PER_PAGE + 1);
    let mut cursor = 0;
    while cursor < entries.len() {
        let hash = entries[cursor].hash;
        let shift = if slots == 1 { 0 } else { 64 - slots.trailing_zeros() };
        let slot = ((hash >> shift) as usize).min(slots - 1);
        let start = cursor;
        let mut end = cursor + 1;
        while end < entries.len() && entries[end].hash == hash {
            end += 1;
        }
        // Preserve complete buckets on page boundaries.  A long bucket is
        // still searched page by page by the reader in PR 2.
        while packed.len() % ENTRIES_PER_PAGE != 0 {
            packed.push(Entry::padding());
        }
        let packed_start = packed.len();
        packed.extend_from_slice(&entries[start..end]);
        let len = end - start;
        let (old_start, old_len) = slot_ranges[slot];
        if old_len == 0 {
            slot_ranges[slot] = (packed_start as u32, len as u32);
        } else {
            slot_ranges[slot].1 = packed.len() as u32 - old_start;
        }
        cursor = end;
    }
    let directory_pages = slots.div_ceil(SLOTS_PER_PAGE);
    let mut file = OpenOptions::new().create(true).truncate(true).write(true).open(path)?;
    file.write_all(&[0; TABLE_HEADER_BYTES])?;
    let mut directory = vec![0u8; directory_pages * ENTRY_PAGE_BYTES];
    for (index, (start, len)) in slot_ranges.iter().enumerate() {
        let page = index / SLOTS_PER_PAGE;
        let within = index % SLOTS_PER_PAGE;
        let at = page * ENTRY_PAGE_BYTES + within * 8;
        directory[at..at + 4].copy_from_slice(&start.to_le_bytes());
        directory[at + 4..at + 8].copy_from_slice(&len.to_le_bytes());
    }
    for page in directory.chunks_exact_mut(ENTRY_PAGE_BYTES) {
        let crc_at = ENTRY_PAGE_BYTES - PAGE_CRC_BYTES;
        page[crc_at..].copy_from_slice(&crc32fast::hash(&page[..crc_at]).to_le_bytes());
    }
    file.write_all(&directory)?;
    for chunk in packed.chunks(ENTRIES_PER_PAGE) {
        let mut page = vec![0u8; ENTRY_PAGE_BYTES];
        for (index, entry) in chunk.iter().enumerate() {
            entry.encode(&mut page[index * ENTRY_BYTES..(index + 1) * ENTRY_BYTES]);
        }
        let crc_at = ENTRY_PAGE_BYTES - PAGE_CRC_BYTES;
        page[crc_at..].copy_from_slice(&crc32fast::hash(&page[..crc_at]).to_le_bytes());
        file.write_all(&page)?;
    }
    let mut header = vec![0u8; TABLE_HEADER_BYTES];
    header[..8].copy_from_slice(TABLE_MAGIC);
    header[8..12].copy_from_slice(&TABLE_VERSION.to_le_bytes());
    header[12..16].copy_from_slice(&snapshot_head_crc.to_le_bytes());
    header[16..24].copy_from_slice(&seq.to_le_bytes());
    header[24..32].copy_from_slice(&data_end.to_le_bytes());
    header[32..40].copy_from_slice(&(entries.len() as u64).to_le_bytes());
    header[40..44].copy_from_slice(&(slots as u32).to_le_bytes());
    header[44..48].copy_from_slice(&(directory_pages as u32).to_le_bytes());
    header[48..56].copy_from_slice(&(packed.len() as u64).to_le_bytes());
    let header_crc = crc32fast::hash(&header[..TABLE_HEADER_BYTES - 4]);
    header[TABLE_HEADER_BYTES - 4..].copy_from_slice(&header_crc.to_le_bytes());
    file.seek(SeekFrom::Start(0))?;
    file.write_all(&header)?;
    file.sync_all()?;
    Ok((TABLE_HEADER_BYTES
        + directory.len()
        + packed.len().div_ceil(ENTRIES_PER_PAGE) * ENTRY_PAGE_BYTES) as u64)
}

#[derive(Debug)]
pub(crate) struct TableHeader {
    pub seq: u64,
    pub data_end: u64,
    pub entries: u64,
    pub slots: u32,
    pub directory_pages: u32,
    pub packed_entries: u64,
}

pub(crate) fn validate_header(
    path: &Path,
    snapshot_head_crc: u32,
    seq: u64,
    data_end: u64,
) -> io::Result<Option<TableHeader>> {
    let mut file = match File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    let mut bytes = [0u8; TABLE_HEADER_BYTES];
    file.read_exact(&mut bytes)?;
    if bytes.get(..8) != Some(TABLE_MAGIC.as_slice())
        || read_u32(&bytes[8..12])? != TABLE_VERSION
        || read_u32(&bytes[12..16])? != snapshot_head_crc
        || read_u64(&bytes[16..24])? != seq
        || read_u64(&bytes[24..32])? != data_end
        || read_u32(&bytes[TABLE_HEADER_BYTES - 4..])?
            != crc32fast::hash(&bytes[..TABLE_HEADER_BYTES - 4])
    {
        return Ok(None);
    }
    let header = TableHeader {
        seq: read_u64(&bytes[16..24])?,
        data_end: read_u64(&bytes[24..32])?,
        entries: read_u64(&bytes[32..40])?,
        slots: read_u32(&bytes[40..44])?,
        directory_pages: read_u32(&bytes[44..48])?,
        packed_entries: read_u64(&bytes[48..56])?,
    };
    if header.slots == 0
        || !header.slots.is_power_of_two()
        || header.directory_pages as usize != (header.slots as usize).div_ceil(SLOTS_PER_PAGE)
        || header.packed_entries < header.entries
    {
        return Ok(None);
    }
    Ok(Some(header))
}

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

fn read_u32(bytes: &[u8]) -> io::Result<u32> {
    let value = bytes.get(..4).ok_or_else(|| invalid("kin integer"))?;
    Ok(u32::from_le_bytes(value.try_into().map_err(|_| invalid("kin integer"))?))
}

fn read_u64(bytes: &[u8]) -> io::Result<u64> {
    let value = bytes.get(..8).ok_or_else(|| invalid("kin integer"))?;
    Ok(u64::from_le_bytes(value.try_into().map_err(|_| invalid("kin integer"))?))
}

pub(crate) fn set_aside(path: &Path) -> io::Result<()> {
    let mut bad = path.as_os_str().to_os_string();
    bad.push(".bad");
    match fs::rename(path, bad) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_hash_vector_is_stable() {
        let key = RowKey::new("local", "chat-1");
        assert_eq!(key_fingerprint(&key, FAMILY_KIND), (0x0d22_b478_04e9_d17c, 0xb87b_4fdf));
    }

    #[test]
    fn entries_are_fixed_width() {
        let entry = Entry { hash: 1, activity: 2, offset: 3, check: 4, len: 5, depth: 6, kind: 7 };
        let mut bytes = [0; ENTRY_BYTES];
        entry.encode(&mut bytes);
        assert_eq!(Entry::decode(&bytes).unwrap(), entry);
    }
}
