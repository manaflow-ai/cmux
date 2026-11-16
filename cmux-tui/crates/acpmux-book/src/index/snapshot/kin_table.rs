//! Optional cold kin sidecar for a sorted snapshot.
//!
//! The sidecar is separate from `index.snap`, so an older binary ignores it.
//! PR1 owns the fixed format and writer. The reader is deliberately added by
//! PR2; until then a valid header is only an accelerator-presence bit.

use crate::index::{ForkOf, RowKey, Summary};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::Path;

pub(crate) const ENTRY_BYTES: usize = 32;
const TABLE_HEADER_BYTES: usize = 4096;
const PAGE_BYTES: usize = 4096;
const PAGE_CRC_BYTES: usize = 4;
const ENTRY_PAGE_BYTES: usize = PAGE_BYTES;
const ENTRIES_PER_PAGE: usize = (ENTRY_PAGE_BYTES - PAGE_CRC_BYTES) / ENTRY_BYTES;
const SLOTS_PER_PAGE: usize = (ENTRY_PAGE_BYTES - PAGE_CRC_BYTES) / 8;
const TABLE_MAGIC: &[u8; 8] = b"ACKIN001";
const TABLE_VERSION: u32 = 1;
const FAMILY_KIND: u8 = 1;
const FORK_KIND: u8 = 2;
const PAD_KIND: u8 = 0;
const MAX_DEPTH: u8 = 64;
const RUN_BUDGET_BYTES: usize = 4 * 1024 * 1024;

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

/// The row metadata is bounded to one compact record per snapshot row. The
/// generated entries use fixed-size spill runs before the final merge.
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
        snapshot_count: u64,
        data_end: u64,
    ) -> io::Result<u64> {
        let mut by_key = HashMap::with_capacity(self.rows.len());
        for row in &self.rows {
            by_key.insert(row.key.clone(), row.clone());
        }

        let mut sorter = EntrySorter::new();
        for row in &self.rows {
            if !row.pinned && !row.live {
                let mut ancestor = row.parent.clone();
                let mut seen = HashSet::new();
                for depth in 1..=MAX_DEPTH {
                    let Some(key) = ancestor.take() else { break };
                    if key == row.key || !seen.insert(key.clone()) {
                        break;
                    }
                    sorter.push(make_entry(&key, row, depth, FAMILY_KIND))?;
                    ancestor = by_key.get(&key).and_then(|parent| parent.parent.clone());
                }
            }
            // Fork records are emitted for every row, including hot rows. The
            // format is shared by PR3's cold fork reader.
            if let Some(fork) = &row.fork_of {
                sorter.push(make_entry(&fork.key, row, 1, FORK_KIND))?;
            }
        }
        write_table(path, snapshot_head_crc, seq, snapshot_count, data_end, sorter.finish()?)
    }
}

fn make_entry(key: &RowKey, row: &OwnedRow, depth: u8, kind: u8) -> Entry {
    let (hash, check) = key_fingerprint(key, kind);
    Entry { hash, activity: row.activity, offset: row.offset, check, len: row.len, depth, kind }
}

struct EntrySorter {
    memory: Vec<Entry>,
    runs: Vec<tempfile::NamedTempFile>,
    bytes: usize,
}

impl EntrySorter {
    fn new() -> Self {
        Self { memory: Vec::new(), runs: Vec::new(), bytes: 0 }
    }

    fn push(&mut self, entry: Entry) -> io::Result<()> {
        self.memory.push(entry);
        self.bytes += ENTRY_BYTES;
        if self.bytes >= RUN_BUDGET_BYTES {
            self.flush_run()?;
        }
        Ok(())
    }

    fn flush_run(&mut self) -> io::Result<()> {
        if self.memory.is_empty() {
            return Ok(());
        }
        self.memory.sort_unstable_by(entry_order);
        let mut run = tempfile::NamedTempFile::new()?;
        for entry in self.memory.drain(..) {
            let mut encoded = [0; ENTRY_BYTES];
            entry.encode(&mut encoded);
            run.write_all(&encoded)?;
        }
        run.as_file_mut().sync_all()?;
        self.bytes = 0;
        self.runs.push(run);
        Ok(())
    }

