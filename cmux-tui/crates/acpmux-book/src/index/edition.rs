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
        let path = directory.join("index.edition");
        let previous = match File::open(&path) {
            Ok(mut file) => {
                let mut bytes = [0; RECORD_BYTES];
                match file.read_exact(&mut bytes) {
                    Ok(()) => decode(&bytes),
                    Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => None,
                    Err(error) => return Err(error),
                }
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => None,
            Err(error) => return Err(error),
        };
        if let Some((edition, old_boot)) = previous
            && old_boot == boot
        {
            return Ok(Self { edition, boot, writes: 0 });
        }
        let edition = match previous {
            Some((edition, _)) => edition.checked_add(1).unwrap_or(1),
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
        let mut file =
            OpenOptions::new().create(true).truncate(true).write(true).open(&temporary)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        fs::rename(temporary, path)?;
        File::open(directory)?.sync_all()?;
        Ok(Self { edition, boot, writes: 1 })
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
mod tests {
    use super::*;

    #[test]
    fn same_boot_never_rewrites_and_new_boot_is_durable_before_return() {
        let dir = tempfile::tempdir().unwrap();
        let first = IndexEdition::open(dir.path(), 123, false, || 7).unwrap();
        assert_eq!(first.edition, 1);
        for _ in 0..50 {
            let same =
                IndexEdition::open(dir.path(), 123, true, || panic!("no randomness")).unwrap();
            assert_eq!((same.edition, same.writes), (1, 0));
        }
        let next = IndexEdition::open(dir.path(), 124, true, || 7).unwrap();
        assert_eq!((next.edition, next.writes), (2, 1));
        let restart = IndexEdition::open(dir.path(), 124, true, || 7).unwrap();
        assert_eq!((restart.edition, restart.writes), (2, 0));
    }

    #[test]
    fn damaged_record_uses_injected_nonzero_random_edition() {
        let dir = tempfile::tempdir().unwrap();
        for cut in 0..RECORD_BYTES {
            fs::write(dir.path().join("index.edition"), vec![0; cut]).unwrap();
            assert_eq!(IndexEdition::open(dir.path(), 1, true, || 73).unwrap().edition, 73);
        }
        fs::write(dir.path().join("index.edition"), []).unwrap();
        assert_eq!(IndexEdition::open(dir.path(), 1, true, || 0).unwrap().edition, 1);
    }
}
