//! The files of one book, and the one value that reads and writes them.
//!
//! ```text
//! <chat>/book/
//!   rows/000001.seg ...   `ABSG` + version, then settled rows in settle order; a segment closes at 64 MB
//!   rows.idx              16-byte entries by rowId: segment, offset, length, rev; mapped
//!   seq.idx               every 256th settle seq to its segment and offset
//!   blobs/<rowId>         bodies over 16 KB
//!   checkpoint            under 64 KB plus 32 bytes per waiting prompt, written atomically
//!   raw.map               the chat's raw files by number, append-only
//!   lock                  held by the book's one owner
//! ```
//!
//! **Two orders.** `seq` orders changes: every append and every patch takes the next one, and a
//! cursor follows it. `rowId` orders the book: what the page draws. They differ only near a live
//! tail, where a tool that began first may settle last. The segments are in seq order;
//! `rows.idx` gives the book order.
//!
//! **What each call costs.** [`Log::append_settled`] and [`Log::patch`] write one record (one
//! `write`) and one index entry: the row's length, whatever the book holds. [`Log::window`] and
//! [`Log::page`] read index entries only and return byte ranges ([`RowRef`]) of stored row text;
//! [`Log::fill`] copies those ranges out with one read per run of neighbouring records, and a
//! page is always one read. [`Log::since`] starts at the `seq.idx` entry before the cursor and
//! reads what was missed. [`Log::open`] reads the checkpoint and the records written after it.
//! None of them parses a row, and none holds more than a record, an index page or a reply in
//! memory.
//!
//! **Durability.** A record is in the kernel when `append_settled` returns, so a kill of every
//! process keeps it. [`Log::sync`] (for an `act` acknowledgement) and [`Log::write_checkpoint`]
//! put it on the disk. A kill mid-write leaves an incomplete record at the end of the last
//! segment; [`Log::open`] cuts it off (`set_len`). After the checkpoint, an incomplete record,
//! a bad check or a range beyond its raw source cuts that record and every later segment.
//! Replay from raw reconstructs the suffix; none of these cuts requires a rebuild.
//!
//! **The indexes are derived.** With a checkpoint, `open` re-applies the records after it (the
//! index writes before it were synced first). With none, it rebuilds both indexes from the
//! segments. A row range is checked against its record's header when it is read, so an index
//! entry left by power loss is repaired before replay. Every patch is synced before its
//! entry is published; a later mismatch names the damaged row and never serves another row.

#[cfg(test)]
mod actor_recovery_tests;
mod checkpoint;
mod index;
mod read;
mod record;
mod recover;

pub use checkpoint::{
    CheckpointHead, MAX_CHECKPOINT, MAX_CHECKPOINT_STATE, MAX_PROMPTS,
    OVERHEAD as CHECKPOINT_OVERHEAD, PROMPT_BYTES, Sections, StateWriter, section, sections,
};
pub use index::ROW_ENTRY_LEN;
pub use read::{
    Anchor, Edge, MAX_FRAME_BYTES, MAX_PAGE_BYTES, MAX_ROWS, RowRef, Side, Since, Window,
};
pub use record::{HEADER_LEN, RECORD_OVERHEAD};

use crate::fsio;
use crate::row::MAX_ROW_TEXT;
use checkpoint::Mark;
use index::{Entry, RowIndex, SeqIndex};
use std::fs::{self, File, OpenOptions, TryLockError};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

/// A segment closes when the next record would take it past this.
pub const SEGMENT_BYTES: u64 = 64 * 1024 * 1024;
/// The segment preamble (`magic u32 | version u32`).
pub const SEGMENT_HEADER_LEN: u64 = 8;
const SEGMENT_MAGIC: u32 = u32::from_le_bytes(*b"ABSG");
const SEGMENT_VERSION: u32 = 1;
/// `seq.idx` has an entry for every seq that is a multiple of this.
pub const SEQ_STRIDE: u64 = 256;
/// The most segment files kept open for reading besides the last one.
const MAX_READERS: usize = 4;
/// How long `open` waits for the book's lock before it is [`Error::Busy`]: 100 tries, 2 ms apart.
const LOCK_TRIES: u32 = 100;
const LOCK_WAIT: std::time::Duration = std::time::Duration::from_millis(2);
/// The most bytes one [`Log::read_blob`] returns.
pub const MAX_BLOB_READ: usize = 1024 * 1024;
const UNDO_HEAD_LEN: usize = 16;
const UNDO_ENTRY_LEN: usize = 28;

/// The source places that fed a settled row. `file == 0` and `len == 0` mean the daemon made the
/// row itself (for example a queued prompt or a notice).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RawRange {
    /// The one-based line number in `raw.map`, or 0 when there are no raw bytes.
    pub file: u32,
    /// The exact first source place (a byte offset for files, a seq for v1).
    pub off: u64,
    /// The span in source places. `u32::MAX` means the end is not recorded: the span
    /// exceeds `u32::MAX - 1`. Recovery cannot check that end against the source.
    /// Zero for a daemon-created row.
    pub len: u32,
}

impl RawRange {
    pub const NONE: RawRange = RawRange { file: 0, off: 0, len: 0 };
}

/// One revision in a batch caused by a single raw line. A batch syncs all its records once,
/// before publishing any of its index entries.
#[derive(Clone, Copy, Debug)]
pub struct Patch<'a> {
    pub row_id: u64,
    pub rev: u32,
    pub raw: RawRange,
    pub text: &'a [u8],
}

/// What can go wrong.
#[derive(Debug)]
pub enum Error {
    Io(io::Error),
    /// Another value (in this process or another) holds the book's lock.
    Busy,
    /// A row text must be 1 to 16384 bytes.
    RowText {
        len: usize,
    },
    /// A rowId is never 0.
    ZeroRowId,
    /// `append_settled` for a row that has already settled; a change to it is a `patch`.
    AlreadySettled {
        row_id: u64,
    },
    /// `patch` for a row that has not settled.
    NotSettled {
        row_id: u64,
    },
    /// `patch` with a rev that is not above the row's.
    StaleRev {
        row_id: u64,
        have: u32,
        got: u32,
    },
    /// The checkpoint exceeds its non-queue or total budget.
    CheckpointTooLarge {
        bytes: usize,
    },
    /// The files do not agree with each other. The book is derived from the raw file: the
    /// owner deletes the book and translates it again.
    Corrupt(&'static str),
    /// The caller supplied a value that cannot describe a book record or checkpoint.
    InvalidInput(&'static str),
    /// A derived entry is damaged; callers can still serve the book's other rows.
    CorruptRow {
        row_id: u64,
        reason: &'static str,
    },
    /// A segment's magic or version is not understood. The book must be rebuilt from raw; this
    /// is never treated as a torn tail.
    Rebuild(&'static str),
    /// A write left the in-memory value unable to prove that its files agree. Reopen it before
    /// accepting another append.
    Stopped,
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Io(error) => write!(f, "book: {error}"),
            Error::Busy => write!(f, "book: another owner holds its lock"),
            Error::RowText { len } => {
                write!(f, "book: a row text of {len} bytes (it must be 1 to 16384)")
            }
            Error::ZeroRowId => write!(f, "book: a rowId is never 0"),
            Error::AlreadySettled { row_id } => write!(f, "book: row {row_id} has already settled"),
            Error::NotSettled { row_id } => write!(f, "book: row {row_id} has not settled"),
            Error::StaleRev { row_id, have, got } => {
                write!(f, "book: row {row_id} is at rev {have}; a patch to rev {got} is not newer")
            }
            Error::CheckpointTooLarge { bytes } => {
                write!(f, "book: a checkpoint of {bytes} bytes (it must be under 65536)")
            }
            Error::Corrupt(what) => write!(f, "book: {what}"),
            Error::InvalidInput(what) => write!(f, "book: invalid input: {what}"),
            Error::CorruptRow { row_id, reason } => write!(f, "book: row {row_id}: {reason}"),
            Error::Rebuild(what) => write!(f, "book: rebuild this book from raw ({what})"),
            Error::Stopped => write!(f, "book: a write failed; open the book again"),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Io(error) => Some(error),
            _ => None,
        }
    }
}

impl From<io::Error> for Error {
    fn from(error: io::Error) -> Error {
        Error::Io(error)
    }
}

/// How a log is opened.
#[derive(Clone, Copy, Debug)]
pub struct Options {
    /// A segment closes when the next record would take it past this. [`SEGMENT_BYTES`] outside
    /// tests.
    pub segment_bytes: u64,
}

impl Default for Options {
    fn default() -> Options {
        Options { segment_bytes: SEGMENT_BYTES }
    }
}

/// What [`Log::open`] found.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Recovered {
    /// Zero with no checkpoint; otherwise the independently checked head's edition.
    pub edition: u32,
    /// The state bytes of the checkpoint (the actor's); empty when there was none.
    pub state: Vec<u8>,
    /// Whether a checkpoint was read. Without one the indexes were rebuilt from the segments.
    pub checkpoint: bool,
    /// The records read after the checkpoint (all of them when there was none).
    pub replayed: u64,
    /// Bytes cut from the failed record and all later segments; 0 after a clean stop.
    pub truncated: u64,
    /// Segment record bytes read at open, excluding the fixed segment preambles.
    pub scanned_bytes: u64,
    /// Raw map boundary recorded by the checkpoint. The actor replays complete lines after it.
    pub raw_files: u32,
    pub raw_map_len: u64,
}

