//! config.json has more than one writer: the daemon, the CLI (`acpmux config --set`, `machine
//! join` and `leave`), a person's editor, and other builds of acpmux. A save writes only what
//! this process changed since it last read or wrote the file, and keeps every other part of the
//! file as it is now (a three-way merge per JSON key, into nested objects). Keys this build
//! does not know (a newer build's) are kept too.

use serde_json::{Map, Value};
use std::path::Path;
use std::sync::{Arc, Mutex};

/// What this process last read from config.json or wrote to it, in the form a save writes
/// (`Config::on_disk_value`). Shared by the clones of a loaded config. None: no file was read
/// (none was there, or the config was built in code).
#[derive(Clone, Default)]
pub struct SavedBase(Arc<Mutex<Option<Value>>>);

impl SavedBase {
    pub(super) fn new(base: Option<Value>) -> Self {
        Self(Arc::new(Mutex::new(base)))
    }

    fn get(&self) -> Option<Value> {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    fn set(&self, base: Value) {
        *self.0.lock().unwrap_or_else(|e| e.into_inner()) = Some(base);
    }
}

impl std::fmt::Debug for SavedBase {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("SavedBase")
    }
}

/// Bookkeeping, not configuration: two configs with the same settings are equal.
impl PartialEq for SavedBase {
    fn eq(&self, _: &Self) -> bool {
        true
    }
}

/// `ours` (what this process would write) merged into the file as it is now: a key this
/// process did not change since `base` keeps the file's value, a changed one takes ours.
fn merge(base: Option<&Value>, ours: &Value, current: Option<&Value>) -> Value {
    let Some(current) = current.filter(|c| c.is_object()) else { return ours.clone() };
    let empty = Value::Object(Map::new());
    // No base: every key this process has is its own; only keys it lacks keep the file's.
    let base = base.unwrap_or(&empty);
    merge_key(Some(base), Some(ours), Some(current)).unwrap_or_else(|| ours.clone())
}

fn merge_key(base: Option<&Value>, ours: Option<&Value>, current: Option<&Value>) -> Option<Value> {
    if ours == base {
        return current.cloned();
    }
    let (Some(Value::Object(b)), Some(Value::Object(o)), Some(Value::Object(c))) =
        (base, ours, current)
    else {
        return ours.cloned();
    };
    let mut keys: Vec<&String> = c.keys().chain(o.keys()).chain(b.keys()).collect();
    keys.sort_unstable();
    keys.dedup();
    let merged = keys
        .into_iter()
        .filter_map(|k| merge_key(b.get(k), o.get(k), c.get(k)).map(|v| (k.clone(), v)))
        .collect();
    Some(Value::Object(merged))
}

/// Writes `ours` into `path` merged with the file as it is now, under the config lock that
/// every acpmux writer of this file takes; `base` then holds `ours`.
pub(super) fn save_merged(
    path: &Path,
    base: &SavedBase,
    ours: Value,
    write: impl FnOnce(&Path, &[u8]) -> anyhow::Result<()>,
) -> anyhow::Result<()> {
    let _lock = lock(path);
    let current = std::fs::read(path).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok());
    let merged = merge(base.get().as_ref(), &ours, current.as_ref());
    write(path, serde_json::to_string_pretty(&merged)?.as_bytes())?;
    base.set(ours);
    Ok(())
}

/// `<config>.lock`, held while a writer reads, merges and writes the file. Bounded: a writer
/// that holds it longer than a save takes (a hung process) is not waited for; the save then
/// goes on unlocked, as every save did before.
#[cfg(unix)]
fn lock(path: &Path) -> Option<std::fs::File> {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;
    let mut name = path.as_os_str().to_owned();
    name.push(".lock");
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&name)
        .ok()?;
    for _ in 0..100 {
        // SAFETY: flock on a descriptor this function owns.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
            return Some(file);
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    tracing::warn!(path = %path.display(), "config lock held for over 1 s; saving without it");
    None
}

#[cfg(not(unix))]
fn lock(_path: &Path) -> Option<std::fs::File> {
    None
}
