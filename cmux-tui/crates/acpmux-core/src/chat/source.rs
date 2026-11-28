//! Ordered whole lines in source places. A chunk owns one buffer and no per-line table.
#![deny(clippy::indexing_slicing, clippy::string_slice, clippy::expect_used)]
#![forbid(unsafe_code)]

use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::ops::Range;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

pub const CHUNK_BYTES: usize = 256 * 1024;
/// Torn-tail recovery reads backwards in fixed-size blocks.
pub const REPAIR_BLOCK_BYTES: u64 = 256 * 1024;
/// Sparse raw seq index spacing: one fixed-size mark per 256 KiB written.
pub const RAW_INDEX_BYTES: u64 = 256 * 1024;
/// Maps one whole line and its byte position to source places. A v1 source can obtain
/// its seq from the line itself; a file uses the byte position. No table grows with lines.
pub type Places = fn(&[u8], u64) -> io::Result<Range<u64>>;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Line {
    pub bytes: Range<usize>,
    pub start: u64,
    pub end: u64,
}

pub struct Chunk {
    bytes: Vec<u8>,
    base: u64,
    places: Places,
    pub at_end: bool,
    pub hint: u64,
    /// The source stamp captured while this chunk was read.
    pub stamp: u64,
}

impl Chunk {
    pub fn new(bytes: Vec<u8>, base: u64, places: Places, at_end: bool, hint: u64) -> Self {
        Self { bytes, base, places, at_end, hint, stamp: 0 }
    }

    pub fn with_stamp(
        bytes: Vec<u8>,
        base: u64,
        places: Places,
        at_end: bool,
        hint: u64,
        stamp: u64,
    ) -> Self {
        Self { bytes, base, places, at_end, hint, stamp }
    }

    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }

    pub fn lines(&self) -> Lines<'_> {
        Lines { chunk: self, at: 0 }
    }

    pub fn resident_bytes(&self) -> usize {
        self.bytes.capacity()
    }

    /// Validate a notice before using it. A source chunk must follow the same invariants.
    pub fn validate(&self, after: u64) -> io::Result<()> {
        let mut previous = after;
        let mut count = 0usize;
        for line in self.lines() {
            let line = line?;
            if line.start < previous || line.start >= line.end {
                return Err(invalid("raw places do not grow"));
            }
            previous = line.end;
            count = count.saturating_add(1);
        }
        if self.bytes.len() > CHUNK_BYTES && count != 1 {
            return Err(invalid("raw chunk exceeds its bound"));
        }
        Ok(())
    }
}

pub struct Lines<'a> {
    chunk: &'a Chunk,
    at: usize,
}

impl Iterator for Lines<'_> {
    type Item = io::Result<Line>;
    fn next(&mut self) -> Option<Self::Item> {
        let rest = self.chunk.bytes.get(self.at..)?;
        if rest.is_empty() {
            return None;
        }
        let start = self.at;
        let Some(newline) = rest.iter().position(|byte| *byte == b'\n') else {
            self.at = self.chunk.bytes.len();
            return Some(Err(invalid("incomplete raw line")));
        };
        let length = newline.saturating_add(1);
        self.at = start.saturating_add(length);
        let bytes = rest.get(..length)?;
        let position = self.chunk.base.checked_add(start as u64);
        Some(position.ok_or_else(|| invalid("raw position overflow")).and_then(|position| {
            (self.chunk.places)(bytes, position).map(|places| Line {
                bytes: start..self.at,
                start: places.start,
                end: places.end,
            })
        }))
    }
}

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

pub fn byte_places(bytes: &[u8], start: u64) -> io::Result<Range<u64>> {
    let end = start.checked_add(bytes.len() as u64).ok_or_else(|| invalid("raw end overflow"))?;
    Ok(start..end)
}

