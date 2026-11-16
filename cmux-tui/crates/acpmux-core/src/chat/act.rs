//! Durable action envelopes for followed chats.
//!
//! This is an opt-in v2 seam. One writer owns `raw/acts.ndjson`; callers get
//! the byte place before and the byte cursor after each synced line. Replay is
//! bounded and never reads the history before the requested cursor.
#![deny(clippy::indexing_slicing, clippy::string_slice, clippy::expect_used)]
#![forbid(unsafe_code)]

use crate::chat::act_ids::{ActIdLookup, ActIdRing};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

pub const MAX_RAW_LINE_BYTES: usize = 256 * 1024;
pub const MAX_QUEUE_ENTRIES: usize = 1024;
pub const DEFAULT_REPLAY_BYTES: usize = MAX_RAW_LINE_BYTES;

/// The compact action line. These fields are deliberately stable: `k` is
/// always `act` for requests and `act_result` for outcomes.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ActEnvelope {
    pub k: String,
    pub op: String,
    pub id: String,
    pub at: u64,
    pub by: String,
    pub since: Option<u64>,
    /// Cursor in the followed transcript that caused this action.
    pub after: u64,
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
        Self {
            k: "act".into(),
            op: op.into(),
            id: id.into(),
            at,
            by: by.into(),
            since,
            after: 0,
            body,
        }
    }

    pub fn with_after(mut self, after: u64) -> Self {
        self.after = after;
        self
    }

    /// Compact JSON plus its newline. Oversized data is rejected before any
    /// filesystem mutation; the writer never spills bodies to another file.
    pub fn line(&self) -> io::Result<Vec<u8>> {
        let mut line = serde_json::to_vec(self).map_err(io::Error::other)?;
        line.push(b'\n');
        if line.len() > MAX_RAW_LINE_BYTES {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "too_large"));
        }
        Ok(line)
    }
}

/// Construct the durable outcome envelope. Outcomes are not queue actions.
pub fn act_result(
    id: impl Into<String>,
    at: u64,
    by: impl Into<String>,
    since: Option<u64>,
    body: Value,
) -> ActEnvelope {
    ActEnvelope {
        k: "act_result".into(),
        op: "act_result".into(),
        id: id.into(),
        at,
        by: by.into(),
        since,
        after: 0,
        body,
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ActReceipt {
    /// Byte place where the line starts in `acts.ndjson`.
    pub place: u64,
    /// Cursor immediately after the synced line.
    pub after: u64,
}

/// The sole writer for one followed chat. The map and action file are both
/// serialized through this writer; no blob directory is created.
pub struct FollowedChatWriter {
    inner: Mutex<WriterInner>,
    pub acts_path: PathBuf,
    pub map_path: PathBuf,
    chat_path: PathBuf,
}

struct WriterInner {
    acts: File,
}

impl FollowedChatWriter {
    pub fn open(chat: &Path, source_path: &Path, identity: &[u8]) -> io::Result<Self> {
        let raw = chat.join("raw");
        fs::create_dir_all(&raw)?;
        let acts_path = raw.join("acts.ndjson");
        let map_path = raw.join("raw.map");
        ensure_map(&map_path, source_path, identity)?;
        let mut acts = OpenOptions::new().create(true).append(true).read(true).open(&acts_path)?;
        repair_torn_tail(&mut acts)?;
        Ok(Self {
            inner: Mutex::new(WriterInner { acts }),
            acts_path,
            map_path,
            chat_path: chat.to_path_buf(),
        })
    }

    /// Append one action and return its byte place/cursor after sync.
    pub fn append(&self, envelope: &ActEnvelope) -> io::Result<ActReceipt> {
        let line = envelope.line()?;
        self.append_line(&line)
    }

    /// Append a batch with one sync. The returned receipt spans the complete
    /// batch and its place is the first line's byte offset.
    pub fn append_batch(&self, envelopes: &[ActEnvelope]) -> io::Result<ActReceipt> {
        let lines: Vec<Vec<u8>> =
            envelopes.iter().map(ActEnvelope::line).collect::<io::Result<_>>()?;
        let bytes = lines.iter().map(Vec::len).sum::<usize>();
        let mut inner = self.lock_inner()?;
        let place = inner.acts.metadata()?.len();
        for line in &lines {
            inner.acts.write_all(line)?;
        }
        inner.acts.sync_all()?;
        let after = place
            .checked_add(bytes as u64)
            .ok_or_else(|| io::Error::other("action offset overflow"))?;
        Ok(ActReceipt { place, after })
    }

    pub fn append_result(&self, result: &ActEnvelope) -> io::Result<ActReceipt> {
        if result.k != "act_result" || result.op != "act_result" {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "result must be act_result"));
        }
        self.append(result)
    }

    fn append_line(&self, line: &[u8]) -> io::Result<ActReceipt> {
        if line.len() > MAX_RAW_LINE_BYTES {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "too_large"));
        }
        let mut inner = self.lock_inner()?;
        let place = inner.acts.metadata()?.len();
        inner.acts.write_all(line)?;
        inner.acts.sync_all()?;
        let after = place
            .checked_add(line.len() as u64)
            .ok_or_else(|| io::Error::other("action offset overflow"))?;
        Ok(ActReceipt { place, after })
    }

    fn lock_inner(&self) -> io::Result<std::sync::MutexGuard<'_, WriterInner>> {
        self.inner.lock().map_err(|_| io::Error::other("action writer poisoned"))
    }
}

