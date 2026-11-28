//! Rows a long list dropped from memory, kept on disk while the app runs so scrolling back
//! brings them back without holding them in RAM. Swift's `RowSpill` encodes each row and
//! orders every call on one utility queue; these are its pages.
//!
//! The spill is a stack of page files: a list evicts its oldest rows from the bottom of its
//! window, so each eviction is newer than every page already on disk, and scrolling back reads
//! the newest page first. A pop reads and deletes one page. The newest rows short of a page
//! wait in memory (at most `page_size - 1`) until the page fills.
//!
//! It is a cache, not an archive: it lives under Caches (the system may purge it), every spill
//! starts empty (`reset`), and it holds at most `max_rows` rows: past that the oldest page is
//! dropped, the way the list dropped it before there was a spill.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};

/// One list's spill on one directory. Calls do plain file I/O under one lock: the app makes
/// them off the main thread.
#[derive(Debug, uniffi::Object)]
pub struct RowSpillPages {
    directory: PathBuf,
    page_size: usize,
    max_rows: usize,
    /// The newest rows, fewer than a page, newest first.
    tail: Mutex<Vec<Vec<u8>>>,
}

#[uniffi::export]
impl RowSpillPages {
    /// The spill on `directory` (made when the first page fills), `page_size` rows a page, at
    /// most `max_rows` rows (at least one page).
    #[uniffi::constructor]
    pub fn new(directory: String, page_size: u32, max_rows: u32) -> Arc<Self> {
        let page_size = page_size.max(1) as usize;
        Arc::new(Self {
            directory: PathBuf::from(directory),
            page_size,
            max_rows: (max_rows as usize).max(page_size),
            tail: Mutex::new(Vec::new()),
        })
    }

    /// Keeps `rows` (newest first, all older than what the list still holds) above every row
    /// held. Whole pages go to disk, oldest first; fewer than a page stay in memory.
    pub fn push(&self, rows: Vec<Vec<u8>>) {
        if rows.is_empty() {
            return;
        }
        let mut tail = self.lock();
        let mut pending = rows;
        pending.append(&mut tail);
        let whole = pending.len() / self.page_size * self.page_size;
        let pages: Vec<Vec<u8>> = pending.drain(pending.len() - whole..).collect();
        *tail = pending;
        if whole == 0 {
            return;
        }
        if fs::create_dir_all(&self.directory).is_err() {
            return;
        }
        let mut existing = self.pages();
        let mut next = existing.last().map_or(0, |p| sequence(p)) + 1;
        // The oldest rows fill the lower pages.
        for page in pages.rchunks(self.page_size) {
            let url = self.page_path(next);
            store(page, &url);
            existing.push(url);
            next += 1;
        }
        // Past the cap the oldest pages go, as the list dropped rows before there was a spill.
        let max_pages = (self.max_rows / self.page_size).max(1);
        if existing.len() > max_pages {
            for url in &existing[..existing.len() - max_pages] {
                let _ = fs::remove_file(url);
            }
        }
    }

    /// Takes the newest page off (newest first): the rows in memory, else the top page file.
    /// Empty when the spill is.
    pub fn pop(&self) -> Vec<Vec<u8>> {
        let mut tail = self.lock();
        if !tail.is_empty() {
            return std::mem::take(&mut *tail);
        }
        let Some(top) = self.pages().pop() else { return Vec::new() };
        let rows = load(&top).unwrap_or_default();
        let _ = fs::remove_file(&top);
        rows
    }

    /// Deletes every spilled row and the directory.
    pub fn reset(&self) {
        let mut tail = self.lock();
        tail.clear();
        let _ = fs::remove_dir_all(&self.directory);
    }

    /// The rows short of a page that wait in memory, newest first (tests and measurements).
    pub fn rows_in_memory(&self) -> Vec<Vec<u8>> {
        self.lock().clone()
    }

    /// How many rows are held (tests and measurements; reads every page).
    pub fn stored_count(&self) -> u32 {
        let tail = self.lock();
        let on_disk: usize = self.pages().iter().map(|p| load(p).map_or(0, |r| r.len())).sum();
        (tail.len() + on_disk) as u32
    }
}

impl RowSpillPages {
    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<Vec<u8>>> {
        self.tail.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn pages(&self) -> Vec<PathBuf> {
        let Ok(entries) = fs::read_dir(&self.directory) else { return Vec::new() };
        let mut pages: Vec<PathBuf> = entries
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().is_some_and(|x| x == "page"))
            .collect();
        pages.sort_by(|a, b| a.file_name().cmp(&b.file_name()));
        pages
    }

    fn page_path(&self, sequence: u64) -> PathBuf {
        self.directory.join(format!("{sequence:012}.page"))
    }
}

fn sequence(path: &Path) -> u64 {
    path.file_stem().and_then(|s| s.to_str()).and_then(|s| s.parse().ok()).unwrap_or(0)
}

/// A page: each row as its length (u32, little endian) then its bytes. Written to a temporary
/// file and renamed, so a page is whole or absent.
fn store(rows: &[Vec<u8>], path: &Path) {
    let mut bytes = Vec::with_capacity(rows.iter().map(|r| r.len() + 4).sum());
    for row in rows {
        let Ok(len) = u32::try_from(row.len()) else { return };
        bytes.extend_from_slice(&len.to_le_bytes());
        bytes.extend_from_slice(row);
    }
    let tmp = path.with_extension("page-tmp");
    let written = fs::File::create(&tmp).and_then(|mut f| f.write_all(&bytes));
    if written.is_err() || fs::rename(&tmp, path).is_err() {
        let _ = fs::remove_file(&tmp);
    }
}

/// A page's rows; nil when it is missing or cut short.
fn load(path: &Path) -> Option<Vec<Vec<u8>>> {
    let bytes = fs::read(path).ok()?;
    let mut rows = Vec::new();
    let mut rest = bytes.as_slice();
    while !rest.is_empty() {
        let (len, body) = rest.split_at_checked(4)?;
        let len = u32::from_le_bytes(len.try_into().ok()?) as usize;
        let (row, after) = body.split_at_checked(len)?;
        rows.push(row.to_vec());
        rest = after;
    }
    Some(rows)
}

/// `scope` (an account or a chat id) as one folder name: letters, digits and `-` stay, every
/// other character is `_`; nothing left is `default`.
#[uniffi::export]
pub fn row_spill_folder_name(scope: String) -> String {
    if scope.is_empty() {
        return "default".to_owned();
    }
    scope.chars().map(|c| if c.is_alphanumeric() || c == '-' { c } else { '_' }).collect()
}

/// Deletes every folder under `parent` but `keep`: the spills earlier runs of the app left (a
/// killed app never deleted its spills).
#[uniffi::export]
pub fn row_spill_purge_runs(parent: String, keep: String) {
    let Ok(entries) = fs::read_dir(&parent) else { return };
    for entry in entries.flatten() {
        if entry.file_name().to_str() == Some(keep.as_str()) {
            continue;
        }
        let path = entry.path();
        let _ = if path.is_dir() { fs::remove_dir_all(&path) } else { fs::remove_file(&path) };
    }
}

#[cfg(test)]
#[path = "row_spill_tests.rs"]
mod tests;
