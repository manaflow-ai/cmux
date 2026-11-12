//! The two indexes of a book.
//!
//! `rows.idx` holds one 16-byte entry per rowId, at byte `rowId * 16`: `seg u32 | off u32 |
//! len u32 | rev u32`, where `off` is the record's offset in segment `seg` and `len` its row
//! text's length. `seg` 0 means the row has not settled. Lookups go through a read-only shared
//! mapping, so a window of 400 rows is 6.4 KB of page cache and no system call; writes are
//! `pwrite`s, so a writer's dirty pages are the kernel's, not this process's resident memory.
//! The file grows 64 KB at a time (sparse), and is only ever grown while mapped.
//!
//! `seq.idx` holds one 8-byte entry per 256 settle seqs, at byte `(seq / 256) * 8`: `seg u32 |
//! off u32` of the record with that seq. A resume from a cursor starts at the entry at or
//! before it and steps over at most 255 records.
//!
//! Neither file is the truth: both are rebuilt from the segments (all of them when there is no
//! checkpoint, else only what was written after it).

use super::record::le_u32;
use crate::fsio;
use std::fs::{File, OpenOptions};
use std::io;
use std::path::Path;

/// The size of one `rows.idx` entry.
pub const ROW_ENTRY_LEN: u64 = 16;
/// `rows.idx` grows by this much at a time.
const GROW: u64 = 64 * 1024;
const SEQ_ENTRY_LEN: u64 = 8;

/// Where a settled row's newest record is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Entry {
    pub seg: u32,
    /// The record's offset in the segment (its header's first byte).
    pub off: u32,
    /// The row text's length.
    pub len: u32,
    pub rev: u32,
}

pub(crate) struct RowIndex {
    file: File,
    len: u64,
    map: Map,
    dirty: bool,
}

impl RowIndex {
    /// Opens `path`, made if missing; emptied first when `reset` (a rebuild from the segments).
    pub(crate) fn open(path: &Path, reset: bool) -> io::Result<RowIndex> {
        let file =
            OpenOptions::new().read(true).write(true).create(true).truncate(false).open(path)?;
        if reset {
            file.set_len(0)?;
        }
        let len = file.metadata()?.len();
        let map = Map::new(&file, len)?;
        Ok(RowIndex { file, len, map, dirty: reset })
    }

    /// The entry of `row_id`, when the row has settled.
    pub(crate) fn get(&self, row_id: u64) -> Option<Entry> {
        let at = row_id.checked_mul(ROW_ENTRY_LEN)?;
        let mut raw = [0u8; 16];
        self.map.read(&self.file, at, &mut raw)?;
        let seg = le_u32(&raw, 0)?;
        if seg == 0 {
            return None;
        }
        Some(Entry { seg, off: le_u32(&raw, 4)?, len: le_u32(&raw, 8)?, rev: le_u32(&raw, 12)? })
    }

    /// Sets the entry of `row_id`; the bytes written (16).
    pub(crate) fn set(&mut self, row_id: u64, entry: Entry) -> io::Result<u64> {
        let too_large = || io::Error::other("rows.idx: the rowId is too large");
        let at = row_id.checked_mul(ROW_ENTRY_LEN).ok_or_else(too_large)?;
        let end = at.checked_add(ROW_ENTRY_LEN).ok_or_else(too_large)?;
        if end > self.len {
            let len = end.div_ceil(GROW).checked_mul(GROW).ok_or_else(too_large)?;
            self.file.set_len(len)?;
            self.map = Map::new(&self.file, len)?;
            self.len = len;
        }
        let mut raw = [0u8; 16];
        let fields = [entry.seg, entry.off, entry.len, entry.rev];
        for (cell, value) in raw.chunks_exact_mut(4).zip(fields) {
            cell.copy_from_slice(&value.to_le_bytes());
        }
        fsio::write_all_at(&self.file, &raw, at)?;
        self.dirty = true;
        Ok(ROW_ENTRY_LEN)
    }

    /// Clears the entry of `row_id`; the bytes written (16).
    pub(crate) fn clear(&mut self, row_id: u64) -> io::Result<u64> {
        let at = row_id
            .checked_mul(ROW_ENTRY_LEN)
            .ok_or_else(|| io::Error::other("rows.idx: the rowId is too large"))?;
        if at.saturating_add(ROW_ENTRY_LEN) > self.len {
            return Ok(0);
        }
        fsio::write_all_at(&self.file, &[0u8; 16], at)?;
        self.dirty = true;
        Ok(ROW_ENTRY_LEN)
    }

    pub(crate) fn max_row_id(&self) -> u64 {
        self.len.saturating_sub(1) / ROW_ENTRY_LEN
    }

    /// Returns entries whose records start at or after `off` in `seg`. This is used only when
    /// recovery found a torn tail; the normal checkpoint path never walks the whole index.
    pub(crate) fn entries_at_or_after(&self, seg: u32, off: u64) -> Vec<(u64, Entry)> {
        (1..=self.max_row_id())
            .filter_map(|row_id| {
                let entry = self.get(row_id)?;
                (entry.seg == seg && u64::from(entry.off) >= off).then_some((row_id, entry))
            })
            .collect()
    }

    pub(crate) fn mark_dirty(&mut self) {
        self.dirty = true;
    }

    /// Syncs the file when it changed since the last sync; whether it did.
    pub(crate) fn sync(&mut self) -> io::Result<bool> {
        if !self.dirty {
            return Ok(false);
        }
        fsio::sync(&self.file)?;
        self.dirty = false;
        Ok(true)
    }

    /// The bytes of address space the mapping takes (a gauge; resident memory is only the pages
    /// lookups touched).
    pub(crate) fn mapped_bytes(&self) -> u64 {
        self.len
    }
}

