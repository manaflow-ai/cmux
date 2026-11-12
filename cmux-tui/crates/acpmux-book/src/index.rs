//! The chat summary index.
//!
//! A summary is the small typed record used by the list stream. Its `extra`
//! member is deliberately a [`serde_json::value::RawValue`]: this crate keeps
//! the bytes exactly as written and never parses the opaque part. The index
//! log is append-only and the sorted snapshot is a compact restart aid; both
//! contain summaries, never chat history.
//!
//! [`SummaryIndex`] uses persistent ordered maps. Applying one summary clones
//! only the map path touched by the change, so the writer does no pass over the
//! number of chats. Readers can retain a published snapshot while the writer
//! builds the next one.

use imbl::OrdMap;
use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;
use std::cmp::Ordering;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, BufWriter, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering as AtomicOrdering};

/// The on-wire summary of one chat. `extra` is opaque to the daemon.
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Summary {
    pub chat_id: String,
    pub title: String,
    pub harness: String,
    pub state: String,
    pub last_activity: u64,
    pub unread: u32,
    pub workspace: Option<String>,
    pub origin: String,
    pub pinned: bool,
    #[serde(default = "empty_object")]
    pub extra: Box<RawValue>,
}

/// Name used by the design document for a summary's durable record.
pub type SummaryRecord = Summary;

/// A summary is deliberately small: the list can never be made unbounded by
/// one harness supplied title or opaque extension.
pub const MAX_TITLE_BYTES: usize = 256;
pub const MAX_SUMMARY_BYTES: usize = 2 * 1024;
const MAX_FIELD_BYTES: usize = 256;
const HOT_PAGE_ROWS: usize = 400;

fn empty_object() -> Box<RawValue> {
    RawValue::from_string("{}".to_owned()).expect("a static JSON object is valid")
}

impl Clone for Summary {
    fn clone(&self) -> Self {
        Self {
            chat_id: self.chat_id.clone(),
            title: self.title.clone(),
            harness: self.harness.clone(),
            state: self.state.clone(),
            last_activity: self.last_activity,
            unread: self.unread,
            workspace: self.workspace.clone(),
            origin: self.origin.clone(),
            pinned: self.pinned,
            extra: self.extra.to_owned(),
        }
    }
}

impl Summary {
    /// A compact default useful when a chat has not supplied a title yet.
    pub fn new(chat_id: impl Into<String>) -> Self {
        Self {
            chat_id: chat_id.into(),
            title: String::new(),
            harness: String::new(),
            state: String::new(),
            last_activity: 0,
            unread: 0,
            workspace: None,
            origin: "local".to_owned(),
            pinned: false,
            extra: empty_object(),
        }
    }

    pub fn encoded_len(&self) -> usize {
        serde_json::to_vec(self).map_or(0, |bytes| bytes.len())
    }

    /// Clamps user supplied text at the index boundary. `extra` stays opaque;
    /// an extension that cannot fit is represented by the empty object rather
    /// than parsed or allowed to expand the list frame.
    pub fn bounded(mut self) -> Self {
        self.chat_id = truncate_utf8(&self.chat_id, MAX_FIELD_BYTES);
        self.title = truncate_utf8(&self.title, MAX_TITLE_BYTES);
        self.harness = truncate_utf8(&self.harness, MAX_FIELD_BYTES);
        self.state = truncate_utf8(&self.state, MAX_FIELD_BYTES);
        self.workspace = self.workspace.map(|value| truncate_utf8(&value, MAX_FIELD_BYTES));
        self.origin = truncate_utf8(&self.origin, MAX_FIELD_BYTES);
        if self.encoded_len() > MAX_SUMMARY_BYTES {
            self.extra = empty_object();
        }
        if self.encoded_len() > MAX_SUMMARY_BYTES {
            self.title = truncate_utf8(&self.title, MAX_TITLE_BYTES / 2);
        }
        // JSON escaping can make a 256-byte UTF-8 field larger than its text
        // length. Keep shrinking textual fields until the serialized record,
        // including opaque bytes, is inside the wire bound.
        while self.encoded_len() > MAX_SUMMARY_BYTES {
            let mut changed = false;
            macro_rules! shrink {
                ($value:expr) => {
                    if $value.len() > 1 {
                        let next = $value.len() / 2;
                        $value = truncate_utf8(&$value, next);
                        changed = true;
                    }
                };
            }
            shrink!(self.title);
            if self.encoded_len() > MAX_SUMMARY_BYTES {
                shrink!(self.harness);
            }
            if self.encoded_len() > MAX_SUMMARY_BYTES {
                shrink!(self.state);
            }
            if self.encoded_len() > MAX_SUMMARY_BYTES {
                if let Some(value) = self.workspace.as_mut() {
                    shrink!(*value);
                }
            }
            if self.encoded_len() > MAX_SUMMARY_BYTES {
                shrink!(self.origin);
            }
            if self.encoded_len() > MAX_SUMMARY_BYTES {
                shrink!(self.chat_id);
            }
            if !changed {
                break;
            }
        }
        self
    }
}

