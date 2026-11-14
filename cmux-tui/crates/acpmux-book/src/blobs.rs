//! Open bodies use append-only text and immutable field values. Checkpoints own their
//! lifetimes: replacing or settling a value never removes files a checkpoint can name.
#![deny(clippy::indexing_slicing, clippy::string_slice, clippy::expect_used)]

use crate::{fsio, json, log::Error, row::MAX_ROW_TEXT};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

/// The checkpoint stores these references, never a spilled field's contents.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FieldFile {
    pub generation: u64,
    /// Escaped content length for text; complete JSON value length otherwise.
    pub len: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Value {
    /// Text omits its surrounding quotes. Other values include their JSON syntax.
    Inline(Vec<u8>),
    File(FieldFile),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Body {
    pub row: u64,
    /// Advances whenever a field changes; field files keep their own stable generation.
    pub generation: u64,
    pub spilled: bool,
    /// Lexicographic key order is the fixed order for inline and spilled bodies alike.
    pub fields: BTreeMap<String, Value>,
}

impl Body {
    pub fn new(row: u64) -> Result<Self, Error> {
        if row == 0 {
            return Err(Error::ZeroRowId);
        }
        Ok(Self { row, generation: 0, spilled: false, fields: BTreeMap::new() })
    }

    pub fn len(&self) -> u64 {
        self.fields
            .iter()
            .map(|(key, value)| {
                let len = match value {
                    Value::Inline(bytes) => bytes.len() as u64,
                    Value::File(f) => f.len,
                };
                len.saturating_add(key.len() as u64 + 3 + if key == "text" { 2 } else { 0 })
            })
            .fold(2u64, u64::saturating_add)
            .saturating_add(self.fields.len().saturating_sub(1) as u64)
    }

    pub fn is_empty(&self) -> bool {
        self.fields.is_empty()
    }

    /// The offset, in the stored JSON [`Blobs::write_body`] writes, of the end of `text`'s
    /// content: where its closing quote is. [`Body::len`] when the body has no `text`.
    pub fn fixed(&self) -> u64 {
        // `{`, then each field as `"key":value` with `,` between fields; text adds its quotes.
        let mut at = 1u64;
        for (index, (key, value)) in self.fields.iter().enumerate() {
            if index != 0 {
                at = at.saturating_add(1);
            }
            at = at.saturating_add(key.len() as u64 + 3);
            if key == "text" {
                return at.saturating_add(1).saturating_add(value_len(value));
            }
            at = at.saturating_add(value_len(value));
        }
        self.len()
    }
}

pub struct Blobs {
    dir: PathBuf,
    open: PathBuf,
    stopped: bool,
}

/// The maximum bytes returned by one body range read: the log's one bound.
pub use crate::log::MAX_BLOB_READ;

/// A range of the open body's stored JSON at one content generation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct OpenBlobRange {
    pub start: u64,
    pub end: u64,
    pub total: u64,
    pub generation: u64,
    /// [`Body::fixed`] of the body read: where `text`'s closing quote is, or `total`.
    pub fixed: u64,
}

impl Blobs {
    pub fn open(book: &Path) -> Result<Self, Error> {
        let dir = book.join("blobs");
        let open = dir.join("open");
        fs::create_dir_all(&open)?;
        fsio::sync_dir(&dir)?;
        Ok(Self { dir, open, stopped: false })
    }

    fn writable(&self) -> Result<(), Error> {
        if self.stopped { Err(Error::Stopped) } else { Ok(()) }
    }

