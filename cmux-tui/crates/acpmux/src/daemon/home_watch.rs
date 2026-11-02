//! A daemon whose home is gone stops. A test harness that made a temporary `ACPMUX_HOME`,
//! started a daemon there and then removed the folder left that daemon running for days on
//! deleted files (cosmic-gray, 2026-10-29: two nightly daemons under a removed Python `mkdtemp`
//! home, one 8 days old); nothing could reach it, and a later command that recreated the folder
//! found its lock free and started a second one. So the daemon watches the folders that hold
//! its home, socket and lock, and shuts down normally once any of the three is no longer the
//! file it started with: removed, renamed away, or replaced by another one.
//!
//! Event-driven, never a timer: on Linux/macOS, watch the individual home/socket/lock paths
//! and their lexical and resolved ancestors for rename/removal only. Kernel subscription masks
//! exclude directory-entry activity, so unrelated writes under /tmp or /Users never wake us.
//! One exception, macOS: kqueue cannot watch a socket (open(2) refuses one), so the entries of
//! the folder that holds the socket wake a check instead (`record_watch::DirWatch`).
//! Other Unix platforms keep a nearest-directory notify watch with event filtering.
//! The watcher is dropped when its task ends. Home and socket have separate tasks, so losing the
//! socket does not stop monitoring the home during shutdown.
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
//! write its record into the replacement, as on a daemon without this watch.

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
struct OwnedPath {
    path: PathBuf,
    identity: Identity,
    /// Resolve the lexical path again before comparing; this catches symlink retargeting.
    resolved: bool,
}

#[derive(Clone, Debug)]
#[cfg_attr(not(unix), allow(dead_code))]
pub(crate) struct Owned {
    paths: Vec<OwnedPath>,
    /// The folder the last path given to [`Owned::now`] sits in, as resolved then: a socket
    /// lost from the same folder may be bound again ([`Owned::only_leaf_lost`]).
    leaf_folder: Option<(PathBuf, Identity)>,
}

impl Owned {
    /// The identities of `paths` now; `None` when any cannot be read (a relative or already
    /// missing path): then nothing is watched, so a path this daemon never saw is never taken
    /// for a loss.
    #[cfg(unix)]
    pub(crate) fn now(paths: &[&Path]) -> Option<Self> {
        let mut owned: Vec<OwnedPath> = Vec::new();
        for path in paths {
            for ancestor in lexical_ancestors(path) {
                let id = identity(&ancestor)?;
                if !owned.iter().any(|entry| entry.path == ancestor) {
                    owned.push(OwnedPath { path: ancestor, identity: id, resolved: false });
                }
            }
            let resolved = std::fs::canonicalize(path).ok()?;
            let id = identity(&resolved)?;
            owned.push(OwnedPath { path: path.to_path_buf(), identity: id, resolved: true });
        }
        let leaf_folder = paths.last().and_then(|leaf| {
            let folder = leaf_folder(leaf);
            let id = std::fs::canonicalize(&folder).ok().and_then(|p| identity(&p))?;
            Some((folder, id))
        });
        Some(Self { paths: owned, leaf_folder })
    }

    /// These paths and `other`'s.
    #[cfg(unix)]
    fn with(mut self, other: Owned) -> Self {
        self.paths.extend(other.paths);
        self.leaf_folder = other.leaf_folder;
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
        self.paths.iter().filter(|entry| Some(entry.path.as_path()) != skip).find_map(|entry| {
            let now = if entry.resolved {
                std::fs::canonicalize(&entry.path).ok().and_then(|path| identity(&path))
            } else {
                identity(&entry.path)
            };
            match now {
                None => Some(format!("{} was removed", entry.path.display())),
                Some(now) if now != entry.identity => {
                    Some(format!("{} was replaced", entry.path.display()))
                }
                Some(_) => None,
            }
        })
    }
}