pub trait RawSource: Send + 'static {
    fn read_chunk(&mut self, place: u64) -> io::Result<Chunk>;
    /// Whether a previously delivered line end still exists. This is not an end search.
    fn holds(&mut self, place: u64) -> io::Result<bool>;
    /// A growth hint, not a whole-line end. Equality with the last at_end read avoids spins.
    fn hint(&self) -> io::Result<u64>;
    /// Sync before any checkpoint or patch derived from these lines becomes durable.
    fn sync_through(&mut self, place: u64) -> io::Result<()>;
    fn identity(&self) -> &[u8];
    /// Changes whenever a previously delivered line can read differently.
    fn stamp(&self) -> u64;
    /// A file source inside a derived book must retain its path and inode at swap.
    fn file_path(&self) -> Option<&Path> {
        None
    }
    /// At most `max` bytes of the line that starts at `place`, from `offset` in it, and whether
    /// the line ends there. A queue head, a waiting prompt's `blob` and a body read back use it,
    /// so none of them reads a line whole. A source that cannot answers `Unsupported`.
    fn read_at(&mut self, _place: u64, _offset: u64, _max: usize) -> io::Result<Piece> {
        Err(io::Error::new(io::ErrorKind::Unsupported, "this source reads no part of a line"))
    }
}

/// Each `raw.map` entry's number by its path and identity.
type MapEntries = HashMap<(String, String), u32>;

/// A durable source entry in `raw.map`. The map is append-only and synced before the first raw
/// record names the returned number.
pub struct RawMap {
    file: File,
    path: PathBuf,
    next: u32,
    /// Read once at open. A lookup is one hash, not a scan of the file.
    entries: MapEntries,
    poisoned: bool,
}

impl RawMap {
    pub fn open(path: &Path) -> io::Result<Self> {
        let mut file = OpenOptions::new().create(true).read(true).append(true).open(path)?;
        repair_torn_tail(&mut file)?;
        let (entries, next) = read_map_entries(&mut file)?;
        Ok(Self { file, path: path.to_path_buf(), next, entries, poisoned: false })
    }

    /// Append and sync one source description. The returned number is the zero-based map line.
    pub fn append_file(&mut self, path: &Path, identity: &[u8]) -> io::Result<u32> {
        if self.poisoned {
            return Err(io::Error::other("raw map is poisoned; reopen it"));
        }
        let identity = String::from_utf8_lossy(identity).into_owned();
        let path_text = path.to_string_lossy().into_owned();
        // A source may be reopened after another source was registered. Preserve the existing
        // map number instead of registering the same file twice.
        let key = (path_text, identity);
        if let Some(number) = self.entries.get(&key) {
            return Ok(*number);
        }
        let number = self.next;
        let next = number.checked_add(1).ok_or_else(|| invalid("raw map is full"))?;
        let line = serde_json::json!({
            "source": number,
            "kind": "file",
            "path": &key.0,
            "identity": &key.1,
        });
        let mut bytes = serde_json::to_vec(&line).map_err(io::Error::other)?;
        bytes.push(b'\n');
        let start = self.file.metadata()?.len();
        let written = self
            .file
            .write_all(&bytes)
            .and_then(|_| self.file.sync_all())
            .and_then(|_| if start == 0 { sync_parent_dir(&self.path) } else { Ok(()) });
        if let Err(error) = written {
            self.poisoned = true;
            self.file.set_len(start)?;
            self.file.sync_all()?;
            return Err(error);
        }
        self.next = next;
        self.entries.insert(key, number);
        Ok(number)
    }
}

/// The sole writer for one hosted chat's raw file. It shares no lock with another chat. Callers
/// send the returned receipt as the lossy actor notice; a host entry is acknowledged once this
/// method returns successfully.
pub struct RawWriter {
    file: File,
    index: Option<File>,
    path: PathBuf,
    next_seq: u64,
    offset: u64,
    last_sync: Instant,
    unsynced: bool,
    /// The index file's length, set at open and advanced by each mark, so no append asks the
    /// file system for it.
    index_len: u64,
    last_index_offset: u64,
    poisoned: bool,
    #[cfg(test)]
    fail_after: Option<usize>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WriteReceipt {
    pub seq: u64,
    pub start: u64,
    pub end: u64,
    pub synced: bool,
}

impl RawWriter {
    /// Register the file in `raw.map` (and sync that line) before opening the append handle.
    pub fn open_mapped(
        map: &mut RawMap,
        path: &Path,
        identity: &[u8],
        index_path: Option<&Path>,
        next_seq: u64,
    ) -> io::Result<(u32, Self)> {
        let source = map.append_file(path, identity)?;
        Ok((source, Self::open_with_index(path, index_path, next_seq)?))
    }

    /// Open a raw file after its `raw.map` line has been synced by the caller.
    pub fn open(path: &Path, next_seq: u64) -> io::Result<Self> {
        Self::open_with_index(path, None, next_seq)
    }

