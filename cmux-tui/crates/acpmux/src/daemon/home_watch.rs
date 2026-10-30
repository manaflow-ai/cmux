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
//!
//! A removal at any depth is seen: removing a folder removes its entries first, the socket and
//! the lock among them. Renaming an ancestor of the home (`mv /tmp/t /tmp/u` for the home
//! `/tmp/t/.acpmux`) changes no entry in the watched folders, so it is seen only at the next
//! entry change there; watching every ancestor would wake the daemon for activity anywhere
//! above it (FSEvents watches a folder's whole tree). A command never starts a daemon in the
//! old, now missing path (`config::autostart_refusal`).
//!
//! The home and lock are read as soon as the daemon holds its lock (by path: a replacement in
//! the instant between taking the lock and that read is not seen), and the socket as it is
//! bound, so one replaced during the startup is a loss too. Unix only: off Unix there is no
//! watch, and the shutdown keeps base's cleanup. Once the loss is reported the shutdown removes nothing at the old
//! paths except the socket it bound, and the shared write paths (`config::private_state_dir*`,
//! `write_atomic`, `owner_only`, the store, the registry, the catalog and live-model caches,
//! `agent_tools::write_private`) refuse to write under the old home (`config::mark_home_lost`):
//! it may be another daemon's now. A request already being served when the loss is seen may
//! still finish a write of its own there during the bounded shutdown; base, with no watch,
//! kept writing there for as long as it ran. Hosted agents end when the loss is seen before the
//! shutdown reads its plan for them; a loss seen later leaves them to end with their record.
//! The socket is checked, then unlinked by path, and so are the pid and app files after one
//! last check of the home: a replacement in between cannot be ruled out (POSIX has no
//! unlink-if-same-file). Its agent hosts are other processes: they end with
//! their record (`agent_host` `watch_record`); one still starting when the home is replaced may
//! write its record into the replacement, as on a daemon without this watch. A renamed
//! ancestor (above) also leaves an unadopted host running until its folder changes.

use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;

/// One path's identity: the device and inode it had when the daemon bound it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[cfg_attr(not(unix), allow(dead_code))]
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
#[cfg_attr(not(unix), allow(dead_code))]
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

    /// These paths and `other`'s.
    #[cfg(unix)]
    fn with(mut self, other: Owned) -> Self {
        self.paths.extend(other.paths);
        self
    }

    /// The first owned path that is no longer the file it was, and why.
    #[cfg(unix)]
    pub(crate) fn lost(&self) -> Option<String> {
        self.lost_except(None)
    }

    /// [`Owned::lost`], leaving out `skip` (a path this daemon removes itself).
    #[cfg(unix)]
    fn lost_except(&self, skip: Option<&Path>) -> Option<String> {
        self.paths.iter().filter(|(path, _)| Some(path.as_path()) != skip).find_map(
            |(path, was)| match identity(path) {
                None => Some(format!("{} was removed", path.display())),
                Some(now) if now != *was => Some(format!("{} was replaced", path.display())),
                Some(_) => None,
            },
        )
    }
}

/// Set just before a shutdown removes the socket it bound: from then on the watch leaves the
/// socket out, so that removal is not taken for a lost home.
#[cfg_attr(not(unix), allow(dead_code))]
static SOCKET_RELEASED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// This daemon removes its own socket now (see [`SOCKET_RELEASED`]).
pub(crate) fn release_socket() {
    SOCKET_RELEASED.store(true, std::sync::atomic::Ordering::SeqCst);
}

/// Resolves once the home, the socket or the lock is lost; never when the watch could not be
/// set up (it logs why). Dropping it ends the watch.
pub(crate) type HomeGone = Pin<Box<dyn Future<Output = String> + Send>>;

/// Watch `home`, `socket` and `lock` (see the module doc).
#[cfg(unix)]
pub(crate) fn watch(
    held: Option<Owned>,
    bound: Option<Owned>,
    home: &Path,
    socket: &Path,
) -> HomeGone {
    use notify::Watcher as _;
    // The home and lock as the daemon first held them (`held`), and the socket as bound.
    let Some(owned) = held.zip(bound).map(|(held, bound)| held.with(bound)) else {
        tracing::warn!("home watch off: {} or {} cannot be read", home.display(), socket.display());
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
            // A folder gone before its watch began (the home removed during the startup) is
            // the loss itself, not a watch that could not be set up.
            if let Some(why) = owned.lost() {
                crate::config::mark_home_lost();
                return Box::pin(std::future::ready(why));
            }
            tracing::warn!("home watch off: watch {}: {e}", dir.display());
            return Box::pin(std::future::pending());
        }
    }
    let socket = socket.to_path_buf();
    Box::pin(async move {
        // Owned here: the watch lives exactly as long as this future.
        let _watcher = watcher;
        let check = || {
            let released = SOCKET_RELEASED.load(std::sync::atomic::Ordering::SeqCst);
            owned.lost_except(released.then_some(socket.as_path()))
        };
        // A loss between reading the identities and the first watch.
        let mut lost = check();
        while lost.is_none() {
            if rx.recv().await.is_none() {
                return std::future::pending().await;
            }
            lost = check();
        }
        // At once, before the shutdown starts: no write may make the old home again.
        crate::config::mark_home_lost();
        lost.unwrap_or_default()
    })
}

#[cfg(not(unix))]
impl Owned {
    pub(crate) fn now(_paths: &[&Path]) -> Option<Self> {
        None
    }

    pub(crate) fn lost(&self) -> Option<String> {
        None
    }
}

#[cfg(not(unix))]
pub(crate) fn watch(
    _held: Option<Owned>,
    _bound: Option<Owned>,
    _home: &Path,
    _socket: &Path,
) -> HomeGone {
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
    fn a_path_the_daemon_removes_itself_is_left_out() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        std::fs::create_dir(&home).unwrap();
        let socket = home.join("acpmux.sock");
        std::fs::write(&socket, "").unwrap();
        let owned = Owned::now(&[&home, &socket]).unwrap();
        std::fs::remove_file(&socket).unwrap();
        assert!(owned.lost().is_some(), "a removed socket is a loss");
        assert_eq!(owned.lost_except(Some(&socket)), None, "unless the daemon removed it");
        std::fs::remove_dir_all(&home).unwrap();
        assert!(owned.lost_except(Some(&socket)).is_some(), "the home still counts");
    }

    #[test]
    fn a_path_that_cannot_be_read_at_start_is_never_watched() {
        let dir = tempfile::tempdir().unwrap();
        assert!(Owned::now(&[&dir.path().join("missing")]).is_none());
    }
}
