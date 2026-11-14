//! Fixed byte storage for list resume. No retained row, per-record allocation,
//! or search by sequence; the entry slot is the offset from the first seq.
use super::{ListItem, SummaryEvent};
use acpmux_book::index::Summary;
use serde::{Deserialize, Serialize};
use std::hash::{DefaultHasher, Hasher};
use std::io::{self, Write};
use std::sync::Arc;
#[cfg(test)]
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

const CREDIT_WINDOW_BYTES: usize = 1024 * 1024;
// Every encoded op is longer than 32 bytes, including an empty gone at seq 0.
const MIN_OP_BYTES: usize = 32;

#[derive(Clone, Copy, Default)]
struct Entry {
    seq: u64,
    start: usize,
    len: usize,
    checksum: u64,
}

pub(super) struct History {
    bytes: Box<[u8]>,
    entries: Box<[Entry]>,
    head: usize,
    len: usize,
    first: u64,
    tail: usize,
    used: usize,
    #[cfg(test)]
    encoded_ops: AtomicUsize,
    #[cfg(test)]
    raw_copies: Arc<AtomicUsize>,
    #[cfg(test)]
    raw_copy_permit: Arc<AtomicBool>,
    #[cfg(test)]
    raw_copy_waiting: Arc<AtomicBool>,
    #[cfg(test)]
    snapshot_open_permit: Arc<AtomicBool>,
    #[cfg(test)]
    snapshot_open_waiting: Arc<AtomicBool>,
}

/// A sparse fixed-size ring for the local rows sent to peer links. Sequence
/// numbers still advance for every index record, but remote-origin records do
/// not allocate bytes here. The peer connection can therefore copy the raw
/// peer projection without decoding or re-encoding the local operation ring.
pub(super) struct PeerHistory {
    bytes: Box<[u8]>,
    entries: Box<[Entry]>,
    head: usize,
    len: usize,
    first: u64,
    floor: u64,
    last: u64,
    tail: usize,
    used: usize,
}

/// A comma-separated span of the already encoded operations in the ring.
/// The connection wraps these bytes in the delta envelope without decoding
/// or re-encoding an operation for each subscriber.
pub(crate) struct RawSpan {
    pub(crate) bytes: Vec<u8>,
    pub(crate) last_seq: u64,
    entries: Vec<Entry>,
}

impl RawSpan {
    pub(super) fn folder(bytes: Vec<u8>, last_seq: u64) -> Self {
        Self { bytes, last_seq, entries: Vec::new() }
    }

    /// Check the copied bytes after releasing the ring lock. Entry offsets
    /// address this span, so later ring writes cannot affect validation. The
    /// checksum catches a damaged read before decode; its append-time hashing
    /// is part of the replay-append timing gate.
    pub(super) fn is_valid(&self) -> bool {
        self.entries.iter().all(|entry| {
            let Some(bytes) = self.bytes.get(entry.start..entry.start + entry.len) else {
                return false;
            };
            let mut checksum = DefaultHasher::new();
            checksum.write(bytes);
            checksum.finish() == entry.checksum
        })
    }
}

/// Immutable bytes and entry metadata captured when a replay subscription
/// opens. Replay copies use this snapshot without holding the writer's history
/// mutex, so a raw frame cannot stall an append.
pub(super) struct HistorySnapshot {
    bytes: Box<[u8]>,
    entries: Box<[Entry]>,
    head: usize,
    len: usize,
    first: u64,
    used: usize,
    #[cfg(test)]
    reserved_bytes: usize,
    #[cfg(test)]
    raw_copies: Arc<AtomicUsize>,
    #[cfg(test)]
    raw_copy_permit: Arc<AtomicBool>,
    #[cfg(test)]
    raw_copy_waiting: Arc<AtomicBool>,
}

