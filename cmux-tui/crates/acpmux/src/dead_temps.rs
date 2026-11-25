//! Temporary copies a writer killed before its rename left behind. Every atomic writer in acpmux
//! writes a temporary copy beside its file, named with its own pid (`<stem>.tmp-<pid>-<n>`,
//! `<stem>.tmp-<pid>`, `.<name>.tmp-<pid>-<n>`), then renames it over the file, and removes the
//! copy when the write fails. A process stopped between the copy's open and its rename (a daemon
//! stopped by its supervisor or an update's handoff, a CLI run under a timeout) never removes it:
//! a joined Mac's `machine-consent/` held `refusal.json` and 8 `refusal.tmp-<pid>-<n>` files.
//!
//! The next write of the same file removes them ([`remove_beside`]): it reads at most
//! [`MAX_NAMES`] names of that one folder, at most once a minute for each file per process, and
//! removes only a copy whose pid no process runs now and that is a minute old, so a running
//! writer's copy is never touched.
//!
//! A copy is named by its file and its writer's pid alone (`<stem>.tmp-<pid>`,
//! `.<name>.tmp-<pid>`), never with a counter too: fseventsd keeps what it learns of every path
//! it is told of until it restarts, and a peer snapshot's `.tmp-<pid>-<n>` minted a new name on
//! every write, about 400 a minute on a Mac with a few dozen peer chats streaming (#44520). Two
//! writers in one process take turns on a name ([`hold`]); another process's name differs by its
//! pid.

use std::collections::HashMap;
use std::hash::{Hash as _, Hasher as _};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant, SystemTime};

/// Locks a writer of this process holds on its temporary copy's name, picked by the name's hash:
/// a fixed number, so they cost the same however many files are written.
const NAME_LOCKS: usize = 64;

/// Held by a writer of this process from its temporary copy's open to its rename (or removal),
/// so another writer of the same name (`tmp`) in this process waits and no two fill one copy.
/// Hold it around the open, the write and the rename only, never around another write: two
/// names may share a lock.
pub(crate) fn hold(tmp: &Path) -> MutexGuard<'static, ()> {
    static LOCKS: [Mutex<()>; NAME_LOCKS] = [const { Mutex::new(()) }; NAME_LOCKS];
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    tmp.hash(&mut hasher);
    let index = hasher
        .finish()
        .checked_rem(NAME_LOCKS as u64)
        .and_then(|i| usize::try_from(i).ok())
        .unwrap_or(0);
    // `index` is below NAME_LOCKS, so `get` always finds one; the first stands in otherwise.
    let lock = LOCKS.get(index).or(LOCKS.first());
    match lock {
        Some(lock) => lock.lock().unwrap_or_else(PoisonError::into_inner),
        None => {
            static ONE: Mutex<()> = Mutex::new(());
            ONE.lock().unwrap_or_else(PoisonError::into_inner)
        }
    }
}

/// The names read in a folder per sweep: the cost of a write stays the same however full its
/// folder is.
const MAX_NAMES: usize = 1024;
/// How long a file's folder is not looked at again after a sweep, and how old a copy must be.
const QUIET: Duration = Duration::from_secs(60);
/// The files whose last sweep is remembered; past it all are forgotten, and swept again once.
const MAX_REMEMBERED: usize = 1024;
/// The highest pid any supported system hands out (Linux's `pid_max` limit, 2^22; macOS stops
/// below 100000). A larger number (a date, `notes.tmp-20261115`) is no writer's pid.
const MAX_PID: u32 = 1 << 22;

/// [`remove`] for the copies the `path.with_extension("tmp-…")` writers leave beside `path`
/// (`<stem>.tmp-<pid>…`).
pub(crate) fn remove_beside(path: &Path) {
    let tmp = path.with_extension("tmp-");
    let (Some(dir), Some(name)) = (path.parent(), tmp.file_name()) else { return };
    remove(dir, &name.to_string_lossy());
}

/// Removes the files in `dir` named `<prefix><pid>` or `<prefix><pid>-<anything>` whose pid is
/// not this process's, no process runs, and which were last changed over a minute ago. Errors
/// are ignored: a copy that stays is removed by a later write.
pub(crate) fn remove(dir: &Path, prefix: &str) {
    if !due(dir.join(prefix)) {
        return;
    }
    let Ok(names) = crate::home_fs::read_dir_names(dir, MAX_NAMES) else { return };
    let own = std::process::id();
    let now = SystemTime::now();
    for name in names {
        let Some(pid) = name.to_str().and_then(|name| pid_after(name, prefix)) else { continue };
        if pid == own || running(pid) {
            continue;
        }
        let path = dir.join(&name);
        let old = crate::home_fs::symlink_metadata(&path).ok().is_some_and(|meta| {
            meta.is_file()
                && meta
                    .modified()
                    .ok()
                    .and_then(|at| now.duration_since(at).ok())
                    .is_some_and(|age| age >= QUIET)
        });
        if old {
            let _ = crate::home_fs::remove_file(&path);
        }
    }
}

/// Whether `key`'s folder is looked at now: not in the last [`QUIET`] by this process.
fn due(key: PathBuf) -> bool {
    static LAST: Mutex<Option<HashMap<PathBuf, Instant>>> = Mutex::new(None);
    let mut last = LAST.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let last = last.get_or_insert_with(HashMap::new);
    let now = Instant::now();
    if last.get(&key).is_some_and(|at| now.duration_since(*at) < QUIET) {
        return false;
    }
    if last.len() >= MAX_REMEMBERED {
        last.clear();
    }
    last.insert(key, now);
    true
}

/// The pid in `name` when it is `<prefix><digits>` or `<prefix><digits>-<anything>`.
fn pid_after(name: &str, prefix: &str) -> Option<u32> {
    let rest = name.strip_prefix(prefix)?;
    let digits = rest.split('-').next()?;
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    digits.parse().ok().filter(|pid| (1..=MAX_PID).contains(pid))
}

/// Whether a process with `pid` runs now. When that cannot be told, it is taken to run.
fn running(pid: u32) -> bool {
    #[cfg(unix)]
    {
        let Ok(pid) = libc::pid_t::try_from(pid) else { return true };
        // SAFETY: signal 0 sends nothing; it only checks that the pid exists.
        if unsafe { libc::kill(pid, 0) } == 0 {
            return true;
        }
        std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
    }
    #[cfg(not(unix))]
    {
        let _ = pid;
        true
    }
}

#[cfg(test)]
#[path = "dead_temps_tests.rs"]
mod tests;
