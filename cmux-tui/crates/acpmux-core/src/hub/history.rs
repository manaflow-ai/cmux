//! Fixed byte storage for list resume. No retained row, per-record allocation,
//! or search by sequence; the entry slot is the offset from the first seq.
use super::{ListItem, SummaryEvent};
use acpmux_book::index::Summary;
use serde::{Deserialize, Serialize};
use std::hash::{DefaultHasher, Hasher};
use std::io::{self, Write};
use std::sync::Arc;
#[cfg(test)]
use std::sync::atomic::{AtomicUsize, Ordering};

const CREDIT_WINDOW_BYTES: usize = 1024 * 1024;
// Every encoded op is longer than 32 bytes, including an empty gone at seq 0.
const MIN_OP_BYTES: usize = 32;

#[derive(Clone, Copy, Default)]
struct Entry {
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
    /// address this span, so later ring writes cannot affect validation.
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
        *entry = Entry { start, len, checksum };
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
            if !self.copy_entry_into(entry, &mut out) {
                return None;
            }
            last_seq = first.saturating_add(index as u64);
        }
        (!out.is_empty()).then_some(RawSpan { bytes: out, last_seq, entries })
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
mod tests {
    use super::*;

    fn gone(seq: u64) -> ListItem {
        ListItem::Gone { seq, origin: "remote".into(), chat_id: format!("id-{seq}") }
    }

    #[test]
    fn wrapping_and_byte_eviction_preserve_consecutive_ops() {
        let mut history = History::with_capacity(230);
        let buffers = (history.bytes.as_ptr(), history.entries.as_ptr());
        for seq in 1..1000 {
            history.append(&gone(seq)).unwrap();
            assert!(history.used <= 230);
            assert_eq!((history.bytes.as_ptr(), history.entries.as_ptr()), buffers);
            let first = history.first;
            assert!(history.after(first.saturating_sub(2), seq).is_none() || first == 1);
            let items = decode(history.after(first - 1, seq).unwrap()).unwrap();
            assert_eq!(items.len(), history.len);
            for (offset, item) in items.into_iter().enumerate() {
                match item {
                    ListItem::Gone { seq, origin, chat_id } => {
                        assert_eq!(seq, first + offset as u64);
                        assert_eq!(origin, "remote");
                        assert_eq!(chat_id, format!("id-{seq}"));
                    }
                    _ => panic!("expected gone"),
                }
            }
        }
    }

    #[test]
    fn exact_full_buffer_and_partial_replay_keep_the_byte_span() {
        let mut probe = History::new();
        probe.append(&gone(1)).unwrap();
        let mut history = History::with_capacity(2 * probe.used);
        history.append(&gone(1)).unwrap();
        history.append(&gone(2)).unwrap();
        assert_eq!(history.used, history.bytes.len());
        assert_eq!(decode(history.after(0, 2).unwrap()).unwrap().len(), 2);
        assert_eq!(decode(history.after(1, 2).unwrap()).unwrap().len(), 1);
        history.append(&gone(3)).unwrap();
        assert!(history.after(0, 3).is_none());
        assert_eq!(decode(history.after(1, 3).unwrap()).unwrap().len(), 2);
    }

    #[test]
    fn raw_frame_span_inserts_only_operation_separators_and_stops_at_the_cap() {
        let mut history = History::new();
        history.append(&gone(1)).unwrap();
        history.append(&gone(2)).unwrap();
        assert!(history.after_frame(0, 2, 1).is_none());
        let one_size = history.after(0, 1).unwrap().len();
        let one = history.after_frame(0, 2, one_size).unwrap();
        assert!(one.is_valid());
        assert_eq!(one.last_seq, 1);
        let parsed: Vec<serde_json::Value> = serde_json::from_slice(
            format!("[{}]", String::from_utf8(one.bytes).unwrap()).as_bytes(),
        )
        .unwrap();
        assert_eq!(parsed.len(), 1);
        let both = history.after_frame(0, 2, usize::MAX).unwrap();
        assert!(both.is_valid());
        assert_eq!(both.last_seq, 2);
        let parsed: Vec<serde_json::Value> = serde_json::from_slice(
            format!("[{}]", String::from_utf8(both.bytes).unwrap()).as_bytes(),
        )
        .unwrap();
        assert_eq!(parsed.len(), 2);
    }