impl HistorySnapshot {
    fn empty(first: u64, _history: &History) -> Self {
        Self {
            bytes: Box::new([]),
            entries: Box::new([]),
            head: 0,
            len: 0,
            first,
            used: 0,
            #[cfg(test)]
            reserved_bytes: 0,
            #[cfg(test)]
            raw_copies: _history.raw_copies.clone(),
            #[cfg(test)]
            raw_copy_permit: _history.raw_copy_permit.clone(),
            #[cfg(test)]
            raw_copy_waiting: _history.raw_copy_waiting.clone(),
        }
    }

    pub(super) fn first_seq(&self) -> Option<u64> {
        (self.len != 0).then_some(self.first)
    }

    pub(super) fn last_seq(&self) -> Option<u64> {
        self.first_seq().and_then(|first| first.checked_add(self.len as u64 - 1))
    }

    pub(super) fn after_frame(
        &self,
        cursor: u64,
        through: u64,
        max_bytes: usize,
    ) -> Option<RawSpan> {
        if cursor >= through {
            return Some(RawSpan { bytes: Vec::new(), last_seq: cursor, entries: Vec::new() });
        }
        let first = cursor.checked_add(1)?;
        let offset = usize::try_from(first.checked_sub(self.first)?).ok()?;
        let available = usize::try_from(through.checked_sub(cursor)?).ok()?;
        let count = available.min(self.len.checked_sub(offset)?);
        if count == 0 {
            return None;
        }
        let max_bytes = max_bytes.min(256 * 1024);
        #[cfg(test)]
        let _copy_permit = RawCopyPermit::new(&self.raw_copy_permit, &self.raw_copy_waiting);
        let mut out = Vec::with_capacity(max_bytes.min(self.used.saturating_add(count)));
        let mut last_seq = cursor;
        for index in 0..count {
            let entry = *self.entries.get((self.head + offset + index) % self.entries.len())?;
            let separator = usize::from(!out.is_empty());
            if out.len().saturating_add(separator).saturating_add(entry.len) > max_bytes {
                break;
            }
            if separator != 0 {
                out.push(b',');
            }
            if !copy_entry_into(&self.bytes, entry, &mut out) {
                return None;
            }
            #[cfg(test)]
            if index == 0 {
                // A positive observation proves bytes have already copied.
                self.raw_copies.fetch_add(1, Ordering::Release);
            }
            last_seq = first.saturating_add(index as u64);
        }
        (!out.is_empty()).then_some(RawSpan { bytes: out, last_seq, entries: Vec::new() })
    }
}

#[derive(Serialize)]
#[serde(tag = "op", rename_all = "camelCase", rename_all_fields = "camelCase")]
enum Op<T, S> {
    Summary {
        seq: u64,
        summary: T,
    },
    Gone {
        seq: u64,
        origin: S,
        chat_id: S,
    },
    Origin {
        seq: u64,
        id: String,
        state: crate::wire::OriginState,
        since: u64,
        #[serde(skip_serializing_if = "Option::is_none")]
        extra: Option<serde_json::Value>,
    },
}

impl History {
    pub(super) fn new() -> Self {
        Self::with_capacity(CREDIT_WINDOW_BYTES)
    }

    fn with_capacity(capacity: usize) -> Self {
        Self {
            bytes: vec![0; capacity].into_boxed_slice(),
            entries: vec![Entry::default(); (capacity / MIN_OP_BYTES).max(1)].into_boxed_slice(),
            head: 0,
            len: 0,
            first: 0,
            tail: 0,
            used: 0,
            #[cfg(test)]
            encoded_ops: AtomicUsize::new(0),
            #[cfg(test)]
            raw_copies: Arc::new(AtomicUsize::new(0)),
            #[cfg(test)]
            raw_copy_permit: Arc::new(AtomicBool::new(true)),
            #[cfg(test)]
            raw_copy_waiting: Arc::new(AtomicBool::new(false)),
            #[cfg(test)]
            snapshot_open_permit: Arc::new(AtomicBool::new(true)),
            #[cfg(test)]
            snapshot_open_waiting: Arc::new(AtomicBool::new(false)),
        }
    }

    #[cfg(test)]
    pub(super) fn reset_encoded_ops(&self) {
        self.encoded_ops.store(0, Ordering::Relaxed);
    }

