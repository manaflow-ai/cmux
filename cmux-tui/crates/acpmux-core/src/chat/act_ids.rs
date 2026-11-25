//! Durable idempotency receipts for the v2 `act` request.
//!
//! Receipts accumulate in memory while the actor appends daemon lines. A
//! checkpoint calls [`ActIdRing::save`] once, so an action never causes a
//! second sync or a per-action metadata write.

use sha2::{Digest, Sha256};
use std::collections::VecDeque;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

pub const ACT_ID_CAPACITY: usize = 1024;
pub const ACT_ID_ENTRY_BYTES: usize = 32;
pub const ACT_IDS_FILE: &str = "act-ids";

const MAGIC: &[u8; 4] = b"AIDR";
const VERSION: u32 = 2;
// magic, version, count, floor-present, floor, checkpoint-through
const HEADER_BYTES: usize = 32;
const MAX_RING_BYTES: usize = HEADER_BYTES + ACT_ID_CAPACITY * ACT_ID_ENTRY_BYTES;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ActIdLookup {
    Replay { ack_seq: u64 },
    IdReuse,
    New,
    IdUnknown,
}

impl ActIdLookup {
    pub fn code(self) -> &'static str {
        match self {
            Self::Replay { .. } => "ack",
            Self::IdReuse => "id_reuse",
            Self::New => "new",
            Self::IdUnknown => "id_unknown",
        }
    }

    pub fn ack_seq(self) -> Option<u64> {
        match self {
            Self::Replay { ack_seq } => Some(ack_seq),
            Self::IdReuse | Self::New | Self::IdUnknown => None,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ActIdReceipt {
    pub id_hash: [u8; 16],
    pub op_body_hash: u64,
    pub ack_seq: u64,
}

#[derive(Clone, Debug)]
pub struct ActIdRing {
    path: PathBuf,
    entries: VecDeque<ActIdReceipt>,
    /// Set only after an entry is evicted. `open_at` uses the checkpoint as a
    /// conservative floor when the receipt file is absent or damaged.
    floor: Option<u64>,
    through: u64,
}

impl ActIdRing {
    /// Opens a ring without a checkpoint fallback. Missing or malformed files
    /// become an empty ring with no floor.
    pub fn open(book: &Path) -> io::Result<Self> {
        Self::open_inner(book, None)
    }

    /// Opens a ring associated with a book checkpoint. Missing, short, or
    /// damaged receipt files are tolerated and start at that checkpoint floor.
    pub fn open_at(book: &Path, checkpoint_seq: u64) -> io::Result<Self> {
        Self::open_inner(book, Some(checkpoint_seq))
    }

    fn open_inner(book: &Path, checkpoint_seq: Option<u64>) -> io::Result<Self> {
        let path = book.join(ACT_IDS_FILE);
        let (entries, floor, through) = match File::open(&path) {
            Ok(mut file) => match decode(&mut file) {
                Ok((entries, floor, through)) => (entries, floor, through),
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::InvalidData | io::ErrorKind::UnexpectedEof
                    ) =>
                {
                    (VecDeque::new(), checkpoint_seq, checkpoint_seq.unwrap_or_default())
                }
                Err(error) => return Err(error),
            },
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                (VecDeque::new(), checkpoint_seq, checkpoint_seq.unwrap_or_default())
            }
            Err(error) => return Err(error),
        };
        Ok(Self { path, entries, floor, through })
    }

    pub fn empty(book: &Path) -> Self {
        Self { path: book.join(ACT_IDS_FILE), entries: VecDeque::new(), floor: None, through: 0 }
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn floor(&self) -> Option<u64> {
        self.floor
    }

    pub fn through(&self) -> u64 {
        self.through
    }

    pub fn lookup(&self, id: &str, op: &str, body: &serde_json::Value) -> ActIdLookup {
        let body = serde_json::to_vec(body).unwrap_or_default();
        self.lookup_bytes_with_since(id, op, &body, None)
    }

    pub fn lookup_bytes(&self, id: &str, op: &str, body: &[u8]) -> ActIdLookup {
        self.lookup_bytes_with_since(id, op, body, None)
    }

    pub fn lookup_with_since(
        &self,
        id: &str,
        op: &str,
        body: &serde_json::Value,
        since: Option<u64>,
    ) -> ActIdLookup {
        let body = serde_json::to_vec(body).unwrap_or_default();
        self.lookup_bytes_with_since(id, op, &body, since)
    }

    pub fn lookup_bytes_with_since(
        &self,
        id: &str,
        op: &str,
        body: &[u8],
        since: Option<u64>,
    ) -> ActIdLookup {
        let id_hash = hash_id(id);
        let op_body_hash = hash_op_body(op, body);
        let Some(receipt) = self.entries.iter().rev().find(|entry| entry.id_hash == id_hash) else {
            return if since.is_some_and(|cursor| self.floor.is_some_and(|floor| cursor <= floor)) {
                ActIdLookup::IdUnknown
            } else {
                ActIdLookup::New
            };
        };
        if receipt.op_body_hash == op_body_hash {
            ActIdLookup::Replay { ack_seq: receipt.ack_seq }
        } else {
            ActIdLookup::IdReuse
        }
    }

    /// Records a receipt in memory. Persistence is deferred to `save` at the
    /// next checkpoint. Call this only after the daemon line is committed.
    pub fn remember(
        &mut self,
        id: &str,
        op: &str,
        body: &serde_json::Value,
        ack_seq: u64,
    ) -> io::Result<()> {
        let body = serde_json::to_vec(body).map_err(io::Error::other)?;
        self.remember_bytes(id, op, &body, ack_seq)
    }

    pub fn remember_bytes(
        &mut self,
        id: &str,
        op: &str,
        body: &[u8],
        ack_seq: u64,
    ) -> io::Result<()> {
        self.remember_receipt(ActIdReceipt {
            id_hash: hash_id(id),
            op_body_hash: hash_op_body(op, body),
            ack_seq,
        })
    }

    pub fn remember_receipt(&mut self, receipt: ActIdReceipt) -> io::Result<()> {
        self.entries.retain(|entry| entry.id_hash != receipt.id_hash);
        self.entries.push_back(receipt);
        if self.entries.len() > ACT_ID_CAPACITY
            && let Some(evicted) = self.entries.pop_front()
        {
            self.floor =
                Some(self.floor.map_or(evicted.ack_seq, |floor| floor.max(evicted.ack_seq)));
        }
        Ok(())
    }

    pub fn oldest_seq(&self) -> Option<u64> {
        self.entries.iter().map(|entry| entry.ack_seq).min()
    }

    /// Saves one checkpoint-consistent snapshot. Receipts after `through` are
    /// excluded because they belong to the uncheckpointed tail.
    pub fn save(&self, through: u64) -> io::Result<()> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)?;
        }
        let temporary = self.path.with_extension("new");
        let mut file =
            OpenOptions::new().create(true).truncate(true).write(true).open(&temporary)?;
        let entries = self
            .entries
            .iter()
            .copied()
            .filter(|entry| entry.ack_seq <= through)
            .collect::<VecDeque<_>>();
        let floor = self.floor.filter(|floor| *floor <= through);
        encode(&mut file, &entries, floor, through)?;
        file.sync_all()?;
        fs::rename(&temporary, &self.path)?;
        if let Some(parent) = self.path.parent()
            && let Ok(directory) = File::open(parent)
        {
            let _ = directory.sync_all();
        }
        Ok(())
    }
}

