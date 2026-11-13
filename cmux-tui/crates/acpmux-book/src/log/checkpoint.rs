//! The checkpoint: where the log stood, and the chat actor's small state, in one file under
//! 64 KB plus 32 bytes per queued prompt, written atomically.
//!
//! ```text
//! magic u32 | version u32 | edition u32 | head_crc u32 |
//! last_seq u64 | min_row u64 | max_row u64 | seg u32 | off u64 |
//! raw_files u32 | raw_map_len u64 | open_count u32 | state_len u32 | open_row_ids | state | crc32
//! ```
//!
//! `seg` and `off` are the end of the last segment when the checkpoint was written: everything
//! before that point is synced and indexed, so recovery reads only what came after. `state` is
//! the actor's (the open rows, the raw cursor, the summary, the prompt queue, pending asks, each
//! person's seen row, the open folds, the translator version). The log keeps those bytes and
//! does not read them; [`StateWriter`] and [`sections`] give them a tagged layout.

use super::Error;
use super::record::{le_u32, le_u64};
use std::io::Read;
use std::path::Path;

/// The non-queue part, including the log envelope and section headers, stays under 64 KB.
pub const MAX_CHECKPOINT_STATE: usize = 64 * 1024 - 1;
/// A waiting prompt occupies exactly 32 bytes; the production queue holds at most 1,024.
pub const PROMPT_BYTES: usize = 32;
pub const MAX_PROMPTS: usize = 1024;
/// The total cap cannot be borrowed by state outside the prompt queue.
pub const MAX_CHECKPOINT: usize = MAX_CHECKPOINT_STATE + PROMPT_BYTES * MAX_PROMPTS;

/// The log does not parse actor state, only its section envelopes to account for the queue.
/// Legacy opaque state is still accepted inside the original non-queue budget.
fn check_budget(state: &[u8], open_count: usize) -> Result<(), Error> {
    let bytes = state.len().saturating_add(OVERHEAD).saturating_add(open_count.saturating_mul(8));
    let mut rest = state;
    let mut queue = None;
    while !rest.is_empty() {
        let Some((tag, body)) = sections(rest).next() else {
            // Incomplete sections cannot claim any queue allowance.
            queue = None;
            break;
        };
        if tag == section::PROMPT_QUEUE {
            if queue.is_some()
                || !body.len().is_multiple_of(PROMPT_BYTES)
                || body.len() > PROMPT_BYTES * MAX_PROMPTS
            {
                return Err(Error::InvalidInput("invalid checkpoint prompt queue"));
            }
            queue = Some(body.len());
        }
        rest = rest.get(body.len().saturating_add(5)..).unwrap_or_default();
    }
    if bytes.saturating_sub(queue.unwrap_or(0)) > MAX_CHECKPOINT_STATE || bytes > MAX_CHECKPOINT {
        return Err(Error::CheckpointTooLarge { bytes });
    }
    Ok(())
}

const MAGIC: u32 = u32::from_le_bytes(*b"ABCK");
const VERSION: u32 = 2;
/// The bytes before `state`.
const FIXED: usize = 72;
/// `FIXED` and the crc.
pub const OVERHEAD: usize = 76;

/// Every later checkpoint format preserves these first sixteen bytes. The head has
/// its own checksum so a damaged or unknown body still supplies its previous edition.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CheckpointHead {
    pub version: u32,
    pub edition: u32,
}

impl CheckpointHead {
    pub fn decode(bytes: &[u8]) -> Option<Self> {
        if le_u32(bytes, 0)? != MAGIC || crc32fast::hash(bytes.get(..12)?) != le_u32(bytes, 12)? {
            return None;
        }
        let edition = le_u32(bytes, 8)?;
        if edition == 0 {
            return None;
        }
        Some(Self { version: le_u32(bytes, 4)?, edition })
    }

    /// Reads just the fixed head, including when the body's version is not understood.
    pub fn read(book: &Path) -> Result<Option<Self>, Error> {
        let mut file = match std::fs::File::open(book.join("checkpoint")) {
            Ok(file) => file,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e.into()),
        };
        let mut bytes = [0; 16];
        match file.read_exact(&mut bytes) {
            Ok(()) => Ok(Self::decode(&bytes)),
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => Ok(None),
            Err(e) => Err(e.into()),
        }
    }
}

/// Where the log stood when a checkpoint was written.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Mark {
    pub edition: u32,
    pub last_seq: u64,
    /// The lowest and highest settled rowId; 0 when the book is empty.
    pub min_row: u64,
    pub max_row: u64,
    /// The last segment and its length.
    pub seg: u32,
    pub off: u64,
    pub raw_files: u32,
    pub raw_map_len: u64,
}