fn truncate_utf8(value: &str, max: usize) -> String {
    if value.len() <= max {
        return value.to_owned();
    }
    let mut end = max;
    while end > 0 && !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_owned()
}

/// An index-log record. The sequence is monotonic for this index and is the
/// cursor clients use to resume the list stream.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IndexRecord {
    pub seq: u64,
    pub chat_id: String,
    pub summary: Summary,
    #[serde(default)]
    pub gone: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct SortKey {
    last_activity: u64,
    chat_id: String,
}

impl Ord for SortKey {
    fn cmp(&self, other: &Self) -> Ordering {
        other.last_activity.cmp(&self.last_activity).then_with(|| self.chat_id.cmp(&other.chat_id))
    }
}

impl PartialOrd for SortKey {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

/// An immutable, sorted view of the summaries at one index sequence.
#[derive(Clone, Debug)]
pub struct SummaryIndex {
    seq: u64,
    by_id: OrdMap<String, Arc<Summary>>,
    ordered: OrdMap<SortKey, Arc<Summary>>,
    hot: Arc<Vec<Arc<Summary>>>,
}

impl Default for SummaryIndex {
    fn default() -> Self {
        Self::new()
    }
}

impl SummaryIndex {
    pub fn new() -> Self {
        Self { seq: 0, by_id: OrdMap::new(), ordered: OrdMap::new(), hot: Arc::new(Vec::new()) }
    }

    pub fn seq(&self) -> u64 {
        self.seq
    }

    pub fn len(&self) -> usize {
        self.by_id.len()
    }

    pub fn is_empty(&self) -> bool {
        self.by_id.is_empty()
    }

    pub fn get(&self, chat_id: &str) -> Option<Arc<Summary>> {
        self.by_id.get(chat_id).cloned()
    }

    /// Applies one summary without walking the rest of the index.
    pub fn apply(&self, seq: u64, summary: Summary) -> Self {
        let summary = Arc::new(summary.bounded());
        let mut by_id = self.by_id.clone();
        let mut ordered = self.ordered.clone();
        if let Some(old) = by_id.get(&summary.chat_id) {
            ordered.remove(&SortKey {
                last_activity: old.last_activity,
                chat_id: old.chat_id.clone(),
            });
        }
        ordered.insert(
            SortKey { last_activity: summary.last_activity, chat_id: summary.chat_id.clone() },
            summary.clone(),
        );
        by_id.insert(summary.chat_id.clone(), summary);
        let hot = Arc::new(ordered.values().take(HOT_PAGE_ROWS).cloned().collect());
        Self { seq: self.seq.max(seq), by_id, ordered, hot }
    }

    /// Test/telemetry hook: applying one summary records the number of
    /// summaries touched by the operation. It stays one for a 20-chat and an
    /// 11k-chat index alike; the persistent maps do the logarithmic path copy.
    pub fn apply_counted(&self, seq: u64, summary: Summary, visited: &AtomicUsize) -> Self {
        visited.fetch_add(1, AtomicOrdering::Relaxed);
        self.apply(seq, summary)
    }

