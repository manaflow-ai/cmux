//! Derived group boundaries, owned by the chat's sole book writer.
//!
//! A checkpoint records the committed byte length. Recovery truncates the suffix,
//! then translation appends groups again even when the row log says already settled.
#![deny(clippy::indexing_slicing, clippy::string_slice, clippy::expect_used)]

use crate::{fsio, log::Error};
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};

pub const ENTRY_BYTES: u64 = 16;

pub struct Folds {
    file: File,
    len: u64,
    last_group: u64,
    last_row: u64,
    stopped: bool,
    counters: Counters,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Entry {
    pub group: u64,
    pub last: u64,
}

/// What reads of `folds.idx` cost since it was opened.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct FoldStats {
    /// Calls of [`Folds::search`] (and of [`Folds::containing`], which uses it).
    pub searches: u64,
    /// Entries those searches read.
    pub search_reads: u64,
    /// Entries [`Folds::entry_at`] read: steps to a neighbouring entry.
    pub entry_reads: u64,
}

/// Readers hold `&Folds`; the counts are relaxed atomics so the value stays `Sync`.
#[derive(Default)]
struct Counters {
    searches: AtomicU64,
    search_reads: AtomicU64,
    entry_reads: AtomicU64,
}

fn bump(counter: &AtomicU64) {
    counter.fetch_add(1, Ordering::Relaxed);
}

impl Folds {
    /// Reads only the final checkpointed entry, independent of the number of groups.
    pub fn open(path: &Path, checkpoint_len: u64) -> Result<Self, Error> {
        if !checkpoint_len.is_multiple_of(ENTRY_BYTES) {
            return Err(Error::Corrupt("fold checkpoint is not an entry boundary"));
        }
        let mut file =
            OpenOptions::new().read(true).write(true).create(true).truncate(false).open(path)?;
        let actual = file.metadata()?.len();
        if actual < checkpoint_len {
            return Err(Error::Corrupt("folds.idx is shorter than its checkpoint"));
        }
        let (last_group, last_row) = if checkpoint_len == 0 {
            (0, 0)
        } else {
            file.seek(SeekFrom::Start(checkpoint_len - ENTRY_BYTES))?;
            let (group, last) = read_entry(&mut file)?;
            if group == 0 || group > last {
                return Err(Error::Corrupt("invalid fold boundary"));
            }
            (group, last)
        };
        if actual != checkpoint_len {
            file.set_len(checkpoint_len)?;
            fsio::sync(&file)?;
        }
        file.seek(SeekFrom::Start(checkpoint_len))?;
        Ok(Self {
            file,
            len: checkpoint_len,
            last_group,
            last_row,
            stopped: false,
            counters: Counters::default(),
        })
    }