    fn finish(mut self) -> io::Result<Vec<Entry>> {
        self.flush_run()?;
        let mut entries = Vec::new();
        for mut run in self.runs {
            run.as_file_mut().seek(SeekFrom::Start(0))?;
            let mut bytes = [0; ENTRY_BYTES];
            loop {
                match run.as_file_mut().read_exact(&mut bytes) {
                    Ok(()) => entries.push(Entry::decode(&bytes)?),
                    Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => break,
                    Err(error) => return Err(error),
                }
            }
        }
        entries.append(&mut self.memory);
        entries.sort_unstable_by(entry_order);
        Ok(entries)
    }
}

fn entry_order(left: &Entry, right: &Entry) -> std::cmp::Ordering {
    left.hash.cmp(&right.hash).then_with(|| left.offset.cmp(&right.offset))
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

fn slot_for(hash: u64, slots: usize) -> usize {
    if slots == 1 { 0 } else { (hash >> (64 - slots.trailing_zeros())) as usize }
}

fn write_table(
    path: &Path,
    snapshot_head_crc: u32,
    seq: u64,
    snapshot_count: u64,
    data_end: u64,
    entries: Vec<Entry>,
) -> io::Result<u64> {
    let slots = entries.len().div_ceil(64).next_power_of_two().max(1);
    let directory_pages = if entries.is_empty() { 0 } else { slots.div_ceil(SLOTS_PER_PAGE) };
    let mut slot_ranges = vec![(0u32, 0u32); slots];
    let mut packed = Vec::with_capacity(entries.len() + entries.len() / ENTRIES_PER_PAGE + 1);
    let mut cursor = 0;
    for slot in 0..slots {
        let start = cursor;
        while cursor < entries.len() && slot_for(entries[cursor].hash, slots) == slot {
            cursor += 1;
        }
        let bucket_len = cursor - start;
        if bucket_len == 0 {
            continue;
        }
        if bucket_len <= ENTRIES_PER_PAGE {
            let used = packed.len() % ENTRIES_PER_PAGE;
            if used != 0 && used + bucket_len > ENTRIES_PER_PAGE {
                packed.resize(packed.len() + ENTRIES_PER_PAGE - used, Entry::padding());
            }
        } else if !packed.len().is_multiple_of(ENTRIES_PER_PAGE) {
            let used = packed.len() % ENTRIES_PER_PAGE;
            packed.resize(packed.len() + ENTRIES_PER_PAGE - used, Entry::padding());
        }
        let packed_start = packed.len();
        packed.extend_from_slice(&entries[start..cursor]);
        slot_ranges[slot] = (packed_start as u32, bucket_len as u32);
    }

    let mut file = OpenOptions::new().create(true).truncate(true).write(true).open(path)?;
    file.write_all(&[0; TABLE_HEADER_BYTES])?;
    if directory_pages != 0 {
        let mut directory = vec![0u8; directory_pages * ENTRY_PAGE_BYTES];
        for (index, (start, len)) in slot_ranges.iter().enumerate() {
            let page = index / SLOTS_PER_PAGE;
            let within = index % SLOTS_PER_PAGE;
            let at = page * ENTRY_PAGE_BYTES + within * 8;
            directory[at..at + 4].copy_from_slice(&start.to_le_bytes());
            directory[at + 4..at + 8].copy_from_slice(&len.to_le_bytes());
        }
        add_page_crcs(&mut directory);
        file.write_all(&directory)?;
    }
    for chunk in packed.chunks(ENTRIES_PER_PAGE) {
        let mut page = vec![0u8; ENTRY_PAGE_BYTES];
        for (index, entry) in chunk.iter().enumerate() {
            entry.encode(&mut page[index * ENTRY_BYTES..(index + 1) * ENTRY_BYTES]);
        }
        let crc_at = ENTRY_PAGE_BYTES - PAGE_CRC_BYTES;
        let page_crc = crc32fast::hash(&page[..crc_at]);
        page[crc_at..].copy_from_slice(&page_crc.to_le_bytes());
        file.write_all(&page)?;
    }

    let mut header = vec![0u8; TABLE_HEADER_BYTES];
    header[..8].copy_from_slice(TABLE_MAGIC);
    header[8..12].copy_from_slice(&TABLE_VERSION.to_le_bytes());
    header[12..16].copy_from_slice(&snapshot_head_crc.to_le_bytes());
    header[16..24].copy_from_slice(&seq.to_le_bytes());
    header[24..32].copy_from_slice(&data_end.to_le_bytes());
    header[32..40].copy_from_slice(&snapshot_count.to_le_bytes());
    header[40..48].copy_from_slice(&(entries.len() as u64).to_le_bytes());
    header[48..52].copy_from_slice(&(slots as u32).to_le_bytes());
    header[52..56].copy_from_slice(&(directory_pages as u32).to_le_bytes());
    header[56..64].copy_from_slice(&(packed.len() as u64).to_le_bytes());
    let header_crc = crc32fast::hash(&header[..TABLE_HEADER_BYTES - 4]);
    header[TABLE_HEADER_BYTES - 4..].copy_from_slice(&header_crc.to_le_bytes());
    file.seek(SeekFrom::Start(0))?;
    file.write_all(&header)?;
    file.sync_all()?;
    Ok((TABLE_HEADER_BYTES
        + directory_pages * ENTRY_PAGE_BYTES
        + packed.len().div_ceil(ENTRIES_PER_PAGE) * ENTRY_PAGE_BYTES) as u64)
}

fn add_page_crcs(bytes: &mut [u8]) {
    for page in bytes.chunks_exact_mut(ENTRY_PAGE_BYTES) {
        let at = ENTRY_PAGE_BYTES - PAGE_CRC_BYTES;
        let page_crc = crc32fast::hash(&page[..at]);
        page[at..].copy_from_slice(&page_crc.to_le_bytes());
    }
}

#[derive(Debug)]
pub(crate) struct TableHeader {
    pub seq: u64,
    pub snapshot_count: u64,
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
    snapshot_count: u64,
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
        || read_u64(&bytes[32..40])? != snapshot_count
        || read_u32(&bytes[TABLE_HEADER_BYTES - 4..])?
            != crc32fast::hash(&bytes[..TABLE_HEADER_BYTES - 4])
    {
        return Ok(None);
    }
    let header = TableHeader {
        seq: read_u64(&bytes[16..24])?,
        snapshot_count: read_u64(&bytes[32..40])?,
        data_end: read_u64(&bytes[24..32])?,
        entries: read_u64(&bytes[40..48])?,
        slots: read_u32(&bytes[48..52])?,
        directory_pages: read_u32(&bytes[52..56])?,
        packed_entries: read_u64(&bytes[56..64])?,
    };
    if header.slots == 0
        || !header.slots.is_power_of_two()
        || header.directory_pages as usize
            != if header.entries == 0 {
                0
            } else {
                (header.slots as usize).div_ceil(SLOTS_PER_PAGE)
            }
        || header.packed_entries < header.entries
    {
        return Ok(None);
    }
    let expected = TABLE_HEADER_BYTES as u64
        + u64::from(header.directory_pages) * ENTRY_PAGE_BYTES as u64
        + header.packed_entries.div_ceil(ENTRIES_PER_PAGE as u64) * ENTRY_PAGE_BYTES as u64;
    if file.metadata()?.len() != expected {
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
        assert_eq!(key_fingerprint(&key, FAMILY_KIND), (0xd22b_4780_4e9d_17c0, 0xb87b_4fdf));
    }

    #[test]
    fn entries_are_fixed_width() {
        let entry = Entry { hash: 1, activity: 2, offset: 3, check: 4, len: 5, depth: 6, kind: 7 };
        let mut bytes = [0; ENTRY_BYTES];
        entry.encode(&mut bytes);
        assert_eq!(Entry::decode(&bytes).unwrap(), entry);
    }

    #[test]
    fn sorter_spills_and_preserves_order() {
        let mut sorter = EntrySorter::new();
        for index in (0..(RUN_BUDGET_BYTES / ENTRY_BYTES + 3)).rev() {
            sorter
                .push(Entry {
                    hash: index as u64,
                    activity: 0,
                    offset: 0,
                    check: 0,
                    len: 1,
                    depth: 1,
                    kind: FAMILY_KIND,
                })
                .unwrap();
        }
        let entries = sorter.finish().unwrap();
        assert!(entries.windows(2).all(|pair| entry_order(&pair[0], &pair[1]).is_le()));
    }
}
