//! Durable action envelopes for followed chats.
//!
//! This module is opt-in: the v1 event log and actor do not call into it. Actions are one compact
//! JSON envelope per line, with a byte cursor (`after`) returned by the sole writer. Replays seek
//! to that cursor and read a bounded number of bytes, so reconnecting never walks whole history.
#![deny(clippy::indexing_slicing, clippy::string_slice, clippy::expect_used)]
#![forbid(unsafe_code)]

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, VecDeque};
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

pub const MAX_RAW_LINE_BYTES: usize = 256 * 1024;
pub const MAX_QUEUE_ENTRIES: usize = 1024;
pub const DEFAULT_REPLAY_BYTES: usize = 256 * 1024;

/// The one raw envelope persisted by a followed chat.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ActEnvelope {
    pub k: String,
    pub op: String,
    pub id: String,
    pub at: u64,
    pub by: String,
    pub since: Option<u64>,
    pub body: Value,
}

impl ActEnvelope {
    pub fn new(
        op: impl Into<String>,
        id: impl Into<String>,
        at: u64,
        by: impl Into<String>,
        since: Option<u64>,
        body: Value,
    ) -> Self {
        Self { k: "act".into(), op: op.into(), id: id.into(), at, by: by.into(), since, body }
    }

    /// Compact JSON plus its trailing newline, bounded before it reaches the writer.
    pub fn line(&self) -> io::Result<Vec<u8>> {
        let mut line = serde_json::to_vec(self).map_err(io::Error::other)?;
        line.push(b'\n');
        if line.len() > MAX_RAW_LINE_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "raw action line exceeds 256 KiB",
            ));
        }
        Ok(line)
    }
}