    pub fn len(&self) -> u64 {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// A failed write poisons this value: only reopening can establish a boundary again.
    pub fn append(&mut self, group: u64, last: u64) -> Result<(), Error> {
        if self.stopped {
            return Err(Error::Stopped);
        }
        if group <= self.last_group || group <= self.last_row || group > last {
            return Err(Error::InvalidInput("fold ranges must rise without overlapping"));
        }
        let len =
            self.len.checked_add(ENTRY_BYTES).ok_or(Error::InvalidInput("fold index overflow"))?;
        self.stopped = true;
        self.file.write_all(&group.to_le_bytes())?;
        self.file.write_all(&last.to_le_bytes())?;
        self.len = len;
        self.last_group = group;
        self.last_row = last;
        self.stopped = false;
        Ok(())
    }

    /// Must finish before publishing a checkpoint that names `len()`.
    pub fn sync(&mut self) -> Result<(), Error> {
        if self.stopped {
            return Err(Error::Stopped);
        }
        self.stopped = true;
        fsio::sync(&self.file)?;
        self.stopped = false;
        Ok(())
    }

    /// The number of entries.
    pub fn count(&self) -> u64 {
        self.len / ENTRY_BYTES
    }

    /// What reads of the index cost since it was opened.
    pub fn stats(&self) -> FoldStats {
        FoldStats {
            searches: self.counters.searches.load(Ordering::Relaxed),
            search_reads: self.counters.search_reads.load(Ordering::Relaxed),
            entry_reads: self.counters.entry_reads.load(Ordering::Relaxed),
        }
    }

    /// Returns the closed fold containing a row, when one exists.
    pub fn containing(&self, row_id: u64) -> Result<Option<Entry>, Error> {
        if row_id == 0 {
            if self.stopped {
                return Err(Error::Stopped);
            }
            return Ok(None);
        }
        Ok(self.search(row_id)?.map(|(_, entry)| entry).filter(|entry| row_id <= entry.last))
    }

    /// The entry with the greatest group at or before `row_id`, and its position: the fold
    /// holding the row, or the one before the gap it lies in. `None` when the row is before
    /// every fold. One search: the last entry is held in memory, so it goes back from the end
    /// by doubling steps and then halves; a row near the end costs a read or two however many
    /// folds the book has, and any row at most two reads per doubling of its distance.
    pub fn search(&self, row_id: u64) -> Result<Option<(u64, Entry)>, Error> {
        if self.stopped {
            return Err(Error::Stopped);
        }
        bump(&self.counters.searches);
        let count = self.count();
        if count == 0 {
            return Ok(None);
        }
        let last = count.saturating_sub(1);
        if row_id >= self.last_group {
            return Ok(Some((last, Entry { group: self.last_group, last: self.last_row })));
        }
        // Positions below `next` are known at or before the row (`found` is the greatest of
        // them); positions from `above` on are known after it.
        let mut found = None;
        let mut next = 0u64;
        let mut above = last;
        let mut step = 1u64;
        while above > 0 {
            let probe = above.saturating_sub(step);
            let entry = self.read_for_search(probe)?;
            if entry.group <= row_id {
                found = Some((probe, entry));
                next = probe.saturating_add(1);
                break;
            }
            above = probe;
            step = step.saturating_mul(2);
        }
        while next < above {
            let mid = next + (above - next) / 2;
            let entry = self.read_for_search(mid)?;
            if entry.group <= row_id {
                found = Some((mid, entry));
                next = mid.saturating_add(1);
            } else {
                above = mid;
            }
        }
        Ok(found)
    }

    /// The entry at `position`, `None` past the last one. One 16-byte read; the last entry is
    /// held in memory and costs none.
    pub fn entry_at(&self, position: u64) -> Result<Option<Entry>, Error> {
        if self.stopped {
            return Err(Error::Stopped);
        }
        let count = self.count();
        if position >= count {
            return Ok(None);
        }
        if position == count.saturating_sub(1) {
            return Ok(Some(Entry { group: self.last_group, last: self.last_row }));
        }
        bump(&self.counters.entry_reads);
        let (group, last) = read_entry_at(&self.file, position.saturating_mul(ENTRY_BYTES))?;
        Ok(Some(Entry { group, last }))
    }

    fn read_for_search(&self, position: u64) -> Result<Entry, Error> {
        bump(&self.counters.search_reads);
        let (group, last) = read_entry_at(&self.file, position.saturating_mul(ENTRY_BYTES))?;
        Ok(Entry { group, last })
    }
}

fn read_entry(file: &mut File) -> Result<(u64, u64), Error> {
    let mut group = [0; 8];
    let mut last = [0; 8];
    file.read_exact(&mut group)?;
    file.read_exact(&mut last)?;
    Ok((u64::from_le_bytes(group), u64::from_le_bytes(last)))
}

fn read_entry_at(file: &File, offset: u64) -> Result<(u64, u64), Error> {
    let mut bytes = [0u8; ENTRY_BYTES as usize];
    let read = fsio::read_at(file, &mut bytes, offset)?;
    if read != bytes.len() {
        return Err(Error::Corrupt("short fold entry"));
    }
    let group = bytes
        .get(..8)
        .and_then(|bytes| bytes.try_into().ok())
        .map(u64::from_le_bytes)
        .ok_or(Error::Corrupt("short fold group"))?;
    let last = bytes
        .get(8..)
        .and_then(|bytes| bytes.try_into().ok())
        .map(u64::from_le_bytes)
        .ok_or(Error::Corrupt("short fold end"))?;
    Ok((group, last))
}

#[cfg(test)]
mod tests;
