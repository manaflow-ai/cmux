//! The index: a dedicated OptChat memory home (default `~/.cmux/agent-memory`)
//! that no Chief host owns, written in-process the way `optchat-chief import`
//! writes and read with the read-only connection `memory search` uses. Each
//! entry is one imported message whose first line is `[source]`, so a hit
//! names its source with no side map.
//!
//! One lock file beside the index (`agent-memory.lock`, flock): a rebuild
//! or a note takes it exclusively; a search takes it shared, so no rebuild
//! swaps the database under a reader. A rebuild writes a fresh sibling
//! directory and renames it into place. The manifest lists the entries'
//! sources; the index is stale when it is missing, when any source file is
//! newer, or when the list of sources changed (a deleted file changes no
//! mtime that survives).

use std::fs::File;
use std::path::{Path, PathBuf};

use optchat_core::Kind;
use optchat_host::db::ReadOnly;
use serde_json::{Value, json};

use super::notes::{self, Provenance};
use super::sources::{Entry, Sources, note_entry};
use crate::paths::Paths;

const MANIFEST: &str = "agent-memory-manifest.json";
/// Bumped when the stored text or manifest changes shape: an older index
/// (the leo-workspace prototype's bare label list) is rebuilt.
const MANIFEST_VERSION: u64 = 2;

/// One search hit or one entry read by id.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Hit {
    pub id: u64,
    pub kind: String,
    pub date: String,
    pub source: String,
    /// The matching words in `[` `]` with some context (empty for `get`).
    pub snippet: String,
    /// The entry's full text, without its `[source]` line.
    pub text: String,
}

impl Hit {
    pub fn to_json(&self) -> Value {
        json!({
            "id": self.id,
            "kind": self.kind,
            "date": self.date,
            "source": self.source,
            "snippet": self.snippet,
            "text": self.text,
        })
    }
}

pub struct Index {
    /// The OptChat home of the index.
    pub root: PathBuf,
    pub sources: Sources,
}

impl Index {
    pub fn new(root: PathBuf, sources: Sources) -> Index {
        Index { root, sources }
    }

    fn paths(&self) -> Paths {
        Paths::new(&self.root)
    }

    fn lock(&self, shared: bool) -> Result<File, String> {
        let parent = self.root.parent().unwrap_or(Path::new("/"));
        std::fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
        let path = sibling(&self.root, ".lock");
        let file = File::options()
            .create(true)
            .truncate(false)
            .write(true)
            .open(&path)
            .map_err(|e| format!("{}: {e}", path.display()))?;
        use std::os::fd::AsRawFd;
        let op = if shared { libc::LOCK_SH } else { libc::LOCK_EX };
        // SAFETY: flock on a descriptor this function owns; released on drop.
        if unsafe { libc::flock(file.as_raw_fd(), op) } != 0 {
            return Err(format!(
                "{}: {}",
                path.display(),
                std::io::Error::last_os_error()
            ));
        }
        Ok(file)
    }

    fn manifest(&self) -> Option<Vec<String>> {
        let text = std::fs::read_to_string(self.root.join(MANIFEST)).ok()?;
        let value: Value = serde_json::from_str(&text).ok()?;
        if value.get("version").and_then(Value::as_u64) != Some(MANIFEST_VERSION) {
            return None;
        }
        value
            .get("sources")?
            .as_array()?
            .iter()
            .map(|s| s.as_str().map(str::to_owned))
            .collect()
    }

    fn write_manifest(dir: &Path, sources: &[String]) -> Result<(), String> {
        let path = dir.join(MANIFEST);
        let text = json!({"version": MANIFEST_VERSION, "sources": sources}).to_string();
        let tmp = dir.join(format!("{MANIFEST}.tmp"));
        std::fs::write(&tmp, text)
            .and_then(|()| std::fs::rename(&tmp, &path))
            .map_err(|e| format!("{}: {e}", path.display()))
    }

