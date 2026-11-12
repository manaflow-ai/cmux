//! Versioned actor state inside the log's atomic checkpoint envelope. The queue has its
//! own budget; body data must spill before it can exhaust the non-queue budget.
#![deny(clippy::indexing_slicing, clippy::string_slice, clippy::expect_used)]

use crate::blobs::{Body, FieldFile, Value};
use crate::log::{
    Error, MAX_CHECKPOINT, MAX_CHECKPOINT_STATE, RawRange, StateWriter, section, sections,
};
use std::collections::{BTreeMap, BTreeSet};

const VERSION: u32 = 1;
const ACTOR: u8 = 128;
pub const MAX_OPEN_BODIES: usize = 64;
pub const MAX_PROMPTS: usize = 1024;
const MAX_FIELDS: usize = 32;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Cursor {
    pub file: u32,
    pub place: u64,
    pub stamp: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OpenBody {
    pub body: Body,
    pub raw: RawRange,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Person {
    pub id: [u8; 16],
    pub seen: u64,
    pub folds: Vec<u64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Checkpoint {
    pub edition: u32,
    pub translator_version: u32,
    pub translator: Vec<u8>,
    pub cursors: Vec<Cursor>,
    /// Last allocated row, including open rows. The log envelope owns the settled mark.
    pub last_row: u64,
    pub folds_len: u64,
    pub open: Vec<OpenBody>,
    pub summary: Vec<u8>,
    pub pending_asks: Vec<u64>,
    pub people: Vec<Person>,
    pub prompts: Vec<[u8; 32]>,
}

impl Checkpoint {
    pub fn new(translator_version: u32) -> Self {
        Self {
            edition: 1,
            translator_version,
            translator: Vec::new(),
            cursors: Vec::new(),
            last_row: 0,
            folds_len: 0,
            open: Vec::new(),
            summary: Vec::new(),
            pending_asks: Vec::new(),
            people: Vec::new(),
            prompts: Vec::new(),
        }
    }

    /// Returns the state for `Log::write_checkpoint`, which syncs the segment and indexes
    /// before the atomic replacement. Its caller syncs raw, body files and folds first.
    /// `log_open_rows` includes metadata-only rows as well as rows with bodies.
    pub fn encode(&self, log_open_rows: usize) -> Result<Vec<u8>, Error> {
        self.validate()?;
        // 68-byte log envelope, row ids, two five-byte section envelopes.
        let cap = MAX_CHECKPOINT_STATE
            .checked_sub(78usize.saturating_add(log_open_rows.saturating_mul(8)))
            .ok_or(Error::CheckpointTooLarge { bytes: usize::MAX })?;
        let mut e = Encoder { bytes: Vec::new(), cap };
        e.u32(VERSION)?;
        e.u32(self.edition)?;
        e.u32(self.translator_version)?;
        e.u64(self.last_row)?;
        e.u64(self.folds_len)?;
        e.blob(&self.translator)?;
        e.u32(self.cursors.len() as u32)?;
        for cursor in &self.cursors {
            e.u32(cursor.file)?;
            e.u64(cursor.place)?;
            e.u64(cursor.stamp)?;
        }
        e.u32(self.open.len() as u32)?;
        for open in &self.open {
            let body = &open.body;
            e.u64(body.row)?;
            e.u64(body.generation)?;
            e.put(&[u8::from(body.spilled)])?;
            e.u32(open.raw.file)?;
            e.u64(open.raw.off)?;
            e.u32(open.raw.len)?;
            e.u32(body.fields.len() as u32)?;
            for (key, value) in &body.fields {
                e.blob(key.as_bytes())?;
                match value {
                    Value::Inline(bytes) => {
                        e.put(&[0])?;
                        e.blob(bytes)?;
                    }
                    Value::File(field) => {
                        e.put(&[1])?;
                        e.u64(field.generation)?;
                        e.u64(field.len)?;
                    }
                }
            }
        }
        e.blob(&self.summary)?;
        e.u32(self.pending_asks.len() as u32)?;
        for ask in &self.pending_asks {
            e.u64(*ask)?;
        }
        e.u32(self.people.len() as u32)?;
        for person in &self.people {
            e.put(&person.id)?;
            e.u64(person.seen)?;
            e.u32(person.folds.len() as u32)?;
            for fold in &person.folds {
                e.u64(*fold)?;
            }
        }
        let mut state = StateWriter::new();
        state.push(ACTOR, &e.bytes);
        let mut queue = Vec::with_capacity(self.prompts.len() * 32);
        for prompt in &self.prompts {
            queue.extend_from_slice(prompt);
        }
        state.push(section::PROMPT_QUEUE, &queue);
        Ok(state.as_bytes().to_vec())
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, Error> {
        if bytes.len() > MAX_CHECKPOINT {
            return Err(bad());
        }
        let mut actor = None;
        let mut queue = None;
        let mut consumed = 0usize;
        for (tag, part) in sections(bytes) {
            consumed = consumed.checked_add(5 + part.len()).ok_or_else(bad)?;
            match tag {
                ACTOR if actor.is_none() => actor = Some(part),
                section::PROMPT_QUEUE if queue.is_none() => queue = Some(part),
                _ => return Err(bad()),
            }
        }
        if consumed != bytes.len() {
            return Err(bad());
        }
        let mut d = Decoder { bytes: actor.ok_or_else(bad)? };
        if d.u32()? != VERSION {
            return Err(Error::Rebuild("actor checkpoint version"));
        }
        let mut result = Self::new(0);
        result.edition = d.u32()?;
        result.translator_version = d.u32()?;
        result.last_row = d.u64()?;
        result.folds_len = d.u64()?;
        result.translator = d.blob()?.to_vec();
        for _ in 0..d.count(2)? {
            result.cursors.push(Cursor { file: d.u32()?, place: d.u64()?, stamp: d.u64()? });
        }
        for _ in 0..d.count(MAX_OPEN_BODIES)? {
            let row = d.u64()?;
            let generation = d.u64()?;
            let spilled = match d.byte()? {
                0 => false,
                1 => true,
                _ => return Err(bad()),
            };
            let raw = RawRange { file: d.u32()?, off: d.u64()?, len: d.u32()? };
            let mut fields = BTreeMap::new();
            for _ in 0..d.count(MAX_FIELDS)? {
                let key = std::str::from_utf8(d.blob()?).map_err(|_| bad())?.to_owned();
                let value = match d.byte()? {
                    0 => Value::Inline(d.blob()?.to_vec()),
                    1 => Value::File(FieldFile { generation: d.u64()?, len: d.u64()? }),
                    _ => return Err(bad()),
                };
                if fields.insert(key, value).is_some() {
                    return Err(bad());
                }
            }
            result.open.push(OpenBody { body: Body { row, generation, spilled, fields }, raw });
        }
        result.summary = d.blob()?.to_vec();
        for _ in 0..d.count(64)? {
            result.pending_asks.push(d.u64()?);
        }
        for _ in 0..d.count(16)? {
            let id = d.take(16)?.try_into().map_err(|_| bad())?;
            let seen = d.u64()?;
            let mut folds = Vec::new();
            for _ in 0..d.count(32)? {
                folds.push(d.u64()?);
            }
            result.people.push(Person { id, seen, folds });
        }
        if !d.bytes.is_empty() {
            return Err(bad());
        }
        let queue = queue.ok_or_else(bad)?;
        if !queue.len().is_multiple_of(32) || queue.len() > 32 * MAX_PROMPTS {
            return Err(bad());
        }
        for prompt in queue.chunks_exact(32) {
            result.prompts.push(prompt.try_into().map_err(|_| bad())?);
        }
        result.validate()?;
        // This includes the log's minimum row-id overhead; log::decode checks the exact count.
        result.encode(result.open.len()).map_err(|_| bad())?;
        Ok(result)
    }

    fn validate(&self) -> Result<(), Error> {
        if self.edition == 0
            || self.cursors.len() > 2
            || self.open.len() > MAX_OPEN_BODIES
            || self.translator.len() > 32 * 1024
            || self.summary.len() > 2048
            || self.prompts.len() > MAX_PROMPTS
            || self.pending_asks.len() > 64
            || self.people.len() > 16
            || self.people.iter().any(|p| p.folds.len() > 32)
            || !self.folds_len.is_multiple_of(crate::folds::ENTRY_BYTES)
        {
            return Err(bad());
        }
        let mut ids = BTreeSet::new();
        for open in &self.open {
            let body = &open.body;
            if body.row == 0
                || body.row > self.last_row
                || !ids.insert(body.row)
                || body.fields.len() > MAX_FIELDS
            {
                return Err(bad());
            }
            for (key, value) in &body.fields {
                if key.is_empty()
                    || key.len() > 32
                    || !key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
                {
                    return Err(bad());
                }
                match value {
                    Value::File(f)
                        if !body.spilled || f.generation == 0 || f.generation > body.generation =>
                    {
                        return Err(bad());
                    }
                    Value::Inline(_) if body.spilled => return Err(bad()),
                    _ => {}
                }
            }
        }
        let mut files = BTreeSet::new();
        if self.cursors.iter().any(|c| c.file == 0 || !files.insert(c.file)) {
            return Err(bad());
        }
        Ok(())
    }

    /// Rebuilds preserve client cursors only when both translator and raw meaning agree.
    pub fn rebuild_edition(
        old: Option<&Self>,
        translator: u32,
        cursors: &[Cursor],
    ) -> Result<u32, Error> {
        match old {
            Some(old)
                if old.translator_version == translator
                    && old.cursors.len() == cursors.len()
                    && old
                        .cursors
                        .iter()
                        .zip(cursors)
                        .all(|(a, b)| a.file == b.file && a.stamp == b.stamp) =>
            {
                Ok(old.edition)
            }
            Some(old) => old.edition.checked_add(1).ok_or(Error::InvalidInput("edition exhausted")),
            // Edition 1 belongs to a brand new book. Unreadable existing state starts a new edition.
            None => Err(Error::Rebuild("previous edition needs recovery")),
        }
    }
}

fn bad() -> Error {
    Error::Rebuild("invalid actor checkpoint")
}

struct Encoder {
    bytes: Vec<u8>,
    cap: usize,
}
impl Encoder {
    fn put(&mut self, bytes: &[u8]) -> Result<(), Error> {
        let len = self.bytes.len().saturating_add(bytes.len());
        if len > self.cap {
            return Err(Error::CheckpointTooLarge { bytes: len });
        }
        self.bytes.extend_from_slice(bytes);
        Ok(())
    }
    fn u32(&mut self, n: u32) -> Result<(), Error> {
        self.put(&n.to_le_bytes())
    }
    fn u64(&mut self, n: u64) -> Result<(), Error> {
        self.put(&n.to_le_bytes())
    }
    fn blob(&mut self, bytes: &[u8]) -> Result<(), Error> {
        self.u32(
            u32::try_from(bytes.len())
                .map_err(|_| Error::CheckpointTooLarge { bytes: bytes.len() })?,
        )?;
        self.put(bytes)
    }
}
struct Decoder<'a> {
    bytes: &'a [u8],
}
impl<'a> Decoder<'a> {
    fn take(&mut self, count: usize) -> Result<&'a [u8], Error> {
        let (part, rest) = self.bytes.split_at_checked(count).ok_or_else(bad)?;
        self.bytes = rest;
        Ok(part)
    }
    fn byte(&mut self) -> Result<u8, Error> {
        self.take(1)?.first().copied().ok_or_else(bad)
    }
    fn u32(&mut self) -> Result<u32, Error> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().map_err(|_| bad())?))
    }
    fn u64(&mut self) -> Result<u64, Error> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into().map_err(|_| bad())?))
    }
    fn count(&mut self, max: usize) -> Result<usize, Error> {
        let count = self.u32()? as usize;
        if count > max { Err(bad()) } else { Ok(count) }
    }
    fn blob(&mut self) -> Result<&'a [u8], Error> {
        let len = self.count(MAX_CHECKPOINT_STATE)?;
        self.take(len)
    }
}

#[cfg(test)]
mod tests;