/// Reads the durable envelope without opening derived indexes, for rebuild provenance.
pub fn saved_checkpoint(dir: &Path) -> Result<Option<Recovered>, Error> {
    let file = match File::open(dir.join("checkpoint")) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    let mut bytes = Vec::new();
    file.take(MAX_CHECKPOINT as u64 + 1).read_to_end(&mut bytes)?;
    let Some((mark, state, _)) = checkpoint::decode(&bytes) else { return Ok(None) };
    Ok(Some(Recovered {
        edition: mark.edition,
        state: state.to_vec(),
        checkpoint: true,
        raw_files: mark.raw_files,
        raw_map_len: mark.raw_map_len,
        ..Recovered::default()
    }))
}

/// Counters of what the log did since it was opened. Gauges for the `status` stream.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Stats {
    /// Bytes written to the segments, the indexes, the checkpoint and the blobs.
    pub bytes_written: u64,
    /// Write calls for those bytes.
    pub writes: u64,
    /// Bytes read from the segments and the blobs.
    pub bytes_read: u64,
    /// Read calls for those bytes.
    pub reads: u64,
    /// Syncs of a file.
    pub syncs: u64,
    /// Checkpoints written.
    pub checkpoints: u64,
    /// The address space `rows.idx` is mapped into (resident memory is only the pages touched).
    pub index_mapped_bytes: u64,
    /// Segment files held open for reading (at most 4), besides the last segment.
    pub open_readers: u64,
}

struct Tail {
    seg: u32,
    file: File,
    len: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct UndoHead {
    edition: u32,
    seg: u32,
    off: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct UndoEntry {
    row_id: u64,
    entry: Entry,
}

fn undo_head_for(mark: Mark) -> UndoHead {
    UndoHead {
        edition: mark.edition,
        seg: mark.seg,
        off: u32::try_from(mark.off).unwrap_or(u32::MAX),
    }
}

fn encode_undo_head(head: UndoHead, out: &mut [u8; UNDO_HEAD_LEN]) {
    out[..4].copy_from_slice(&head.edition.to_le_bytes());
    out[4..8].copy_from_slice(&head.seg.to_le_bytes());
    out[8..12].copy_from_slice(&head.off.to_le_bytes());
    let crc = crc32fast::hash(&out[..12]);
    out[12..16].copy_from_slice(&crc.to_le_bytes());
}

fn decode_undo_head(bytes: &[u8]) -> Option<UndoHead> {
    let edition = record::le_u32(bytes, 0)?;
    let seg = record::le_u32(bytes, 4)?;
    let off = record::le_u32(bytes, 8)?;
    let crc = record::le_u32(bytes, 12)?;
    (crc32fast::hash(bytes.get(..12)?) == crc).then_some(UndoHead { edition, seg, off })
}

fn encode_undo_entry(entry: UndoEntry, out: &mut [u8; UNDO_ENTRY_LEN]) {
    out[..8].copy_from_slice(&entry.row_id.to_le_bytes());
    out[8..12].copy_from_slice(&entry.entry.seg.to_le_bytes());
    out[12..16].copy_from_slice(&entry.entry.off.to_le_bytes());
    out[16..20].copy_from_slice(&entry.entry.len.to_le_bytes());
    out[20..24].copy_from_slice(&entry.entry.rev.to_le_bytes());
    let crc = crc32fast::hash(&out[..24]);
    out[24..28].copy_from_slice(&crc.to_le_bytes());
}

fn decode_undo_entry(bytes: &[u8]) -> Option<UndoEntry> {
    let crc = record::le_u32(bytes, 24)?;
    if crc32fast::hash(bytes.get(..24)?) != crc {
        return None;
    }
    Some(UndoEntry {
        row_id: record::le_u64(bytes, 0)?,
        entry: Entry {
            seg: record::le_u32(bytes, 8)?,
            off: record::le_u32(bytes, 12)?,
            len: record::le_u32(bytes, 16)?,
            rev: record::le_u32(bytes, 20)?,
        },
    })
}

fn read_undo(
    file: &File,
    expected: Option<UndoHead>,
) -> Result<(Option<UndoHead>, Vec<UndoEntry>), Error> {
    let len = file.metadata()?.len();
    let clear = |file: &File| -> Result<(), Error> {
        if file.metadata()?.len() != 0 {
            file.set_len(0)?;
            fsio::sync(file)?;
        }
        Ok(())
    };
    if len == 0 {
        return Ok((None, Vec::new()));
    }
    let mut head_bytes = [0u8; UNDO_HEAD_LEN];
    if len < UNDO_HEAD_LEN as u64 || fsio::read_at(file, &mut head_bytes, 0)? != head_bytes.len() {
        clear(file)?;
        return Ok((None, Vec::new()));
    }
    let Some(head) = decode_undo_head(&head_bytes) else {
        clear(file)?;
        return Ok((None, Vec::new()));
    };
    if expected != Some(head) {
        clear(file)?;
        return Ok((None, Vec::new()));
    }
    let mut entries = Vec::new();
    let mut at = UNDO_HEAD_LEN as u64;
    let mut bytes = [0u8; UNDO_ENTRY_LEN];
    while at.saturating_add(UNDO_ENTRY_LEN as u64) <= len {
        if fsio::read_at(file, &mut bytes, at)? != bytes.len() {
            break;
        }
        let Some(entry) = decode_undo_entry(&bytes) else { break };
        entries.push(entry);
        at = at.saturating_add(UNDO_ENTRY_LEN as u64);
    }
    if at != len {
        file.set_len(at)?;
        fsio::sync(file)?;
    }
    Ok((Some(head), entries))
}

#[cfg(test)]
struct FailAfter<'a> {
    file: &'a File,
    remaining: usize,
}

#[cfg(test)]
impl Write for FailAfter<'_> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if self.remaining == 0 {
            return Err(io::Error::other("injected short write"));
        }
        let amount = self.remaining.min(bytes.len());
        let written = self.file.write(&bytes[..amount])?;
        self.remaining = self.remaining.saturating_sub(written);
        Ok(written)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.file.flush()
    }
}

