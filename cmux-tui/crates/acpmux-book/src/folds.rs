//! Derived group boundaries, owned by the chat's sole book writer.
//!
//! A checkpoint records the committed byte length. Recovery truncates the suffix,
//! then translation appends groups again even when the row log says already settled.
#![deny(clippy::indexing_slicing, clippy::string_slice, clippy::expect_used)]

use crate::{fsio, log::Error};
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::Path;

pub const ENTRY_BYTES: u64 = 16;

pub struct Folds {
    file: File,
    len: u64,
    last_group: u64,
    stopped: bool,
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
        let last_group = if checkpoint_len == 0 {
            0
        } else {
            file.seek(SeekFrom::Start(checkpoint_len - ENTRY_BYTES))?;
            let (group, last) = read_entry(&mut file)?;
            if group == 0 || group > last {
                return Err(Error::Corrupt("invalid fold boundary"));
            }
            group
        };
        if actual != checkpoint_len {
            file.set_len(checkpoint_len)?;
            fsio::sync(&file)?;
        }
        file.seek(SeekFrom::Start(checkpoint_len))?;
        Ok(Self { file, len: checkpoint_len, last_group, stopped: false })
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
        if group <= self.last_group || group > last {
            return Err(Error::InvalidInput("fold groups must rise and not exceed their last row"));
        }
        let len =
            self.len.checked_add(ENTRY_BYTES).ok_or(Error::InvalidInput("fold index overflow"))?;
        self.stopped = true;
        self.file.write_all(&group.to_le_bytes())?;
        self.file.write_all(&last.to_le_bytes())?;
        self.len = len;
        self.last_group = group;
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
}

fn read_entry(file: &mut File) -> Result<(u64, u64), Error> {
    let mut group = [0; 8];
    let mut last = [0; 8];
    file.read_exact(&mut group)?;
    file.read_exact(&mut last)?;
    Ok((u64::from_le_bytes(group), u64::from_le_bytes(last)))
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
