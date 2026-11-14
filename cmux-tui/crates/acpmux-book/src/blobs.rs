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
}

pub struct Blobs {
    dir: PathBuf,
    open: PathBuf,
    stopped: bool,
}

/// The maximum bytes returned by one body range read.
pub const MAX_BLOB_READ: usize = 256 * 1024;

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
                let generation = body
                    .generation
                    .checked_add(1)
                    .ok_or(Error::InvalidInput("body generation overflow"))?;
                let path = self.open.join(field_name(body.row, key, generation));
                OpenOptions::new().create_new(true).write(true).open(path)?.write_all(bytes)?;
                body.generation = generation;
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

    /// Reads one bounded range of an open body's field. Inline fields are sliced directly;
    /// spilled fields are read at the requested offset from their immutable open file. The
    /// returned length is the complete field length, so callers can continue until the body is
    /// exhausted without reading it first.
    pub fn read_open_range(
        &self,
        body: &Body,
        key: &str,
        offset: u64,
        max: usize,
        out: &mut Vec<u8>,
    ) -> Result<u64, Error> {
        self.writable()?;
        out.clear();
        let Some(value) = body.fields.get(key) else {
            return Err(Error::InvalidInput("open body field is missing"));
        };
        let (len, amount) = match value {
            Value::Inline(bytes) => {
                let len = bytes.len() as u64;
                let start = usize::try_from(offset).unwrap_or(usize::MAX).min(bytes.len());
                let amount = crate::log::Log::bound(max, MAX_BLOB_READ)
                    .min(bytes.len().saturating_sub(start));
                out.extend_from_slice(
                    bytes.get(start..start.saturating_add(amount)).unwrap_or_default(),
                );
                (len, amount)
            }
            Value::File(field) => {
                let len = field.len;
                let left = usize::try_from(len.saturating_sub(offset)).unwrap_or(usize::MAX);
                let amount = crate::log::Log::bound(max, MAX_BLOB_READ).min(left);
                out.resize(amount, 0);
                let path = self.open.join(field_name(body.row, key, field.generation));
                let file = File::open(path).map_err(named_file_error)?;
                let read = fsio::read_at(&file, out, offset)?;
                out.truncate(read);
                (len, read)
            }
        };
        let _ = amount;
        Ok(len)
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