    /// Whether the index no longer matches its sources (see the module doc).
    pub fn stale(&self) -> bool {
        self.stale_against(None)
    }

    fn stale_against(&self, entries: Option<&[Entry]>) -> bool {
        let Some(listed) = self.manifest() else {
            return true;
        };
        if !self.paths().memory_db.is_file() {
            return true;
        }
        let built = std::fs::metadata(self.root.join(MANIFEST)).and_then(|m| m.modified());
        match (self.sources.newest(), built) {
            (Some(newest), Ok(built)) if newest > built => return true,
            (_, Err(_)) => return true,
            _ => {}
        }
        let now: Vec<String> = match entries {
            Some(entries) => entries.iter().map(|e| e.source.clone()).collect(),
            None => self
                .sources
                .entries()
                .into_iter()
                .map(|e| e.source)
                .collect(),
        };
        listed != now
    }

    /// Rebuilds when stale; a no-op when current. Returns what it did.
    pub fn refresh(&self, force: bool) -> Result<String, String> {
        if !force && !self.stale() {
            return Ok("index already current".into());
        }
        let _lock = self.lock(false)?;
        // Another process may have rebuilt while this one waited.
        if !force && !self.stale() {
            return Ok("index already current".into());
        }
        let n = self.rebuild()?;
        Ok(format!(
            "indexed {n} memory entries into {}",
            self.root.display()
        ))
    }

