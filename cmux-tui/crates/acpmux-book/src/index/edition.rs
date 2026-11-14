//! A boot fences cursors that may have escaped before the last log sync.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::Path;

const MAGIC: &[u8; 4] = b"ILST";
const RECORD_BYTES: usize = 24;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct IndexEdition {
    pub edition: u32,
    pub boot: u64,
    /// Observability for the same-boot no-write contract.
    pub writes: u32,
}

impl IndexEdition {
    /// Completes the small durable fence before the opener exposes a writer.
    /// The random source is injected; zero is mapped to one, without retrying.
    pub fn open(
        directory: &Path,
        boot: u64,
        has_records: bool,
        random: impl FnOnce() -> u32,
    ) -> io::Result<Self> {
        Self::open_inner(directory, boot, has_records, random, false)
    }

    /// Opens the edition after the durable index has been quarantined. A
    /// rebuild is a new cursor epoch even when the daemon keeps the same boot
    /// number, so a valid same-boot edition is advanced and an absent or
    /// damaged one gets a random fence that cannot be the first-start values.
    pub fn open_rebuild(
        directory: &Path,
        boot: u64,
        random: impl FnOnce() -> u32,
    ) -> io::Result<Self> {
        Self::open_inner(directory, boot, true, random, true)
    }

    fn open_inner(
        directory: &Path,
        boot: u64,
        has_records: bool,
        random: impl FnOnce() -> u32,
        rebuild: bool,
    ) -> io::Result<Self> {
        let path = directory.join("index.edition");
        // An edition is only a cursor fence. If the file is unreadable, keep
        // the random in-memory fence and let the derived index open; a
        // permissions or transient storage error must not stop the daemon.
        let previous = match File::open(&path) {
            Ok(mut file) => {
                let mut bytes = [0; RECORD_BYTES];
                match file.read_exact(&mut bytes) {
                    Ok(()) => decode(&bytes),
                    Err(_) => None,
                }
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => None,
            Err(_) => None,
        };
        if !rebuild
            && let Some((edition, old_boot)) = previous
            && old_boot == boot
        {
            return Ok(Self { edition, boot, writes: 0 });
        }
        let edition = match previous {
            Some((edition, _)) => edition.checked_add(1).unwrap_or(1),
            None if rebuild => random().max(2),
            None if has_records => random().max(1),
            None => 1,
        };
        let mut bytes = Vec::with_capacity(RECORD_BYTES);
        bytes.extend_from_slice(MAGIC);
        bytes.extend_from_slice(&1_u32.to_le_bytes());
        bytes.extend_from_slice(&edition.to_le_bytes());
        bytes.extend_from_slice(&boot.to_le_bytes());
        bytes.extend_from_slice(&crc32fast::hash(&bytes).to_le_bytes());
        let temporary = directory.join("index.edition.new");
        let persisted = (|| -> io::Result<()> {
            let mut file =
                OpenOptions::new().create(true).truncate(true).write(true).open(&temporary)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            fs::rename(&temporary, &path)?;
            File::open(directory)?.sync_all()?;
            Ok(())
        })();
        if persisted.is_ok() {
            Ok(Self { edition, boot, writes: 1 })
        } else {
            // Keep the in-memory fence. The next successful open will repair
            // the small durable marker; callers still get a live hub now.
            let _ = fs::remove_file(temporary);
            Ok(Self { edition, boot, writes: 0 })
        }
    }
}

fn decode(bytes: &[u8]) -> Option<(u32, u64)> {
    if bytes.get(..4)? != MAGIC || bytes.get(4..8)? != 1_u32.to_le_bytes() {
        return None;
    }
    let edition = u32::from_le_bytes(bytes.get(8..12)?.try_into().ok()?);
    let boot = u64::from_le_bytes(bytes.get(12..20)?.try_into().ok()?);
    let crc = u32::from_le_bytes(bytes.get(20..24)?.try_into().ok()?);
    (edition != 0 && crc32fast::hash(bytes.get(..20)?) == crc).then_some((edition, boot))
}

#[cfg(test)]
mod tests;
