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
mod tests {
    use super::*;

    #[test]
    fn write_failure_stops_the_owner_until_reopen() -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("folds.idx");
        let mut folds = Folds::open(&path, 0)?;
        folds.append(2, 8)?;
        folds.sync()?;
        drop(folds);
        // A read-only descriptor makes the write fail without a filesystem-wide fault.
        let mut stopped = Folds {
            file: File::open(&path)?,
            len: ENTRY_BYTES,
            last_group: 2,
            last_row: 8,
            stopped: false,
            counters: Counters::default(),
        };
        assert!(matches!(stopped.append(10, 20), Err(Error::Io(_))));
        assert_eq!(stopped.len(), ENTRY_BYTES);
        assert!(matches!(stopped.append(10, 20), Err(Error::Stopped)));
        assert!(matches!(stopped.sync(), Err(Error::Stopped)));
        drop(stopped);
        let mut reopened = Folds::open(&path, ENTRY_BYTES)?;
        reopened.append(10, 20)?;
        reopened.sync()?;
        assert_eq!(reopened.len(), 2 * ENTRY_BYTES);
        Ok(())
    }

    #[test]
    fn checkpoint_suffix_is_replayed_once() -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("folds.idx");
        let mut folds = Folds::open(&path, 0)?;
        folds.append(2, 8)?;
        folds.sync()?;
        let checkpoint = folds.len();
        folds.append(10, 20)?;
        drop(folds);
        // Include a torn final entry, as a killed writer can leave.
        OpenOptions::new().append(true).open(&path)?.write_all(&[1, 2, 3])?;
        let mut folds = Folds::open(&path, checkpoint)?;
        assert_eq!(folds.len(), ENTRY_BYTES);
        folds.append(10, 20)?;
        folds.sync()?;
        assert_eq!(folds.len(), 2 * ENTRY_BYTES);
        let mut reader = File::open(&path)?;
        assert_eq!(read_entry(&mut reader)?, (2, 8));
        assert_eq!(read_entry(&mut reader)?, (10, 20));
        assert_eq!(reader.metadata()?.len(), 2 * ENTRY_BYTES);
        Ok(())
    }

    #[test]
    fn missing_checkpoint_bytes_are_damage() -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("folds.idx");
        assert!(matches!(Folds::open(&path, ENTRY_BYTES), Err(Error::Corrupt(_))));
        assert!(matches!(Folds::open(&path, 1), Err(Error::Corrupt(_))));
        let mut folds = Folds::open(&path, 0)?;
        assert!(matches!(folds.append(0, 1), Err(Error::InvalidInput(_))));
        folds.append(2, 8)?;
        assert!(matches!(folds.append(2, 8), Err(Error::InvalidInput(_))));
        assert!(matches!(folds.append(10, 9), Err(Error::InvalidInput(_))));
        Ok(())
    }

    #[test]
    fn overlapping_and_nested_ranges_are_refused_before_and_after_reopen()
    -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("folds.idx");
        let mut folds = Folds::open(&path, 0)?;
        folds.append(2, 8)?;
        for (group, last) in [(3, 4), (7, 10), (8, 9)] {
            assert!(matches!(folds.append(group, last), Err(Error::InvalidInput(_))));
            assert_eq!(folds.len(), ENTRY_BYTES);
        }
        folds.sync()?;
        drop(folds);
        let mut folds = Folds::open(&path, ENTRY_BYTES)?;
        assert!(matches!(folds.append(8, 20), Err(Error::InvalidInput(_))));
        folds.append(9, 9)?;
        folds.append(10, 20)?;
        assert_eq!(folds.containing(8)?, Some(Entry { group: 2, last: 8 }));
        assert_eq!(folds.containing(9)?, Some(Entry { group: 9, last: 9 }));
        assert_eq!(folds.containing(10)?, Some(Entry { group: 10, last: 20 }));
        assert_eq!(folds.len(), 3 * ENTRY_BYTES);
        Ok(())
    }

    #[test]
    fn search_finds_the_entry_at_or_before_a_row() -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        let mut folds = Folds::open(&dir.path().join("folds.idx"), 0)?;
        assert_eq!(folds.search(5)?, None);
        assert_eq!(folds.entry_at(0)?, None);
        // Folds (10k+1 ..= 10k+5) for k in 1..=1000; rows 10k+6 ..= 10k+10 are gaps.
        for k in 1..=1000u64 {
            folds.append(10 * k + 1, 10 * k + 5)?;
        }
        let rows = [0, 1, 10, 11, 13, 15, 16, 20, 21, 5_000, 5_001, 9_999, 10_001, 10_006, 99_999];
        for row in rows {
            let expected = (1..=1000u64)
                .rev()
                .map(|k| (k - 1, Entry { group: 10 * k + 1, last: 10 * k + 5 }))
                .find(|(_, entry)| entry.group <= row);
            assert_eq!(folds.search(row)?, expected, "row {row}");
            let within = expected.map(|(_, entry)| entry).filter(|entry| row <= entry.last);
            assert_eq!(folds.containing(row)?, within, "row {row}");
            if let Some((position, entry)) = expected {
                assert_eq!(folds.entry_at(position)?, Some(entry));
            }
        }
        assert_eq!(folds.entry_at(1000)?, None);
        // A row in the last fold reads nothing; one near the end a few entries.
        let before = folds.stats();
        assert_eq!(folds.search(10_003)?.map(|(position, _)| position), Some(999));
        let after = folds.stats();
        assert_eq!(
            (after.searches - before.searches, after.search_reads),
            (1, before.search_reads)
        );
        folds.search(9_993)?;
        assert!(folds.stats().search_reads - after.search_reads <= 3);
        let before = folds.stats();
        folds.search(13)?;
        let after = folds.stats();
        assert_eq!(after.searches - before.searches, 1);
        assert!(after.search_reads - before.search_reads <= 2 * 11, "logarithmic in the distance");
        assert_eq!(folds.entry_at(3)?, Some(Entry { group: 41, last: 45 }));
        assert_eq!(folds.stats().entry_reads - after.entry_reads, 1);
        Ok(())
    }
}
