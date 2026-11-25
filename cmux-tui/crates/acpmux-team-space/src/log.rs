//! What this machine keeps for a person's digest: their log of digests shown and actions taken,
//! and one cursor per space. The hosted forum has no endpoint for either yet, so a hosted store
//! keeps them here (a hosted store, which lands separately, appends to a [`RecordLog`]).
//!
//! [`JsonlLog`] is the file form, the same shape as acpmux's forum log (`forum.rs`): one JSON
//! record per line, owner-only, replayed when opened; a line that does not parse is skipped, so
//! a torn last write loses only itself. [`MemoryLog`] is the same without a file.

use crate::record::PersonRecord;
use crate::store::StoreError;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, PoisonError};

/// A person's digest log.
pub trait RecordLog: Send + Sync {
    fn append(&self, record: &PersonRecord) -> Result<(), StoreError>;
    /// The person's records at or after `since` (ms since the epoch), in the order appended.
    fn records(&self, person: &str, since: u64) -> Result<Vec<PersonRecord>, StoreError>;
}

/// Where a person has read each space up to. A cursor moves forward only.
pub trait CursorLog: Send + Sync {
    fn cursor(&self, person: &str, space: &str) -> u64;
    /// Moves the cursor to `seq`; a `seq` at or behind the cursor changes nothing.
    fn set_cursor(&self, person: &str, space: &str, seq: u64, at: u64) -> Result<(), StoreError>;
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum Line {
    Record { record: PersonRecord },
    Cursor { person: String, space: String, seq: u64, at: u64 },
}

#[derive(Default)]
struct State {
    records: Vec<PersonRecord>,
    cursors: BTreeMap<(String, String), u64>,
}

impl State {
    fn apply(&mut self, line: Line) {
        match line {
            Line::Record { record } => self.records.push(record),
            Line::Cursor { person, space, seq, .. } => {
                let slot = self.cursors.entry((person, space)).or_default();
                *slot = (*slot).max(seq);
            }
        }
    }

    fn records(&self, person: &str, since: u64) -> Vec<PersonRecord> {
        self.records.iter().filter(|r| r.person() == person && r.at() >= since).cloned().collect()
    }
}

/// How a file is opened for appending. The default creates it owner-only; a daemon that guards
/// its home folder passes its own.
pub type Opener = fn(&Path) -> std::io::Result<std::fs::File>;

fn open_private(path: &Path) -> std::io::Result<std::fs::File> {
    let mut options = std::fs::OpenOptions::new();
    options.append(true).create(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)
}

/// The log in a file, replayed when opened.
pub struct JsonlLog {
    /// None: kept in memory only.
    path: Option<PathBuf>,
    opener: Opener,
    state: Mutex<State>,
}

impl JsonlLog {
    pub fn open(path: impl Into<PathBuf>) -> std::io::Result<Self> {
        Self::open_with(path, open_private)
    }

    pub fn open_with(path: impl Into<PathBuf>, opener: Opener) -> std::io::Result<Self> {
        let path = path.into();
        let mut state = State::default();
        let bytes = match std::fs::read(&path) {
            Ok(bytes) => bytes,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(e) => return Err(e),
        };
        // As bytes: a torn line, even mid-character, is skipped and never fatal.
        for line in bytes.split(|&b| b == b'\n') {
            if let Ok(line) = serde_json::from_slice::<Line>(line) {
                state.apply(line);
            }
        }
        if bytes.last().is_some_and(|&c| c != b'\n') {
            // End a torn last line, so the next record starts on its own.
            opener(&path)?.write_all(b"\n")?;
        }
        Ok(Self { path: Some(path), opener, state: Mutex::new(state) })
    }

    /// A log with no file: what a daemon without a store on disk keeps.
    pub fn in_memory() -> Self {
        Self { path: None, opener: open_private, state: Mutex::default() }
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Written before it counts: a failed write leaves the state as it was.
    fn write(&self, line: &Line) -> Result<(), StoreError> {
        let Some(path) = &self.path else { return Ok(()) };
        let unavailable = |e: &dyn std::fmt::Display| {
            StoreError::Unavailable(format!("the digest log {}: {e}", path.display()))
        };
        let mut bytes = serde_json::to_vec(line).map_err(|e| unavailable(&e))?;
        bytes.push(b'\n');
        let mut file = (self.opener)(path).map_err(|e| unavailable(&e))?;
        if let Err(e) = file.write_all(&bytes) {
            let _ = file.write_all(b"\n");
            return Err(unavailable(&e));
        }
        file.sync_data().map_err(|e| unavailable(&e))
    }
}

impl RecordLog for JsonlLog {
    fn append(&self, record: &PersonRecord) -> Result<(), StoreError> {
        let mut state = self.lock();
        let line = Line::Record { record: record.clone() };
        self.write(&line)?;
        state.apply(line);
        Ok(())
    }

    fn records(&self, person: &str, since: u64) -> Result<Vec<PersonRecord>, StoreError> {
        Ok(self.lock().records(person, since))
    }
}

impl CursorLog for JsonlLog {
    fn cursor(&self, person: &str, space: &str) -> u64 {
        self.lock().cursors.get(&(person.to_owned(), space.to_owned())).copied().unwrap_or(0)
    }

    fn set_cursor(&self, person: &str, space: &str, seq: u64, at: u64) -> Result<(), StoreError> {
        let mut state = self.lock();
        if seq <= state.cursors.get(&(person.to_owned(), space.to_owned())).copied().unwrap_or(0) {
            return Ok(());
        }
        let line = Line::Cursor { person: person.to_owned(), space: space.to_owned(), seq, at };
        self.write(&line)?;
        state.apply(line);
        Ok(())
    }
}

/// The log in memory only.
#[derive(Default)]
pub struct MemoryLog {
    state: Mutex<State>,
}

impl MemoryLog {
    pub fn new() -> Self {
        Self::default()
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl RecordLog for MemoryLog {
    fn append(&self, record: &PersonRecord) -> Result<(), StoreError> {
        self.lock().records.push(record.clone());
        Ok(())
    }

    fn records(&self, person: &str, since: u64) -> Result<Vec<PersonRecord>, StoreError> {
        Ok(self.lock().records(person, since))
    }
}

impl CursorLog for MemoryLog {
    fn cursor(&self, person: &str, space: &str) -> u64 {
        self.lock().cursors.get(&(person.to_owned(), space.to_owned())).copied().unwrap_or(0)
    }

    fn set_cursor(&self, person: &str, space: &str, seq: u64, at: u64) -> Result<(), StoreError> {
        self.lock().apply(Line::Cursor {
            person: person.to_owned(),
            space: space.to_owned(),
            seq,
            at,
        });
        Ok(())
    }
}
