//! The trace as the inspector reads it: each day file parsed once and then
//! only its new tail, so the Live tab's poll and a click on a turn do not
//! parse weeks of JSON lines again. A `turn.start` keeps its view parts
//! (hundreds of names) out of the cache; `turn_start` reads that one line
//! back from its file when a turn's prompt is asked for.

use std::collections::{BTreeMap, HashMap};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde_json::Value;

#[derive(Default)]
struct FileEvents {
    /// Bytes parsed so far (always at a line end).
    len: u64,
    events: Vec<Value>,
    /// Each `turn.start`'s line: turn key to (offset, length).
    starts: HashMap<String, (u64, usize)>,
}

#[derive(Default)]
pub struct TraceCache {
    files: Mutex<BTreeMap<PathBuf, FileEvents>>,
}

fn day_of(ms: u64) -> String {
    chrono::DateTime::from_timestamp_millis(ms as i64)
        .map(|t| {
            t.with_timezone(&chrono::Local)
                .format("%Y-%m-%d")
                .to_string()
        })
        .unwrap_or_default()
}

/// Reads `path` from `cached.len` on: the complete new lines.
fn refresh(path: &Path, cached: &mut FileEvents) {
    let Ok(mut file) = std::fs::File::open(path) else {
        return;
    };
    let size = file.metadata().map(|m| m.len()).unwrap_or(0);
    if size < cached.len {
        // Rewritten (never by the host, which only appends): start over.
        *cached = FileEvents::default();
    }
    if size == cached.len || file.seek(SeekFrom::Start(cached.len)).is_err() {
        return;
    }
    let mut tail = Vec::new();
    if file.read_to_end(&mut tail).is_err() {
        return;
    }
    // Only whole lines: a line being written stays for the next read.
    let Some(last) = tail.iter().rposition(|b| *b == b'\n') else {
        return;
    };
    let mut offset = cached.len;
    for line in tail[..=last].split_inclusive(|b| *b == b'\n') {
        if let Ok(mut event) = serde_json::from_slice::<Value>(line) {
            if event["ev"] == "turn.start"
                && let Some(key) = event["turn"].as_str()
            {
                cached.starts.insert(key.to_owned(), (offset, line.len()));
                if let Some(view) = event.get_mut("view").and_then(Value::as_object_mut) {
                    let recorded = view.remove("parts").is_some();
                    view.insert("parts_recorded".into(), Value::Bool(recorded));
                }
            }
            cached.events.push(event);
        }
        offset += line.len() as u64;
    }
    cached.len = offset;
}

impl TraceCache {
    fn day_files(dir: &Path, since_day: &str) -> Vec<PathBuf> {
        let mut files: Vec<PathBuf> = std::fs::read_dir(dir)
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.path())
            .filter(|p| {
                p.extension().is_some_and(|x| x == "jsonl")
                    && p.file_stem()
                        .and_then(|s| s.to_str())
                        .is_some_and(|day| day >= since_day)
            })
            .collect();
        files.sort();
        files
    }

    /// Every event at or after `since_ms`, oldest first (view parts left out).
    pub fn events(&self, dir: &Path, since_ms: u64) -> Vec<Value> {
        let since_day = if since_ms == 0 {
            String::new()
        } else {
            day_of(since_ms)
        };
        let mut files = self
            .files
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut out = Vec::new();
        for path in Self::day_files(dir, &since_day) {
            let cached = files.entry(path.clone()).or_default();
            refresh(&path, cached);
            out.extend(
                cached
                    .events
                    .iter()
                    .filter(|e| e["ts"].as_u64().unwrap_or(0) >= since_ms)
                    .cloned(),
            );
        }
        out.sort_by_key(|e| e["ts"].as_u64().unwrap_or(0));
        out
    }

    /// The whole `turn.start` line of turn `key` (with its view parts), the
    /// newest when a key repeats.
    pub fn turn_start(&self, dir: &Path, key: &str) -> Option<Value> {
        self.events(dir, 0);
        let files = self
            .files
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let (path, (offset, len)) = files
            .iter()
            .rev()
            .find_map(|(p, f)| f.starts.get(key).map(|at| (p.clone(), *at)))?;
        drop(files);
        let mut file = std::fs::File::open(path).ok()?;
        file.seek(SeekFrom::Start(offset)).ok()?;
        let mut line = vec![0u8; len];
        file.read_exact(&mut line).ok()?;
        serde_json::from_slice(&line).ok()
    }
}
