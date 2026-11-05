//! Activity: what other machines did here, one JSON line each
//! (docs/multi-machine-sessions.md, "Audit and revoke").
//!
//! Append only, 0600, never content: who, what, the target and the decision.
//! Bounded: at [`ROTATE_AT`] the file becomes `<name>.1.jsonl` (one previous
//! file kept), so a peer repeating refused requests cannot fill the disk.
//! Phones are not logged here; their lanes keep their own records.

use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;

use serde::Serialize;

/// One request a machine made here.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Entry {
    /// Epoch milliseconds.
    pub at_ms: i64,
    /// The peer's device id (backend-stamped) and its name as it gave it at `auth`.
    pub peer: String,
    pub kind: &'static str,
    /// `in`: the peer asked this Mac; `out`: this Mac asked the peer.
    pub direction: &'static str,
    /// The link service (`machine`, `daemon`, `install`, ...).
    pub service: String,
    /// `allowed`, or the refusal code (`not_granted`, `not_offered`, `revoked`, `unpaired`).
    pub decision: String,
    /// What it touched, when the service names one (a bundle id and sha256, a workspace id).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
}

/// Where entries go.
#[derive(Debug)]
pub struct Activity {
    path: Option<PathBuf>,
    /// The size at which the file rotates.
    rotate_at: u64,
    /// Kept in memory as well, newest last, for tests and `machine activity`.
    recent: Mutex<Vec<Entry>>,
}

/// How many entries stay in memory.
const RECENT: usize = 512;
/// The file's size bound before it rotates (two files, so twice this on disk).
pub const ROTATE_AT: u64 = 4 * 1024 * 1024;

impl Activity {
    /// Kept in memory only (tests, unsupervised hostd).
    pub fn memory() -> Self {
        Self { path: None, rotate_at: ROTATE_AT, recent: Mutex::default() }
    }

    /// Appended to `path` as well.
    pub fn file(path: PathBuf) -> Self {
        Self { path: Some(path), rotate_at: ROTATE_AT, recent: Mutex::default() }
    }

    /// The same, rotating at `bytes` (tests).
    pub fn rotating_at(mut self, bytes: u64) -> Self {
        self.rotate_at = bytes;
        self
    }

    pub fn record(&self, entry: Entry) {
        if let Some(path) = &self.path
            && let Err(error) = append(path, &entry, self.rotate_at)
        {
            tracing::warn!(path = %path.display(), %error, "could not write machine activity");
        }
        let mut recent = self.recent.lock().expect("activity");
        recent.push(entry);
        let excess = recent.len().saturating_sub(RECENT);
        recent.drain(..excess);
    }

    pub fn recent(&self) -> Vec<Entry> {
        self.recent.lock().expect("activity").clone()
    }
}

fn append(path: &std::path::Path, entry: &Entry, rotate_at: u64) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    if std::fs::metadata(path).is_ok_and(|meta| meta.len() >= rotate_at) {
        std::fs::rename(path, path.with_extension("1.jsonl"))?;
    }
    let mut options = std::fs::OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path)?;
    let mut line = serde_json::to_vec(entry).map_err(std::io::Error::other)?;
    line.push(b'\n');
    file.write_all(&line)
}

pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(service: &str, decision: &str) -> Entry {
        Entry {
            at_ms: 1,
            peer: "mac-1".into(),
            kind: "mac",
            direction: "in",
            service: service.into(),
            decision: decision.into(),
            target: None,
        }
    }

    #[test]
    fn entries_append_as_private_json_lines() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sub/machine-activity.jsonl");
        let activity = Activity::file(path.clone());
        activity.record(entry("machine", "allowed"));
        activity.record(entry("daemon", "not_granted"));
        let text = std::fs::read_to_string(&path).unwrap();
        let lines: Vec<serde_json::Value> = text.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[1]["service"], "daemon");
        assert_eq!(lines[1]["decision"], "not_granted");
        assert!(lines[0].get("target").is_none());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        }
        assert_eq!(activity.recent().len(), 2);
    }

    #[test]
    fn the_file_rotates_and_keeps_one_previous() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("machine-activity.jsonl");
        let activity = Activity::file(path.clone()).rotating_at(300);
        for _ in 0..20 {
            activity.record(entry("daemon", "not_granted"));
        }
        let previous = dir.path().join("machine-activity.1.jsonl");
        assert!(std::fs::metadata(&path).unwrap().len() < 300 + 200);
        assert!(std::fs::metadata(&previous).unwrap().len() < 300 + 200);
        let names = std::fs::read_dir(dir.path()).unwrap().count();
        assert_eq!(names, 2, "never more than the file and one previous");
    }
}