/// Build an external outcome while retaining the same envelope shape.
pub fn act_result(
    id: impl Into<String>,
    at: u64,
    by: impl Into<String>,
    since: Option<u64>,
    body: Value,
) -> ActEnvelope {
    ActEnvelope::new("act_result", id, at, by, since, body)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BlobRef {
    pub id: String,
    pub bytes: u64,
}

impl BlobRef {
    fn value(&self) -> Value {
        serde_json::json!({"blob": {"id": self.id, "bytes": self.bytes}})
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ActReceipt {
    /// Byte offset immediately after the durable line; this is the replay cursor.
    pub after: u64,
    pub start: u64,
    pub end: u64,
    pub blob: bool,
}

/// The sole append writer for one followed chat. `raw.map` is synced before its first action.
pub struct FollowedChatWriter {
    inner: Mutex<WriterInner>,
    pub acts_path: PathBuf,
    pub map_path: PathBuf,
    blobs: PathBuf,
}

struct WriterInner {
    acts: File,
}

impl FollowedChatWriter {
    pub fn open(chat: &Path, source_path: &Path, identity: &[u8]) -> io::Result<Self> {
        let raw = chat.join("raw");
        let blobs = raw.join("blobs");
        fs::create_dir_all(&blobs)?;
        let acts_path = raw.join("acts.ndjson");
        let map_path = raw.join("raw.map");
        let mut map = OpenOptions::new().create(true).append(true).open(&map_path)?;
        let map_line = serde_json::json!({"kind":"file", "path":source_path.to_string_lossy(), "identity":String::from_utf8_lossy(identity)});
        let mut encoded = serde_json::to_vec(&map_line).map_err(io::Error::other)?;
        encoded.push(b'\n');
        map.write_all(&encoded)?;
        map.sync_all()?;
        let mut acts = OpenOptions::new().create(true).append(true).read(true).open(&acts_path)?;
        repair_torn_tail(&mut acts)?;
        Ok(Self { inner: Mutex::new(WriterInner { acts }), acts_path, map_path, blobs })
    }

    /// Append one action, spilling only an oversized body to `raw/blobs/`.
    pub fn append(&self, envelope: &ActEnvelope) -> io::Result<ActReceipt> {
        let mut inner =
            self.inner.lock().map_err(|_| io::Error::other("action writer poisoned"))?;
        let (line, blob) = self.encode_with_blob(envelope)?;
        let start = inner.acts.metadata()?.len();
        inner.acts.write_all(&line)?;
        inner.acts.sync_all()?;
        let end = start
            .checked_add(line.len() as u64)
            .ok_or_else(|| io::Error::other("action offset overflow"))?;
        Ok(ActReceipt { after: end, start, end, blob: blob.is_some() })
    }

    /// Persist an external outcome. Results use the same envelope but are kept out of queue
    /// admission and transition state.
    pub fn append_result(&self, result: &ActEnvelope) -> io::Result<ActReceipt> {
        if result.op != "act_result" {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "result operation must be act_result",
            ));
        }
        self.append(result)
    }

    fn encode_with_blob(&self, envelope: &ActEnvelope) -> io::Result<(Vec<u8>, Option<BlobRef>)> {
        match envelope.line() {
            Ok(line) => Ok((line, None)),
            Err(error) if error.kind() == io::ErrorKind::InvalidData => {
                let body = serde_json::to_vec(&envelope.body).map_err(io::Error::other)?;
                let id = format!("{}-body", sanitize_id(&envelope.id));
                let path = self.blobs.join(&id);
                let mut file = OpenOptions::new().create_new(true).write(true).open(&path)?;
                file.write_all(&body)?;
                file.sync_all()?;
                let reference = BlobRef { id, bytes: body.len() as u64 };
                let reduced = ActEnvelope { body: reference.value(), ..envelope.clone() };
                Ok((reduced.line()?, Some(reference)))
            }
            Err(error) => Err(error),
        }
    }
}

fn repair_torn_tail(file: &mut File) -> io::Result<()> {
    let length = file.metadata()?.len();
    if length == 0 {
        return Ok(());
    }
    file.seek(SeekFrom::Start(length - 1))?;
    let mut last = [0u8; 1];
    file.read_exact(&mut last)?;
    if last[0] == b'\n' {
        return Ok(());
    }
    let window = length.min(MAX_RAW_LINE_BYTES as u64);
    file.seek(SeekFrom::Start(length - window))?;
    let mut bytes = vec![0; usize::try_from(window).map_err(io::Error::other)?];
    file.read_exact(&mut bytes)?;
    let Some(newline) = bytes.iter().rposition(|byte| *byte == b'\n') else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "raw action torn tail exceeds 256 KiB",
        ));
    };
    file.set_len(length - window + newline as u64 + 1)?;
    file.sync_all()
}

fn sanitize_id(id: &str) -> String {
    let mut out = String::with_capacity(id.len().min(80));
    for byte in id.bytes().take(80) {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_') {
            out.push(byte as char);
        } else {
            out.push('_');
        }
    }
    if out.is_empty() { "action".into() } else { out }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ReplayBatch {
    pub entries: Vec<ActEnvelope>,
    pub next: u64,
    pub more: bool,
}