pub(crate) fn encode(mark: &Mark, state: &[u8], open_rows: &[u64]) -> Result<Vec<u8>, Error> {
    if mark.edition == 0 {
        return Err(Error::InvalidInput("edition is zero"));
    }
    check_budget(state, open_rows.len())?;
    let bytes =
        state.len().saturating_add(OVERHEAD).saturating_add(open_rows.len().saturating_mul(8));
    let state_len = u32::try_from(state.len()).ok().filter(|_| bytes <= MAX_CHECKPOINT);
    let Some(state_len) = state_len else {
        return Err(Error::CheckpointTooLarge { bytes });
    };
    let open_count =
        u32::try_from(open_rows.len()).map_err(|_| Error::CheckpointTooLarge { bytes })?;
    let mut out = Vec::with_capacity(bytes);
    out.extend_from_slice(&MAGIC.to_le_bytes());
    out.extend_from_slice(&VERSION.to_le_bytes());
    out.extend_from_slice(&mark.edition.to_le_bytes());
    let head_crc = crc32fast::hash(&out);
    out.extend_from_slice(&head_crc.to_le_bytes());
    out.extend_from_slice(&mark.last_seq.to_le_bytes());
    out.extend_from_slice(&mark.min_row.to_le_bytes());
    out.extend_from_slice(&mark.max_row.to_le_bytes());
    out.extend_from_slice(&mark.seg.to_le_bytes());
    out.extend_from_slice(&mark.off.to_le_bytes());
    out.extend_from_slice(&mark.raw_files.to_le_bytes());
    out.extend_from_slice(&mark.raw_map_len.to_le_bytes());
    out.extend_from_slice(&open_count.to_le_bytes());
    out.extend_from_slice(&state_len.to_le_bytes());
    for row_id in open_rows {
        out.extend_from_slice(&row_id.to_le_bytes());
    }
    out.extend_from_slice(state);
    let crc = crc32fast::hash(&out);
    out.extend_from_slice(&crc.to_le_bytes());
    Ok(out)
}

/// The mark and the state of a checkpoint file; `None` when the bytes are not a whole
/// checkpoint of this version (the actor rebuilds it from raw).
pub(crate) fn decode(bytes: &[u8]) -> Option<(Mark, &[u8], &[u8])> {
    let head = CheckpointHead::decode(bytes)?;
    if bytes.len() > MAX_CHECKPOINT || head.version != VERSION {
        return None;
    }
    let mark = Mark {
        edition: head.edition,
        last_seq: le_u64(bytes, 16)?,
        min_row: le_u64(bytes, 24)?,
        max_row: le_u64(bytes, 32)?,
        seg: le_u32(bytes, 40)?,
        off: le_u64(bytes, 44)?,
        raw_files: le_u32(bytes, 52)?,
        raw_map_len: le_u64(bytes, 56)?,
    };
    let state_start = FIXED.checked_add((le_u32(bytes, 64)? as usize).checked_mul(8)?)?;
    let state_end = state_start.checked_add(le_u32(bytes, 68)? as usize)?;
    let crc_end = state_end.checked_add(4)?;
    if crc_end != bytes.len()
        || crc32fast::hash(bytes.get(..state_end)?) != le_u32(bytes, state_end)?
    {
        return None;
    }
    let state = bytes.get(state_start..state_end)?;
    let open_rows = bytes.get(FIXED..state_start)?;
    check_budget(state, open_rows.len() / 8).ok()?;
    Some((mark, state, open_rows))
}

/// The tags of the actor's state sections.
pub mod section {
    /// The open rows: each a `len u32` and a row text.
    pub const OPEN_ROWS: u8 = 1;
    /// The raw cursor: file, inode, byte offset.
    pub const RAW_CURSOR: u8 = 2;
    /// The chat's summary record.
    pub const SUMMARY: u8 = 3;
    /// The prompt queue.
    pub const PROMPT_QUEUE: u8 = 4;
    /// Pending asks.
    pub const ASKS: u8 = 5;
    /// Each person's seen row.
    pub const SEEN: u8 = 6;
    /// The open folds.
    pub const FOLDS: u8 = 7;
    /// The translator version that wrote the book.
    pub const TRANSLATOR: u8 = 8;
}

/// Builds a checkpoint's state: sections of `tag u8 | len u32 | bytes`.
#[derive(Clone, Debug, Default)]
pub struct StateWriter {
    bytes: Vec<u8>,
}

impl StateWriter {
    pub fn new() -> StateWriter {
        StateWriter::default()
    }

    /// Adds one section. A section over 4 GiB cannot be written and is left out (a checkpoint
    /// holding it would be refused for its size anyway).
    pub fn push(&mut self, tag: u8, bytes: &[u8]) -> &mut StateWriter {
        if let Ok(len) = u32::try_from(bytes.len()) {
            self.bytes.push(tag);
            self.bytes.extend_from_slice(&len.to_le_bytes());
            self.bytes.extend_from_slice(bytes);
        }
        self
    }

    /// The state so far, for [`super::Log::write_checkpoint`].
    pub fn as_bytes(&self) -> &[u8] {
        &self.bytes
    }

    /// Empties the writer, keeping its buffer.
    pub fn clear(&mut self) {
        self.bytes.clear();
    }
}

/// The sections of a checkpoint's state, in the order they were pushed. Ends at the first
/// section that is cut short.
pub fn sections(state: &[u8]) -> Sections<'_> {
    Sections { rest: state }
}

/// The iterator [`sections`] returns.
#[derive(Clone, Debug)]
pub struct Sections<'a> {
    rest: &'a [u8],
}

impl<'a> Iterator for Sections<'a> {
    type Item = (u8, &'a [u8]);

    fn next(&mut self) -> Option<(u8, &'a [u8])> {
        let tag = *self.rest.first()?;
        let end = 5usize.checked_add(le_u32(self.rest, 1)? as usize)?;
        let body = self.rest.get(5..end)?;
        self.rest = self.rest.get(end..)?;
        Some((tag, body))
    }
}