    /// Returns summaries newest first. The iterator borrows the persistent
    /// snapshot; collecting it is a caller-owned page operation.
    pub fn iter(&self) -> impl Iterator<Item = &Arc<Summary>> {
        self.ordered.values()
    }

    pub fn page(&self, start: usize, limit: usize) -> Vec<Arc<Summary>> {
        if start.saturating_add(limit) <= HOT_PAGE_ROWS {
            return self.hot.iter().skip(start).take(limit).cloned().collect();
        }
        self.iter().skip(start).take(limit).cloned().collect()
    }

    /// Returns a keyset page. The key is exclusive, so inserts before the
    /// anchor do not shift the next page.
    pub fn page_after_key(&self, key: Option<(&u64, &str)>, limit: usize) -> Vec<Arc<Summary>> {
        if key.is_none() && limit <= HOT_PAGE_ROWS {
            return self.hot.iter().take(limit).cloned().collect();
        }
        self.ordered
            .iter()
            .filter(|(sort, _)| {
                key.is_none_or(|(activity, chat)| {
                    sort.last_activity < *activity
                        || (sort.last_activity == *activity && sort.chat_id.as_str() > chat)
                })
            })
            .take(limit)
            .map(|(_, summary)| summary.clone())
            .collect()
    }

    /// Returns the keyset page immediately before an exclusive anchor. The
    /// ordered map is newest-first, so this collects the preceding range and
    /// reverses it to preserve the list's display order.
    pub fn page_before_key(&self, key: (&u64, &str), limit: usize) -> Vec<Arc<Summary>> {
        let mut rows: Vec<_> = self
            .ordered
            .iter()
            .filter(|(sort, _)| {
                sort.last_activity > *key.0
                    || (sort.last_activity == *key.0 && sort.chat_id.as_str() < key.1)
            })
            .map(|(_, summary)| summary.clone())
            .collect();
        rows.reverse();
        rows.truncate(limit);
        rows.reverse();
        rows
    }

    pub fn summaries(&self) -> Vec<Summary> {
        self.iter().map(|summary| summary.as_ref().clone()).collect()
    }

    pub fn remove(&self, seq: u64, chat_id: &str) -> Option<Self> {
        let old = self.by_id.get(chat_id)?.clone();
        let mut by_id = self.by_id.clone();
        let mut ordered = self.ordered.clone();
        by_id.remove(chat_id);
        ordered.remove(&SortKey { last_activity: old.last_activity, chat_id: old.chat_id.clone() });
        let hot = Arc::new(ordered.values().take(HOT_PAGE_ROWS).cloned().collect());
        Some(Self { seq: self.seq.max(seq), by_id, ordered, hot })
    }
}

/// The append-only `index.log` writer.
pub struct IndexLog {
    file: BufWriter<File>,
    path: PathBuf,
    next_seq: u64,
    offset: u64,
}

impl IndexLog {
    pub fn open(path: impl AsRef<Path>) -> io::Result<Self> {
        let requested = path.as_ref().to_owned();
        let snapshot_path = requested.with_extension("snap");
        let (path, snapshot_seq) = match SortedSnapshot::metadata(&snapshot_path)? {
            Some(snapshot) => {
                let candidate = snapshot.log_name.as_deref().map(|name| {
                    snapshot_path.parent().unwrap_or_else(|| Path::new(".")).join(name)
                });
                let active = candidate.filter(|candidate| candidate.exists()).unwrap_or(requested);
                (active, snapshot.seq)
            }
            None => (requested, 0),
        };
        let bytes = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => Vec::new(),
            Err(error) => return Err(error),
        };
        let mut offset = 0usize;
        let mut next_seq = 0;
        for line in bytes.split_inclusive(|byte| *byte == b'\n') {
            let end = offset + line.len();
            let text = line.strip_suffix(b"\n").unwrap_or(line);
            match serde_json::from_slice::<IndexRecord>(text) {
                Ok(record) => {
                    next_seq = next_seq.max(record.seq);
                    offset = end;
                }
                Err(_) => break,
            }
        }
        if offset < bytes.len() {
            let file = OpenOptions::new().write(true).open(&path)?;
            file.set_len(offset as u64)?;
        } else if offset > 0 && !bytes[..offset].ends_with(b"\n") {
            let mut file = OpenOptions::new().append(true).open(&path)?;
            file.write_all(b"\n")?;
            offset += 1;
        }
        let file = OpenOptions::new().create(true).append(true).open(&path)?;
        Ok(Self {
            file: BufWriter::new(file),
            path,
            next_seq: next_seq.max(snapshot_seq),
            offset: offset as u64,
        })
    }

