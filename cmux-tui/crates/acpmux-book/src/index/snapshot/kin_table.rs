//! Optional, snapshot-bound cold kin index (decisions 302–310).
//!
//! Snapshot ACIDX003 is unchanged: older readers ignore this separate file.
//! Open reads only its 4 KiB header. Pages are checked lazily; any failure
//! disables this handle once, without renaming a potentially newer sidecar.
use crate::index::RowKey;
use std::fs::File;
use std::io::{self, Read, Write};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

mod build;
mod format;
mod sort;
#[cfg(test)]
mod tests;
pub(in crate::index) use build::Builder;

pub(crate) const ENTRY_BYTES: usize = 32;
const TABLE_HEADER_BYTES: usize = 4096;
const PAGE_BYTES: usize = 4096;
const ENTRIES_PER_PAGE: usize = 127;
const SLOTS_PER_PAGE: usize = 511;
const FAMILY_KIND: u8 = 1;
const FORK_KIND: u8 = 2;
const MAX_DEPTH: u8 = 64;
const _: () =
    assert!(crate::index::MAX_INDEX_RECORD_BYTES + super::TRAILER_BYTES <= u16::MAX as usize);
static TABLE_FAILURES: AtomicUsize = AtomicUsize::new(0);
static WRITE_FAILURES: AtomicUsize = AtomicUsize::new(0);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct Entry {
    pub hash: u64,
    pub activity: u64,
    pub offset: u64,
    pub check: u32,
    pub len: u16,
    pub depth: u8,
    pub kind: u8,
}

impl Entry {
    fn encode(self, mut out: &mut [u8]) -> io::Result<()> {
        if out.len() != ENTRY_BYTES {
            return Err(invalid("kin entry length"));
        }
        out.write_all(&self.hash.to_le_bytes())?;
        out.write_all(&self.activity.to_le_bytes())?;
        out.write_all(&self.offset.to_le_bytes())?;
        out.write_all(&self.check.to_le_bytes())?;
        out.write_all(&self.len.to_le_bytes())?;
        out.write_all(&[self.depth, self.kind])
    }

    fn decode(mut bytes: &[u8]) -> io::Result<Self> {
        if bytes.len() != ENTRY_BYTES {
            return Err(invalid("kin entry length"));
        }
        let hash = u64::from_le_bytes(take_bytes(&mut bytes)?);
        let activity = u64::from_le_bytes(take_bytes(&mut bytes)?);
        let offset = u64::from_le_bytes(take_bytes(&mut bytes)?);
        let check = u32::from_le_bytes(take_bytes(&mut bytes)?);
        let len = u16::from_le_bytes(take_bytes(&mut bytes)?);
        let [depth, kind] = take_bytes(&mut bytes)?;
        Ok(Self { hash, activity, offset, check, len, depth, kind })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct Binding {
    pub head_crc: u32,
    pub seq: u64,
    pub count: u64,
    pub data_end: u64,
}

#[derive(Debug)]
pub(super) struct TableHeader {
    pub entries: u64,
    pub slots: u32,
    pub directory_pages: u32,
    pub packed_entries: u64,
}

#[derive(Debug)]
#[cfg_attr(not(test), allow(dead_code))] // PR2 consumes the retained handle and page metadata.
pub(super) struct Table {
    file: File,
    pub header: TableHeader,
    disabled: AtomicBool,
}

impl Table {
    pub(super) fn open(path: &Path, binding: Binding) -> io::Result<Option<Self>> {
        let mut file = match File::open(path) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        let mut bytes = [0; TABLE_HEADER_BYTES];
        file.read_exact(&mut bytes)?;
        let header = format::decode_header(&bytes, binding, file.metadata()?.len())?;
        Ok(Some(Self { file, header, disabled: AtomicBool::new(false) }))
    }

    pub(super) fn is_usable(&self) -> bool {
        !self.disabled.load(Ordering::Relaxed)
    }

    /// Read a whole CRC page. A caller falling back must discard any partial
    /// answer from the table. No later read on this snapshot retries the table.
    /// Page 0 is the directory's first page (the header is not a data page).
    #[allow(dead_code)] // PR1 establishes failure handling; PR2 routes list reads here.
    pub(super) fn read_page(&self, index: u64) -> Option<[u8; PAGE_BYTES]> {
        if !self.is_usable() {
            return None;
        }
        let result = (|| {
            let pages = u64::from(self.header.directory_pages)
                + self.header.packed_entries.div_ceil(ENTRIES_PER_PAGE as u64);
            if index >= pages {
                return Err(invalid("kin page outside extent"));
            }
            let mut bytes = [0; PAGE_BYTES];
            super::read_at(
                &self.file,
                &mut bytes,
                TABLE_HEADER_BYTES as u64 + index * PAGE_BYTES as u64,
            )?;
            if read_u32(&bytes[PAGE_BYTES - 4..])? != crc32fast::hash(&bytes[..PAGE_BYTES - 4]) {
                return Err(invalid("kin page checksum"));
            }
            Ok(bytes)
        })();
        match result {
            Ok(bytes) => Some(bytes),
            Err(error) => {
                self.disable(&error);
                None
            }
        }
    }

    #[allow(dead_code)] // Also used when PR2 observes a referenced frame CRC failure.
    pub(super) fn disable(&self, error: &io::Error) {
        if !self.disabled.swap(true, Ordering::Relaxed) {
            table_failure(error);
        }
    }

    #[cfg(test)]
    fn failures(&self) -> usize {
        usize::from(self.disabled.load(Ordering::Relaxed))
    }
}

impl Builder {
    #[cfg(test)]
    fn write(
        self,
        path: &Path,
        head_crc: u32,
        seq: u64,
        count: u64,
        data_end: u64,
    ) -> io::Result<u64> {
        format::write_table(path, Binding { head_crc, seq, count, data_end }, self.finish()?)
    }
}

/// A single owned namespace binds all spill files to this staged table.
/// Child sorters drop before this guard; restart reclaims numeric compaction
/// stage namespaces if the process died before their RAII cleanup ran.
pub(super) struct WorkDirectory {
    path: std::path::PathBuf,
}
impl WorkDirectory {
    pub(super) fn new(table: &Path) -> io::Result<Self> {
        let mut name = table.as_os_str().to_os_string();
        name.push(".work");
        let path = std::path::PathBuf::from(name);
        let mut builder = std::fs::DirBuilder::new();
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder.create(&path)?;
        Ok(Self { path })
    }
    pub(super) fn path(&self) -> &Path {
        &self.path
    }
}
impl Drop for WorkDirectory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir(&self.path);
    }
}