    #[test]
    fn copied_span_validation_survives_overwrite_and_detects_damaged_bytes() {
        let mut history = History::with_capacity(230);
        history.append(&gone(1)).unwrap();
        let copied = history.after_frame(0, 1, 230).unwrap();
        // Damage the ring after the copy. Validation owns its bytes and may
        // run while the writer replaces or evicts the original record.
        let first = history.entries.get(history.head).unwrap().start;
        *history.bytes.get_mut(first).unwrap() = b'!';
        let damaged = history.after_frame(0, 1, 230).unwrap();
        assert!(copied.is_valid());
        assert!(!damaged.is_valid());
        for seq in 2..100 {
            history.append(&gone(seq)).unwrap();
        }
        assert!(copied.is_valid());
        assert!(!damaged.is_valid());
    }

    #[test]
    fn a_full_ring_replays_in_bounded_complete_operation_spans() {
        let mut history = History::new();
        let mut last = 0;
        while history.first_seq().is_none_or(|first| first == 1) {
            last += 1;
            history.append(&gone(last)).unwrap();
        }
        assert!(history.used > CREDIT_WINDOW_BYTES - 100);
        let mut cursor = history.first_seq().unwrap() - 1;
        let mut frames = 0;
        let mut rows = 0;
        while cursor < last {
            let span = history.after_frame(cursor, last, 256 * 1024).unwrap();
            assert!(span.is_valid());
            assert!(span.bytes.len() <= 256 * 1024);
            let ops: Vec<serde_json::Value> =
                serde_json::from_str(&format!("[{}]", String::from_utf8(span.bytes).unwrap()))
                    .unwrap();
            for (offset, op) in ops.iter().enumerate() {
                assert_eq!(op["seq"], cursor + offset as u64 + 1);
            }
            assert_eq!(span.last_seq, cursor + ops.len() as u64);
            cursor = span.last_seq;
            rows += ops.len();
            frames += 1;
        }
        assert_eq!(rows, history.len());
        assert!(frames >= 4);
    }

    #[test]
    fn summary_bytes_release_rows_and_round_trip_escaped_keys() {
        let mut history = History::new();
        let mut summary = Summary::new("chat\"\n雪");
        summary.origin = "peer\\two".into();
        summary.extra =
            serde_json::value::RawValue::from_string(r#"{"nested": [1, true, {"x": "y"}]}"#.into())
                .unwrap();
        let row = Arc::new(summary);
        let weak = Arc::downgrade(&row);
        history.append(&ListItem::Summary(SummaryEvent { seq: 19, summary: row.clone() })).unwrap();
        drop(row);
        assert!(weak.upgrade().is_none());
        let items = decode(history.after(18, 19).unwrap()).unwrap();
        let ListItem::Summary(event) = items.first().unwrap() else { panic!("summary") };
        assert_eq!(event.seq, 19);
        assert_eq!(event.summary.chat_id, "chat\"\n雪");
        assert_eq!(event.summary.origin, "peer\\two");
        assert_eq!(event.summary.extra.get(), r#"{"nested": [1, true, {"x": "y"}]}"#);
        assert!(history.after(17, 19).is_none());
        assert!(history.after(19, 19).unwrap().is_empty());
    }

    #[test]
    fn failed_or_discontinuous_append_never_leaves_a_resumable_gap() {
        let mut history = History::with_capacity(128);
        history.append(&gone(1)).unwrap();
        let row = Arc::new(Summary::new("too-large-for-test-ring"));
        assert!(history.append(&ListItem::Summary(SummaryEvent { seq: 2, summary: row })).is_err());
        assert!(history.after(0, 2).is_none());
        history.append(&gone(3)).unwrap();
        assert!(history.after(1, 3).is_none());
        assert_eq!(decode(history.after(2, 3).unwrap()).unwrap().len(), 1);
        history.append(&gone(5)).unwrap();
        assert!(history.after(3, 5).is_none());
        assert_eq!(decode(history.after(4, 5).unwrap()).unwrap().len(), 1);
    }
}