    #[cfg(test)]
    pub(super) fn encoded_ops(&self) -> usize {
        self.encoded_ops.load(Ordering::Relaxed)
    }

    #[cfg(test)]
    pub(super) fn reset_raw_copies(&self) {
        self.raw_copies.store(0, Ordering::Relaxed);
    }

    #[cfg(test)]
    pub(super) fn raw_copies(&self) -> usize {
        self.raw_copies.load(Ordering::Acquire)
    }

    #[cfg(test)]
    pub(super) fn raw_copy_control(&self) -> (Arc<AtomicBool>, Arc<AtomicBool>) {
        (self.raw_copy_permit.clone(), self.raw_copy_waiting.clone())
    }

    #[cfg(test)]
    pub(super) fn snapshot_open_control(&self) -> (Arc<AtomicBool>, Arc<AtomicBool>) {
        (self.snapshot_open_permit.clone(), self.snapshot_open_waiting.clone())
    }

    /// Copy only the retained operations after `cursor`. The copy is made once
    /// while the history lock is held, then replay frames read the compact
    /// immutable suffix without sharing that lock with the writer.
    pub(super) fn snapshot_after(&self, cursor: u64) -> HistorySnapshot {
        #[cfg(test)]
        let _snapshot_permit =
            SnapshotOpenPermit::new(&self.snapshot_open_permit, &self.snapshot_open_waiting);
        let Some(last) = self.last_seq() else {
            return HistorySnapshot::empty(cursor.saturating_add(1), self);
        };
        let first = cursor.saturating_add(1).max(self.first);
        if first > last {
            return HistorySnapshot::empty(first, self);
        }
        let offset = usize::try_from(first.saturating_sub(self.first)).unwrap_or(self.len);
        let count = self.len.saturating_sub(offset);
        let Some(begin) = self.entries.get((self.head + offset) % self.entries.len()) else {
            return HistorySnapshot::empty(first, self);
        };
        // Retained operations are contiguous in the byte ring. A nonempty
        // suffix with equal endpoints occupies the full capacity.
        let suffix_bytes = if self.tail > begin.start {
            self.tail - begin.start
        } else {
            self.bytes.len() - begin.start + self.tail
        };
        let mut bytes = Vec::with_capacity(suffix_bytes);
        let mut entries = Vec::with_capacity(count);
        for index in 0..count {
            let Some(entry) = self.entries.get((self.head + offset + index) % self.entries.len())
            else {
                return HistorySnapshot::empty(first, self);
            };
            let start = bytes.len();
            if !copy_entry_into(&self.bytes, *entry, &mut bytes) {
                return HistorySnapshot::empty(first, self);
            }
            entries.push(Entry { start, ..*entry });
        }
        let used = bytes.len();
        #[cfg(test)]
        let reserved_bytes = bytes.capacity();
        HistorySnapshot {
            bytes: bytes.into_boxed_slice(),
            entries: entries.into_boxed_slice(),
            head: 0,
            len: count,
            first,
            used,
            #[cfg(test)]
            reserved_bytes,
            #[cfg(test)]
            raw_copies: self.raw_copies.clone(),
            #[cfg(test)]
            raw_copy_permit: self.raw_copy_permit.clone(),
            #[cfg(test)]
            raw_copy_waiting: self.raw_copy_waiting.clone(),
        }
    }

    #[cfg(test)]
    pub(super) fn len(&self) -> usize {
        self.len
    }

    #[cfg(all(test, target_os = "linux"))]
    pub(super) fn is_empty(&self) -> bool {
        self.len == 0
    }

    pub(super) fn first_seq(&self) -> Option<u64> {
        (self.len != 0).then_some(self.first)
    }

    pub(super) fn last_seq(&self) -> Option<u64> {
        self.first_seq().and_then(|first| first.checked_add(self.len as u64 - 1))
    }

    fn clear(&mut self) {
        self.head = 0;
        self.len = 0;
        self.used = 0;
        self.tail = 0;
    }