/// One book's log. The chat actor owns it and is its only writer; a second `open` of the same
/// directory fails with [`Error::Busy`] until this value is dropped.
pub struct Log {
    staging: bool,
    edition: u32,
    dir: PathBuf,
    rows_dir: PathBuf,
    raw_map: File,
    raw_files: u32,
    raw_map_len: u64,
    undo: File,
    checkpoint_mark: UndoHead,
    checkpoint_last_seq: u64,
    checkpoint_min_row: u64,
    checkpoint_max_row: u64,
    checkpoint_raw_files: u32,
    checkpoint_raw_map_len: u64,
    undo_head: Option<UndoHead>,
    options: Options,
    /// Held for the lock on it.
    _lock: File,
    tail: Tail,
    rows: RowIndex,
    seqs: SeqIndex,
    /// Older segments open for reading, the most recently used first.
    readers: Vec<(u32, File)>,
    /// The record being written; at most a row text and its 44 bytes.
    scratch: Vec<u8>,
    last_seq: u64,
    min_row: u64,
    max_row: u64,
    /// Whether the last segment has bytes that were not synced.
    unsynced: bool,
    /// Set when a failed record write could not be cut back, or an index write failed after
    /// its record: the files are only known to agree again after the next open.
    broken: bool,
    #[cfg(test)]
    cut_fail_after: Option<usize>,
    stats: Stats,
    #[cfg(test)]
    fail_after: Option<usize>,
}

fn segment_path(rows_dir: &Path, seg: u32) -> PathBuf {
    rows_dir.join(format!("{seg:06}.seg"))
}

/// Recover only the map suffix after the checkpoint; discard an incomplete last line before
/// accepting another append, so two distinct file names can never be joined after a kill.
fn recover_raw_map(file: &File, mut files: u32, from: u64) -> Result<(u32, u64), Error> {
    let len = file.metadata()?.len();
    if len < from {
        return Err(Error::Corrupt("raw.map is shorter than its checkpoint"));
    }
    let mut offset = from;
    let mut complete = from;
    let mut buf = [0u8; 4096];
    loop {
        let read = fsio::read_at(file, &mut buf, offset)?;
        if read == 0 {
            break;
        }
        for (at, byte) in buf.iter().take(read).enumerate() {
            if *byte == b'\n' {
                files = files.checked_add(1).ok_or(Error::Corrupt("raw.map is full"))?;
                complete = offset.saturating_add(at as u64).saturating_add(1);
            }
        }
        offset = offset.saturating_add(read as u64);
    }
    if complete != len {
        file.set_len(complete)?;
        fsio::sync(file)?;
    }
    Ok((files, complete))
}

fn check_segment_header(file: &File) -> Result<(), Error> {
    let mut bytes = [0u8; 8];
    if fsio::read_at(file, &mut bytes, 0)? != bytes.len() {
        return Err(Error::Rebuild("a segment has no complete header"));
    }
    let mut magic_bytes = [0u8; 4];
    let mut version_bytes = [0u8; 4];
    magic_bytes.copy_from_slice(&bytes[..4]);
    version_bytes.copy_from_slice(&bytes[4..]);
    let magic = u32::from_le_bytes(magic_bytes);
    let version = u32::from_le_bytes(version_bytes);
    if magic != SEGMENT_MAGIC {
        return Err(Error::Rebuild("a segment has the wrong magic"));
    }
    if version != SEGMENT_VERSION {
        return Err(Error::Rebuild("a segment has an unknown version"));
    }
    Ok(())
}

fn write_segment_header(file: &mut File) -> io::Result<()> {
    file.write_all(&SEGMENT_MAGIC.to_le_bytes())?;
    file.write_all(&SEGMENT_VERSION.to_le_bytes())
}

/// The highest segment number in `rows_dir`; 0 when there is none.
fn last_segment(rows_dir: &Path) -> Result<u32, Error> {
    let mut highest = 0u32;
    let mut count = 0u32;
    for entry in fs::read_dir(rows_dir)? {
        let name = entry?.file_name();
        let number = name
            .to_str()
            .and_then(|name| name.strip_suffix(".seg"))
            .filter(|digits| digits.len() == 6 && digits.bytes().all(|byte| byte.is_ascii_digit()))
            .and_then(|digits| digits.parse::<u32>().ok());
        if let Some(number) = number.filter(|number| *number != 0) {
            highest = highest.max(number);
            count = count.saturating_add(1);
        }
    }
    if count != highest {
        return Err(Error::Corrupt("a segment file is missing"));
    }
    Ok(highest)
}

impl Log {
    /// Opens the book in `dir` (made if missing) and repairs its tail.
    ///
    /// Reads the checkpoint, then the records written after it: each is checked by its crc and
    /// its index entries are set again. The first failed record and all later segments are cut.
    /// The cost is one checkpoint interval, the same for a book of 40 rows and one of 2 million.
    /// With no checkpoint the indexes are rebuilt from every segment. An unreadable
    /// checkpoint requests a rebuild from raw; it never makes open scan all history.
    pub fn open(dir: &Path, options: Options) -> Result<(Log, Recovered), Error> {
        Self::open_with_raw_holds(dir, options, |_, _| Ok(true))
    }

    /// Checks each known raw range's end through a bounded question to its source.
    /// A false answer cuts the replayable suffix, just like a bad crc. Source I/O errors
    /// propagate without turning a failed read into a cut. The actor separately checks
    /// checkpoint cursors; no source needs to discover its whole-line end at open.
    pub fn open_with_raw_holds(
        dir: &Path,
        options: Options,
        holds: impl FnMut(u32, u64) -> io::Result<bool>,
    ) -> Result<(Log, Recovered), Error> {
        Self::open_with_raw_holds_mode(dir, options, holds, false)
    }

    /// Opens an unserved rebuild. Only this mode accepts edition-zero checkpoints.
    pub fn open_staging(
        dir: &Path,
        options: Options,
        holds: impl FnMut(u32, u64) -> io::Result<bool>,
    ) -> Result<(Log, Recovered), Error> {
        Self::open_with_raw_holds_mode(dir, options, holds, true)
    }