impl Owned {
    /// Whether `leaf`'s own entry is the one path lost: every ancestor is still the folder it
    /// was, and so is the folder its resolved path sits in (a symlinked folder moved away and
    /// made again is another folder, never this daemon's to bind into).
    #[cfg(unix)]
    pub(crate) fn only_leaf_lost(&self, leaf: &Path) -> bool {
        let mut leaf_lost = false;
        for entry in &self.paths {
            let now = if entry.resolved {
                std::fs::canonicalize(&entry.path).ok().and_then(|path| identity(&path))
            } else {
                identity(&entry.path)
            };
            if now == Some(entry.identity) {
                continue;
            }
            if entry.path != leaf || !entry.resolved {
                return false;
            }
            leaf_lost = true;
        }
        leaf_lost
            && self.leaf_folder.as_ref().is_some_and(|(path, id)| {
                path == &leaf_folder(leaf)
                    && std::fs::canonicalize(path).ok().and_then(|p| identity(&p)) == Some(*id)
            })
    }
}

/// The folder a leaf's resolved path sits in, spelled lexically.
#[cfg(unix)]
fn leaf_folder(leaf: &Path) -> PathBuf {
    leaf.parent().unwrap_or(Path::new("/")).to_path_buf()
}

/// Preserve `..` components too: resolving them lexically would change symlink semantics.
#[cfg(unix)]
fn lexical_ancestors(path: &Path) -> Vec<PathBuf> {
    path.ancestors()
        .filter(|p| !p.as_os_str().is_empty() && *p != Path::new("/"))
        .map(Path::to_path_buf)
        .collect()
}

/// Set just before a shutdown removes the socket it bound: from then on the watch leaves the
/// socket out, so that removal is not taken for a lost home.
#[cfg(unix)]
static SOCKET_RELEASED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// This daemon removes its own socket now (see [`SOCKET_RELEASED`]).
#[cfg(unix)]
pub(crate) fn release_socket() {
    SOCKET_RELEASED.store(true, std::sync::atomic::Ordering::SeqCst);
}

/// What the watch saw lost, and why.
#[derive(Debug)]
pub(crate) enum Lost {
    /// The home, the lock, or the folder that holds the socket: the daemon stops.
    Stop(String),
    /// Only the socket's own entry, in the same folder of a home and lock still this daemon's:
    /// the daemon binds it again (`daemon/socket_rebind.rs`). Nothing is fenced.
    Socket(String),
}

/// Resolves once the home, the socket or the lock is lost; never when the watch could not be
/// set up (it logs why). Dropping it ends the watch.
pub(crate) type HomeGone = Pin<Box<dyn Future<Output = Lost> + Send>>;