    fn pop(&mut self) -> io::Result<()> {
        if self.len == 0 {
            return Err(io::Error::other("list op exceeds history byte capacity"));
        }
        let entry = self.entries.get(self.head).ok_or_else(invalid_entry)?;
        self.used -= entry.len;
        self.head = (self.head + 1) % self.entries.len();
        self.len -= 1;
        self.first = self.first.saturating_add(1);
        Ok(())
    }

    pub(super) fn append(&mut self, item: &ListItem) -> serde_json::Result<()> {
        let op = match item {
            ListItem::Summary(event) => {
                Op::Summary { seq: event.seq, summary: event.summary.as_ref() }
            }
            ListItem::Gone { seq, origin, chat_id } => {
                Op::Gone { seq: *seq, origin: origin.as_str(), chat_id: chat_id.as_str() }
            }
            ListItem::Origin { seq, origin } => Op::Origin {
                seq: *seq,
                id: origin.id.clone(),
                state: origin.state,
                since: origin.since,
                extra: origin.extra.clone(),
            },
            ListItem::Folders { .. } | ListItem::Lagged { .. } => return Ok(()),
        };
        let seq = match &op {
            Op::Summary { seq, .. } | Op::Gone { seq, .. } | Op::Origin { seq, .. } => *seq,
        };
        if self.len != 0 && self.first.checked_add(self.len as u64) != Some(seq) {
            self.clear();
        }
        if self.len == self.entries.len() {
            self.pop().map_err(serde_json::Error::io)?;
        }
        let start = self.tail;
        #[cfg(test)]
        self.encoded_ops.fetch_add(1, Ordering::Relaxed);
        let mut writer = Append { history: self, written: 0, checksum: DefaultHasher::new() };
        if let Err(error) = serde_json::to_writer(&mut writer, &op) {
            writer.history.clear();
            return Err(error);
        }
        let len = writer.written;
        let checksum = writer.checksum.finish();
        let slot = (self.head + self.len) % self.entries.len();
        let Some(entry) = self.entries.get_mut(slot) else {
            self.clear();
            return Err(serde_json::Error::io(invalid_entry()));
        };
        *entry = Entry { seq, start, len, checksum };
        if self.len == 0 {
            self.first = seq;
        }
        self.len += 1;
        Ok(())
    }

    /// Copy consecutive ops in (cursor, through], or signal a missed cursor.
    /// The caller drops its lock before decoding these concatenated JSON ops.
    pub(super) fn after(&self, cursor: u64, through: u64) -> Option<Vec<u8>> {
        if cursor >= through {
            return Some(Vec::new());
        }
        let first = cursor.checked_add(1)?;
        let offset = usize::try_from(first.checked_sub(self.first)?).ok()?;
        let count = usize::try_from(through.checked_sub(cursor)?).ok()?;
        if offset.checked_add(count)? > self.len {
            return None;
        }
        let begin = self.entries.get((self.head + offset) % self.entries.len())?;
        let end = self.entries.get((self.head + offset + count - 1) % self.entries.len())?;
        let capacity = self.bytes.len();
        let length = (end.start + end.len + capacity - begin.start) % capacity;
        let length = if length == 0 { capacity } else { length };
        let mut out = Vec::with_capacity(length);
        let first_len = length.min(capacity - begin.start);
        out.extend_from_slice(self.bytes.get(begin.start..begin.start + first_len)?);
        out.extend_from_slice(self.bytes.get(..length - first_len)?);
        Some(out)
    }