    pub fn append(&mut self, summary: Summary) -> io::Result<IndexRecord> {
        self.next_seq = self.next_seq.saturating_add(1);
        let record = IndexRecord {
            seq: self.next_seq,
            chat_id: summary.chat_id.clone(),
            summary,
            gone: false,
        };
        let mut bytes = serde_json::to_vec(&record).map_err(io::Error::other)?;
        bytes.push(b'\n');
        self.file.write_all(&bytes)?;
        self.offset = self.offset.saturating_add(bytes.len() as u64);
        Ok(record)
    }

    pub fn append_remove(&mut self, chat_id: impl Into<String>) -> io::Result<IndexRecord> {
        self.next_seq = self.next_seq.saturating_add(1);
        let chat_id = chat_id.into();
        let record = IndexRecord {
            seq: self.next_seq,
            chat_id: chat_id.clone(),
            summary: Summary::new(chat_id),
            gone: true,
        };
        let mut bytes = serde_json::to_vec(&record).map_err(io::Error::other)?;
        bytes.push(b'\n');
        self.file.write_all(&bytes)?;
        self.offset = self.offset.saturating_add(bytes.len() as u64);
        Ok(record)
    }

    pub fn flush(&mut self) -> io::Result<()> {
        self.file.flush()
    }

    pub fn sync(&mut self) -> io::Result<()> {
        self.file.flush()?;
        self.file.get_ref().sync_data()
    }

    pub fn next_seq(&self) -> u64 {
        self.next_seq
    }

    pub fn offset(&self) -> u64 {
        self.offset
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Writes a sorted snapshot and starts a fresh log. The snapshot is
    /// replaced atomically before the old log is truncated, so a crash can
    /// replay duplicate records but cannot lose a committed summary.
    pub fn compact(
        &mut self,
        snapshot_path: impl AsRef<Path>,
        index: &SummaryIndex,
    ) -> io::Result<()> {
        self.sync()?;
        let parent = self.path.parent().unwrap_or_else(|| Path::new(".")).to_owned();
        let stem = self.path.file_name().and_then(|name| name.to_str()).unwrap_or("index.log");
        let generation = parent.join(format!("{stem}.{}", index.seq()));
        let generation_file =
            OpenOptions::new().create(true).write(true).truncate(true).open(&generation)?;
        generation_file.sync_all()?;
        SortedSnapshot::write_with_offset_and_name(
            &snapshot_path,
            index,
            0,
            generation.file_name().and_then(|name| name.to_str()),
        )?;
        self.file.flush()?;
        let old_path = self.path.clone();
        self.file = BufWriter::new(OpenOptions::new().create(true).append(true).open(&generation)?);
        self.path = generation;
        self.offset = 0;
        self.next_seq = index.seq();
        if old_path != self.path {
            let _ = fs::remove_file(old_path);
        }
        if let Ok(dir) = File::open(&parent) {
            dir.sync_all()?;
        }
        Ok(())
    }
}

/// Reads the log's tail into a persistent index. A malformed or partial final
/// line is ignored so a torn append does not hide earlier summaries.
pub fn replay_log(path: impl AsRef<Path>, index: SummaryIndex) -> io::Result<SummaryIndex> {
    replay_log_from(path, 0, index)
}

/// Replays only the log tail not covered by a sorted snapshot.
pub fn replay_log_from(
    path: impl AsRef<Path>,
    offset: u64,
    mut index: SummaryIndex,
) -> io::Result<SummaryIndex> {
    let file = match File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(index),
        Err(error) => return Err(error),
    };
    let mut reader = BufReader::new(file);
    reader.seek(SeekFrom::Start(offset))?;
    for line in reader.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let record: IndexRecord = match serde_json::from_str(&line) {
            Ok(record) => record,
            Err(_) => break,
        };
        index = if record.gone {
            index.remove(record.seq, &record.chat_id).unwrap_or(index)
        } else {
            index.apply(record.seq, record.summary)
        };
    }
    Ok(index)
}