    /// `json_value` is compact JSON. Only text can append; escaped bytes are kept as
    /// they will appear in the final body, with no decoding/encoding at settlement.
    pub fn set(
        &mut self,
        body: &mut Body,
        key: &str,
        json_value: &str,
        append: bool,
    ) -> Result<(), Error> {
        self.writable()?;
        if !valid_key(key) || !json::is_compact_value(json_value) || (append && key != "text") {
            return Err(Error::InvalidInput("invalid body field"));
        }
        let bytes = if key == "text" {
            json_value
                .strip_prefix('"')
                .and_then(|s| s.strip_suffix('"'))
                .ok_or(Error::InvalidInput("text is not a JSON string"))?
                .as_bytes()
        } else {
            json_value.as_bytes()
        };
        // Spill before copying a large value. An append costs the incoming bytes only.
        let old = body.fields.get(key).map(value_len).unwrap_or(0);
        let projected = body
            .len()
            .saturating_sub(if append { 0 } else { old })
            .saturating_add(bytes.len() as u64)
            .saturating_add(key.len() as u64 + 6);
        if !body.spilled && projected > MAX_ROW_TEXT as u64 {
            self.spill(body)?;
        }
        let generation = body
            .generation
            .checked_add(1)
            .ok_or(Error::InvalidInput("body generation overflow"))?;
        self.stopped = true;
        if body.spilled {
            if append && let Some(Value::File(field)) = body.fields.get_mut(key) {
                let path = self.open.join(field_name(body.row, key, field.generation));
                let mut file = OpenOptions::new().append(true).open(path)?;
                if file.metadata()?.len() != field.len {
                    return Err(Error::Corrupt("open text length differs from actor state"));
                }
                file.write_all(bytes)?;
                field.len = field
                    .len
                    .checked_add(bytes.len() as u64)
                    .ok_or(Error::InvalidInput("body length overflow"))?;
            } else {
                let path = self.open.join(field_name(body.row, key, generation));
                OpenOptions::new().create_new(true).write(true).open(path)?.write_all(bytes)?;
                body.fields.insert(
                    key.into(),
                    Value::File(FieldFile { generation, len: bytes.len() as u64 }),
                );
            }
        } else if append && let Some(Value::Inline(value)) = body.fields.get_mut(key) {
            value.extend_from_slice(bytes);
        } else {
            body.fields.insert(key.into(), Value::Inline(bytes.to_vec()));
        }
        body.generation = generation;
        self.stopped = false;
        Ok(())
    }

    /// Also used to make the non-queue checkpoint fit its own 64 KB budget.
    pub fn spill(&mut self, body: &mut Body) -> Result<(), Error> {
        self.writable()?;
        if body.spilled {
            return Ok(());
        }
        self.stopped = true;
        for (key, value) in &mut body.fields {
            let Value::Inline(bytes) = value else { continue };
            body.generation = body
                .generation
                .checked_add(1)
                .ok_or(Error::InvalidInput("body generation overflow"))?;
            let path = self.open.join(field_name(body.row, key, body.generation));
            OpenOptions::new().write(true).create_new(true).open(path)?.write_all(bytes)?;
            *value =
                Value::File(FieldFile { generation: body.generation, len: bytes.len() as u64 });
        }
        body.spilled = true;
        self.stopped = false;
        Ok(())
    }

    /// Writes in fixed order with one 4 KB scratch buffer regardless of body size.
    pub fn write_body(&self, body: &Body, out: &mut impl Write) -> Result<(), Error> {
        out.write_all(b"{")?;
        for (index, (key, value)) in body.fields.iter().enumerate() {
            if !valid_key(key) {
                return Err(Error::Corrupt("invalid body field name"));
            }
            if index != 0 {
                out.write_all(b",")?;
            }
            out.write_all(b"\"")?;
            out.write_all(key.as_bytes())?;
            out.write_all(b"\":")?;
            if key == "text" {
                out.write_all(b"\"")?;
            }
            match value {
                Value::Inline(bytes) => out.write_all(bytes)?,
                Value::File(field) => {
                    let path = self.open.join(field_name(body.row, key, field.generation));
                    let mut file = File::open(path).map_err(named_file_error)?.take(field.len);
                    let mut scratch = [0; 4096];
                    let mut copied = 0u64;
                    loop {
                        let read = file.read(&mut scratch)?;
                        if read == 0 {
                            break;
                        }
                        out.write_all(
                            scratch.get(..read).ok_or(Error::Corrupt("body read length"))?,
                        )?;
                        copied += read as u64;
                    }
                    if copied != field.len {
                        return Err(Error::Corrupt("body field is short"));
                    }
                }
            }
            if key == "text" {
                out.write_all(b"\"")?;
            }
        }
        out.write_all(b"}")?;
        Ok(())
    }