/// Watch `home`, `socket` and `lock` (see the module doc).
#[cfg(unix)]
pub(crate) fn watch(
    held: Option<Owned>,
    bound: Option<Owned>,
    home: &Path,
    socket: &Path,
) -> HomeGone {
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    use notify::Watcher as _;
    // The home and lock as the daemon first held them (`held`), and the socket as bound. The
    // home watcher starts immediately after lock acquisition, before startup writes; the socket
    // watcher is added once the socket is bound. Keep the held set separate: a socket ancestor
    // outside the home must never be classified as a home loss.
    let held_for_classification = held.clone();
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    let home_owned = held.is_some();
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    let bound_owned = bound.is_some();
    let Some(owned) = (match (held, bound) {
        (Some(held), Some(bound)) => Some(held.with(bound)),
        (Some(held), None) => Some(held),
        (None, Some(bound)) => Some(bound),
        (None, None) => None,
    }) else {
        tracing::warn!("home watch off: {} or {} cannot be read", home.display(), socket.display());
        return Box::pin(std::future::pending());
    };
    // One slot: events that arrive while a check runs fold into the next check.
    let (tx, mut rx) = tokio::sync::mpsc::channel::<()>(1);
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    let watcher = {
        let mut paths: Vec<PathBuf> = owned.paths.iter().map(|entry| entry.path.clone()).collect();
        // Include resolved ancestors too: an intermediate symlink's target may itself move.
        for entry in &owned.paths {
            if let Ok(resolved) = std::fs::canonicalize(&entry.path) {
                paths.extend(lexical_ancestors(&resolved));
            }
        }
        paths.sort();
        paths.dedup();
        crate::agent_host::record_watch::DirWatch::start_identities(&paths, move || {
            let _ = tx.try_send(());
            tx.is_closed()
        })
    };
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    let watcher = {
        // FSEvents reports canonical paths; retain both spellings for filtering while identity
        // checks keep the lexical spelling. Ancestor watches must not wake us for unrelated entries.
        let mut relevant: Vec<PathBuf> =
            owned.paths.iter().map(|entry| entry.path.clone()).collect();
        relevant
            .extend(owned.paths.iter().filter_map(|entry| std::fs::canonicalize(&entry.path).ok()));
        let watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
            let relevant_event = match event {
                Ok(e) => {
                    !e.kind.is_access()
                        && (e.need_rescan()
                            || e.paths.is_empty()
                            || e.paths.iter().any(|p| relevant.contains(p)))
                }
                Err(_) => true,
            };
            if relevant_event {
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
        let mut dirs = Vec::new();
        if home_owned {
            dirs.push(home.to_path_buf());
        }
        if bound_owned {
            let parent = socket.parent().unwrap_or(socket).to_path_buf();
            if !dirs.contains(&parent) {
                dirs.push(parent);
            }
        }
        for dir in &dirs {
            if let Err(e) = watcher.watch(&dir, notify::RecursiveMode::NonRecursive) {
                // A folder gone before its watch began (the home removed during the startup) is
                // the loss itself, not a watch that could not be set up.
                if let Some(why) = owned.lost() {
                    if held_for_classification.as_ref().is_some_and(|held| held.lost().is_some()) {
                        crate::config::mark_home_lost();
                    } else {
                        crate::config::mark_socket_lost();
                    }
                    return Box::pin(std::future::ready(Lost::Stop(why)));
                }
                tracing::warn!("home watch off: watch {}: {e}", dir.display());
                return Box::pin(std::future::pending());
            }
        }
        watcher
    };
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
        let why = lost.unwrap_or_default();
        // At once, before the shutdown starts: no write may make the old home again.
        if held_for_classification.as_ref().is_some_and(|held| held.lost().is_some()) {
            crate::config::mark_home_lost();
        } else if owned.only_leaf_lost(&socket) {
            return Lost::Socket(why);
        } else {
            crate::config::mark_socket_lost();
        }
        Lost::Stop(why)
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
pub(crate) fn release_socket() {}

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
    fn an_ancestor_rename_is_lost_even_when_the_home_is_unchanged() {
        let dir = tempfile::tempdir().unwrap();
        let parent = dir.path().join("parent");
        let home = parent.join("home");
        std::fs::create_dir_all(&home).unwrap();
        let owned = Owned::now(&[home.as_path()]).unwrap();
        std::fs::rename(&parent, dir.path().join("moved")).unwrap();
        assert!(owned.lost().is_some(), "ancestor rename was not detected");
    }

    #[cfg(unix)]
    #[test]
    fn a_symlink_ancestor_retarget_is_lost() {
        let dir = tempfile::tempdir().unwrap();
        let one = dir.path().join("one");
        let two = dir.path().join("two");
        std::fs::create_dir_all(one.join("home")).unwrap();
        std::fs::create_dir_all(two.join("home")).unwrap();
        let link = dir.path().join("link");
        std::os::unix::fs::symlink(&one, &link).unwrap();
        let home = link.join("home");
        let owned = Owned::now(&[home.as_path()]).unwrap();
        std::fs::remove_file(&link).unwrap();
        std::os::unix::fs::symlink(&two, &link).unwrap();
        assert!(owned.lost().is_some(), "symlink retarget was not detected");
    }

    #[test]
    fn a_socket_ancestor_loss_is_not_a_home_loss() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let first = dir.path().join("first");
        let second = dir.path().join("second");
        std::fs::create_dir_all(&home).unwrap();
        std::fs::create_dir_all(&first).unwrap();
        std::fs::create_dir_all(&second).unwrap();
        let link = dir.path().join("socket-link");
        std::os::unix::fs::symlink(&first, &link).unwrap();
        let socket = link.join("s.sock");
        std::fs::write(&socket, "").unwrap();
        let held = Owned::now(&[home.as_path()]).unwrap();
        let bound = Owned::now(&[socket.as_path()]).unwrap();
        std::fs::rename(dir.path().join("second"), dir.path().join("replacement")).unwrap();
        std::fs::remove_file(&link).unwrap();
        std::os::unix::fs::symlink(dir.path().join("replacement"), &link).unwrap();
        assert!(held.lost().is_none(), "socket ancestor changed the home identity");
        assert!(bound.lost().is_some(), "socket ancestor replacement was not detected");
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