/// A read-only shared mapping of `rows.idx`.
#[cfg(unix)]
struct Map {
    start: *mut libc::c_void,
    len: usize,
}

// SAFETY: the mapping is plain memory this value owns; nothing about it is tied to a thread.
#[cfg(unix)]
unsafe impl Send for Map {}

#[cfg(unix)]
impl Map {
    fn new(file: &File, len: u64) -> io::Result<Map> {
        use std::os::fd::AsRawFd;
        let len =
            usize::try_from(len).map_err(|_| io::Error::other("rows.idx: too large to map"))?;
        if len == 0 {
            return Ok(Map { start: std::ptr::null_mut(), len: 0 });
        }
        // SAFETY: a new mapping at an address the kernel picks, of a descriptor `file` owns for
        // the whole call; no existing memory is touched.
        let start = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                len,
                libc::PROT_READ,
                libc::MAP_SHARED,
                file.as_raw_fd(),
                0,
            )
        };
        if start == libc::MAP_FAILED {
            return Err(io::Error::last_os_error());
        }
        Ok(Map { start, len })
    }

    /// Copies `out.len()` bytes at `at` into `out`; `None` when they are not all in the file.
    fn read(&self, _file: &File, at: u64, out: &mut [u8]) -> Option<()> {
        let at = usize::try_from(at).ok()?;
        let end = at.checked_add(out.len())?;
        if end > self.len {
            return None;
        }
        // SAFETY: `at..end` is inside the mapping (checked above), which lives as long as
        // `self`. The file is never shortened while it is mapped (the book's one owner only
        // grows it, and holds the book's lock), so every page of the mapping is backed. `out` is
        // a separate buffer, so the two do not overlap.
        unsafe {
            std::ptr::copy_nonoverlapping(
                self.start.cast::<u8>().add(at),
                out.as_mut_ptr(),
                out.len(),
            );
        }
        Some(())
    }
}

#[cfg(unix)]
impl Drop for Map {
    fn drop(&mut self) {
        if self.len != 0 {
            // SAFETY: `start..start+len` is the mapping `new` made, unmapped only here.
            unsafe {
                libc::munmap(self.start, self.len);
            }
        }
    }
}

/// Where there is no `mmap` in reach, the same lookups as reads at an offset.
#[cfg(not(unix))]
struct Map {
    len: u64,
}

#[cfg(not(unix))]
impl Map {
    fn new(_file: &File, len: u64) -> io::Result<Map> {
        Ok(Map { len })
    }

    fn read(&self, file: &File, at: u64, out: &mut [u8]) -> Option<()> {
        if at.checked_add(out.len() as u64)? > self.len {
            return None;
        }
        (fsio::read_at(file, out, at).ok()? == out.len()).then_some(())
    }
}

pub(crate) struct SeqIndex {
    file: File,
    dirty: bool,
}

impl SeqIndex {
    /// Opens `path`, made if missing; emptied first when `reset`.
    pub(crate) fn open(path: &Path, reset: bool) -> io::Result<SeqIndex> {
        let file =
            OpenOptions::new().read(true).write(true).create(true).truncate(false).open(path)?;
        if reset {
            file.set_len(0)?;
        }
        Ok(SeqIndex { file, dirty: reset })
    }

    /// The segment and offset of the record whose seq is `slot * 256`.
    pub(crate) fn get(&self, slot: u64) -> io::Result<Option<(u32, u32)>> {
        let Some(at) = slot.checked_mul(SEQ_ENTRY_LEN) else {
            return Ok(None);
        };
        let mut raw = [0u8; 8];
        if fsio::read_at(&self.file, &mut raw, at)? != raw.len() {
            return Ok(None);
        }
        Ok(match (le_u32(&raw, 0), le_u32(&raw, 4)) {
            (Some(seg), Some(off)) if seg != 0 => Some((seg, off)),
            _ => None,
        })
    }

    /// Sets the entry of `slot`; the bytes written (8).
    pub(crate) fn set(&mut self, slot: u64, seg: u32, off: u32) -> io::Result<u64> {
        let at = slot
            .checked_mul(SEQ_ENTRY_LEN)
            .ok_or_else(|| io::Error::other("seq.idx: the seq is too large"))?;
        let mut raw = [0u8; 8];
        for (cell, value) in raw.chunks_exact_mut(4).zip([seg, off]) {
            cell.copy_from_slice(&value.to_le_bytes());
        }
        fsio::write_all_at(&self.file, &raw, at)?;
        self.dirty = true;
        Ok(SEQ_ENTRY_LEN)
    }

    pub(crate) fn clear(&mut self, slot: u64) -> io::Result<u64> {
        let at = slot
            .checked_mul(SEQ_ENTRY_LEN)
            .ok_or_else(|| io::Error::other("seq.idx: the seq is too large"))?;
        if at.saturating_add(SEQ_ENTRY_LEN) > self.file.metadata()?.len() {
            return Ok(0);
        }
        fsio::write_all_at(&self.file, &[0u8; 8], at)?;
        self.dirty = true;
        Ok(SEQ_ENTRY_LEN)
    }

    pub(crate) fn mark_dirty(&mut self) {
        self.dirty = true;
    }

    pub(crate) fn max_slot(&self) -> u64 {
        self.file.metadata().map_or(0, |meta| meta.len().saturating_sub(1) / SEQ_ENTRY_LEN)
    }

    /// Syncs the file when it changed since the last sync.
    pub(crate) fn sync(&mut self) -> io::Result<bool> {
        if !self.dirty {
            return Ok(false);
        }
        fsio::sync(&self.file)?;
        self.dirty = false;
        Ok(true)
    }
}