    /// Writes every entry into a fresh sibling and swaps it in (lock held).
    fn rebuild(&self) -> Result<usize, String> {
        let entries = self.sources.entries();
        // A short sibling keeps the chat lock's socket path under SUN_LEN.
        let fresh = sibling(&self.root, &format!(".new-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&fresh);
        let result = (|| {
            create_private(&fresh)?;
            import(&fresh, &entries)?;
            let sources: Vec<String> = entries.iter().map(|e| e.source.clone()).collect();
            Self::write_manifest(&fresh, &sources)?;
            let old = sibling(&self.root, ".old");
            let _ = std::fs::remove_dir_all(&old);
            if self.root.exists() {
                std::fs::rename(&self.root, &old)
                    .map_err(|e| format!("{}: {e}", self.root.display()))?;
            }
            std::fs::rename(&fresh, &self.root)
                .map_err(|e| format!("{}: {e}", self.root.display()))?;
            let _ = std::fs::remove_dir_all(&old);
            Ok(entries.len())
        })();
        let _ = std::fs::remove_dir_all(&fresh);
        result
    }

    /// Full-text search: entries holding every word, best first.
    pub fn search(&self, query: &str, limit: usize) -> Result<Vec<Hit>, String> {
        self.refresh(false)?;
        let _lock = self.lock(true)?;
        let db = self.read_only()?;
        let hits = db
            .search(query, limit)
            .map_err(|e| format!("searching: {e}"))?;
        let mut out = Vec::new();
        for hit in hits {
            // Only messages: no host builds summary nodes in this home.
            if let optchat_host::db::Hit::Message { id, snippet, .. } = hit
                && let Some(mut found) = self.row(&db, id)?
            {
                found.snippet = snippet;
                out.push(found);
            }
        }
        Ok(out)
    }

    /// Entry `id` in full, as indexed. Builds a missing index, but never
    /// rebuilds a stale one: that could renumber the ids a search just gave.
    pub fn get(&self, id: u64) -> Result<Hit, String> {
        if self.manifest().is_none() || !self.paths().memory_db.is_file() {
            self.refresh(false)?;
        }
        let _lock = self.lock(true)?;
        let db = self.read_only()?;
        self.row(&db, id)?.ok_or_else(|| format!("no entry #{id}"))
    }

    fn read_only(&self) -> Result<ReadOnly, String> {
        let db = self.paths().memory_db;
        ReadOnly::open(&db).map_err(|e| format!("{}: {e}", db.display()))
    }

    fn row(&self, db: &ReadOnly, id: u64) -> Result<Option<Hit>, String> {
        let row = db
            .message_row(id)
            .map_err(|e| format!("reading entry #{id}: {e}"))?;
        Ok(row.map(|row| {
            let (source, text) = split_label(&row.text);
            Hit {
                id,
                kind: row.kind,
                date: row.date,
                source: source.to_owned(),
                snippet: String::new(),
                text: text.to_owned(),
            }
        }))
    }

    /// Saves a note and indexes it: one appended entry when the index was
    /// current, else a rebuild. The note is durable once this returns Ok,
    /// even when indexing failed (the next search catches up).
    pub fn remember(&self, text: &str, from: &Provenance) -> Result<String, String> {
        let _lock = self.lock(false)?;
        let was_current = !self.stale();
        let (i, note) = notes::append(&self.sources.notes, text, from)?;
        let entry = note_entry(i, &note);
        let indexed = if was_current {
            let mut sources = self.manifest().unwrap_or_default();
            import(&self.root, std::slice::from_ref(&entry)).and_then(|ids| {
                sources.push(entry.source.clone());
                Self::write_manifest(&self.root, &sources)?;
                Ok(format!("saved {} as entry #{}", entry.source, ids[0]))
            })
        } else {
            self.rebuild().map(|_| format!("saved {}", entry.source))
        };
        Ok(indexed.unwrap_or_else(|e| {
            format!(
                "saved {}; the index catches up on the next search ({e})",
                entry.source
            )
        }))
    }
}

/// `root` with `suffix` on its file name (`agent-memory.lock`).
fn sibling(root: &Path, suffix: &str) -> PathBuf {
    let name = root
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "agent-memory".into());
    root.with_file_name(format!("{name}{suffix}"))
}

fn create_private(dir: &Path) -> Result<(), String> {
    use std::os::unix::fs::DirBuilderExt;
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .map_err(|e| format!("{}: {e}", dir.display()))
}

/// Appends `entries` to the memory in `home` (no host runs there); their ids.
fn import(home: &Path, entries: &[Entry]) -> Result<Vec<u64>, String> {
    let paths = Paths::new(home);
    create_private(&paths.root)?;
    let chat = crate::browse::open_offline(&paths.chat, &paths.memory_db)?;
    let mut ids = Vec::with_capacity(entries.len());
    let mut failed = None;
    for entry in entries {
        let date = chrono::DateTime::parse_from_rfc3339(&entry.date)
            .is_ok()
            .then_some(entry.date.as_str());
        match chat.append_imported(Kind::Note, &labelled(entry), date) {
            Ok(id) => ids.push(id),
            Err(e) => {
                failed = Some(format!("indexing {}: {e}", entry.source));
                break;
            }
        }
    }
    chat.shutdown();
    match failed {
        Some(e) => Err(e),
        None => Ok(ids),
    }
}

/// The stored text: `[source]` on its own line, then the entry.
fn labelled(entry: &Entry) -> String {
    format!("[{}]\n{}", entry.source, entry.text)
}

/// The stored text's source and the entry's own text.
pub fn split_label(stored: &str) -> (&str, &str) {
    if let Some(rest) = stored.strip_prefix('[')
        && let Some((first, body)) = rest.split_once('\n')
        && let Some(source) = first.strip_suffix(']')
    {
        return (source, body);
    }
    ("", stored)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn labels_round_trip() {
        let entry = Entry {
            source: "~/a [b].md".into(),
            date: String::new(),
            text: "line one\nline two".into(),
        };
        assert_eq!(
            split_label(&labelled(&entry)),
            ("~/a [b].md", "line one\nline two")
        );
        assert_eq!(split_label("no label"), ("", "no label"));
    }

    #[test]
    fn siblings_keep_the_name() {
        assert_eq!(
            sibling(Path::new("/h/.cmux/agent-memory"), ".lock"),
            PathBuf::from("/h/.cmux/agent-memory.lock")
        );
    }
}
