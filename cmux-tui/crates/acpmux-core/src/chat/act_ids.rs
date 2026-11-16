//! Durable idempotency receipts for the v2 `act` request.
//!
//! The ring is intentionally independent of action execution. A writer can
//! inspect a receipt before doing work, then remember the committed sequence
//! after its daemon line has been synced. The file sits beside `checkpoint` and
//! is replaced atomically on every remember, so a restart sees either the old
//! or the new complete ring.

use sha2::{Digest, Sha256};
use std::collections::VecDeque;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

pub const ACT_ID_CAPACITY: usize = 1024;
pub const ACT_ID_ENTRY_BYTES: usize = 32;
pub const ACT_IDS_FILE: &str = "act-ids";

const MAGIC: &[u8; 4] = b"AIDR";
const VERSION: u32 = 1;
const HEADER_BYTES: usize = 16;

/// The result of looking up an id in the retained receipt window.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ActIdLookup {
    /// The id and operation/body hash match a durable receipt.
    Replay { ack_seq: u64 },
    /// The id is retained, but its operation or body differs.
    IdReuse,
    /// The id is absent and the sender's cursor is still covered by the ring.
    New,
    /// The id is not in the retained window (including an id evicted from it).
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

/// One fixed-size receipt. The on-disk representation is exactly these 32
/// bytes: 16 bytes of id hash, 8 bytes of operation/body hash, and 8 bytes of
/// the acknowledged sequence.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ActIdReceipt {
    pub id_hash: [u8; 16],
    pub op_body_hash: u64,
    pub ack_seq: u64,
}

/// The newest [`ACT_ID_CAPACITY`] action receipts for one chat.
#[derive(Clone, Debug)]
pub struct ActIdRing {
    path: PathBuf,
    entries: VecDeque<ActIdReceipt>,
}

impl ActIdRing {
    /// Opens the ring beside `book`, treating a missing file as an empty ring.
    pub fn open(book: &Path) -> io::Result<Self> {
        let path = book.join(ACT_IDS_FILE);
        let entries = match File::open(&path) {
            Ok(mut file) => decode(&mut file)?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => VecDeque::new(),
            Err(error) => return Err(error),
        };
        Ok(Self { path, entries })
    }

    /// Alias for [`Self::open`] for callers that treat the receipt file as a
    /// small durable store.
    pub fn new(book: &Path) -> io::Result<Self> {
        Self::open(book)
    }

    /// Constructs an empty ring writing to `book` when the first receipt lands.
    pub fn empty(book: &Path) -> Self {
        Self { path: book.join(ACT_IDS_FILE), entries: VecDeque::new() }
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

    /// Looks up an id using the canonical JSON bytes of `body`.
    ///
    /// Without a sender cursor, a miss is conservatively treated as a new id.
    /// Call [`Self::lookup_with_since`] when the request supplies `since` so a
    /// miss older than the retained window can be rejected as `id_unknown`.
    pub fn lookup(&self, id: &str, op: &str, body: &serde_json::Value) -> ActIdLookup {
        let body = serde_json::to_vec(body).unwrap_or_default();
        self.lookup_bytes_with_since(id, op, &body, None)
    }

    /// Looks up an id using already-encoded body bytes.
    pub fn lookup_bytes(&self, id: &str, op: &str, body: &[u8]) -> ActIdLookup {
        self.lookup_bytes_with_since(id, op, body, None)
    }

    /// Looks up an id while applying the sender's oldest known sequence.
    ///
    /// A missing id is `new` when the ring still reaches `since` (or when no
    /// cursor was supplied). It is `id_unknown` only when `since` predates the
    /// oldest retained acknowledgement, which proves the ring can no longer
    /// decide whether that id was previously committed.
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
            return if since
                .is_some_and(|since| self.oldest_seq().is_some_and(|oldest| since < oldest))
            {
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

    pub fn check(&self, id: &str, op: &str, body: &serde_json::Value) -> ActIdLookup {
        self.lookup(id, op, body)
    }

    /// The oldest acknowledged sequence still retained by this ring.
    pub fn oldest_seq(&self) -> Option<u64> {
        self.entries.iter().map(|entry| entry.ack_seq).min()
    }

    /// Appends a receipt and atomically persists the newest window.
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

    /// Appends a receipt using already-encoded body bytes.
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

    pub fn record(
        &mut self,
        id: &str,
        op: &str,
        body: &serde_json::Value,
        ack_seq: u64,
    ) -> io::Result<()> {
        self.remember(id, op, body, ack_seq)
    }

    /// Records a pre-hashed receipt. This is useful to a writer that already
    /// serialized the request body before appending its daemon line.
    pub fn remember_receipt(&mut self, receipt: ActIdReceipt) -> io::Result<()> {
        self.entries.retain(|entry| entry.id_hash != receipt.id_hash);
        self.entries.push_back(receipt);
        while self.entries.len() > ACT_ID_CAPACITY {
            self.entries.pop_front();
        }
        self.persist()
    }

    fn persist(&self) -> io::Result<()> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)?;
        }
        let temporary = self.path.with_extension("new");
        let mut file =
            OpenOptions::new().create(true).truncate(true).write(true).open(&temporary)?;
        encode(&mut file, &self.entries)?;
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
    digest[..16].try_into().unwrap_or_default()
}