    /// Copy as many complete operations as fit in `max_bytes`, inserting the
    /// commas needed by the delta frame's `ops` array. The caller must hold no
    /// lock while wrapping or offering the returned bytes.
    pub(super) fn after_frame(
        &self,
        cursor: u64,
        through: u64,
        max_bytes: usize,
    ) -> Option<RawSpan> {
        #[cfg(test)]
        let _copy_permit = RawCopyPermit::new(&self.raw_copy_permit, &self.raw_copy_waiting);
        #[cfg(test)]
        self.raw_copies.fetch_add(1, Ordering::Release);
        if cursor >= through {
            return Some(RawSpan { bytes: Vec::new(), last_seq: cursor, entries: Vec::new() });
        }
        let first = cursor.checked_add(1)?;
        let offset = usize::try_from(first.checked_sub(self.first)?).ok()?;
        let available = usize::try_from(through.checked_sub(cursor)?).ok()?;
        let count = available.min(self.len.checked_sub(offset)?);
        if count == 0 {
            return None;
        }
        // One byte-buffer allocation and one metadata-vector allocation under
        // the history lock. Do not allocate a temporary Vec per operation: a
        // full replay can contain thousands of operations.
        let max_bytes = max_bytes.min(256 * 1024);
        let mut out = Vec::with_capacity(max_bytes.min(self.used.saturating_add(count)));
        let mut entries = Vec::with_capacity(count.min(max_bytes / MIN_OP_BYTES));
        let mut last_seq = cursor;
        for index in 0..count {
            let entry = *self.entries.get((self.head + offset + index) % self.entries.len())?;
            let separator = usize::from(!out.is_empty());
            if out.len().saturating_add(separator).saturating_add(entry.len) > max_bytes {
                break;
            }
            if separator != 0 {
                out.push(b',');
            }
            entries.push(Entry { start: out.len(), ..entry });
            if !copy_entry_into(&self.bytes, entry, &mut out) {
                return None;
            }
            last_seq = first.saturating_add(index as u64);
        }
        (!out.is_empty()).then_some(RawSpan { bytes: out, last_seq, entries })
    }
}

fn copy_entry_into(bytes: &[u8], entry: Entry, out: &mut Vec<u8>) -> bool {
    let capacity = bytes.len();
    let first_len = entry.len.min(capacity.saturating_sub(entry.start));
    let Some(first) = bytes.get(entry.start..entry.start + first_len) else {
        return false;
    };
    out.extend_from_slice(first);
    let Some(second) = bytes.get(..entry.len.saturating_sub(first_len)) else {
        return false;
    };
    out.extend_from_slice(second);
    true
}

#[cfg(test)]
struct RawCopyPermit<'a> {
    waiting: &'a AtomicBool,
}

#[cfg(test)]
struct SnapshotOpenPermit<'a> {
    waiting: &'a AtomicBool,
}

#[cfg(test)]
impl<'a> SnapshotOpenPermit<'a> {
    fn new(permit: &'a AtomicBool, waiting: &'a AtomicBool) -> Self {
        waiting.store(true, Ordering::Release);
        while !permit.load(Ordering::Acquire) {
            std::thread::yield_now();
        }
        Self { waiting }
    }
}

#[cfg(test)]
impl Drop for SnapshotOpenPermit<'_> {
    fn drop(&mut self) {
        self.waiting.store(false, Ordering::Release);
    }
}

#[cfg(test)]
impl<'a> RawCopyPermit<'a> {
    fn new(permit: &'a AtomicBool, waiting: &'a AtomicBool) -> Self {
        waiting.store(true, Ordering::Release);
        while !permit.load(Ordering::Acquire) {
            std::thread::yield_now();
        }
        Self { waiting }
    }
}

#[cfg(test)]
impl Drop for RawCopyPermit<'_> {
    fn drop(&mut self) {
        self.waiting.store(false, Ordering::Release);
    }
}

impl PeerHistory {
    pub(super) fn new(start: u64) -> Self {
        Self::with_capacity(start, CREDIT_WINDOW_BYTES)
    }

    fn with_capacity(start: u64, capacity: usize) -> Self {
        Self {
            bytes: vec![0; capacity].into_boxed_slice(),
            entries: vec![Entry::default(); (capacity / MIN_OP_BYTES).max(1)].into_boxed_slice(),
            head: 0,
            len: 0,
            first: 0,
            floor: start,
            last: start,
            tail: 0,
            used: 0,
        }
    }

    pub(super) fn last_seq(&self) -> u64 {
        self.last
    }

    pub(super) fn can_resume(&self, cursor: u64) -> bool {
        cursor >= self.floor
    }