    /// Reads the same stored JSON that `write_body` streams, without assembling the body.
    /// Only field files intersecting this range are opened, at their intersecting offsets.
    /// The sole writer holds `body` unchanged for this call; generation names that snapshot.
    pub fn read_open_range(
        &self,
        body: &Body,
        offset: u64,
        max: usize,
        out: &mut Vec<u8>,
    ) -> Result<OpenBlobRange, Error> {
        self.writable()?;
        out.clear();
        let total = body.len();
        let start = offset.min(total);
        let amount =
            (crate::log::Log::bound(max, MAX_BLOB_READ) as u64).min(total.saturating_sub(start));
        let end = start.saturating_add(amount);
        out.reserve(amount as usize);
        let mut range = BodyRangeReader { start, end, position: 0, out };
        range.bytes(b"{")?;
        for (index, (key, value)) in body.fields.iter().enumerate() {
            if !valid_key(key) {
                return Err(Error::Corrupt("invalid body field name"));
            }
            if index != 0 {
                range.bytes(b",")?;
            }
            range.bytes(b"\"")?;
            range.bytes(key.as_bytes())?;
            range.bytes(b"\":")?;
            if key == "text" {
                range.bytes(b"\"")?;
            }
            match value {
                Value::Inline(bytes) => range.bytes(bytes)?,
                Value::File(field) => {
                    if let Some((offset, amount)) = range.take(field.len)? {
                        let path = self.open.join(field_name(body.row, key, field.generation));
                        let file = File::open(path).map_err(named_file_error)?;
                        let base = range.out.len();
                        range.out.resize(base.saturating_add(amount), 0);
                        let buffer =
                            range.out.get_mut(base..).ok_or(Error::Corrupt("body range length"))?;
                        if fsio::read_at(&file, buffer, offset)? != amount {
                            return Err(Error::Corrupt("body field is short"));
                        }
                    }
                }
            }
            if key == "text" {
                range.bytes(b"\"")?;
            }
        }
        range.bytes(b"}")?;
        Ok(OpenBlobRange { start, end, total, generation: body.generation, fixed: body.fixed() })
    }

    /// The caller syncs raw first. A small final body stays inline even if it once spilled.
    /// Large bodies stream once to a temporary file, then replace `blobs/<rowId>`.
    /// Open files remain until a later durable checkpoint releases them.
    pub fn settle(&mut self, body: &Body) -> Result<Option<Vec<u8>>, Error> {
        self.writable()?;
        if body.len() <= MAX_ROW_TEXT as u64 {
            let mut bytes = Vec::with_capacity(body.len() as usize);
            self.write_body(body, &mut bytes)?;
            return Ok(Some(bytes));
        }
        self.stopped = true;
        // A bounded recovery journal avoids enumerating all historical final blobs.
        let witness = self.open.join(format!("{}-final", body.row));
        fsio::sync(&OpenOptions::new().write(true).create(true).truncate(false).open(witness)?)?;
        fsio::sync_dir(&self.open)?;
        let temporary = self.open.join(format!("{}-settling", body.row));
        let mut file = File::create(&temporary)?;
        self.write_body(body, &mut file)?;
        fsio::sync(&file)?;
        fs::rename(temporary, self.dir.join(body.row.to_string()))?;
        fsio::sync_dir(&self.dir)?;
        self.stopped = false;
        Ok(None)
    }