/// Replay from a byte cursor. A partial final line is left for the next call.
pub fn replay_from(path: &Path, after: u64, budget: usize) -> io::Result<ReplayBatch> {
    let mut file = File::open(path)?;
    let length = file.metadata()?.len();
    let start = after.min(length);
    file.seek(SeekFrom::Start(start))?;
    let mut reader = BufReader::new(file);
    let mut entries = Vec::new();
    let mut used = 0usize;
    let mut cursor = start;
    loop {
        let mut line = Vec::new();
        let read = reader.read_until(b'\n', &mut line)?;
        if read == 0 {
            break;
        }
        if !line.ends_with(b"\n") {
            return Ok(ReplayBatch { entries, next: cursor, more: true });
        }
        if !entries.is_empty() && used.saturating_add(read) > budget {
            break;
        }
        if entries.is_empty() && read > budget {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "replay budget is smaller than one action",
            ));
        }
        used = used.saturating_add(read);
        cursor = cursor.saturating_add(read as u64);
        entries.push(serde_json::from_slice::<ActEnvelope>(&line).map_err(io::Error::other)?);
    }
    Ok(ReplayBatch { entries, next: cursor, more: cursor < length })
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum QueueError {
    Full,
    Invalid(String),
    Io(String),
}
impl From<io::Error> for QueueError {
    fn from(error: io::Error) -> Self {
        Self::Io(error.to_string())
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct QueueReceipt {
    pub receipt: ActReceipt,
    pub duplicate: bool,
    pub result: ActEnvelope,
}

#[derive(Clone, Debug, PartialEq)]
struct QueueItem {
    body: Value,
    held: bool,
}

/// Bounded, idempotent action transitions. State is committed only after the line is durable.
pub struct ActorQueue {
    writer: FollowedChatWriter,
    items: BTreeMap<String, QueueItem>,
    receipts: BTreeMap<(String, String), QueueReceipt>,
    receipt_order: VecDeque<(String, String)>,
}

impl ActorQueue {
    pub fn new(writer: FollowedChatWriter) -> Self {
        Self {
            writer,
            items: BTreeMap::new(),
            receipts: BTreeMap::new(),
            receipt_order: VecDeque::new(),
        }
    }
    pub fn len(&self) -> usize {
        self.items.len()
    }

    pub fn apply(&mut self, envelope: ActEnvelope) -> Result<QueueReceipt, QueueError> {
        if envelope.k != "act" || envelope.op == "act_result" || envelope.id.is_empty() {
            return Err(QueueError::Invalid("invalid action envelope".into()));
        }
        let operation = (envelope.op.clone(), envelope.id.clone());
        if let Some(receipt) = self.receipts.get(&operation) {
            return Ok(QueueReceipt { duplicate: true, ..receipt.clone() });
        }
        let target = action_target(&envelope);
        if envelope.op == "prompt"
            && !self.items.contains_key(target)
            && self.items.len() >= MAX_QUEUE_ENTRIES
        {
            return Err(QueueError::Full);
        }
        let mut next_items = self.items.clone();
        transition(&mut next_items, &envelope)?;
        let receipt = self.writer.append(&envelope)?;
        self.items = next_items;
        let result = act_result(
            envelope.id.clone(),
            envelope.at,
            envelope.by.clone(),
            Some(receipt.after),
            serde_json::json!({"ok":true,"op":envelope.op}),
        );
        let out = QueueReceipt { receipt, duplicate: false, result };
        if self.receipt_order.len() >= MAX_QUEUE_ENTRIES {
            if let Some(oldest) = self.receipt_order.pop_front() {
                self.receipts.remove(&oldest);
            }
        }
        self.receipt_order.push_back(operation.clone());
        self.receipts.insert(operation, out.clone());
        Ok(out)
    }
}

fn transition(
    items: &mut BTreeMap<String, QueueItem>,
    envelope: &ActEnvelope,
) -> Result<(), QueueError> {
    let target = action_target(envelope);
    match envelope.op.as_str() {
        "prompt" => {
            let held = envelope.body.get("held").and_then(Value::as_bool).unwrap_or(false);
            items
                .entry(target.into())
                .or_insert_with(|| QueueItem { body: envelope.body.clone(), held });
        }
        "retract" | "remove" => {
            items.remove(target);
        }
        "edit" => {
            if let Some(item) = items.get_mut(target) {
                item.body = envelope.body.clone();
            }
        }
        "clear" => items.clear(),
        "supersede" => {
            let old = envelope.body.get("old").and_then(Value::as_str).unwrap_or_default();
            let new = envelope.body.get("new").and_then(Value::as_str).unwrap_or_default();
            if old.is_empty() || new.is_empty() {
                return Err(QueueError::Invalid("supersede needs old and new".into()));
            }
            items.remove(old);
            items
                .entry(new.into())
                .or_insert_with(|| QueueItem { body: envelope.body.clone(), held: false });
        }
        "resume" => {
            if let Some(item) = items.get_mut(target) {
                item.held = false;
            }
        }
        _ => return Err(QueueError::Invalid(format!("unknown action operation: {}", envelope.op))),
    }
    Ok(())
}

fn action_target(envelope: &ActEnvelope) -> &str {
    envelope
        .body
        .get("promptId")
        .or_else(|| envelope.body.get("target"))
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .unwrap_or(&envelope.id)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::indexing_slicing, clippy::expect_used)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn envelope_is_one_compact_act_line() {
        let line =
            ActEnvelope::new("prompt", "p1", 7, "person", None, serde_json::json!({"text":"hi"}))
                .line()
                .unwrap();
        assert!(line.ends_with(b"\n"));
        let value: Value = serde_json::from_slice(&line).unwrap();
        assert_eq!(value["k"], "act");
        assert_eq!(value["op"], "prompt");
    }

    #[test]
    fn queue_full_is_checked_before_the_writer() {
        let dir = tempdir().unwrap();
        let writer = FollowedChatWriter::open(dir.path(), Path::new("source"), b"x").unwrap();
        let mut queue = ActorQueue::new(writer);
        for n in 0..MAX_QUEUE_ENTRIES {
            queue.items.insert(format!("p{n}"), QueueItem { body: Value::Null, held: false });
        }
        let error = queue
            .apply(ActEnvelope::new("prompt", "new", 1, "person", None, Value::Null))
            .unwrap_err();
        assert_eq!(error, QueueError::Full);
        assert_eq!(fs::metadata(dir.path().join("raw/acts.ndjson")).unwrap().len(), 0);
    }

    #[test]
    fn replay_uses_after_cursor_and_duplicate_is_idempotent() {
        let dir = tempdir().unwrap();
        let writer = FollowedChatWriter::open(dir.path(), Path::new("source"), b"x").unwrap();
        let path = writer.acts_path.clone();
        let mut queue = ActorQueue::new(writer);
        let first =
            queue.apply(ActEnvelope::new("prompt", "p", 1, "person", None, Value::Null)).unwrap();
        let duplicate =
            queue.apply(ActEnvelope::new("prompt", "p", 1, "person", None, Value::Null)).unwrap();
        assert!(duplicate.duplicate);
        assert_eq!(first.receipt.after, duplicate.receipt.after);
        assert_eq!(replay_from(&path, 0, DEFAULT_REPLAY_BYTES).unwrap().entries.len(), 1);
        assert!(
            replay_from(&path, first.receipt.after, DEFAULT_REPLAY_BYTES)
                .unwrap()
                .entries
                .is_empty()
        );
    }

    #[test]
    fn receipt_memory_is_bounded_to_queue_capacity() {
        let dir = tempdir().unwrap();
        let writer = FollowedChatWriter::open(dir.path(), Path::new("source"), b"x").unwrap();
        let mut queue = ActorQueue::new(writer);
        for n in 0..=MAX_QUEUE_ENTRIES {
            queue
                .apply(ActEnvelope::new("remove", format!("p{n}"), 1, "person", None, Value::Null))
                .unwrap();
        }
        assert_eq!(queue.receipts.len(), MAX_QUEUE_ENTRIES);
        assert_eq!(queue.receipt_order.len(), MAX_QUEUE_ENTRIES);
    }

    #[test]
    fn oversized_body_is_replaced_by_a_blob_reference() {
        let dir = tempdir().unwrap();
        let writer = FollowedChatWriter::open(dir.path(), Path::new("source"), b"x").unwrap();
        let body = serde_json::json!({"text": "x".repeat(MAX_RAW_LINE_BYTES)});
        let receipt =
            writer.append(&ActEnvelope::new("prompt", "large", 1, "person", None, body)).unwrap();
        assert!(receipt.blob);
        let batch = replay_from(&writer.acts_path, 0, DEFAULT_REPLAY_BYTES).unwrap();
        assert!(batch.entries[0].body.get("blob").is_some());
        assert!(fs::read_dir(dir.path().join("raw/blobs")).unwrap().next().is_some());
    }
}
