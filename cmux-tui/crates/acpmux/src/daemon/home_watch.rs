//! A daemon whose home is gone stops. A test harness that made a temporary `ACPMUX_HOME`,
//! started a daemon there and then removed the folder left that daemon running for days on
//! deleted files (cosmic-gray, 2026-10-29: two nightly daemons under a removed Python `mkdtemp`
//! home, one 8 days old); nothing could reach it, and a later command that recreated the folder
//! found its lock free and started a second one. So the daemon watches the folders that hold
//! its home, socket and lock, and shuts down normally once any of the three is no longer the
//! file it started with: removed, renamed away, or replaced by another one.
//!
//! Event-driven, never a timer: one `notify` watch (inotify on Linux, FSEvents on macOS) on the
//! home and on the socket's folder when that is another one. An idle daemon's folders see no
//! entry change, so the watch adds no wakeup (`tests/daemon_idle.rs`). Each event re-reads the
//! three paths' identities (`lstat`); nothing else. The watch stops when [`HomeGone`] is
//! dropped: at shutdown, or once it reported the loss.

use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;

/// One path's identity: the device and inode it had when the daemon bound it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Identity {
    dev: u64,
    ino: u64,
}

#[cfg(unix)]
pub(crate) fn identity(path: &Path) -> Option<Identity> {
    use std::os::unix::fs::MetadataExt;
    std::fs::symlink_metadata(path).ok().map(|m| Identity { dev: m.dev(), ino: m.ino() })
}

/// The paths a running daemon owns, with the identity each had when it started.
#[derive(Clone, Debug)]
pub(crate) struct Owned {
    paths: Vec<(PathBuf, Identity)>,
}

impl Owned {
    /// The identities of `paths` now; `None` when any cannot be read (a relative or already
    /// missing path): then nothing is watched, so a path this daemon never saw is never taken
    /// for a loss.
    #[cfg(unix)]
    pub(crate) fn now(paths: &[&Path]) -> Option<Self> {
        let paths = paths
            .iter()
            .map(|p| identity(p).map(|id| (p.to_path_buf(), id)))
            .collect::<Option<Vec<_>>>()?;
        Some(Self { paths })
    }

    /// The first owned path that is no longer the file it was, and why.
    #[cfg(unix)]
    pub(crate) fn lost(&self) -> Option<String> {
        self.paths.iter().find_map(|(path, was)| match identity(path) {
            None => Some(format!("{} was removed", path.display())),
            Some(now) if now != *was => Some(format!("{} was replaced", path.display())),
            Some(_) => None,
        })
    }
}

/// Resolves once the home, the socket or the lock is lost; never when the watch could not be
/// set up (it logs why). Dropping it ends the watch.
pub(crate) type HomeGone = Pin<Box<dyn Future<Output = String> + Send>>;

/// Watch `home`, `socket` and `lock` (see the module doc).
#[cfg(unix)]
pub(crate) fn watch(home: &Path, socket: &Path, lock: &Path) -> HomeGone {
    use notify::Watcher as _;
    let Some(owned) = Owned::now(&[home, socket, lock]) else {
        tracing::warn!(
            "home watch off: {}, {} or {} cannot be read",
            home.display(),
            socket.display(),
            lock.display()
        );
        return Box::pin(std::future::pending());
    };
    // One slot: events that arrive while a check runs fold into the next check.
    let (tx, mut rx) = tokio::sync::mpsc::channel::<()>(1);
    let watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
        if !matches!(&event, Ok(e) if e.kind.is_access()) {
            let _ = tx.try_send(());
        }
    });
    let mut watcher = match watcher {
        Ok(w) => w,
        Err(e) => {
            tracing::warn!("home watch off: {e}");
            return Box::pin(std::future::pending());
        }
    };
    // The folders, canonical: FSEvents reports `/private/var/...` for `/var/...`.
    let mut dirs = vec![home.to_path_buf()];
    if let Some(parent) = socket.parent().filter(|p| !p.as_os_str().is_empty())
        && std::fs::canonicalize(parent).ok() != std::fs::canonicalize(home).ok()
    {
        dirs.push(parent.to_path_buf());
    }
    for dir in &dirs {
        let dir = std::fs::canonicalize(dir).unwrap_or_else(|_| dir.clone());
        if let Err(e) = watcher.watch(&dir, notify::RecursiveMode::NonRecursive) {
            tracing::warn!("home watch off: watch {}: {e}", dir.display());
            return Box::pin(std::future::pending());
        }
    }
    Box::pin(async move {
        // Owned here: the watch lives exactly as long as this future.
        let _watcher = watcher;
        // A loss between reading the identities and the first watch.
        if let Some(why) = owned.lost() {
            return why;
        }
        loop {
            if rx.recv().await.is_none() {
                return std::future::pending().await;
            }
            if let Some(why) = owned.lost() {
                return why;
            }
        }
    })
}

#[cfg(not(unix))]
pub(crate) fn watch(_home: &Path, _socket: &Path, _lock: &Path) -> HomeGone {
    Box::pin(std::future::pending())
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn a_removed_or_replaced_path_is_lost_and_an_unchanged_one_is_not() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        std::fs::create_dir(&home).unwrap();
        let lock = home.join("daemon.lock");
        std::fs::write(&lock, "").unwrap();
        let owned = Owned::now(&[&home, &lock]).unwrap();
        assert_eq!(owned.lost(), None);
        // Replaced: another file renamed over it (made while the first one exists, so its
        // inode cannot be the first one's reused).
        std::fs::write(dir.path().join("other"), "").unwrap();
        std::fs::rename(dir.path().join("other"), &lock).unwrap();
        assert!(owned.lost().unwrap().ends_with("was replaced"), "{:?}", owned.lost());
        std::fs::remove_dir_all(&home).unwrap();
        assert!(owned.lost().unwrap().ends_with("was removed"), "{:?}", owned.lost());
    }

    #[test]
    fn a_path_that_cannot_be_read_at_start_is_never_watched() {
        let dir = tempfile::tempdir().unwrap();
        assert!(Owned::now(&[&dir.path().join("missing")]).is_none());
    }
}