    /// Open with an optional sparse `(seq, byte_offset)` index. The index is append-only and is
    /// synced with the raw file, so a reader can seek to one chunk without a whole-file scan.
    pub fn open_with_index(
        path: &Path,
        index_path: Option<&Path>,
        next_seq: u64,
    ) -> io::Result<Self> {
        let new_file = !path.exists();
        let mut file = OpenOptions::new().create(true).read(true).append(true).open(path)?;
        repair_torn_tail(&mut file)?;
        let offset = file.metadata()?.len();
        if new_file {
            file.sync_all()?;
            sync_parent_dir(path)?;
        }
        let (index, index_len, last_index_offset) = if let Some(index_path) = index_path {
            let mut index =
                OpenOptions::new().create(true).read(true).append(true).open(index_path)?;
            let length = index.metadata()?.len();
            let mut valid_length = length - length % 16;
            let last_mark = loop {
                if valid_length == 0 {
                    break None;
                }
                index.seek(SeekFrom::Start(valid_length - 16))?;
                let mut seq = [0; 8];
                let mut mark = [0; 8];
                index.read_exact(&mut seq)?;
                index.read_exact(&mut mark)?;
                let mark = u64::from_le_bytes(mark);
                if mark < offset {
                    break Some((u64::from_le_bytes(seq), mark));
                }
                valid_length -= 16;
            };
            if valid_length != length {
                index.set_len(valid_length)?;
                index.sync_all()?;
            }
            let mut last_index_offset = last_mark.map_or(0, |(_, mark)| mark);
            // A kill between the raw write and the index write leaves lines with no mark.
            let missing = missing_index_marks(&mut file, offset, last_mark, next_seq)?;
            if let Some((_, start)) = missing.last() {
                let mut bytes = Vec::with_capacity(missing.len().saturating_mul(16));
                for (seq, start) in &missing {
                    bytes.extend_from_slice(&seq.to_le_bytes());
                    bytes.extend_from_slice(&start.to_le_bytes());
                }
                index.write_all(&bytes)?;
                index.sync_all()?;
                valid_length += bytes.len() as u64;
                last_index_offset = *start;
            }
            (Some(index), valid_length, last_index_offset)
        } else {
            (None, 0, 0)
        };
        Ok(Self {
            file,
            index,
            path: path.to_path_buf(),
            next_seq,
            offset,
            last_sync: Instant::now(),
            unsynced: false,
            index_len,
            last_index_offset,
            poisoned: false,
            #[cfg(test)]
            fail_after: None,
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Sequence for the caller's next encoded record. It advances only on a successful append.
    pub fn next_seq(&self) -> u64 {
        self.next_seq
    }

    /// Append one pre-encoded line without its newline; record policy/serialization is the caller's.
    /// The receipt carries the next seq supplied at open. `sync_now` is true for acts and turn ends.
    /// The actor must also call `sync` on its one-second timer when no further append arrives.
    pub fn append(&mut self, line: &[u8], sync_now: bool) -> io::Result<WriteReceipt> {
        if self.poisoned {
            return Err(io::Error::other("raw writer is poisoned; reopen it"));
        }
        let seq = self.next_seq;
        let mut line = line.to_vec();
        line.push(b'\n');
        let start = self.offset;
        let end =
            start.checked_add(line.len() as u64).ok_or_else(|| invalid("raw offset overflow"))?;
        let next_seq = seq.checked_add(1).ok_or_else(|| invalid("raw seq overflow"))?;
        let index_start = self.index.as_ref().map(|_| self.index_len);
        if let Err(error) = self.write_raw(&line) {
            return Err(self.rollback(start, index_start, error));
        }
        self.offset = end;
        if (self.offset.saturating_sub(self.last_index_offset) >= RAW_INDEX_BYTES
            || line.len() as u64 >= RAW_INDEX_BYTES)
            && let Some(index) = &mut self.index
        {
            if let Err(error) = index
                .write_all(&seq.to_le_bytes())
                .and_then(|_| index.write_all(&start.to_le_bytes()))
            {
                return Err(self.rollback(start, index_start, error));
            }
            self.index_len += 16;
            self.last_index_offset = start;
        }
        self.unsynced = true;
        let due = sync_now || self.last_sync.elapsed() >= Duration::from_secs(1);
        if due {
            let sync_result = self
                .file
                .sync_all()
                .and_then(|_| self.index.as_ref().map_or(Ok(()), File::sync_all));
            if let Err(error) = sync_result {
                return Err(self.rollback(start, index_start, error));
            }
            self.last_sync = Instant::now();
            self.unsynced = false;
        }
        self.next_seq = next_seq;
        Ok(WriteReceipt { seq, start, end: self.offset, synced: !self.unsynced })
    }

    fn write_raw(&mut self, bytes: &[u8]) -> io::Result<()> {
        #[cfg(test)]
        if let Some(limit) = self.fail_after {
            let count = limit.min(bytes.len());
            self.file.write_all(bytes.get(..count).ok_or_else(|| invalid("fault offset"))?)?;
            return Err(io::Error::other("injected raw write failure"));
        }
        self.file.write_all(bytes)
    }

    fn rollback(&mut self, start: u64, index_start: Option<u64>, error: io::Error) -> io::Error {
        self.poisoned = true;
        self.offset = start;
        let raw = self.file.set_len(start).and_then(|_| self.file.sync_all());
        let index = match (self.index.as_mut(), index_start) {
            (Some(index), Some(length)) => {
                self.index_len = length;
                index.set_len(length).and_then(|_| index.sync_all())
            }
            _ => Ok(()),
        };
        if let Err(repair) = raw.and(index) {
            return io::Error::other(format!(
                "raw write failed ({error}); rollback failed ({repair})"
            ));
        }
        error
    }

    #[cfg(test)]
    fn fail_after(&mut self, bytes: usize) {
        self.fail_after = Some(bytes);
    }

    pub fn sync(&mut self) -> io::Result<()> {
        if self.poisoned {
            return Err(io::Error::other("raw writer is poisoned; reopen it"));
        }
        if self.unsynced {
            if let Err(error) = self
                .file
                .sync_all()
                .and_then(|_| self.index.as_ref().map_or(Ok(()), File::sync_all))
            {
                self.poisoned = true;
                return Err(error);
            }
            self.last_sync = Instant::now();
            self.unsynced = false;
        }
        Ok(())
    }
}

fn repair_torn_tail(file: &mut File) -> io::Result<()> {
    let length = file.metadata()?.len();
    if length == 0 {
        return Ok(());
    }
    file.seek(SeekFrom::Start(length - 1))?;
    let mut last = [0u8; 1];
    file.read_exact(&mut last)?;
    if last == [b'\n'] {
        return Ok(());
    }
    let mut end = length;
    loop {
        let start = end.saturating_sub(REPAIR_BLOCK_BYTES);
        file.seek(SeekFrom::Start(start))?;
        let mut bytes = vec![0; usize::try_from(end - start).map_err(io::Error::other)?];
        file.read_exact(&mut bytes)?;
        if let Some(newline) = bytes.iter().rposition(|byte| *byte == b'\n') {
            file.set_len(start + newline as u64 + 1)?;
            return file.sync_all();
        }
        if start == 0 {
            file.set_len(0)?;
            return file.sync_all();
        }
        end = start;
    }
}

fn sync_parent_dir(path: &Path) -> io::Result<()> {
    let parent = path.parent().ok_or_else(|| io::Error::other("path has no parent"))?;
    File::open(parent)?.sync_all()
}

fn parse_map_entry(bytes: &[u8], fallback: u32) -> Option<(u32, String, String)> {
    let value: serde_json::Value = serde_json::from_slice(bytes).ok()?;
    let number = value
        .get("source")
        .and_then(serde_json::Value::as_u64)
        .and_then(|number| u32::try_from(number).ok())
        .unwrap_or(fallback);
    Some((
        number,
        value.get("path")?.as_str()?.to_owned(),
        value.get("identity")?.as_str()?.to_owned(),
    ))
}

/// Read every entry once, at open. A torn or invalid last line is what a kill mid-write leaves:
/// it is cut and every earlier entry kept. An invalid line before the last fails the open.
/// Returns the entries and the next number.
fn read_map_entries(file: &mut File) -> io::Result<(MapEntries, u32)> {
    file.seek(SeekFrom::Start(0))?;
    let mut reader = BufReader::new(&mut *file);
    let mut entries = HashMap::new();
    let mut next = 0u32;
    let mut ordinal = 0u32;
    let mut at = 0u64;
    let mut invalid_at = None;
    let mut line = Vec::new();
    loop {
        line.clear();
        let count = reader.read_until(b'\n', &mut line)?;
        if count == 0 {
            break;
        }
        if invalid_at.is_some() {
            return Err(invalid("invalid raw map entry before its last line"));
        }
        // Entries written before the map carried numbers take their line's ordinal.
        match parse_map_entry(line.as_slice(), ordinal) {
            Some((number, path, identity)) => {
                entries.entry((path, identity)).or_insert(number);
                next = number.checked_add(1).ok_or_else(|| invalid("raw map is full"))?;
            }
            None => invalid_at = Some(at),
        }
        at = at.checked_add(count as u64).ok_or_else(|| invalid("raw map offset overflow"))?;
        ordinal = ordinal.checked_add(1).ok_or_else(|| invalid("raw map is full"))?;
    }
    drop(reader);
    if let Some(start) = invalid_at {
        file.set_len(start)?;
        file.sync_all()?;
    }
    Ok((entries, next))
}

/// The start of the raw file's last line, walking back from `end` no further than `floor`.
/// `floor` is a line start, so it is the answer when no newline lies past it. The walk costs
/// at most the last line's length.
fn last_line_start(file: &mut File, end: u64, floor: u64) -> io::Result<u64> {
    // The byte before `end` is the last line's own newline.
    let mut at = end.saturating_sub(1);
    while at > floor {
        let start = at.saturating_sub(REPAIR_BLOCK_BYTES).max(floor);
        file.seek(SeekFrom::Start(start))?;
        let mut block = vec![0; usize::try_from(at - start).map_err(io::Error::other)?];
        file.read_exact(&mut block)?;
        if let Some(newline) = block.iter().rposition(|byte| *byte == b'\n') {
            return Ok(start + newline as u64 + 1);
        }
        at = start;
    }
    Ok(floor)
}

/// The `(seq, start)` marks `append` would have written that the index lacks, after a kill
/// between the raw write and the index write or a torn last mark. It reads from the last good
/// mark forward only, and reads at most the last line when no mark is missing. With no mark the
/// first line's seq comes from `next_seq` and the file's line count.
fn missing_index_marks(
    file: &mut File,
    end: u64,
    last_mark: Option<(u64, u64)>,
    next_seq: u64,
) -> io::Result<Vec<(u64, u64)>> {
    let from = last_mark.map_or(0, |(_, mark)| mark);
    // No line past `from` can need a mark until the file holds a mark's spacing past it.
    if end.saturating_sub(from) < RAW_INDEX_BYTES {
        return Ok(Vec::new());
    }
    // A marked line may be long; if it is the last line, the next one is not written yet.
    if last_mark.is_some() && last_line_start(file, end, from)? == from {
        return Ok(Vec::new());
    }
    let mut marks = Vec::new();
    let mut last = from;
    let mut line_start = from;
    let mut ordinal = 0u64;
    let mut at = from;
    let mut block = vec![0; usize::try_from(REPAIR_BLOCK_BYTES).map_err(io::Error::other)?];
    file.seek(SeekFrom::Start(from))?;
    while at < end {
        let count =
            usize::try_from((end - at).min(REPAIR_BLOCK_BYTES)).map_err(io::Error::other)?;
        let bytes = block.get_mut(..count).ok_or_else(|| invalid("index rebuild block"))?;
        file.read_exact(bytes)?;
        for (position, byte) in bytes.iter().enumerate() {
            if *byte != b'\n' {
                continue;
            }
            let line_end = at + position as u64 + 1;
            // The line at a good mark is marked already.
            let marked_already = last_mark.is_some() && ordinal == 0;
            if !marked_already && line_end - last >= RAW_INDEX_BYTES {
                marks.push((ordinal, line_start));
                last = line_start;
            }
            line_start = line_end;
            ordinal += 1;
        }
        at += count as u64;
    }
    let first_seq = match last_mark {
        Some((seq, _)) => seq,
        None => next_seq
            .checked_sub(ordinal)
            .ok_or_else(|| invalid("raw seq is below the file's line count"))?,
    };
    marks
        .into_iter()
        .map(|(ordinal, start)| {
            first_seq
                .checked_add(ordinal)
                .map(|seq| (seq, start))
                .ok_or_else(|| invalid("raw seq overflow"))
        })
        .collect()
}

/// Part of one line, from [`RawSource::read_at`]. `bytes` holds no newline.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Piece {
    pub bytes: Vec<u8>,
    /// The line ends where `bytes` ends.
    pub ends: bool,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct ReadStats {
    pub bytes: u64,
    pub scanned: u64,
    pub holds_bytes: u64,
    /// A complete line larger than `CHUNK_BYTES` is allowed by the source contract. These
    /// counters make that exception visible to the follow gate instead of hiding its allocation.
    pub oversized_lines: u64,
    pub oversized_bytes: u64,
}

/// An append-only file. No open or read walks to its last newline. The only retained
/// scan state is the cursor and how far past it we have looked without a newline.
pub struct FileSource {
    file: File,
    identity: Vec<u8>,
    path: PathBuf,
    cursor: u64,
    looked: u64,
    stats: ReadStats,
}

impl FileSource {
    pub fn open(path: &Path) -> io::Result<Self> {
        let file = File::open(path)?;
        let path = path.canonicalize()?;
        let mut identity = String::from("file:");
        use std::fmt::Write;
        for byte in path.as_os_str().as_encoded_bytes() {
            write!(&mut identity, "{byte:02x}").map_err(io::Error::other)?;
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            let metadata = file.metadata()?;
            write!(&mut identity, ":{}:{}", metadata.dev(), metadata.ino())
                .map_err(io::Error::other)?;
        }
        Ok(Self {
            file,
            identity: identity.into_bytes(),
            path,
            cursor: 0,
            looked: 0,
            stats: ReadStats::default(),
        })
    }

    pub fn stats(&self) -> ReadStats {
        self.stats
    }

    fn read_exact_at(&mut self, offset: u64, bytes: &mut [u8]) -> io::Result<()> {
        self.file.seek(SeekFrom::Start(offset))?;
        self.file.read_exact(bytes)?;
        self.stats.bytes = self.stats.bytes.saturating_add(bytes.len() as u64);
        Ok(())
    }
}

impl RawSource for FileSource {
    fn file_path(&self) -> Option<&Path> {
        Some(&self.path)
    }

    fn read_chunk(&mut self, place: u64) -> io::Result<Chunk> {
        let length = self.hint()?;
        let mut budget = CHUNK_BYTES;
        if place != self.cursor || length < self.looked {
            if !self.holds(place)? {
                return Err(invalid("raw cursor no longer exists"));
            }
            budget -= usize::from(place != 0);
            self.cursor = place;
            self.looked = place;
        }
        if place > length {
            return Err(invalid("raw cursor past file"));
        }
        if self.looked == length {
            return Ok(Chunk::with_stamp(
                Vec::new(),
                place,
                byte_places,
                true,
                length,
                self.stamp(),
            ));
        }
        let prefix = self.looked - place;
        let base = self.looked;
        let count =
            usize::try_from((length - base).min(budget as u64)).map_err(io::Error::other)?;
        let mut bytes = vec![0; count];
        self.read_exact_at(base, &mut bytes)?;
        // With an unfinished prefix, finish just that line. With none, return every
        // whole line in the chunk. No partial prefix is read again until it completes.
        let newline = if prefix != 0 {
            bytes.iter().position(|byte| *byte == b'\n')
        } else {
            bytes.iter().rposition(|byte| *byte == b'\n')
        };
        let scanned = if prefix != 0 { newline.map_or(count, |at| at + 1) } else { count };
        self.stats.scanned = self.stats.scanned.saturating_add(scanned as u64);
        self.looked = base + scanned as u64;
        let Some(newline) = newline else {
            return Ok(Chunk::with_stamp(
                Vec::new(),
                place,
                byte_places,
                self.looked == length,
                length,
                self.stamp(),
            ));
        };
        let end = base + newline as u64 + 1;
        if prefix != 0 {
            // Reconstitute the completed line in the same allocation. Oversized lines
            // allocate only here; every prior scan yielded to the actor's mailbox.
            let size = usize::try_from(end - place).map_err(io::Error::other)?;
            bytes.resize(size, 0);
            self.read_exact_at(place, &mut bytes)?;
            if size > CHUNK_BYTES {
                self.stats.oversized_lines = self.stats.oversized_lines.saturating_add(1);
                self.stats.oversized_bytes = self.stats.oversized_bytes.saturating_add(size as u64);
            }
        } else {
            bytes.truncate(newline + 1);
        }
        self.cursor = end;
        Ok(Chunk::with_stamp(
            bytes,
            place,
            byte_places,
            self.looked == length,
            length,
            self.stamp(),
        ))
    }

    fn holds(&mut self, place: u64) -> io::Result<bool> {
        if place > self.file.metadata()?.len() {
            return Ok(false);
        }
        if place == 0 {
            return Ok(true);
        }
        let mut byte = [0];
        self.read_exact_at(place - 1, &mut byte)?;
        self.stats.holds_bytes = self.stats.holds_bytes.saturating_add(1);
        Ok(byte == [b'\n'])
    }

    fn hint(&self) -> io::Result<u64> {
        Ok(self.file.metadata()?.len())
    }

    fn sync_through(&mut self, place: u64) -> io::Result<()> {
        if !self.holds(place)? {
            return Err(invalid("raw source has not reached this place"));
        }
        self.file.sync_all()
    }

    fn identity(&self) -> &[u8] {
        &self.identity
    }
    fn stamp(&self) -> u64 {
        1
    }

    fn read_at(&mut self, place: u64, offset: u64, max: usize) -> io::Result<Piece> {
        let length = self.hint()?;
        let at = place.checked_add(offset).ok_or_else(|| invalid("raw position overflow"))?;
        if at > length {
            return Err(invalid("a part of a line past the file"));
        }
        let count = usize::try_from((length - at).min(max as u64)).map_err(io::Error::other)?;
        let mut bytes = vec![0; count];
        self.read_exact_at(at, &mut bytes)?;
        let ends = match bytes.iter().position(|byte| *byte == b'\n') {
            Some(newline) => {
                bytes.truncate(newline);
                true
            }
            None => false,
        };
        Ok(Piece { bytes, ends })
    }
}

/// The identity and fixed-head proof for one followed transcript generation.
///
/// `size` is monotonic within a generation. A growth keeps the generation and only advances
/// `size`; a replacement, shrink, or changed head is a new generation and must be handled by the
/// actor's rebuild path before it translates another line.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct FileGeneration {
    pub dev: u64,
    pub ino: u64,
    pub size: u64,
    /// Number of initial bytes covered by the fixed-head proof. Keeping this fixed across
    /// appends avoids treating growth of a short file as a rewrite of its head.
    pub head_len: u64,
    pub head: u64,
    pub head_fixed: bool,
}

impl FileGeneration {
    fn stamp(self) -> u64 {
        let mut hash = 0xcbf2_9ce4_8422_2325u64;
        let values =
            if self.head_fixed { [self.dev, self.ino, self.head] } else { [self.dev, self.ino, 0] };
        for value in values {
            for byte in value.to_le_bytes() {
                hash = (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3);
            }
        }
        hash
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GenerationChange {
    Unchanged,
    Appended { size: u64 },
    Replaced,
    Rewritten,
}

/// An append-following file source. The held descriptor remains the source of bytes; the path is
/// sampled only for the bounded generation proof. A changed generation returns an error before a
/// chunk is handed to the actor, so the actor cannot translate bytes from two files as one chat.
pub struct FollowFileSource {
    inner: FileSource,
    generation: FileGeneration,
}

impl FollowFileSource {
    pub fn open(path: &Path) -> io::Result<Self> {
        let mut inner = FileSource::open(path)?;
        let (path_identity, generation) = inner.generation_proof(None)?;
        if path_identity != (generation.dev, generation.ino) {
            return Err(io::Error::new(
                io::ErrorKind::Interrupted,
                "transcript changed during generation read",
            ));
        }
        Ok(Self { inner, generation })
    }

    pub fn generation(&self) -> FileGeneration {
        self.generation
    }

    pub fn stats(&self) -> ReadStats {
        self.inner.stats()
    }

    /// Compare the path's bounded generation proof with the last one observed. Appends are
    /// accepted and advance the monotonic size; every other mutation is returned to the caller.
    pub fn check_generation(&mut self) -> io::Result<GenerationChange> {
        let previous = self.generation;
        let (path_identity, current) = self.inner.generation_proof(Some(previous))?;
        if path_identity != (previous.dev, previous.ino)
            || current.dev != previous.dev
            || current.ino != previous.ino
        {
            return Ok(GenerationChange::Replaced);
        }
        if current.size < previous.size {
            return Ok(GenerationChange::Replaced);
        }
        if previous.head_fixed && current.head != previous.head {
            return Ok(GenerationChange::Rewritten);
        }
        if current.size > previous.size || current.head_fixed != previous.head_fixed {
            self.generation = current;
            return Ok(GenerationChange::Appended { size: current.size });
        }
        Ok(GenerationChange::Unchanged)
    }

    fn ensure_generation(&mut self) -> io::Result<()> {
        match self.check_generation()? {
            GenerationChange::Unchanged | GenerationChange::Appended { .. } => Ok(()),
            GenerationChange::Replaced => Err(invalid("follow transcript generation replaced")),
            GenerationChange::Rewritten => Err(invalid("follow transcript generation rewritten")),
        }
    }
}

impl RawSource for FollowFileSource {
    fn read_chunk(&mut self, place: u64) -> io::Result<Chunk> {
        let chunk = self.inner.read_chunk(place)?;
        self.ensure_generation()?;
        Ok(Chunk::with_stamp(
            chunk.bytes,
            chunk.base,
            chunk.places,
            chunk.at_end,
            chunk.hint,
            self.stamp(),
        ))
    }

    fn holds(&mut self, place: u64) -> io::Result<bool> {
        let held = self.inner.holds(place)?;
        self.ensure_generation()?;
        Ok(held)
    }

    fn hint(&self) -> io::Result<u64> {
        self.inner.hint()
    }

    fn sync_through(&mut self, place: u64) -> io::Result<()> {
        self.inner.sync_through(place)?;
        self.ensure_generation()
    }

    fn identity(&self) -> &[u8] {
        self.inner.identity()
    }

    fn stamp(&self) -> u64 {
        self.generation.stamp()
    }

    fn file_path(&self) -> Option<&Path> {
        self.inner.file_path()
    }

    fn read_at(&mut self, place: u64, offset: u64, max: usize) -> io::Result<Piece> {
        let piece = self.inner.read_at(place, offset, max)?;
        self.ensure_generation()?;
        Ok(piece)
    }
}

impl FileSource {
    /// Take one bounded proof from the path and the held descriptor. The path is only stat'ed;
    /// all bytes come from the descriptor that the source already owns.
    fn generation_proof(
        &mut self,
        previous: Option<FileGeneration>,
    ) -> io::Result<((u64, u64), FileGeneration)> {
        let path = std::fs::metadata(&self.path)?;
        let held = self.file.metadata()?;
        let (dev, ino) = file_identity(&held);
        let size = held.len();
        let (head_fixed, head_len, head) = if let Some(previous) = previous {
            if previous.head_fixed && size >= previous.head_len {
                let head_len = previous.head_len.min(size);
                let mut bytes = vec![0; usize::try_from(head_len).map_err(io::Error::other)?];
                self.read_exact_at(0, &mut bytes)?;
                (true, head_len, fnv1a(&bytes))
            } else {
                self.read_head(size)?
            }
        } else {
            self.read_head(size)?
        };
        Ok((file_identity(&path), FileGeneration { dev, ino, size, head_len, head, head_fixed }))
    }

    fn read_head(&mut self, size: u64) -> io::Result<(bool, u64, u64)> {
        let count = size.min(4096);
        let mut bytes = vec![0; usize::try_from(count).map_err(io::Error::other)?];
        if !bytes.is_empty() {
            self.read_exact_at(0, &mut bytes)?;
        }
        let fixed_len = bytes
            .iter()
            .position(|byte| *byte == b'\n')
            .map(|at| at.saturating_add(1))
            .or_else(|| (count == 4096).then_some(4096));
        let Some(head_len) = fixed_len else {
            return Ok((false, 0, 0));
        };
        Ok((true, head_len as u64, fnv1a(bytes.get(..head_len).unwrap_or_default())))
    }
}

fn fnv1a(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325u64, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x0100_0000_01b3)
    })
}

#[cfg(unix)]
fn file_identity(metadata: &std::fs::Metadata) -> (u64, u64) {
    use std::os::unix::fs::MetadataExt;
    (metadata.dev(), metadata.ino())
}

#[cfg(not(unix))]
fn file_identity(metadata: &std::fs::Metadata) -> (u64, u64) {
    (0, metadata.len())
}

#[cfg(test)]
#[path = "source_follow_gates.rs"]
mod follow_gates;

#[cfg(test)]
#[path = "raw_append_cost_bench.rs"]
mod raw_append_cost_bench;

#[cfg(test)]
#[path = "source_tests.rs"]
mod tests;