    pub(super) fn append(&mut self, seq: u64, summary: Option<&Summary>) -> serde_json::Result<()> {
        self.last = self.last.max(seq);
        let Some(summary) = summary else { return Ok(()) };
        if summary.origin != "local" {
            return Ok(());
        }
        let mut op =
            Vec::with_capacity(summary.peer_form.as_ref().map_or(256, |raw| raw.get().len()));
        op.extend_from_slice(br#"{"op":"summary","seq":"#);
        serde_json::to_writer(&mut op, &seq)?;
        op.extend_from_slice(br#","summary":"#);
        if let Some(peer) = summary.peer_form.as_ref() {
            op.extend_from_slice(peer.get().as_bytes());
        } else {
            serde_json::to_writer(&mut op, summary)?;
        }
        op.push(b'}');
        self.append_bytes(seq, &op).map_err(serde_json::Error::io)
    }

    pub(super) fn append_gone(
        &mut self,
        seq: u64,
        origin: &str,
        chat_id: &str,
    ) -> serde_json::Result<()> {
        self.last = self.last.max(seq);
        if origin != "local" {
            return Ok(());
        }
        let mut op = Vec::with_capacity(64 + origin.len() + chat_id.len());
        op.extend_from_slice(br#"{"op":"gone","seq":"#);
        serde_json::to_writer(&mut op, &seq)?;
        op.extend_from_slice(br#","origin":"#);
        serde_json::to_writer(&mut op, origin)?;
        op.extend_from_slice(br#","chatId":"#);
        serde_json::to_writer(&mut op, chat_id)?;
        op.push(b'}');
        self.append_bytes(seq, &op).map_err(serde_json::Error::io)
    }

    fn append_bytes(&mut self, seq: u64, bytes: &[u8]) -> io::Result<()> {
        if bytes.len() > self.bytes.len() {
            self.clear(self.last);
            return Err(io::Error::other("peer list op exceeds history byte capacity"));
        }
        while self.used + bytes.len() > self.bytes.len() || self.len == self.entries.len() {
            if self.len == 0 {
                break;
            }
            let entry = *self.entries.get(self.head).ok_or_else(invalid_entry)?;
            self.used = self.used.saturating_sub(entry.len);
            self.head = (self.head + 1) % self.entries.len();
            self.len -= 1;
            self.floor = entry.seq;
            self.first = self.entries.get(self.head).map_or(seq, |next| next.seq);
        }
        let start = self.tail;
        let first_len = bytes.len().min(self.bytes.len() - self.tail);
        self.bytes
            .get_mut(self.tail..self.tail + first_len)
            .ok_or_else(invalid_entry)?
            .copy_from_slice(bytes.get(..first_len).ok_or_else(invalid_entry)?);
        self.bytes
            .get_mut(..bytes.len() - first_len)
            .ok_or_else(invalid_entry)?
            .copy_from_slice(bytes.get(first_len..).ok_or_else(invalid_entry)?);
        let mut checksum = DefaultHasher::new();
        checksum.write(bytes);
        let slot = (self.head + self.len) % self.entries.len();
        *self.entries.get_mut(slot).ok_or_else(invalid_entry)? =
            Entry { seq, start, len: bytes.len(), checksum: checksum.finish() };
        self.tail = (self.tail + bytes.len()) % self.bytes.len();
        self.used += bytes.len();
        if self.len == 0 {
            self.first = seq;
        }
        self.len += 1;
        Ok(())
    }

    pub(super) fn after_frame(
        &self,
        cursor: u64,
        through: u64,
        max_bytes: usize,
    ) -> Option<RawSpan> {
        if cursor >= through {
            return Some(RawSpan { bytes: Vec::new(), last_seq: cursor, entries: Vec::new() });
        }
        if cursor < self.floor {
            return None;
        }
        let mut out = Vec::new();
        let mut entries = Vec::new();
        let mut last_seq = through;
        for index in 0..self.len {
            let entry = *self.entries.get((self.head + index) % self.entries.len())?;
            if entry.seq <= cursor || entry.seq > through {
                continue;
            }
            let separator = usize::from(!out.is_empty());
            if out.len().saturating_add(separator).saturating_add(entry.len) > max_bytes {
                last_seq = entry.seq.saturating_sub(1);
                break;
            }
            if separator != 0 {
                out.push(b',');
            }
            let start = out.len();
            if !self.copy_entry_into(entry, &mut out) {
                return None;
            }
            entries.push(Entry { start, ..entry });
            last_seq = entry.seq;
        }
        Some(RawSpan { bytes: out, last_seq, entries })
    }

    fn copy_entry_into(&self, entry: Entry, out: &mut Vec<u8>) -> bool {
        let capacity = self.bytes.len();
        let first_len = entry.len.min(capacity.saturating_sub(entry.start));
        let Some(first) = self.bytes.get(entry.start..entry.start + first_len) else {
            return false;
        };
        out.extend_from_slice(first);
        let Some(second) = self.bytes.get(..entry.len.saturating_sub(first_len)) else {
            return false;
        };
        out.extend_from_slice(second);
        true
    }

    fn clear(&mut self, floor: u64) {
        self.head = 0;
        self.len = 0;
        self.first = 0;
        self.floor = floor;
        self.last = floor;
        self.tail = 0;
        self.used = 0;
    }
}

struct Append<'a> {
    history: &'a mut History,
    written: usize,
    checksum: DefaultHasher,
}

fn invalid_entry() -> io::Error {
    io::Error::other("invalid list history entry")
}

impl Write for Append<'_> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let history = &mut self.history;
        self.checksum.write(bytes);
        if bytes.len() > history.bytes.len().saturating_sub(self.written) {
            return Err(io::Error::other("list op exceeds history byte capacity"));
        }
        while history.used + bytes.len() > history.bytes.len() {
            history.pop()?;
        }
        let first_len = bytes.len().min(history.bytes.len() - history.tail);
        history
            .bytes
            .get_mut(history.tail..history.tail + first_len)
            .ok_or_else(invalid_entry)?
            .copy_from_slice(bytes.get(..first_len).ok_or_else(invalid_entry)?);
        history
            .bytes
            .get_mut(..bytes.len() - first_len)
            .ok_or_else(invalid_entry)?
            .copy_from_slice(bytes.get(first_len..).ok_or_else(invalid_entry)?);
        history.tail = (history.tail + bytes.len()) % history.bytes.len();
        history.used += bytes.len();
        self.written += bytes.len();
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

// A struct decoder lets serde_json pass the opaque RawValue directly to
// Summary. An internally tagged enum would buffer it through serde Content.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReadOp {
    op: String,
    seq: u64,
    summary: Option<Summary>,
    origin: Option<String>,
    chat_id: Option<String>,
    id: Option<String>,
    state: Option<crate::wire::OriginState>,
    since: Option<u64>,
    extra: Option<serde_json::Value>,
}

pub(super) fn decode(bytes: Vec<u8>) -> serde_json::Result<Vec<ListItem>> {
    serde_json::Deserializer::from_slice(&bytes)
        .into_iter::<ReadOp>()
        .map(|op| {
            let op = op?;
            match (op.op.as_str(), op.summary, op.origin, op.chat_id) {
                ("summary", Some(summary), _, _) => {
                    Ok(ListItem::Summary(SummaryEvent { seq: op.seq, summary: Arc::new(summary) }))
                }
                ("gone", None, Some(origin), Some(chat_id)) => {
                    Ok(ListItem::Gone { seq: op.seq, origin, chat_id })
                }
                ("origin", None, _, _) => Ok(ListItem::Origin {
                    seq: op.seq,
                    origin: crate::wire::Origin {
                        id: op.id.ok_or_else(|| serde_json::Error::io(invalid_entry()))?,
                        state: op.state.ok_or_else(|| serde_json::Error::io(invalid_entry()))?,
                        since: op.since.ok_or_else(|| serde_json::Error::io(invalid_entry()))?,
                        extra: op.extra,
                    },
                }),
                _ => Err(serde_json::Error::io(invalid_entry())),
            }
        })
        .collect()
}

#[cfg(test)]
mod tests;