impl crate::chat::DaemonLineWriter for FollowedChatWriter {
    fn append_daemon_lines(&self, lines: &[&[u8]]) -> Result<u64, crate::chat::ActWriteError> {
        let mut inner = self.lock_inner()?;
        let place = inner.acts.metadata()?.len();
        let mut bytes = 0usize;
        for line in lines {
            crate::chat::validate_daemon_line(line)?;
            bytes = bytes.saturating_add(line.len());
        }
        for line in lines {
            if let Err(error) = inner.acts.write_all(line) {
                let _ = inner.acts.set_len(place);
                let _ = inner.acts.sync_all();
                return Err(error.into());
            }
        }
        inner.acts.sync_all()?;
        let _ = place
            .checked_add(bytes as u64)
            .ok_or_else(|| io::Error::other("action offset overflow"))?;
        Ok(place)
    }
}

fn ensure_map(path: &Path, source_path: &Path, identity: &[u8]) -> io::Result<()> {
    let mut file = OpenOptions::new().create(true).read(true).append(true).open(path)?;
    repair_torn_tail_inner(&mut file, MAX_RAW_LINE_BYTES)?;
    let path_text = source_path.to_string_lossy();
    let identity_text = hex_identity(identity);
    let same = last_map_entry(&mut file)?.is_some_and(|entry| {
        entry.get("path").and_then(Value::as_str) == Some(path_text.as_ref())
            && entry.get("identity").and_then(Value::as_str) == Some(identity_text.as_str())
    });
    if same {
        return Ok(());
    }
    let line = serde_json::json!({"kind":"file", "path": path_text, "identity": identity_text});
    let mut encoded = serde_json::to_vec(&line).map_err(io::Error::other)?;
    encoded.push(b'\n');
    let was_empty = file.metadata()?.len() == 0;
    file.write_all(&encoded)?;
    file.sync_all()?;
    if was_empty
        && let Some(parent) = path.parent()
        && let Ok(dir) = File::open(parent)
    {
        let _ = dir.sync_all();
    }
    Ok(())
}

fn hex_identity(identity: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(identity.len().saturating_mul(2));
    for byte in identity {
        let hi = HEX.get((byte >> 4) as usize).copied().unwrap_or(b'0');
        let lo = HEX.get((byte & 0x0f) as usize).copied().unwrap_or(b'0');
        out.push(hi as char);
        out.push(lo as char);
    }
    out
}

fn last_map_entry(file: &mut File) -> io::Result<Option<Value>> {
    let length = file.metadata()?.len();
    if length == 0 {
        return Ok(None);
    }
    let window = length.min(MAX_RAW_LINE_BYTES as u64);
    file.seek(SeekFrom::Start(length - window))?;
    let mut bytes = vec![0; usize::try_from(window).map_err(io::Error::other)?];
    file.read_exact(&mut bytes)?;
    let end = if bytes.last().copied() == Some(b'\n') {
        bytes.len().saturating_sub(1)
    } else {
        bytes.len()
    };
    let content = bytes.get(..end).unwrap_or_default();
    let start = content
        .iter()
        .rposition(|byte| *byte == b'\n')
        .map_or(0, |newline| newline.saturating_add(1));
    if start >= end {
        return Ok(None);
    }
    serde_json::from_slice(bytes.get(start..end).unwrap_or_default())
        .map(Some)
        .map_err(io::Error::other)
}

fn repair_torn_tail(file: &mut File) -> io::Result<()> {
    repair_torn_tail_inner(file, MAX_RAW_LINE_BYTES)
}