pub fn hash_id(id: &str) -> [u8; 16] {
    let digest = Sha256::digest(id.as_bytes());
    digest.first_chunk::<16>().map_or([0; 16], |chunk| *chunk)
}

pub fn hash_op_body(op: &str, body: &[u8]) -> u64 {
    let mut hasher = Sha256::new();
    hasher.update(op.as_bytes());
    hasher.update([0]);
    hasher.update(body);
    let digest = hasher.finalize();
    digest.first_chunk::<8>().map_or(0, |chunk| u64::from_le_bytes(*chunk))
}

fn encode(
    mut output: impl Write,
    entries: &VecDeque<ActIdReceipt>,
    floor: Option<u64>,
    through: u64,
) -> io::Result<()> {
    output.write_all(MAGIC)?;
    output.write_all(&VERSION.to_le_bytes())?;
    output.write_all(&(entries.len() as u32).to_le_bytes())?;
    output.write_all(&[u8::from(floor.is_some()); 4])?;
    output.write_all(&floor.unwrap_or_default().to_le_bytes())?;
    output.write_all(&through.to_le_bytes())?;
    for entry in entries {
        output.write_all(&entry.id_hash)?;
        output.write_all(&entry.op_body_hash.to_le_bytes())?;
        output.write_all(&entry.ack_seq.to_le_bytes())?;
    }
    Ok(())
}

fn decode(mut input: impl Read) -> io::Result<(VecDeque<ActIdReceipt>, Option<u64>, u64)> {
    let mut bounded = input.by_ref().take((MAX_RING_BYTES + 1) as u64);
    let mut header = [0; HEADER_BYTES];
    bounded.read_exact(&mut header)?;
    let (magic, rest) = header.split_first_chunk::<4>().ok_or_else(invalid_ring)?;
    let (version_bytes, rest) = rest.split_first_chunk::<4>().ok_or_else(invalid_ring)?;
    let (count_bytes, rest) = rest.split_first_chunk::<4>().ok_or_else(invalid_ring)?;
    let (flags, floor_bytes) = rest.split_first_chunk::<4>().ok_or_else(invalid_ring)?;
    let (floor_value, through_bytes) =
        floor_bytes.split_first_chunk::<8>().ok_or_else(invalid_ring)?;
    let (through_value, _) = through_bytes.split_first_chunk::<8>().ok_or_else(invalid_ring)?;
    if magic != MAGIC || u32::from_le_bytes(*version_bytes) != VERSION {
        return Err(invalid_ring());
    }
    let count = usize::try_from(u32::from_le_bytes(*count_bytes)).map_err(|_| invalid_ring())?;
    if count > ACT_ID_CAPACITY || flags.iter().any(|flag| *flag > 1) {
        return Err(invalid_ring());
    }
    let floor =
        if flags.first() == Some(&1) { Some(u64::from_le_bytes(*floor_value)) } else { None };
    let mut entries = VecDeque::with_capacity(count);
    let mut bytes = [0; ACT_ID_ENTRY_BYTES];
    for _ in 0..count {
        bounded.read_exact(&mut bytes)?;
        let (id_hash, rest) = bytes.split_first_chunk::<16>().ok_or_else(invalid_ring)?;
        let (op_hash, seq) = rest.split_first_chunk::<8>().ok_or_else(invalid_ring)?;
        let seq = seq.first_chunk::<8>().ok_or_else(invalid_ring)?;
        entries.push_back(ActIdReceipt {
            id_hash: *id_hash,
            op_body_hash: u64::from_le_bytes(*op_hash),
            ack_seq: u64::from_le_bytes(*seq),
        });
    }
    let mut trailing = [0; 1];
    if bounded.read(&mut trailing)? != 0 {
        return Err(invalid_ring());
    }
    Ok((entries, floor, u64::from_le_bytes(*through_value)))
}

fn invalid_ring() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "invalid act id ring")
}

#[cfg(test)]
#[path = "act_ids_tests.rs"]
mod tests;
