//! Immutable sorted records, a fixed head, and sparse seek checkpoints.
use super::{IndexRecord, SortKey, Summary, SummaryIndex, codec};
use serde::{Deserialize, Serialize};
use std::fs::{self, File};
use std::io::{self, BufWriter, Seek, SeekFrom, Write};
use std::path::Path;
use std::sync::{Arc, OnceLock};

const HEADER_BYTES: usize = 256;
const MAGIC: &[u8; 8] = b"ACIDX002";
pub const SEEK_BYTES: usize = 64 * 1024;
pub const PAGE_BYTES: usize = 256 * 1024;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Head {
    pub seq: u64,
    pub log_offset: u64,
    pub log_name: Option<String>,
    data_end: u64,
    directory_bytes: usize,
    count: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Checkpoint {
    key: SortKey,
    offset: u64,
    ordinal: u64,
}

#[derive(Debug)]
pub struct DiskSnapshot {
    file: File,
    pub(super) head: Head,
    directory: OnceLock<Vec<Checkpoint>>,
}

/// One bounded physical piece, including its progress when filtering yields no rows.
pub struct SnapshotPiece {
    pub rows: Vec<Arc<Summary>>,
    pub first_ordinal: u64,
    pub next_offset: u64,
    pub has_before: bool,
    pub has_after: bool,
    pub bytes_read: usize,
}

impl DiskSnapshot {
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
        let len = u32::from_le_bytes(
            bytes
                .get(8..12)
                .ok_or_else(|| codec::invalid("head length"))?
                .try_into()
                .map_err(io::Error::other)?,
        ) as usize;
        let crc = u32::from_le_bytes(
            bytes
                .get(252..)
                .ok_or_else(|| codec::invalid("head crc"))?
                .try_into()
                .map_err(io::Error::other)?,
        );
        if len > 240
            || crc32fast::hash(bytes.get(..252).ok_or_else(|| codec::invalid("head"))?) != crc
        {
            return Err(codec::invalid("index snapshot head checksum"));
        }
        let head: Head = serde_json::from_slice(
            bytes.get(12..12 + len).ok_or_else(|| codec::invalid("head body"))?,
        )
        .map_err(io::Error::other)?;
        if head.data_end < HEADER_BYTES as u64
            || head.data_end.checked_add(head.directory_bytes as u64)
                != Some(file.metadata()?.len())
        {
            return Err(codec::invalid("snapshot extent"));
        }
        Ok(Some(Arc::new(Self { file, head, directory: OnceLock::new() })))
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

    fn directory(&self) -> io::Result<&[Checkpoint]> {
        if self.directory.get().is_none() {
            // Validate against file length before allocating an on-disk count.
            let mut bytes = vec![0; self.head.directory_bytes];
            read_at(&self.file, &mut bytes, self.head.data_end)?;
            let directory: Vec<Checkpoint> =
                serde_json::from_slice(&bytes).map_err(io::Error::other)?;
            for pair in directory.windows(2) {
                if let [a, b] = pair
                    && (a.key >= b.key
                        || a.offset >= b.offset
                        || a.ordinal >= b.ordinal
                        || b.offset - a.offset > SEEK_BYTES as u64)
                {
                    return Err(codec::invalid("snapshot checkpoint order"));
                }
            }
            let _ = self.directory.set(directory);
        }
        self.directory.get().map(Vec::as_slice).ok_or_else(|| codec::invalid("snapshot directory"))
    }

    /// At most one 64 KiB seek piece; checkpoints end before exceeding the cap.
    pub fn seek(&self, key: &SortKey, inclusive: bool) -> io::Result<(u64, u64)> {
        let directory = self.directory()?;
        let block = directory.partition_point(|entry| entry.key <= *key).saturating_sub(1);
        let Some(entry) = directory.get(block) else {
            return Ok((HEADER_BYTES as u64, 0));
        };
        let end = directory.get(block + 1).map_or(self.head.data_end, |entry| entry.offset);
        let bytes = self.read_range(entry.offset, (end - entry.offset) as usize)?;
        let mut input = bytes.as_slice();
        let mut offset = entry.offset;
        let mut ordinal = entry.ordinal;
        while let Some((record, len)) = codec::read(&mut input)? {
            let candidate = SortKey::of(&record.summary);
            if candidate > *key || (inclusive && candidate == *key) {
                break;
            }
            ordinal += 1;
            offset += len as u64;
        }
        Ok((offset, ordinal))
    }

    pub fn first_page(&self, max_bytes: usize) -> io::Result<SnapshotPiece> {
        self.piece(HEADER_BYTES as u64, 0, max_bytes)
    }

    /// A single bounded read after the sparse seek. A partial final record is
    /// left for the next page; it is never counted as a visited row.
    pub fn piece(&self, offset: u64, ordinal: u64, max_bytes: usize) -> io::Result<SnapshotPiece> {
        let bytes = self.read_range(offset, max_bytes.min(PAGE_BYTES))?;
        let mut input = bytes.as_slice();
        let mut next = offset;
        let mut rows = Vec::new();
        loop {
            match codec::read(&mut input) {
                Ok(Some((record, len))) => {
                    next += len as u64;
                    rows.push(Arc::new(record.summary));
                }
                Ok(None) => break,
                Err(error)
                    if error.kind() == io::ErrorKind::UnexpectedEof
                        && offset + (bytes.len() as u64) < self.head.data_end =>
                {
                    break;
                }
                Err(error) => return Err(error),
            }
        }
        Ok(SnapshotPiece {
            rows,
            first_ordinal: ordinal,
            next_offset: next,
            has_before: ordinal > 0,
            has_after: next < self.head.data_end,
            bytes_read: bytes.len(),
        })
    }

    pub fn checkpoint_before(&self, offset: u64) -> io::Result<(u64, u64)> {
        let directory = self.directory()?;
        let index = directory.partition_point(|entry| entry.offset <= offset).saturating_sub(1);
        Ok(directory
            .get(index)
            .map_or((HEADER_BYTES as u64, 0), |entry| (entry.offset, entry.ordinal)))
    }

    fn read_range(&self, offset: u64, max_bytes: usize) -> io::Result<Vec<u8>> {
        if offset < HEADER_BYTES as u64 || offset > self.head.data_end {
            return Err(codec::invalid("snapshot offset"));
        }
        let len = (self.head.data_end - offset).min(max_bytes as u64) as usize;
        let mut bytes = vec![0; len];
        read_at(&self.file, &mut bytes, offset)?;
        Ok(bytes)
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

pub struct SortedSnapshot;

impl SortedSnapshot {
    pub const VERSION: u32 = 2;

    pub fn write(path: impl AsRef<Path>, index: &SummaryIndex) -> io::Result<()> {
        Self::write_with_offset(path, index, 0)
    }

    pub fn write_with_offset(
        path: impl AsRef<Path>,
        index: &SummaryIndex,
        log_offset: u64,
    ) -> io::Result<()> {
        Self::write_with_offset_and_name(path, index, log_offset, None)
    }

    pub(super) fn write_with_offset_and_name(
        path: impl AsRef<Path>,
        index: &SummaryIndex,
        log_offset: u64,
        log_name: Option<&str>,
    ) -> io::Result<()> {
        Self::write_stream(
            path,
            index.seq(),
            log_offset,
            log_name,
            index.iter().map(|row| Ok(row.clone())),
        )
    }

    /// The input is already ordered. Only one row and the sparse keys are held.
    pub fn write_stream(
        path: impl AsRef<Path>,
        seq: u64,
        log_offset: u64,
        log_name: Option<&str>,
        rows: impl IntoIterator<Item = io::Result<Arc<Summary>>>,
    ) -> io::Result<()> {
        let path = path.as_ref();
        let temp = path.with_extension("snap.new");
        let mut writer = BufWriter::new(File::create(&temp)?);
        writer.write_all(&[0; HEADER_BYTES])?;
        let mut offset = HEADER_BYTES as u64;
        let mut count = 0;
        let mut checkpoints: Vec<Checkpoint> = Vec::new();
        let mut previous = None;
        for row in rows {
            let row = row?;
            let key = SortKey::of(&row);
            if previous.as_ref().is_some_and(|previous| previous >= &key) {
                return Err(codec::invalid("unsorted snapshot input"));
            }
            let record = IndexRecord {
                seq,
                origin: row.origin.clone(),
                chat_id: row.chat_id.clone(),
                summary: row.as_ref().clone(),
                gone: false,
            };
            let bytes = codec::encode(&record)?;
            if checkpoints.last().is_none_or(|last| {
                count - last.ordinal == 256
                    || offset + bytes.len() as u64 - last.offset > SEEK_BYTES as u64
            }) {
                checkpoints.push(Checkpoint { key: key.clone(), offset, ordinal: count });
            }
            writer.write_all(&bytes)?;
            offset += bytes.len() as u64;
            count += 1;
            previous = Some(key);
        }
        let directory = serde_json::to_vec(&checkpoints).map_err(io::Error::other)?;
        writer.write_all(&directory)?;
        let head = Head {
            seq,
            log_offset,
            log_name: log_name.map(str::to_owned),
            data_end: offset,
            directory_bytes: directory.len(),
            count,
        };
        let json = serde_json::to_vec(&head).map_err(io::Error::other)?;
        if json.len() > 240 {
            return Err(codec::invalid("snapshot head too large"));
        }
        let mut header = Vec::from(MAGIC.as_slice());
        header.extend_from_slice(&(json.len() as u32).to_le_bytes());
        header.extend_from_slice(&json);
        header.resize(252, 0);
        header.extend_from_slice(&crc32fast::hash(&header).to_le_bytes());
        writer.seek(SeekFrom::Start(0))?;
        writer.write_all(&header)?;
        writer.flush()?;
        writer.get_ref().sync_all()?;
        fs::rename(&temp, path)?;
        File::open(path.parent().unwrap_or_else(|| Path::new(".")))?.sync_all()?;
        Ok(())
    }

    /// Explicit full materialization for tools/tests, never used by the opener.
    pub fn read(path: impl AsRef<Path>) -> io::Result<Option<SummaryIndex>> {
        Ok(Self::read_with_offset(path)?.map(|(index, _)| index))
    }

    pub fn read_with_offset(path: impl AsRef<Path>) -> io::Result<Option<(SummaryIndex, u64)>> {
        let Some(snapshot) = DiskSnapshot::open(path)? else {
            return Ok(None);
        };
        let mut index = SummaryIndex::new();
        index.seq = snapshot.seq();
        let mut offset = HEADER_BYTES as u64;
        let mut ordinal = 0;
        while offset < snapshot.head.data_end {
            let piece = snapshot.piece(offset, ordinal, PAGE_BYTES)?;
            if piece.rows.is_empty() {
                return Err(codec::invalid("snapshot made no progress"));
            }
            ordinal += piece.rows.len() as u64;
            for row in piece.rows {
                index = index.apply(snapshot.seq(), row.as_ref().clone());
            }
            offset = piece.next_offset;
        }
        Ok(Some((index, snapshot.head.log_offset)))
    }
}