pub(super) fn finish_table(
    builder: Builder,
    path: &Path,
    binding: Binding,
) -> io::Result<(u128, u128)> {
    let started = std::time::Instant::now();
    let entries = builder.finish()?;
    let closure_ns = started.elapsed().as_nanos();
    let started = std::time::Instant::now();
    format::write_table(path, binding, entries)?;
    Ok((closure_ns, started.elapsed().as_nanos()))
}

pub(super) fn table_failure(error: &io::Error) {
    TABLE_FAILURES.fetch_add(1, Ordering::Relaxed);
    eprintln!("cold kin table set aside for snapshot: {error}");
}

pub(in crate::index) fn write_failure(error: &io::Error) {
    WRITE_FAILURES.fetch_add(1, Ordering::Relaxed);
    eprintln!("cold kin table write failed; snapshot remains authoritative: {error}");
}

pub(crate) fn key_fingerprint(key: &RowKey, kind: u8) -> (u64, u32) {
    let mut crc = crc32fast::Hasher::new();
    let mut hash = 0xcbf29ce484222325u64;
    for bytes in [
        &[kind][..],
        &(key.origin.len() as u32).to_le_bytes(),
        key.origin.as_bytes(),
        key.chat_id.as_bytes(),
    ] {
        crc.update(bytes);
        for byte in bytes {
            hash = (hash ^ u64::from(*byte)).wrapping_mul(0x100000001b3);
        }
    }
    hash ^= hash >> 33;
    hash = hash.wrapping_mul(0xff51afd7ed558ccd);
    hash ^= hash >> 33;
    hash = hash.wrapping_mul(0xc4ceb9fe1a85ec53);
    hash ^= hash >> 33;
    (hash, crc.finalize())
}

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}
fn read_u32(bytes: &[u8]) -> io::Result<u32> {
    Ok(u32::from_le_bytes(bytes.try_into().map_err(|_| invalid("kin integer"))?))
}
fn read_u64(bytes: &[u8]) -> io::Result<u64> {
    Ok(u64::from_le_bytes(bytes.try_into().map_err(|_| invalid("kin integer"))?))
}

/// Consume a fixed field without indexing untrusted or truncated record bytes.
fn take_bytes<const N: usize>(bytes: &mut &[u8]) -> io::Result<[u8; N]> {
    let mut field = [0; N];
    bytes.read_exact(&mut field)?;
    Ok(field)
}