/// A sorted `index.snap` file. Snapshot writes are atomic at the caller's
/// boundary; this helper only emits the deterministic compact representation.
pub struct SortedSnapshot;

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct SnapshotFile {
    version: u32,
    seq: u64,
    log_offset: u64,
    #[serde(default)]
    log_name: Option<String>,
    summaries: Vec<Summary>,
}

impl SortedSnapshot {
    pub const VERSION: u32 = 1;

    pub fn write(path: impl AsRef<Path>, index: &SummaryIndex) -> io::Result<()> {
        Self::write_with_offset(path, index, 0)
    }

    pub fn write_with_offset(
        path: impl AsRef<Path>,
        index: &SummaryIndex,
        log_offset: u64,
    ) -> io::Result<()> {
        Self::write_with_offset_and_name(path, index, log_offset, None)
    }

    fn write_with_offset_and_name(
        path: impl AsRef<Path>,
        index: &SummaryIndex,
        log_offset: u64,
        log_name: Option<&str>,
    ) -> io::Result<()> {
        let path = path.as_ref();
        let temp = path.with_extension("snap.tmp");
        let file = File::create(&temp)?;
        let mut writer = BufWriter::new(file);
        serde_json::to_writer(
            &mut writer,
            &SnapshotFile {
                version: Self::VERSION,
                seq: index.seq,
                log_offset,
                log_name: log_name.map(str::to_owned),
                summaries: index.summaries(),
            },
        )
        .map_err(io::Error::other)?;
        writer.flush()?;
        writer.get_ref().sync_all()?;
        fs::rename(&temp, path)?;
        if let Some(parent) = path.parent() {
            if let Ok(dir) = File::open(parent) {
                dir.sync_all()?;
            }
        }
        Ok(())
    }