    /// Sync all named fields before the log writes the checkpoint. Raw is synced first.
    pub fn sync<'a>(&mut self, bodies: impl IntoIterator<Item = &'a Body>) -> Result<(), Error> {
        self.writable()?;
        self.stopped = true;
        for body in bodies {
            for (key, value) in &body.fields {
                if let Value::File(field) = value {
                    fsio::sync(&File::open(self.open.join(field_name(
                        body.row,
                        key,
                        field.generation,
                    )))?)?;
                }
            }
        }
        fsio::sync_dir(&self.open)?;
        self.stopped = false;
        Ok(())
    }

    /// At open, or immediately after publishing a checkpoint, discard only its suffix.
    /// `last_row` is the checkpoint's allocated rowId (including rows still open).
    /// The open directory is bounded by live fields and one checkpoint interval.
    pub fn recover(&mut self, bodies: &[Body], last_row: u64) -> Result<(), Error> {
        self.writable()?;
        self.stopped = true;
        let mut names = BTreeSet::new();
        let mut open_rows = BTreeSet::new();
        for body in bodies {
            open_rows.insert(body.row);
            for (key, value) in &body.fields {
                if !valid_key(key) {
                    return Err(Error::Corrupt("invalid body field name"));
                }
                if let Value::File(field) = value {
                    let name = field_name(body.row, key, field.generation);
                    let file = OpenOptions::new()
                        .write(true)
                        .open(self.open.join(&name))
                        .map_err(named_file_error)?;
                    let actual = file.metadata()?.len();
                    if actual < field.len || (key != "text" && actual != field.len) {
                        return Err(Error::Corrupt("checkpoint body field length"));
                    }
                    if actual != field.len {
                        file.set_len(field.len)?;
                        fsio::sync(&file)?;
                    }
                    names.insert(name);
                }
            }
        }
        for entry in fs::read_dir(&self.open)? {
            let entry = entry?;
            let name =
                entry.file_name().into_string().map_err(|_| Error::Corrupt("body filename"))?;
            if names.contains(&name) {
                continue;
            }
            if let Some(row) = name.strip_suffix("-final").and_then(|s| s.parse::<u64>().ok())
                && (row > last_row || open_rows.contains(&row))
            {
                remove_if_present(&self.dir.join(row.to_string()))?;
                // Keep the witness until deletion of its final blob is durable.
                fsio::sync_dir(&self.dir)?;
            }
            fs::remove_file(entry.path())?;
        }
        fsio::sync_dir(&self.open)?;
        self.stopped = false;
        Ok(())
    }
}

/// Tracks JSON offsets while copying only the intersection with the requested range.
struct BodyRangeReader<'a> {
    start: u64,
    end: u64,
    position: u64,
    out: &'a mut Vec<u8>,
}

impl BodyRangeReader<'_> {
    fn take(&mut self, len: u64) -> Result<Option<(u64, usize)>, Error> {
        let position = self.position;
        self.position = position.checked_add(len).ok_or(Error::Corrupt("body length overflow"))?;
        let lo = position.max(self.start);
        let hi = self.position.min(self.end);
        Ok((lo < hi).then(|| (lo.saturating_sub(position), hi.saturating_sub(lo) as usize)))
    }

    fn bytes(&mut self, bytes: &[u8]) -> Result<(), Error> {
        if let Some((offset, amount)) = self.take(bytes.len() as u64)? {
            let start = usize::try_from(offset).map_err(|_| Error::Corrupt("body range offset"))?;
            let selected = bytes
                .get(start..start.saturating_add(amount))
                .ok_or(Error::Corrupt("body range length"))?;
            self.out.extend_from_slice(selected);
        }
        Ok(())
    }
}

fn field_name(row: u64, key: &str, generation: u64) -> String {
    format!("{row}-{key}-{generation}")
}
fn valid_key(key: &str) -> bool {
    !key.is_empty()
        && key.len() <= 32
        && key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
}
fn value_len(value: &Value) -> u64 {
    match value {
        Value::Inline(bytes) => bytes.len() as u64,
        Value::File(field) => field.len,
    }
}
fn remove_if_present(path: &Path) -> Result<(), Error> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e.into()),
    }
}

fn named_file_error(error: std::io::Error) -> Error {
    if error.kind() == std::io::ErrorKind::NotFound {
        Error::Corrupt("checkpoint body field is missing")
    } else {
        Error::Io(error)
    }
}

#[cfg(test)]
mod tests;

#[cfg(test)]
#[path = "blob_range_tests.rs"]
mod range_tests;
