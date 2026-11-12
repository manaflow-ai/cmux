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
use std::fs::{File, OpenOptions};
use std::io::{self, BufRead, BufReader, BufWriter, Write};
use std::path::Path;
use std::sync::Arc;

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
}

/// An index-log record. The sequence is monotonic for this index and is the
/// cursor clients use to resume the list stream.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IndexRecord {
    pub seq: u64,
    pub chat_id: String,
    pub summary: Summary,
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
}

impl Default for SummaryIndex {
    fn default() -> Self {
        Self::new()
    }
}

impl SummaryIndex {
    pub fn new() -> Self {
        Self { seq: 0, by_id: OrdMap::new(), ordered: OrdMap::new() }
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
        let summary = Arc::new(summary);
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
        Self { seq: self.seq.max(seq), by_id, ordered }
    }

    /// Returns summaries newest first. The iterator borrows the persistent
    /// snapshot; collecting it is a caller-owned page operation.
    pub fn iter(&self) -> impl Iterator<Item = &Arc<Summary>> {
        self.ordered.values()
    }

    pub fn page(&self, start: usize, limit: usize) -> Vec<Arc<Summary>> {
        self.iter().skip(start).take(limit).cloned().collect()
    }

    pub fn summaries(&self) -> Vec<Summary> {
        self.iter().map(|summary| summary.as_ref().clone()).collect()
    }
}

/// The append-only `index.log` writer.
pub struct IndexLog {
    file: BufWriter<File>,
    next_seq: u64,
}

impl IndexLog {
    pub fn open(path: impl AsRef<Path>) -> io::Result<Self> {
        let path = path.as_ref();
        let next_seq = match File::open(path) {
            Ok(file) => BufReader::new(file)
                .lines()
                .filter_map(Result::ok)
                .filter_map(|line| serde_json::from_str::<IndexRecord>(&line).ok())
                .map(|record| record.seq)
                .max()
                .unwrap_or(0),
            Err(error) if error.kind() == io::ErrorKind::NotFound => 0,
            Err(error) => return Err(error),
        };
        let file = OpenOptions::new().create(true).append(true).open(path)?;
        Ok(Self { file: BufWriter::new(file), next_seq })
    }

    pub fn append(&mut self, summary: Summary) -> io::Result<IndexRecord> {
        self.next_seq = self.next_seq.saturating_add(1);
        let record = IndexRecord { seq: self.next_seq, chat_id: summary.chat_id.clone(), summary };
        serde_json::to_writer(&mut self.file, &record).map_err(io::Error::other)?;
        self.file.write_all(b"\n")?;
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
}

/// Reads the log's tail into a persistent index. A malformed or partial final
/// line is ignored so a torn append does not hide earlier summaries.
pub fn replay_log(path: impl AsRef<Path>, mut index: SummaryIndex) -> io::Result<SummaryIndex> {
    let file = match File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(index),
        Err(error) => return Err(error),
    };
    for line in BufReader::new(file).lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let record: IndexRecord = match serde_json::from_str(&line) {
            Ok(record) => record,
            Err(_) => break,
        };
        index = index.apply(record.seq, record.summary);
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
    summaries: Vec<Summary>,
}

impl SortedSnapshot {
    pub const VERSION: u32 = 1;

    pub fn write(path: impl AsRef<Path>, index: &SummaryIndex) -> io::Result<()> {
        let file = File::create(path)?;
        let mut writer = BufWriter::new(file);
        serde_json::to_writer(
            &mut writer,
            &SnapshotFile { version: Self::VERSION, seq: index.seq, summaries: index.summaries() },
        )
        .map_err(io::Error::other)?;
        writer.flush()
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
            return Ok(None);
        }
        let mut index = SummaryIndex::new();
        for summary in snapshot.summaries {
            index = index.apply(snapshot.seq, summary);
        }
        index.seq = snapshot.seq;
        Ok(Some(index))
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
}