    pub fn read(path: impl AsRef<Path>) -> io::Result<Option<SummaryIndex>> {
        let file = match File::open(path) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        let snapshot: SnapshotFile =
            serde_json::from_reader(BufReader::new(file)).map_err(io::Error::other)?;
        if snapshot.version != Self::VERSION {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "unknown index snapshot version",
            ));
        }
        let mut index = SummaryIndex::new();
        for summary in snapshot.summaries {
            index = index.apply(snapshot.seq, summary);
        }
        index.seq = snapshot.seq;
        Ok(Some(index))
    }

    fn metadata(path: impl AsRef<Path>) -> io::Result<Option<SnapshotFile>> {
        let file = match File::open(path) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        let snapshot: SnapshotFile =
            serde_json::from_reader(BufReader::new(file)).map_err(io::Error::other)?;
        if snapshot.version != Self::VERSION {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "unknown index snapshot version",
            ));
        }
        Ok(Some(snapshot))
    }

    pub fn read_with_offset(path: impl AsRef<Path>) -> io::Result<Option<(SummaryIndex, u64)>> {
        let file = match File::open(path) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        let snapshot: SnapshotFile =
            serde_json::from_reader(BufReader::new(file)).map_err(io::Error::other)?;
        if snapshot.version != Self::VERSION {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "unknown index snapshot version",
            ));
        }
        let mut index = SummaryIndex::new();
        for summary in snapshot.summaries {
            index = index.apply(snapshot.seq, summary);
        }
        index.seq = snapshot.seq;
        Ok(Some((index, snapshot.log_offset)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn summary(id: &str, at: u64, extra: &str) -> Summary {
        let mut summary = Summary::new(id);
        summary.last_activity = at;
        summary.extra = RawValue::from_string(extra.to_owned()).unwrap();
        summary
    }

    #[test]
    fn applies_one_summary_and_keeps_opaque_extra_bytes() {
        let index = SummaryIndex::new().apply(1, summary("a", 2, "{\"future\": [1, 2]}"));
        assert_eq!(index.len(), 1);
        assert_eq!(index.get("a").unwrap().extra.get(), "{\"future\": [1, 2]}");
        let index = index.apply(2, summary("a", 3, "{\"new\":true}"));
        assert_eq!(index.len(), 1);
        assert_eq!(index.page(0, 2).first().map(|s| s.last_activity), Some(3));
    }

    #[test]
    fn summaries_are_bounded_without_parsing_extra() {
        let mut value = summary("a", 1, "{}");
        value.title = "é".repeat(MAX_TITLE_BYTES);
        value.extra =
            RawValue::from_string(format!("{{\"text\":\"{}\"}}", "x".repeat(8_000))).unwrap();
        let stored = SummaryIndex::new().apply(1, value).get("a").unwrap();
        assert!(stored.title.len() <= MAX_TITLE_BYTES);
        assert!(stored.encoded_len() <= MAX_SUMMARY_BYTES);
        assert!(stored.title.is_char_boundary(stored.title.len()));
    }

    #[test]
    fn log_and_sorted_snapshot_replay() {
        let dir = tempdir().unwrap();
        let log_path = dir.path().join("index.log");
        let snap_path = dir.path().join("index.snap");
        let mut log = IndexLog::open(&log_path).unwrap();
        let first = log.append(summary("a", 2, "{\"x\":1}")).unwrap();
        let second = log.append(summary("b", 1, "null")).unwrap();
        log.sync().unwrap();
        let index =
            SummaryIndex::new().apply(first.seq, first.summary).apply(second.seq, second.summary);
        SortedSnapshot::write(&snap_path, &index).unwrap();
        let restored = SortedSnapshot::read(&snap_path).unwrap().unwrap();
        assert_eq!(restored.seq(), 2);
        assert_eq!(
            restored.page(0, 2).iter().map(|s| s.chat_id.as_str()).collect::<Vec<_>>(),
            ["a", "b"]
        );
        assert_eq!(replay_log(&log_path, SummaryIndex::new()).unwrap().len(), 2);
    }

    #[test]
    fn open_truncates_a_torn_tail_before_the_next_append() {
        let dir = tempdir().unwrap();
        let log_path = dir.path().join("index.log");
        let mut log = IndexLog::open(&log_path).unwrap();
        log.append(summary("a", 1, "{}")).unwrap();
        log.sync().unwrap();
        OpenOptions::new()
            .append(true)
            .open(&log_path)
            .unwrap()
            .write_all(br#"{"seq":99,"chatId":"torn""#)
            .unwrap();
        drop(log);
        let mut reopened = IndexLog::open(&log_path).unwrap();
        let record = reopened.append(summary("b", 2, "{}")).unwrap();
        assert_eq!(record.seq, 2);
        reopened.sync().unwrap();
        assert_eq!(replay_log(&log_path, SummaryIndex::new()).unwrap().len(), 2);
    }

    #[test]
    fn snapshot_carries_the_log_offset_and_compaction_starts_a_new_tail() {
        let dir = tempdir().unwrap();
        let log_path = dir.path().join("index.log");
        let snap_path = dir.path().join("index.snap");
        let mut log = IndexLog::open(&log_path).unwrap();
        let record = log.append(summary("a", 1, "{}")).unwrap();
        log.sync().unwrap();
        let index = SummaryIndex::new().apply(record.seq, record.summary);
        log.compact(&snap_path, &index).unwrap();
        let (restored, offset) = SortedSnapshot::read_with_offset(&snap_path).unwrap().unwrap();
        assert_eq!(offset, 0);
        assert_eq!(replay_log_from(&log_path, offset, restored).unwrap().len(), 1);
        drop(log);
        let mut reopened = IndexLog::open(&log_path).unwrap();
        let next = reopened.append(summary("b", 2, "{}")).unwrap();
        assert_eq!(next.seq, 2);
        reopened.sync().unwrap();
        let restored = SortedSnapshot::read(&snap_path).unwrap().unwrap();
        assert_eq!(replay_log_from(reopened.path(), 0, restored).unwrap().seq(), 2);
    }
}