pub fn hash_op_body(op: &str, body: &[u8]) -> u64 {
    let mut hasher = Sha256::new();
    hasher.update(op.as_bytes());
    hasher.update([0]);
    hasher.update(body);
    let digest = hasher.finalize();
    u64::from_le_bytes(digest[..8].try_into().unwrap_or_default())
}

fn encode(mut output: impl Write, entries: &VecDeque<ActIdReceipt>) -> io::Result<()> {
    output.write_all(MAGIC)?;
    output.write_all(&VERSION.to_le_bytes())?;
    output.write_all(&(entries.len() as u32).to_le_bytes())?;
    output.write_all(&[0; 4])?;
    for entry in entries {
        output.write_all(&entry.id_hash)?;
        output.write_all(&entry.op_body_hash.to_le_bytes())?;
        output.write_all(&entry.ack_seq.to_le_bytes())?;
    }
    Ok(())
}

fn decode(mut input: impl Read) -> io::Result<VecDeque<ActIdReceipt>> {
    let mut bytes = Vec::new();
    input.read_to_end(&mut bytes)?;
    if bytes.len() < HEADER_BYTES || &bytes[..4] != MAGIC {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid act id ring header"));
    }
    let version = u32::from_le_bytes(bytes[4..8].try_into().unwrap_or_default());
    let count = u32::from_le_bytes(bytes[8..12].try_into().unwrap_or_default()) as usize;
    if version != VERSION || count > ACT_ID_CAPACITY {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid act id ring version or count",
        ));
    }
    let expected = HEADER_BYTES.saturating_add(count.saturating_mul(ACT_ID_ENTRY_BYTES));
    if bytes.len() != expected {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid act id ring length"));
    }
    let mut entries = VecDeque::with_capacity(count);
    for chunk in bytes[HEADER_BYTES..].chunks_exact(ACT_ID_ENTRY_BYTES) {
        let mut id_hash = [0; 16];
        id_hash.copy_from_slice(&chunk[..16]);
        entries.push_back(ActIdReceipt {
            id_hash,
            op_body_hash: u64::from_le_bytes(chunk[16..24].try_into().unwrap_or_default()),
            ack_seq: u64::from_le_bytes(chunk[24..32].try_into().unwrap_or_default()),
        });
    }
    Ok(entries)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn same_id_and_body_replays_and_changed_body_is_reuse() {
        let home = tempfile::tempdir().unwrap();
        let mut ring = ActIdRing::empty(home.path());
        ring.remember("id", "append", &serde_json::json!({"text":"one"}), 41).unwrap();
        assert_eq!(
            ring.lookup("id", "append", &serde_json::json!({"text":"one"})),
            ActIdLookup::Replay { ack_seq: 41 }
        );
        assert_eq!(
            ring.lookup("id", "append", &serde_json::json!({"text":"two"})),
            ActIdLookup::IdReuse
        );
    }

    #[test]
    fn evicted_ids_are_new_without_cursor_but_unknown_before_window() {
        let home = tempfile::tempdir().unwrap();
        let mut ring = ActIdRing::empty(home.path());
        for seq in 0..=ACT_ID_CAPACITY {
            ring.remember(&format!("id-{seq}"), "op", &serde_json::json!(seq), seq as u64).unwrap();
        }
        assert_eq!(ring.len(), ACT_ID_CAPACITY);
        assert_eq!(ring.lookup("id-0", "op", &serde_json::json!(0)), ActIdLookup::New);
        assert_eq!(ring.oldest_seq(), Some(1));
        assert_eq!(
            ring.lookup_with_since("id-0", "op", &serde_json::json!(0), Some(0)),
            ActIdLookup::IdUnknown
        );
        assert_eq!(
            ring.lookup_with_since("new-id", "op", &serde_json::json!(0), Some(1)),
            ActIdLookup::New
        );
        assert_eq!(
            ring.lookup("id-1024", "op", &serde_json::json!(1024)),
            ActIdLookup::Replay { ack_seq: 1024 }
        );
    }

    #[test]
    fn ring_reopens_from_atomic_file() {
        let home = tempfile::tempdir().unwrap();
        let mut ring = ActIdRing::empty(home.path());
        ring.remember("id", "op", &serde_json::json!(true), 9).unwrap();
        let ring = ActIdRing::open(home.path()).unwrap();
        assert_eq!(
            ring.lookup("id", "op", &serde_json::json!(true)),
            ActIdLookup::Replay { ack_seq: 9 }
        );
        assert!(!home.path().join("act-ids.new").exists());
    }
}