fn repair_torn_tail_inner(file: &mut File, cap: usize) -> io::Result<()> {
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
    let window = length.min(cap as u64);
    file.seek(SeekFrom::Start(length - window))?;
    let mut bytes = vec![0; usize::try_from(window).map_err(io::Error::other)?];
    file.read_exact(&mut bytes)?;
    if let Some(newline) = bytes.iter().rposition(|byte| *byte == b'\n') {
        file.set_len(length - window + newline as u64 + 1)?;
    } else {
        // A torn first line has no durable record and is cut to zero.
        file.set_len(0)?;
    }
    file.sync_all()
}

#[derive(Clone, Debug, PartialEq)]
pub struct ReplayBatch {
    pub entries: Vec<ActEnvelope>,
    pub next: u64,
    pub more: bool,
    /// Complete lines skipped because they were malformed or too large.
    pub skipped: usize,
}

/// Replay complete lines from a byte cursor. Malformed lines are counted and
/// skipped. A torn final line is ignored and reports `more: false`.
pub fn replay_from(path: &Path, after: u64, budget: usize) -> io::Result<ReplayBatch> {
    let mut file = File::open(path)?;
    let length = file.metadata()?.len();
    let start = after.min(length);
    file.seek(SeekFrom::Start(start))?;
    let mut reader = BufReader::new(file);
    let budget = budget.min(DEFAULT_REPLAY_BYTES);
    let mut entries = Vec::new();
    let mut skipped = 0usize;
    let mut used = 0usize;
    let mut cursor = start;
    loop {
        let mut line = Vec::new();
        let read = reader.read_until(b'\n', &mut line)?;
        if read == 0 {
            break;
        }
        if !line.ends_with(b"\n") {
            cursor = length;
            break;
        }
        if used > 0 && used.saturating_add(read) > budget {
            break;
        }
        cursor = cursor.saturating_add(read as u64);
        if read > MAX_RAW_LINE_BYTES {
            skipped = skipped.saturating_add(1);
            continue;
        }
        used = used.saturating_add(read);
        match serde_json::from_slice::<ActEnvelope>(&line) {
            Ok(entry) => entries.push(entry),
            Err(_) => skipped = skipped.saturating_add(1),
        }
    }
    Ok(ReplayBatch { entries, next: cursor, more: cursor < length && cursor != length, skipped })
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

/// Queue actions are projected into the translator's packed `QueueEntry`.
/// Prompt bodies carry `{promptId,at,held,place,span,textLen}`; retract bodies
/// carry `{promptId}`. The queue never stores a second body map.
pub struct ActorQueue {
    writer: FollowedChatWriter,
    state: acpmux_book::translate::State,
    ids: ActIdRing,
}

impl ActorQueue {
    pub fn new(writer: FollowedChatWriter) -> Self {
        let ids = ActIdRing::empty(&writer.chat_path);
        Self { writer, state: Default::default(), ids }
    }

    pub fn with_ids(writer: FollowedChatWriter, ids: ActIdRing) -> Self {
        Self { writer, state: Default::default(), ids }
    }
    pub fn len(&self) -> usize {
        self.state.queue_len()
    }

    pub fn apply(&mut self, envelope: ActEnvelope) -> Result<QueueReceipt, QueueError> {
        let after = envelope.after;
        self.apply_at(envelope, after)
    }

    pub fn apply_at(
        &mut self,
        envelope: ActEnvelope,
        transcript_after: u64,
    ) -> Result<QueueReceipt, QueueError> {
        if envelope.k != "act" || envelope.id.is_empty() || !allowed_op(&envelope.op) {
            return Err(QueueError::Invalid("invalid action envelope".into()));
        }
        let body = serde_json::to_vec(&envelope.body)
            .map_err(|error| QueueError::Io(error.to_string()))?;
        match self.ids.lookup_bytes_with_since(&envelope.id, &envelope.op, &body, envelope.since) {
            ActIdLookup::Replay { ack_seq } => {
                let receipt = ActReceipt { place: 0, after: ack_seq };
                return Ok(QueueReceipt {
                    receipt,
                    duplicate: true,
                    result: act_result(
                        envelope.id,
                        envelope.at,
                        envelope.by,
                        Some(ack_seq),
                        serde_json::json!({"ok":true,"replayed":true,"after":ack_seq}),
                    ),
                });
            }
            ActIdLookup::IdReuse => return Err(QueueError::Invalid("id_reuse".into())),
            ActIdLookup::IdUnknown => return Err(QueueError::Invalid("id_unknown".into())),
            ActIdLookup::New => {}
        }
        if envelope.op == "prompt" && self.state.act_queue_full() {
            return Err(QueueError::Full);
        }
        let stored = envelope.with_after(transcript_after);
        let line = stored.line().map_err(QueueError::from)?;
        self.state.validate_act(&line).map_err(|error| QueueError::Invalid(error.to_string()))?;
        let receipt = self.writer.append(&stored)?;
        self.state
            .apply_act(&line, receipt.place, line.len() as u64)
            .map_err(|error| QueueError::Invalid(error.to_string()))?;
        self.ids
            .remember_bytes(&stored.id, &stored.op, &body, receipt.after)
            .map_err(QueueError::from)?;
        let result = act_result(
            stored.id.clone(),
            stored.at,
            stored.by.clone(),
            Some(receipt.after),
            serde_json::json!({"ok":true,"op":stored.op,"after":receipt.after}),
        );
        let output = QueueReceipt { receipt, duplicate: false, result };
        Ok(output)
    }
}

fn allowed_op(op: &str) -> bool {
    matches!(op, "prompt" | "retract")
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::indexing_slicing, clippy::expect_used)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn writer(dir: &Path) -> FollowedChatWriter {
        FollowedChatWriter::open(dir, Path::new("source"), b"\x00\xff").unwrap()
    }

    #[test]
    fn envelope_and_outcome_have_distinct_kinds() {
        let request = ActEnvelope::new(
            "prompt",
            "p1",
            7,
            "person",
            None,
            serde_json::json!({"promptId":"p1"}),
        );
        assert_eq!(serde_json::from_slice::<Value>(&request.line().unwrap()).unwrap()["k"], "act");
        assert_eq!(act_result("p1", 8, "daemon", Some(7), Value::Null).k, "act_result");
    }

    #[test]
    fn map_only_changes_for_source_or_identity_and_identity_is_hex() {
        let dir = tempdir().unwrap();
        let first = writer(dir.path());
        let first_len = fs::metadata(&first.map_path).unwrap().len();
        let second = writer(dir.path());
        assert_eq!(first_len, fs::metadata(&second.map_path).unwrap().len());
        FollowedChatWriter::open(dir.path(), Path::new("source"), b"\x01").unwrap();
        let map = fs::read_to_string(&first.map_path).unwrap();
        assert!(map.contains("00ff"));
        assert!(map.contains("01"));
    }

    #[test]
    fn torn_first_line_is_cut_to_zero_and_replay_reports_no_more() {
        let dir = tempdir().unwrap();
        let raw = dir.path().join("raw");
        fs::create_dir_all(&raw).unwrap();
        fs::write(raw.join("acts.ndjson"), b"torn").unwrap();
        let writer = writer(dir.path());
        assert_eq!(fs::metadata(&writer.acts_path).unwrap().len(), 0);
        let batch = replay_from(&writer.acts_path, 0, DEFAULT_REPLAY_BYTES).unwrap();
        assert!(!batch.more);
    }

    #[test]
    fn malformed_lines_are_skipped_and_counted() {
        let dir = tempdir().unwrap();
        let writer = writer(dir.path());
        fs::write(&writer.acts_path, b"bad\n").unwrap();
        let batch = replay_from(&writer.acts_path, 0, DEFAULT_REPLAY_BYTES).unwrap();
        assert_eq!(batch.skipped, 1);
        assert!(batch.entries.is_empty());
    }

    #[test]
    fn queue_full_is_rejected_before_the_writer_and_replays_after_reopen() {
        let dir = tempdir().unwrap();
        let first_writer = writer(dir.path());
        let mut queue = ActorQueue::new(first_writer);
        for n in 0..MAX_QUEUE_ENTRIES {
            let line = ActEnvelope::new(
                "prompt",
                format!("p{n}"),
                0,
                "person",
                None,
                serde_json::json!({"promptId": format!("p{n}")}),
            )
            .line()
            .unwrap();
            queue.state.apply_act(&line, n as u64, line.len() as u64).unwrap();
        }
        let error = queue
            .apply(ActEnvelope::new("prompt", "new", 1, "person", None, Value::Null))
            .unwrap_err();
        assert_eq!(error, QueueError::Full);
        assert_eq!(fs::metadata(dir.path().join("raw/acts.ndjson")).unwrap().len(), 0);
        let dir2 = tempdir().unwrap();
        let first = writer(dir2.path());
        let path = first.acts_path.clone();
        let mut q = ActorQueue::new(first);
        let request =
            ActEnvelope::new("prompt", "p", 1, "person", None, serde_json::json!({"promptId":"p"}));
        let receipt = q.apply(request).unwrap();
        drop(q);
        let reopened = writer(dir2.path());
        let replay = replay_from(&path, 0, DEFAULT_REPLAY_BYTES).unwrap();
        assert_eq!(replay.entries.len(), 1);
        assert_eq!(replay.next, receipt.receipt.after);
        assert_eq!(replay.entries[0].k, "act");
        drop(reopened);
    }
}