    fn open_with_raw_holds_mode(
        dir: &Path,
        options: Options,
        mut holds: impl FnMut(u32, u64) -> io::Result<bool>,
        staging: bool,
    ) -> Result<(Log, Recovered), Error> {
        let rows_dir = dir.join("rows");
        fs::create_dir_all(&rows_dir)?;
        fs::create_dir_all(dir.join("blobs"))?;
        let raw_map = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(dir.join("raw.map"))?;
        let undo = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(dir.join("rows.undo"))?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(dir.join("lock"))?;
        // The lock belongs to the open file, and a process this one is starting holds a copy of
        // every open file from its fork until its exec. So a book closed a moment ago can still
        // look held for that long: wait it out before saying another owner has it.
        let mut tries = 0u32;
        loop {
            match lock.try_lock() {
                Ok(()) => break,
                Err(TryLockError::WouldBlock) if tries < LOCK_TRIES => {
                    tries = tries.saturating_add(1);
                    std::thread::sleep(LOCK_WAIT);
                }
                Err(TryLockError::WouldBlock) => return Err(Error::Busy),
                Err(TryLockError::Error(error)) => return Err(Error::Io(error)),
            }
        }

        let mut stats = Stats::default();
        let saved_bytes = match File::open(dir.join("checkpoint")) {
            Ok(file) => {
                let mut bytes = Vec::new();
                file.take(MAX_CHECKPOINT as u64 + 1).read_to_end(&mut bytes)?;
                Some(bytes)
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => None,
            Err(error) => return Err(Error::Io(error)),
        };
        let saved = match saved_bytes.as_deref() {
            Some(bytes) => Some(
                checkpoint::decode(bytes)
                    .filter(|(mark, _, _)| staging || mark.edition != 0)
                    .ok_or(Error::Rebuild("unreadable or uncommitted checkpoint"))?,
            ),
            None => None,
        };
        // With a checkpoint the last segment is found by stepping up from the checkpoint's (a
        // name or two), not by listing every segment: an open costs the same at any length.
        let mut last = match saved {
            Some((mark, _, _)) if mark.seg >= 1 && segment_path(&rows_dir, mark.seg).exists() => {
                let mut seg = mark.seg;
                while let Some(next) = seg.checked_add(1) {
                    if !segment_path(&rows_dir, next).exists() {
                        break;
                    }
                    seg = next;
                }
                seg
            }
            _ => last_segment(&rows_dir)?,
        };
        let saved = saved.filter(|(mark, _, _)| {
            // A checkpoint is of use only when the segment it points into is still that long.
            // The indexes must reach as far as it says they were synced, too (a deleted or
            // shortened index file is rebuilt, not trusted).
            let long = |name: &str, len: u64| {
                fs::metadata(dir.join(name)).is_ok_and(|meta| meta.len() >= len)
            };
            mark.seg >= 1
                && mark.seg <= last
                && fs::metadata(segment_path(&rows_dir, mark.seg))
                    .is_ok_and(|meta| meta.len() >= mark.off)
                && (mark.max_row == 0
                    || long("rows.idx", mark.max_row.saturating_add(1).saturating_mul(16)))
                && (mark.last_seq < SEQ_STRIDE
                    || long(
                        "seq.idx",
                        (mark.last_seq / SEQ_STRIDE).saturating_add(1).saturating_mul(8),
                    ))
                && mark.off >= SEGMENT_HEADER_LEN
        });
        let mut recovered = Recovered { checkpoint: saved.is_some(), ..Recovered::default() };
        let saved_checkpoint = saved.as_ref().map(|(saved_mark, _, _)| undo_head_for(*saved_mark));
        let mark = match saved {
            Some((mark, state, _)) => {
                recovered.state = state.to_vec();
                recovered.edition = mark.edition;
                recovered.raw_files = mark.raw_files;
                recovered.raw_map_len = mark.raw_map_len;
                mark
            }
            None => Mark {
                edition: 1,
                last_seq: 0,
                min_row: 0,
                max_row: 0,
                seg: 1,
                off: SEGMENT_HEADER_LEN,
                raw_files: 0,
                raw_map_len: 0,
            },
        };
        let (raw_files, raw_map_len) = recover_raw_map(&raw_map, mark.raw_files, mark.raw_map_len)?;
        let checkpoint_mark = undo_head_for(mark);
        let (undo_head, undo_entries) = read_undo(&undo, saved_checkpoint)?;
        let checkpoint_open_rows = saved.map_or(&[][..], |(_, _, ids)| ids);
        let rebuild = !recovered.checkpoint;
        let mut rows = RowIndex::open(&dir.join("rows.idx"), rebuild)?;
        let mut seqs = SeqIndex::open(&dir.join("seq.idx"), rebuild)?;

        let (mut last_seq, mut min_row, mut max_row) = (mark.last_seq, mark.min_row, mark.max_row);
        let (mut rewritten, mut rewrites) = (0u64, 0u64);
        // Retain only the checkpoint interval's identities. A rebuild without a checkpoint
        // streams the whole book without collecting its records in memory.
        let mut found_rows = std::collections::BTreeSet::new();
        let mut found_slots = std::collections::BTreeSet::new();
        for seg in mark.seg..=last {
            let path = segment_path(&rows_dir, seg);
            let mut file = OpenOptions::new().read(true).write(true).open(&path)?;
            let segment_len = file.metadata()?.len();
            if seg == last && segment_len < SEGMENT_HEADER_LEN {
                if segment_len >= 4 {
                    let mut magic = [0u8; 4];
                    fsio::read_at(&file, &mut magic, 0)?;
                    if magic != SEGMENT_MAGIC.to_le_bytes() {
                        return Err(Error::Rebuild("a segment has the wrong magic"));
                    }
                }
                file.set_len(0)?;
                file.seek(SeekFrom::Start(0))?;
                write_segment_header(&mut file)?;
                fsio::sync(&file)?;
                stats.syncs = stats.syncs.saturating_add(1);
            }
            check_segment_header(&file)?;
            let from = if seg == mark.seg { mark.off } else { SEGMENT_HEADER_LEN };
            let scan = recover::scan(&file, from, |offset, header| {
                if header.raw_len != 0 && (header.raw_file == 0 || header.raw_file > raw_files) {
                    return Err(Error::Corrupt("a record names a raw file absent from raw.map"));
                }
                if header.raw_len != 0 && header.raw_len != u32::MAX {
                    let Some(end) = header.raw_off.checked_add(u64::from(header.raw_len)) else {
                        return Ok(false);
                    };
                    if !holds(header.raw_file, end)? {
                        return Ok(false);
                    }
                }
                if last_seq.checked_add(1) != Some(header.seq) {
                    return Ok(false);
                }
                if u32::try_from(offset).is_err() {
                    return Ok(false);
                }
                let off =
                    u32::try_from(offset).map_err(|_| Error::Corrupt("a segment is past 4 GiB"))?;
                let entry = Entry { seg, off, len: header.len, rev: header.rev };
                if rows.get(header.row_id) != Some(entry) {
                    rewritten = rewritten.saturating_add(rows.set(header.row_id, entry)?);
                    rewrites = rewrites.saturating_add(1);
                } else {
                    // The bytes may have reached the index before the previous process died. It is
                    // still part of this replay and must be included in the next checkpoint's sync.
                    rows.mark_dirty();
                }
                if header.seq.is_multiple_of(SEQ_STRIDE) {
                    let slot = header.seq / SEQ_STRIDE;
                    if seqs.get(slot)? != Some((seg, off)) {
                        rewritten = rewritten.saturating_add(seqs.set(slot, seg, off)?);
                        rewrites = rewrites.saturating_add(1);
                    } else {
                        seqs.mark_dirty();
                    }
                }
                last_seq = header.seq;
                min_row = if min_row == 0 { header.row_id } else { min_row.min(header.row_id) };
                max_row = max_row.max(header.row_id);
                recovered.replayed = recovered.replayed.saturating_add(1);
                if recovered.checkpoint {
                    found_rows.insert(header.row_id);
                    if header.seq.is_multiple_of(SEQ_STRIDE) {
                        found_slots.insert(header.seq / SEQ_STRIDE);
                    }
                }
                Ok(true)
            })?;
            recovered.scanned_bytes = recovered.scanned_bytes.saturating_add(scan.bytes_read);
            if scan.torn {
                // Remove from the end, so a kill during this repair leaves contiguous
                // segments and the same failed record to discover on the next open.
                for later in ((seg + 1)..=last).rev() {
                    let path = segment_path(&rows_dir, later);
                    recovered.truncated =
                        recovered.truncated.saturating_add(fs::metadata(&path)?.len());
                    fs::remove_file(path)?;
                    fsio::sync_dir(&rows_dir)?;
                }
                let len = file.metadata()?.len();
                file.set_len(scan.end)?;
                fsio::sync(&file)?;
                stats.syncs = stats.syncs.saturating_add(1);
                recovered.truncated =
                    recovered.truncated.saturating_add(len.saturating_sub(scan.end));
                last = seg;
                break;
            }
        }

        // Only new settlements can outlive their records: every patch is synced first.
        // Repair the explicitly checkpointed open rows plus the new-id tail. Mapping growth
        // contributes at most one fixed 64-KB slab, independent of the book's history.
        if recovered.checkpoint {
            for undo in &undo_entries {
                if !found_rows.contains(&undo.row_id)
                    && rows.get(undo.row_id).is_some_and(|entry| {
                        entry.seg > checkpoint_mark.seg
                            || (entry.seg == checkpoint_mark.seg
                                && u64::from(entry.off) >= u64::from(checkpoint_mark.off))
                    })
                {
                    rewritten = rewritten.saturating_add(rows.set(undo.row_id, undo.entry)?);
                    rewrites = rewrites.saturating_add(1);
                }
            }
            for id in checkpoint_open_rows.chunks_exact(8) {
                let row_id = record::le_u64(id, 0).ok_or(Error::Corrupt("bad open row id"))?;
                if !found_rows.contains(&row_id) && rows.get(row_id).is_some() {
                    rewritten = rewritten.saturating_add(rows.clear(row_id)?);
                    rewrites = rewrites.saturating_add(1);
                }
            }
            let last_index_row = rows.max_row_id();
            let mut row_id = mark.max_row.saturating_add(1);
            while row_id <= last_index_row {
                if !found_rows.contains(&row_id) && rows.get(row_id).is_some() {
                    rewritten = rewritten.saturating_add(rows.clear(row_id)?);
                    rewrites = rewrites.saturating_add(1);
                }
                row_id = row_id.saturating_add(1);
            }
            let last_slot = seqs.max_slot();
            let mut slot = (mark.last_seq / SEQ_STRIDE).saturating_add(1);
            while slot <= last_slot {
                if !found_slots.contains(&slot) && seqs.get(slot)?.is_some() {
                    rewritten = rewritten.saturating_add(seqs.clear(slot)?);
                    rewrites = rewrites.saturating_add(1);
                }
                slot = slot.saturating_add(1);
            }
        }

        let tail = if last == 0 {
            let file = Self::create_segment(&rows_dir, 1)?;
            Tail { seg: 1, file, len: SEGMENT_HEADER_LEN }
        } else {
            let file =
                OpenOptions::new().read(true).append(true).open(segment_path(&rows_dir, last))?;
            let len = file.metadata()?.len();
            Tail { seg: last, file, len }
        };
        stats.index_mapped_bytes = rows.mapped_bytes();
        stats.bytes_written = rewritten;
        stats.writes = rewrites;
        let log = Log {
            staging,
            edition: mark.edition,
            dir: dir.to_path_buf(),
            rows_dir,
            raw_map,
            raw_files,
            raw_map_len,
            undo,
            checkpoint_mark,
            checkpoint_last_seq: mark.last_seq,
            checkpoint_min_row: mark.min_row,
            checkpoint_max_row: mark.max_row,
            checkpoint_raw_files: mark.raw_files,
            checkpoint_raw_map_len: mark.raw_map_len,
            undo_head,
            options,
            _lock: lock,
            tail,
            rows,
            seqs,
            readers: Vec::new(),
            scratch: Vec::new(),
            last_seq,
            min_row,
            max_row,
            unsynced: recovered.replayed != 0,
            broken: false,
            #[cfg(test)]
            cut_fail_after: None,
            stats,
            #[cfg(test)]
            fail_after: None,
        };
        Ok((log, recovered))
    }

    /// Discards the replay suffix and returns the files to the last checkpoint. The actor uses
    /// this when a source stamp or boot changed: its checkpoint state remains authoritative, so
    /// records translated under the old source must not survive under the new edition.
    pub fn cut_to_checkpoint(&mut self, open_rows: &[u64]) -> Result<(), Error> {
        if self.broken {
            return Err(Error::Stopped);
        }
        if self.tail.seg < self.checkpoint_mark.seg
            || (self.tail.seg == self.checkpoint_mark.seg
                && self.tail.len < u64::from(self.checkpoint_mark.off))
        {
            return Err(Error::Corrupt("checkpoint is past the log tail"));
        }
        let result = (|| {
            self.cut_step()?;
            let (_, undo_entries) = read_undo(&self.undo, Some(self.checkpoint_mark))?;
            // List this interval before removing any bytes. A covered patch with a lost undo
            // cannot be recovered from raw after the checkpoint cursor.
            let mut restored = std::collections::BTreeMap::new();
            for undo in &undo_entries {
                if undo.entry.seg < self.checkpoint_mark.seg
                    || (undo.entry.seg == self.checkpoint_mark.seg
                        && undo.entry.off < self.checkpoint_mark.off)
                {
                    restored.insert(undo.row_id, undo.entry);
                }
            }
            let mut seg = self.checkpoint_mark.seg;
            let mut offset = u64::from(self.checkpoint_mark.off);
            let mut header_bytes = [0; HEADER_LEN];
            while seg <= self.tail.seg {
                let count = self.read_segment(seg, offset, &mut header_bytes)?;
                if count == 0 {
                    seg = seg.saturating_add(1);
                    offset = SEGMENT_HEADER_LEN;
                    continue;
                }
                let header = record::Header::parse(&header_bytes)
                    .filter(|_| count == header_bytes.len())
                    .ok_or(Error::Rebuild("cut suffix has a damaged header"))?;
                if header.row_id <= self.checkpoint_max_row
                    && !open_rows.contains(&header.row_id)
                    && !restored.contains_key(&header.row_id)
                {
                    return Err(Error::Rebuild("cut patch has no trusted undo"));
                }
                offset = offset.saturating_add(header.record_len() as u64);
            }
            for (row_id, entry) in restored {
                if self.rows.get(row_id).is_some_and(|entry| {
                    entry.seg > self.checkpoint_mark.seg
                        || (entry.seg == self.checkpoint_mark.seg
                            && u64::from(entry.off) >= u64::from(self.checkpoint_mark.off))
                }) {
                    self.cut_step()?;
                    self.rows.set(row_id, entry)?;
                }
            }
            for row_id in open_rows {
                if *row_id != 0 && self.rows.get(*row_id).is_some() {
                    self.cut_step()?;
                    self.rows.clear(*row_id)?;
                }
            }
            let last_index_row = self.rows.max_row_id();
            let mut row_id = self.checkpoint_max_row.saturating_add(1);
            while row_id <= last_index_row {
                if self.rows.get(row_id).is_some() {
                    self.cut_step()?;
                    self.rows.clear(row_id)?;
                }
                row_id = row_id.saturating_add(1);
            }
            let last_slot = self.seqs.max_slot();
            let mut slot = (self.checkpoint_last_seq / SEQ_STRIDE).saturating_add(1);
            while slot <= last_slot {
                if self.seqs.get(slot)?.is_some() {
                    self.cut_step()?;
                    self.seqs.clear(slot)?;
                }
                slot = slot.saturating_add(1);
            }
            let rows_synced = self.rows.sync()?;
            let seqs_synced = self.seqs.sync()?;
            self.stats.syncs =
                self.stats.syncs.saturating_add(u64::from(rows_synced) + u64::from(seqs_synced));

            let old_last = self.tail.seg;
            if old_last == self.checkpoint_mark.seg {
                self.tail.file.set_len(u64::from(self.checkpoint_mark.off))?;
                fsio::sync(&self.tail.file)?;
                self.stats.syncs = self.stats.syncs.saturating_add(1);
                self.tail.len = u64::from(self.checkpoint_mark.off);
                self.tail.file.seek(SeekFrom::End(0))?;
            } else {
                let checkpoint_path = segment_path(&self.rows_dir, self.checkpoint_mark.seg);
                let checkpoint_file =
                    OpenOptions::new().read(true).append(true).open(&checkpoint_path)?;
                checkpoint_file.set_len(u64::from(self.checkpoint_mark.off))?;
                fsio::sync(&checkpoint_file)?;
                self.stats.syncs = self.stats.syncs.saturating_add(1);
                let old_file = std::mem::replace(&mut self.tail.file, checkpoint_file);
                drop(old_file);
                for seg in (self.checkpoint_mark.seg + 1)..=old_last {
                    let path = segment_path(&self.rows_dir, seg);
                    if path.exists() {
                        fs::remove_file(path)?;
                        fsio::sync_dir(&self.rows_dir)?;
                    }
                }
                self.tail.seg = self.checkpoint_mark.seg;
                self.tail.len = u64::from(self.checkpoint_mark.off);
            }
            self.raw_map.set_len(self.checkpoint_raw_map_len)?;
            fsio::sync(&self.raw_map)?;
            self.raw_map.seek(SeekFrom::End(0))?;
            self.raw_files = self.checkpoint_raw_files;
            self.raw_map_len = self.checkpoint_raw_map_len;
            self.undo.set_len(0)?;
            fsio::sync(&self.undo)?;
            self.undo_head = None;
            self.last_seq = self.checkpoint_last_seq;
            self.min_row = self.checkpoint_min_row;
            self.max_row = self.checkpoint_max_row;
            self.readers.clear();
            self.unsynced = false;
            Ok(())
        })();
        if result.is_err() {
            self.broken = true;
        }
        result
    }

    #[inline]
    fn cut_step(&mut self) -> Result<(), Error> {
        #[cfg(test)]
        if let Some(left) = &mut self.cut_fail_after {
            if *left == 0 {
                return Err(io::Error::other("injected cut mutation failure").into());
            }
            *left = left.saturating_sub(1);
        }
        Ok(())
    }

    #[cfg(test)]
    pub(crate) fn fail_cut_after(&mut self, writes: usize) {
        self.cut_fail_after = Some(writes);
    }

    fn create_segment(rows_dir: &Path, seg: u32) -> Result<File, Error> {
        let mut file = OpenOptions::new()
            .read(true)
            .append(true)
            .create_new(true)
            .open(segment_path(rows_dir, seg))?;
        write_segment_header(&mut file)?;
        fsio::sync(&file)?;
        fsio::sync_dir(rows_dir)?;
        file.seek(SeekFrom::End(0))?;
        Ok(file)
    }

    /// The seq of the last record; 0 for an empty book. A cursor at this seq has everything.
    pub fn last_seq(&self) -> u64 {
        self.last_seq
    }

    /// The lowest settled rowId; 0 for an empty book.
    pub fn min_row(&self) -> u64 {
        self.min_row
    }

    /// The highest settled rowId; 0 for an empty book.
    pub fn max_row(&self) -> u64 {
        self.max_row
    }

    /// The book's directory.
    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// What the log did since it was opened.
    pub fn stats(&self) -> Stats {
        Stats {
            index_mapped_bytes: self.rows.mapped_bytes(),
            open_readers: self.readers.len() as u64,
            ..self.stats
        }
    }

    /// Recovery has removed entries that can outlive their records. Remaining entries are
    /// checked against the record at read time; damage must not silently hide a settled row.
    fn entry(&self, row_id: u64) -> Option<Entry> {
        if self.broken {
            return None;
        }
        self.rows.get(row_id)
    }

    /// Where the newest text of row `row_id` is stored, when the row has settled.
    pub fn row(&self, row_id: u64) -> Option<RowRef> {
        self.entry(row_id).map(|entry| RowRef::of(row_id, 0, &entry))
    }

    /// Reads the raw range from a row's record header. Index entries intentionally stay 16
    /// bytes, so callers that got a row from a window or page ask for this small header read when
    /// they need the cold source location.
    pub fn raw_range(&mut self, row: &RowRef) -> Result<RawRange, Error> {
        let offset = u64::from(row.off).saturating_sub(record::HEADER_LEN_U64);
        let mut head = [0u8; HEADER_LEN];
        let read = match self.read_segment(row.seg, offset, &mut head) {
            Ok(read) => read,
            Err(Error::Io(error)) if error.kind() == io::ErrorKind::NotFound => {
                return Err(Error::CorruptRow {
                    row_id: row.row_id,
                    reason: "a row points to a missing segment",
                });
            }
            Err(error) => return Err(error),
        };
        if read != HEADER_LEN {
            return Err(Error::CorruptRow {
                row_id: row.row_id,
                reason: "a row points past its segment",
            });
        }
        let Some(header) = record::Header::parse(&head) else {
            return Err(Error::CorruptRow {
                row_id: row.row_id,
                reason: "a segment record is damaged",
            });
        };
        if header.row_id != row.row_id || header.rev != row.rev || header.len != row.len {
            return Err(Error::CorruptRow {
                row_id: row.row_id,
                reason: "a row index entry does not match its record",
            });
        }
        if header.raw_len != 0 && (header.raw_file == 0 || header.raw_file > self.raw_files) {
            return Err(Error::CorruptRow {
                row_id: row.row_id,
                reason: "a record names a raw file absent from raw.map",
            });
        }
        Ok(RawRange { file: header.raw_file, off: header.raw_off, len: header.raw_len })
    }

    /// Appends one line to `raw.map`, syncs it, and returns its one-based file number. A record
    /// may name this number only after this method returns.
    pub fn append_raw_file(&mut self, line: &[u8]) -> Result<u32, Error> {
        if self.broken {
            return Err(Error::Stopped);
        }
        if line.iter().any(|byte| *byte == b'\n' || *byte == b'\r') {
            return Err(Error::InvalidInput("a raw.map line contains a newline"));
        }
        let file = self.raw_files.checked_add(1).ok_or(Error::Corrupt("raw.map is full"))?;
        let result = (|| -> io::Result<()> {
            self.raw_map.seek(SeekFrom::End(0))?;
            self.raw_map.write_all(line)?;
            self.raw_map.write_all(b"\n")?;
            fsio::sync(&self.raw_map)
        })();
        if let Err(error) = result {
            self.broken = true;
            return Err(Error::Io(error));
        }
        self.raw_map_len = self.raw_map_len.saturating_add(line.len() as u64).saturating_add(1);
        self.raw_files = file;
        self.stats.bytes_written =
            self.stats.bytes_written.saturating_add(line.len() as u64).saturating_add(1);
        self.stats.writes = self.stats.writes.saturating_add(1);
        self.stats.syncs = self.stats.syncs.saturating_add(1);
        Ok(file)
    }

    /// Appends a row that has just settled; its seq. `text` is the row's wire text
    /// ([`crate::row::Row::encode`]); it is stored as it is and never parsed. `raw` must name a
    /// line already synced by [`Log::append_raw_file`] when it has bytes. Costs the row's length:
    /// one write to the segment and one index entry. A raw-backed record is in the kernel on
    /// return; a daemon-created record is synced before its index entry is written.
    pub fn append_settled(
        &mut self,
        row_id: u64,
        rev: u32,
        raw: RawRange,
        text: &[u8],
    ) -> Result<u64, Error> {
        if self.broken {
            return Err(Error::Stopped);
        }
        if row_id == 0 {
            return Err(Error::ZeroRowId);
        }
        if self.settled(row_id)?.is_some() {
            return Err(Error::AlreadySettled { row_id });
        }
        let (seq, entry) = self.append_record(row_id, rev, raw, text)?;
        if raw.len == 0
            && let Err(error) = self.sync()
        {
            self.broken = true;
            return Err(error);
        }
        self.index_record(row_id, seq, entry)?;
        Ok(seq)
    }

    /// Validate a settled row before accepting a replay or a patch. Open has already cleared
    /// stale entries; a mismatch here is damage. A new row needs no record read.
    fn settled(&mut self, row_id: u64) -> Result<Option<Entry>, Error> {
        // A row above every settled one has not settled, whatever the index holds: the common
        // append looks nothing up.
        let Some(entry) = self.entry(row_id).filter(|_| row_id <= self.max_row) else {
            return Ok(None);
        };
        let mut head = [0u8; HEADER_LEN];
        let read = match self.read_segment(entry.seg, u64::from(entry.off), &mut head) {
            Ok(read) => read,
            Err(Error::Io(error)) if error.kind() == io::ErrorKind::NotFound => {
                return Err(Error::CorruptRow {
                    row_id,
                    reason: "a row points to a missing segment",
                });
            }
            Err(error) => return Err(error),
        };
        let same = read == HEADER_LEN
            && record::Header::parse(&head).is_some_and(|header| {
                header.row_id == row_id && header.rev == entry.rev && header.len == entry.len
            });
        if !same {
            return Err(Error::CorruptRow {
                row_id,
                reason: "a row index entry does not match its record",
            });
        }
        Ok(Some(entry))
    }

    /// Appends a new rev of a settled row (a permission answered, a rewind); its seq. The old
    /// record stays where it is; the row index now points at this one. `raw` is the range of the
    /// line that caused the patch, or [`RawRange::NONE`] for a daemon-created change.
    pub fn patch(
        &mut self,
        row_id: u64,
        rev: u32,
        raw: RawRange,
        text: &[u8],
    ) -> Result<u64, Error> {
        self.patch_many(&[Patch { row_id, rev, raw, text }])?;
        Ok(self.last_seq)
    }

    /// Applies revisions from one raw line with one segment sync. Each row occurs once;
    /// invalid batches write nothing. A failed write stops the log until it is reopened.
    pub fn patch_many(&mut self, patches: &[Patch<'_>]) -> Result<(), Error> {
        if self.broken {
            return Err(Error::Stopped);
        }
        let mut seen = std::collections::BTreeSet::new();
        let mut previous = Vec::with_capacity(patches.len());
        for patch in patches {
            let Some(entry) = self.settled(patch.row_id)? else {
                return Err(Error::NotSettled { row_id: patch.row_id });
            };
            if patch.rev <= entry.rev {
                return Err(Error::StaleRev {
                    row_id: patch.row_id,
                    have: entry.rev,
                    got: patch.rev,
                });
            }
            if !seen.insert(patch.row_id) {
                return Err(Error::InvalidInput("a patch batch repeats a row"));
            }
            self.validate_record(patch.raw, patch.text)?;
            previous.push(UndoEntry { row_id: patch.row_id, entry });
        }
        if patches.is_empty() {
            return Ok(());
        }
        let result = (|| {
            let mut entries = Vec::with_capacity(patches.len());
            for patch in patches {
                entries.push(self.append_record(patch.row_id, patch.rev, patch.raw, patch.text)?);
            }
            self.append_undo(&previous)?;
            // Even raw-backed patches must be durable before overwriting an older entry.
            self.sync()?;
            fsio::sync(&self.undo)?;
            for (patch, (seq, entry)) in patches.iter().zip(entries) {
                self.index_record(patch.row_id, seq, entry)?;
            }
            Ok(())
        })();
        if result.is_err() {
            self.broken = true;
        }
        result
    }

    fn append_undo(&mut self, entries: &[UndoEntry]) -> Result<(), Error> {
        if entries.is_empty() {
            return Ok(());
        }
        if self.undo_head.is_none() {
            let mut head = [0u8; UNDO_HEAD_LEN];
            encode_undo_head(self.checkpoint_mark, &mut head);
            self.undo.seek(SeekFrom::End(0))?;
            self.undo.write_all(&head)?;
            self.undo_head = Some(self.checkpoint_mark);
        }
        let mut bytes = [0u8; UNDO_ENTRY_LEN];
        for entry in entries {
            encode_undo_entry(*entry, &mut bytes);
            self.undo.seek(SeekFrom::End(0))?;
            self.undo.write_all(&bytes)?;
        }
        Ok(())
    }

    fn validate_record(&self, raw: RawRange, text: &[u8]) -> Result<u32, Error> {
        if raw.len == 0 {
            if raw.file != 0 {
                return Err(Error::InvalidInput("a raw range with no bytes has a file number"));
            }
        } else if raw.file == 0 || raw.file > self.raw_files {
            return Err(Error::InvalidInput("a record names a raw file absent from raw.map"));
        }
        u32::try_from(text.len())
            .ok()
            .filter(|len| *len != 0 && text.len() <= MAX_ROW_TEXT)
            .ok_or(Error::RowText { len: text.len() })
    }

    fn append_record(
        &mut self,
        row_id: u64,
        rev: u32,
        raw: RawRange,
        text: &[u8],
    ) -> Result<(u64, Entry), Error> {
        if self.broken {
            return Err(Error::Stopped);
        }
        let len = self.validate_record(raw, text)?;
        let seq = self.last_seq.checked_add(1).ok_or(Error::Corrupt("the seq overflowed"))?;
        record::encode(&mut self.scratch, seq, row_id, rev, raw, text);
        let record_len = self.scratch.len() as u64;
        if self.tail.len != 0
            && self.tail.len.saturating_add(record_len) > self.options.segment_bytes
            && let Err(error) = self.roll()
        {
            self.broken = true;
            return Err(error);
        }
        let off =
            u32::try_from(self.tail.len).map_err(|_| Error::Corrupt("a segment is past 4 GiB"))?;
        #[cfg(test)]
        let fail_after = self.fail_after.take();
        #[cfg(test)]
        let write_result = match fail_after {
            Some(remaining) => {
                let mut writer = FailAfter { file: &self.tail.file, remaining };
                writer.write_all(&self.scratch)
            }
            None => (&self.tail.file).write_all(&self.scratch),
        };
        #[cfg(not(test))]
        let write_result = (&self.tail.file).write_all(&self.scratch);
        if let Err(error) = write_result {
            // Part of the record may be in the file. Cut it back to where it was, so the next
            // record does not follow a torn one.
            if self.tail.file.set_len(self.tail.len).is_err() {
                self.broken = true;
            }
            return Err(Error::Io(error));
        }
        // The record is in the segment: from here the log's place moves with it, whatever the
        // index writes below do (the next open sets a missed entry again).
        self.tail.len = self.tail.len.saturating_add(record_len);
        self.last_seq = seq;
        self.min_row = if self.min_row == 0 { row_id } else { self.min_row.min(row_id) };
        self.max_row = self.max_row.max(row_id);
        self.unsynced = true;
        self.stats.bytes_written = self.stats.bytes_written.saturating_add(record_len);
        self.stats.writes = self.stats.writes.saturating_add(1);
        Ok((seq, Entry { seg: self.tail.seg, off, len, rev }))
    }

    fn index_record(&mut self, row_id: u64, seq: u64, entry: Entry) -> Result<(), Error> {
        let (mut written, mut writes) = (0u64, 0u64);
        let indexed = self.rows.set(row_id, entry).and_then(|bytes| {
            written = written.saturating_add(bytes);
            writes = writes.saturating_add(1);
            if !seq.is_multiple_of(SEQ_STRIDE) {
                return Ok(());
            }
            let bytes = self.seqs.set(seq / SEQ_STRIDE, entry.seg, entry.off)?;
            written = written.saturating_add(bytes);
            writes = writes.saturating_add(1);
            Ok(())
        });
        self.stats.bytes_written = self.stats.bytes_written.saturating_add(written);
        self.stats.writes = self.stats.writes.saturating_add(writes);
        if let Err(error) = indexed {
            // The record is in the segment but not in an index. No checkpoint may now say the
            // indexes are whole up to here: the log stops, and the next open (which replays
            // from the last checkpoint) sets the entry.
            self.broken = true;
            return Err(Error::Io(error));
        }
        Ok(())
    }

    /// Closes the last segment and starts the next. The closing segment is synced first, so a
    /// torn record can only ever be at the end of the last segment.
    fn roll(&mut self) -> Result<(), Error> {
        fsio::sync(&self.tail.file)?;
        self.stats.syncs = self.stats.syncs.saturating_add(1);
        let seg = self.tail.seg.checked_add(1).ok_or(Error::Corrupt("too many segments"))?;
        let file = Self::create_segment(&self.rows_dir, seg)?;
        // The new segment already contains its synced 8-byte preamble.
        self.tail = Tail { seg, file, len: SEGMENT_HEADER_LEN };
        self.unsynced = false;
        Ok(())
    }

    /// Puts every appended record on the disk (one sync of the last segment; nothing when
    /// nothing was appended since the last one). For an `act` acknowledgement, which means "on
    /// disk".
    pub fn sync(&mut self) -> Result<(), Error> {
        if self.broken {
            return Err(Error::Stopped);
        }
        if self.unsynced {
            if let Err(error) = fsio::sync(&self.tail.file) {
                self.broken = true;
                return Err(Error::Io(error));
            }
            self.stats.syncs = self.stats.syncs.saturating_add(1);
            self.unsynced = false;
        }
        Ok(())
    }

    /// Writes the checkpoint: the log's place and `state`, the actor's bytes ([`StateWriter`]),
    /// together under 64 KB plus 32 bytes per queued prompt. Queue entries use the
    /// `PROMPT_QUEUE` section; its allowance cannot be used by other state.
    /// The segment and both indexes are synced first, so the next open
    /// reads only what is appended after this call. The file is replaced atomically: a kill at
    /// any moment leaves the old checkpoint or the new one.
    /// Checkpoint the actor state and the ids it has allocated but has not settled. The log
    /// needs these ids explicitly: it never parses the actor's opaque state or row text.
    pub fn write_checkpoint(&mut self, state: &[u8], open_rows: &[u64]) -> Result<(), Error> {
        self.write_checkpoint_in_edition(state, open_rows, self.edition)
    }

    /// Publishes a new edition atomically with its actor state. The actor must finish
    /// this write before making a rebuilt or stamp-changed book ready to callers.
    pub fn write_checkpoint_in_edition(
        &mut self,
        state: &[u8],
        open_rows: &[u64],
        edition: u32,
    ) -> Result<(), Error> {
        if edition == 0 && !self.staging {
            return Err(Error::InvalidInput("edition zero is only for an unserved rebuild"));
        }
        if self.broken {
            return Err(Error::Stopped);
        }
        if open_rows.iter().any(|id| *id == 0 || self.rows.get(*id).is_some()) {
            return Err(Error::InvalidInput("checkpoint open rows contain a settled or zero id"));
        }
        let mark = Mark {
            edition,
            last_seq: self.last_seq,
            min_row: self.min_row,
            max_row: self.max_row,
            seg: self.tail.seg,
            off: self.tail.len,
            raw_files: self.raw_files,
            raw_map_len: self.raw_map_len,
        };
        let checkpoint_mark = undo_head_for(mark);
        let bytes = checkpoint::encode(&mark, state, open_rows)?;
        self.sync()?;
        let rows_synced = match self.rows.sync() {
            Ok(synced) => synced,
            Err(error) => {
                self.broken = true;
                return Err(Error::Io(error));
            }
        };
        let seqs_synced = match self.seqs.sync() {
            Ok(synced) => synced,
            Err(error) => {
                self.broken = true;
                return Err(Error::Io(error));
            }
        };
        let synced = u64::from(rows_synced).saturating_add(u64::from(seqs_synced));
        fsio::write_atomic(&self.dir.join("checkpoint"), &bytes)?;
        self.undo.set_len(0)?;
        fsio::sync(&self.undo)?;
        self.checkpoint_mark = checkpoint_mark;
        self.checkpoint_last_seq = mark.last_seq;
        self.checkpoint_min_row = mark.min_row;
        self.checkpoint_max_row = mark.max_row;
        self.checkpoint_raw_files = mark.raw_files;
        self.checkpoint_raw_map_len = mark.raw_map_len;
        self.undo_head = None;
        self.edition = edition;
        self.stats.syncs = self.stats.syncs.saturating_add(synced).saturating_add(1);
        self.stats.bytes_written = self.stats.bytes_written.saturating_add(bytes.len() as u64);
        self.stats.writes = self.stats.writes.saturating_add(1);
        self.stats.checkpoints = self.stats.checkpoints.saturating_add(1);
        Ok(())
    }

    fn blob_path(&self, row_id: u64) -> PathBuf {
        self.dir.join("blobs").join(row_id.to_string())
    }

    /// Stores a row's out-of-line body as `blobs/<rowId>`, whole or not at all. Call it before
    /// the row is appended, so a row never names a blob that is not there.
    pub fn write_blob(&mut self, row_id: u64, bytes: &[u8]) -> Result<(), Error> {
        if row_id == 0 {
            return Err(Error::ZeroRowId);
        }
        fsio::write_atomic(&self.blob_path(row_id), bytes)?;
        self.stats.bytes_written = self.stats.bytes_written.saturating_add(bytes.len() as u64);
        self.stats.writes = self.stats.writes.saturating_add(1);
        self.stats.syncs = self.stats.syncs.saturating_add(1);
        Ok(())
    }

    /// Reads up to `max` bytes (at most [`MAX_BLOB_READ`]) of row `row_id`'s blob from `offset`
    /// into `out` (cleared first); the blob's whole length. One read, whatever the blob's size.
    pub fn read_blob(
        &mut self,
        row_id: u64,
        offset: u64,
        max: usize,
        out: &mut Vec<u8>,
    ) -> Result<u64, Error> {
        out.clear();
        let file = File::open(self.blob_path(row_id))?;
        let len = file.metadata()?.len();
        let left = usize::try_from(len.saturating_sub(offset)).unwrap_or(usize::MAX);
        out.resize(max.min(MAX_BLOB_READ).min(left), 0);
        let read = fsio::read_at(&file, out, offset)?;
        out.truncate(read);
        self.stats.reads = self.stats.reads.saturating_add(1);
        self.stats.bytes_read = self.stats.bytes_read.saturating_add(read as u64);
        Ok(len)
    }

    /// Reads segment `seg` at `offset` into `buf`, until `buf` is full or the segment ends; the
    /// bytes read.
    fn read_segment(&mut self, seg: u32, offset: u64, buf: &mut [u8]) -> Result<usize, Error> {
        if self.broken {
            return Err(Error::Stopped);
        }
        let read = if seg == self.tail.seg {
            fsio::read_at(&self.tail.file, buf, offset)?
        } else {
            let at = match self.readers.iter().position(|(number, _)| *number == seg) {
                Some(at) => at,
                None => {
                    let file = File::open(segment_path(&self.rows_dir, seg))?;
                    self.readers.truncate(MAX_READERS.saturating_sub(1));
                    self.readers.insert(0, (seg, file));
                    0
                }
            };
            if at != 0 {
                let reader = self.readers.remove(at);
                self.readers.insert(0, reader);
            }
            match self.readers.first() {
                Some((_, file)) => fsio::read_at(file, buf, offset)?,
                None => 0,
            }
        };
        self.stats.reads = self.stats.reads.saturating_add(1);
        self.stats.bytes_read = self.stats.bytes_read.saturating_add(read as u64);
        Ok(read)
    }
}

#[cfg(test)]
mod failure_tests {
    use super::*;

    #[test]
    fn failed_writes_stop_the_log_until_reopen() {
        for map_failure in [false, true] {
            let home = tempfile::tempdir().unwrap();
            let (mut log, _) = Log::open(home.path(), Options::default()).unwrap();
            log.append_settled(1, 1, RawRange::NONE, b"old").unwrap();
            log.write_checkpoint(&[], &[]).unwrap();
            // Read-only descriptors produce a real failed write without production fault hooks.
            let error = if map_failure {
                log.raw_map = File::open(home.path().join("raw.map")).unwrap();
                log.append_raw_file(b"raw").unwrap_err()
            } else {
                log.tail.file = File::open(segment_path(&log.rows_dir, log.tail.seg)).unwrap();
                log.append_settled(2, 1, RawRange::NONE, b"new").unwrap_err()
            };
            assert!(matches!(error, Error::Io(_)));
            assert!(matches!(
                log.append_settled(2, 1, RawRange::NONE, b"new"),
                Err(Error::Stopped)
            ));
            assert!(matches!(log.patch(1, 2, RawRange::NONE, b"patch"), Err(Error::Stopped)));
            assert!(matches!(log.write_checkpoint(&[], &[]), Err(Error::Stopped)));
            assert!(matches!(log.append_raw_file(b"raw"), Err(Error::Stopped)));
            drop(log);
            let (mut log, _) = Log::open(home.path(), Options::default()).unwrap();
            assert_eq!(log.append_settled(2, 1, RawRange::NONE, b"new").unwrap(), 2);
        }
    }

    #[test]
    fn a_short_write_in_a_new_segment_does_not_shift_the_next_record() {
        let home = tempfile::tempdir().unwrap();
        let (mut log, _) = Log::open(home.path(), Options::default()).unwrap();
        log.append_settled(1, 1, RawRange::NONE, b"first").unwrap();
        log.roll().unwrap();
        log.fail_after = Some(3);
        assert!(matches!(log.append_settled(2, 1, RawRange::NONE, b"second"), Err(Error::Io(_))));
        log.append_settled(2, 1, RawRange::NONE, b"second").unwrap();
        log.append_settled(3, 1, RawRange::NONE, b"third").unwrap();
        drop(log);
        let (log, _) = Log::open(home.path(), Options::default()).unwrap();
        assert_eq!(log.row(2).unwrap().len, 6);
        assert_eq!(log.row(3).unwrap().len, 5);
    }

    #[test]
    fn a_failed_sync_stops_the_log() {
        let home = tempfile::tempdir().unwrap();
        let (mut log, _) = Log::open(home.path(), Options::default()).unwrap();
        let file = log.append_raw_file(b"raw").unwrap();
        log.append_settled(1, 1, RawRange { file, off: 0, len: 1 }, b"row").unwrap();
        log.tail.file = File::open("/dev/full").unwrap();
        assert!(matches!(log.sync(), Err(Error::Io(_))));
        assert!(matches!(log.append_settled(2, 1, RawRange::NONE, b"row"), Err(Error::Stopped)));
    }
}
