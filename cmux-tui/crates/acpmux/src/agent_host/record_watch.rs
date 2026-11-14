//! The watch a host keeps on the directories that hold its record
//! (`host.rs` `watch_record`): a callback runs whenever an entry of one of
//! them changes or one of them goes away.
//!
//! macOS: a kqueue vnode watch on each directory. The kernel delivers it when
//! the directory's own entries change (a record removed, renamed or written
//! by rename) or the directory is deleted. FSEvents (notify's macOS backend)
//! goes through fseventsd, which falls behind a burst of writes anywhere on
//! the volume (a build) and delivered the deletion of a host's home only after
//! many seconds or not at all: hosts outlived their deleted homes on every
//! fleet Mac (cx-ckdxf, host_lifetime.rs). One thread waits in `kevent` with
//! no timeout; dropping [`DirWatch`] triggers a user event that ends it.
//!
//! Linux: an inotify watch on each directory with a mask of entry changes
//! only (created, deleted, renamed in or out) and the directory's own
//! deletion or move. notify's inotify backend always asks for open, close and
//! modify events too: the callback's own read of the record then queued an
//! open and a close in the watched directory, which ran the callback again,
//! so every pooled host spun at 100% CPU reading its record. With this mask a
//! read never queues an event. One thread waits in `poll` with no timeout;
//! dropping [`DirWatch`] writes an eventfd that ends it.
//!
//! Elsewhere: notify's recommended watcher; access events are ignored there
//! for the same reason.

use std::path::PathBuf;

/// Live while held. `on_change` returns true when it needs no more events.
pub(crate) struct DirWatch {
    #[cfg(target_os = "macos")]
    kq: std::sync::Arc<std::os::fd::OwnedFd>,
    #[cfg(target_os = "linux")]
    stop: std::sync::Arc<std::os::fd::OwnedFd>,
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    _watcher: notify::RecommendedWatcher,
}

#[cfg(target_os = "macos")]
const STOP: usize = 1;

/// Whether `path` itself (not a symlink's target) is a Unix socket.
#[cfg(target_os = "macos")]
fn is_socket(path: &std::path::Path) -> bool {
    use std::os::unix::fs::FileTypeExt;
    std::fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_socket())
}

#[cfg(target_os = "macos")]
fn kevent_change(
    kq: std::os::fd::RawFd,
    ident: usize,
    filter: i16,
    flags: u16,
    fflags: u32,
) -> std::io::Result<()> {
    let change =
        libc::kevent { ident, filter, flags, fflags, data: 0, udata: std::ptr::null_mut() };
    // SAFETY: one valid change, no event list, no timeout.
    let rc = unsafe { libc::kevent(kq, &change, 1, std::ptr::null_mut(), 0, std::ptr::null()) };
    if rc < 0 { Err(std::io::Error::last_os_error()) } else { Ok(()) }
}

impl DirWatch {
    /// Watch only each path's own identity, not directory entries or file contents.
    /// The kernel excludes sibling activity before waking the watcher thread. Symlinks are
    /// watched themselves; callers also supply resolved targets when both identities matter.
    /// macOS: a socket has no vnode kqueue can watch, so the entry changes of the folder that
    /// holds it wake the callback instead (sibling activity there included).
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    pub(crate) fn start_identities(
        paths: &[PathBuf],
        on_change: impl FnMut() -> bool + Send + 'static,
    ) -> Option<Self> {
        Self::start_native(paths, true, on_change)
    }

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    pub(crate) fn start(
        dirs: &[PathBuf],
        on_change: impl FnMut() -> bool + Send + 'static,
    ) -> Option<Self> {
        Self::start_native(dirs, false, on_change)
    }

    /// Watches every directory of `dirs` that can be opened (a missing one
    /// is skipped with a warning). None when no directory is watched.
    #[cfg(target_os = "macos")]
    fn start_native(
        dirs: &[PathBuf],
        identities_only: bool,
        mut on_change: impl FnMut() -> bool + Send + 'static,
    ) -> Option<Self> {
        use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
        use std::os::unix::fs::OpenOptionsExt;
        // SAFETY: kqueue has no preconditions.
        let raw = unsafe { libc::kqueue() };
        if raw < 0 {
            tracing::warn!(
                "the host cannot watch its record: kqueue: {}",
                std::io::Error::last_os_error()
            );
            return None;
        }
        // SAFETY: kqueue returned a new descriptor that nothing else owns.
        let kq = std::sync::Arc::new(unsafe { OwnedFd::from_raw_fd(raw) });
        if let Err(e) =
            kevent_change(raw, STOP, libc::EVFILT_USER, libc::EV_ADD | libc::EV_CLEAR, 0)
        {
            tracing::warn!("the host cannot watch its record: kevent: {e}");
            return None;
        }
        // NOTE_EXTEND and NOTE_ATTRIB: a watched file (the harness profile
        // watch) that is truncated or grows without a NOTE_WRITE.
        let identity_events = libc::NOTE_DELETE | libc::NOTE_RENAME | libc::NOTE_REVOKE;
        let fflags = if identities_only {
            identity_events
        } else {
            identity_events | libc::NOTE_WRITE | libc::NOTE_EXTEND | libc::NOTE_ATTRIB
        };
        // What to open, with its open flags and the events it reports. A socket cannot be
        // opened (open(2) fails with EOPNOTSUPP, "Operation not supported on socket"), so kqueue
        // has no vnode of its own to watch: the daemon's socket went unwatched on every Mac, and
        // its warning came before the daemon's readiness line (cx-n1nrjk). The entry changes of
        // the folder that holds it (NOTE_WRITE: the socket removed, renamed or replaced there)
        // stand in for it; that folder is opened through any symlink, so its entries are the
        // socket's. Linux's inotify watches the socket itself.
        let mut targets: Vec<(&std::path::Path, i32, u32)> = Vec::new();
        for dir in dirs {
            if identities_only
                && is_socket(dir)
                && let Some(folder) = dir.parent().filter(|parent| !parent.as_os_str().is_empty())
            {
                if !targets.iter().any(|(path, flags, _)| *path == folder && *flags == 0) {
                    targets.push((folder, 0, identity_events | libc::NOTE_WRITE));
                }
                continue;
            }
            targets.push((dir, if identities_only { libc::O_SYMLINK } else { 0 }, fflags));
        }
        let mut files = Vec::new();
        for (dir, open_flags, fflags) in targets {
            // O_EVTONLY: the open descriptor never keeps the volume from unmounting.
            let opened = std::fs::OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_EVTONLY | open_flags)
                .open(dir)
                .and_then(|file| {
                    let ident = file.as_raw_fd() as usize;
                    kevent_change(
                        raw,
                        ident,
                        libc::EVFILT_VNODE,
                        libc::EV_ADD | libc::EV_CLEAR,
                        fflags,
                    )
                    .map(|()| file)
                });
            match opened {
                Ok(file) => files.push(file),
                Err(e) => tracing::warn!("the host cannot watch {}: {e}", dir.display()),
            }
        }
        if files.is_empty() {
            return None;
        }
        let thread_kq = kq.clone();
        let spawned = std::thread::Builder::new()
            .name("acpmux-record-watch".into())
            .spawn(move || wait_events(&thread_kq, files, &mut on_change));
        if let Err(e) = spawned {
            tracing::warn!("the host cannot watch its record: {e}");
            return None;
        }
        Some(Self { kq })
    }

    #[cfg(target_os = "linux")]
    fn start_native(
        dirs: &[PathBuf],
        identities_only: bool,
        mut on_change: impl FnMut() -> bool + Send + 'static,
    ) -> Option<Self> {
        use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
        use std::os::unix::ffi::OsStrExt;
        // SAFETY: inotify_init1 has no preconditions.
        let raw = unsafe { libc::inotify_init1(libc::IN_CLOEXEC | libc::IN_NONBLOCK) };
        if raw < 0 {
            tracing::warn!(
                "the host cannot watch its record: inotify: {}",
                std::io::Error::last_os_error()
            );
            return None;
        }
        // SAFETY: inotify_init1 returned a new descriptor that nothing else owns.
        let inotify = unsafe { OwnedFd::from_raw_fd(raw) };
        // SAFETY: eventfd has no preconditions.
        let raw_stop = unsafe { libc::eventfd(0, libc::EFD_CLOEXEC) };
        if raw_stop < 0 {
            tracing::warn!(
                "the host cannot watch its record: eventfd: {}",
                std::io::Error::last_os_error()
            );
            return None;
        }
        // SAFETY: eventfd returned a new descriptor that nothing else owns.
        let stop = std::sync::Arc::new(unsafe { OwnedFd::from_raw_fd(raw_stop) });
        // Entry changes and the directory's own end only: no IN_OPEN,
        // IN_ACCESS, IN_CLOSE_* or IN_MODIFY, which a read of the record
        // (the callback's own) or a write to an open file would queue.
        let identity_events = libc::IN_DELETE_SELF | libc::IN_MOVE_SELF;
        let mask = if identities_only {
            identity_events | libc::IN_DONT_FOLLOW
        } else {
            identity_events
                | libc::IN_CREATE
                | libc::IN_DELETE
                | libc::IN_MOVED_FROM
                | libc::IN_MOVED_TO
                | libc::IN_ONLYDIR
        };
        let mut watched = 0;
        for dir in dirs {
            // An unlinked lock can remain open until shutdown: inotify delays DELETE_SELF
            // until its final close, but reports the link-count change as ATTRIB immediately.
            // Do not request ATTRIB for ancestor directories (unrelated mkdir changes nlink).
            let mask = if identities_only
                && std::fs::symlink_metadata(dir).is_ok_and(|metadata| !metadata.is_dir())
            {
                mask | libc::IN_ATTRIB
            } else {
                mask
            };
            let added = std::ffi::CString::new(dir.as_os_str().as_bytes())
                .map_err(std::io::Error::other)
                .and_then(|path| {
                    // SAFETY: a valid inotify descriptor and a NUL-terminated path.
                    let wd = unsafe {
                        libc::inotify_add_watch(inotify.as_raw_fd(), path.as_ptr(), mask)
                    };
                    if wd < 0 { Err(std::io::Error::last_os_error()) } else { Ok(()) }
                });
            match added {
                Ok(()) => watched += 1,
                Err(e) => tracing::warn!("the host cannot watch {}: {e}", dir.display()),
            }
        }
        if watched == 0 {
            return None;
        }
        let thread_stop = stop.clone();
        let spawned = std::thread::Builder::new()
            .name("acpmux-record-watch".into())
            .spawn(move || wait_inotify(&inotify, &thread_stop, &mut on_change));
        if let Err(e) = spawned {
            tracing::warn!("the host cannot watch its record: {e}");
            return None;
        }
        Some(Self { stop })
    }

    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    pub(crate) fn start(
        dirs: &[PathBuf],
        mut on_change: impl FnMut() -> bool + Send + 'static,
    ) -> Option<Self> {
        use notify::Watcher as _;
        let mut done = false;
        let mut watcher =
            notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
                // An access (the callback's own read of the record among
                // them) never changes whether the record is there.
                let access = matches!(&event, Ok(e) if e.kind.is_access());
                if !done && !access {
                    done = on_change();
                }
            })
            .map_err(|e| tracing::warn!("the host cannot watch its record: {e}"))
            .ok()?;
        let mut watched = 0;
        for dir in dirs {
            match watcher.watch(dir, notify::RecursiveMode::NonRecursive) {
                Ok(()) => watched += 1,
                Err(e) => tracing::warn!("the host cannot watch {}: {e}", dir.display()),
            }
        }
        (watched > 0).then_some(Self { _watcher: watcher })
    }
}

/// Runs `on_change` once per batch of inotify events until it returns true
/// or `stop` becomes readable. Every queued event is drained before the
/// check, so a burst of entry changes costs one check.
#[cfg(target_os = "linux")]
fn wait_inotify(
    inotify: &std::os::fd::OwnedFd,
    stop: &std::os::fd::OwnedFd,
    on_change: &mut dyn FnMut() -> bool,
) {
    use std::os::fd::AsRawFd;
    let mut fds = [
        libc::pollfd { fd: inotify.as_raw_fd(), events: libc::POLLIN, revents: 0 },
        libc::pollfd { fd: stop.as_raw_fd(), events: libc::POLLIN, revents: 0 },
    ];
    // Room for at least one event with the longest name.
    let mut buf = [0u8; 4096];
    loop {
        // SAFETY: two valid pollfds; -1 waits until one is ready.
        let ready = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, -1) };
        if ready < 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            tracing::warn!("the host's record watch stopped: poll: {error}");
            return;
        }
        if fds[1].revents != 0 {
            return;
        }
        if fds[0].revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0 {
            tracing::warn!("the host's record watch stopped: inotify descriptor failed");
            return;
        }
        let mut events = false;
        loop {
            // SAFETY: a valid descriptor and a buffer of `buf.len()` bytes.
            let n = unsafe { libc::read(inotify.as_raw_fd(), buf.as_mut_ptr().cast(), buf.len()) };
            if n > 0 {
                events = true;
                continue;
            }
            if n == 0 {
                break;
            }
            let error = std::io::Error::last_os_error();
            match error.kind() {
                std::io::ErrorKind::Interrupted => continue,
                std::io::ErrorKind::WouldBlock => break,
                _ => {
                    tracing::warn!("the host's record watch stopped: read: {error}");
                    return;
                }
            }
        }
        if events && on_change() {
            return;
        }
    }
}

/// Runs `on_change` for each vnode event until it returns true or the stop
/// event comes. The directories in `files` stay open (watched) meanwhile.
#[cfg(target_os = "macos")]
fn wait_events(
    kq: &std::os::fd::OwnedFd,
    files: Vec<std::fs::File>,
    on_change: &mut dyn FnMut() -> bool,
) {
    use std::os::fd::AsRawFd;
    let _files = files;
    let mut event = libc::kevent {
        ident: 0,
        filter: 0,
        flags: 0,
        fflags: 0,
        data: 0,
        udata: std::ptr::null_mut(),
    };
    loop {
        // SAFETY: room for one event; a null timeout waits until one arrives.
        let count = unsafe {
            libc::kevent(kq.as_raw_fd(), std::ptr::null(), 0, &mut event, 1, std::ptr::null())
        };
        if count < 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            tracing::warn!("the host's record watch stopped: kevent: {error}");
            return;
        }
        if count == 0 {
            continue;
        }
        if event.filter == libc::EVFILT_USER || on_change() {
            return;
        }
    }
}

/// Watches whether a file still says what its owner needs: an agent host's own record
/// (`host.rs` `watch_record`). `present` is asked after a change that could end it and once at
/// the start; `gone` runs once, the first time it says false. `dirs` hold the file (`files` names
/// where it may be now: a pooled host's record is in the pool or its parent).
///
/// Linux and macOS: the identities of the files and of their directories are watched
/// ([`DirWatch::start_identities`]), not the directories' entries. Every host's record sits in
/// the one hosts directory, so an entry watch woke every host for each record any host or the
/// daemon wrote, renamed or removed there: N hosts, O(N) wakeups per change (CMUX-571: ~4000
/// wakeups/s across ~800 agent hosts at 1000 chats). Presence can only be lost through the
/// watched file itself (removed, renamed away, or replaced by a rename over it, which unlinks
/// it: inotify `IN_ATTRIB`, kqueue `NOTE_DELETE`) or its directory moved or removed, so nothing
/// else needs to wake it. A record rewritten by rename is a new file: after each change that
/// leaves it present, the watch is armed again on the files as they are then, and `present` is
/// asked once more after that, so a change between the check and the new watch is not missed.
#[cfg(any(target_os = "linux", target_os = "macos"))]
pub(crate) struct RecordWatch {
    _inner: std::sync::Arc<RecordInner>,
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
struct RecordInner {
    dirs: Vec<PathBuf>,
    files: Box<dyn Fn() -> Vec<PathBuf> + Send + Sync>,
    present: Box<dyn Fn() -> bool + Send + Sync>,
    gone: std::sync::Mutex<Option<Box<dyn FnOnce() + Send>>>,
    /// The watch on the files as they were at the last check; replaced at each re-arm.
    watch: std::sync::Mutex<Option<DirWatch>>,
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
impl RecordInner {
    fn end(&self) {
        let taken = self.gone.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take();
        if let Some(gone) = taken {
            gone();
        }
    }

    /// Watches the directories and the files as they are now, then asks `present`: false when
    /// nothing could be watched.
    fn arm(self: &std::sync::Arc<Self>) -> bool {
        let mut paths = self.dirs.clone();
        // A directory reached through a symlink: its own identity too, not only the link's.
        for dir in &self.dirs {
            if let Ok(real) = std::fs::canonicalize(dir)
                && !paths.contains(&real)
            {
                paths.push(real);
            }
        }
        paths.extend((self.files)());
        let weak = std::sync::Arc::downgrade(self);
        let watch = DirWatch::start_identities(&paths, move || {
            if let Some(inner) = weak.upgrade() {
                inner.changed();
            }
            // Each watch reports one change: `changed` armed the next one, or it ended.
            true
        });
        let armed = watch.is_some();
        // The previous watch (whose thread may be the one running this) ends as it is dropped.
        let previous = std::mem::replace(
            &mut *self.watch.lock().unwrap_or_else(std::sync::PoisonError::into_inner),
            watch,
        );
        drop(previous);
        if !(self.present)() {
            self.end();
        }
        armed
    }

    fn changed(self: &std::sync::Arc<Self>) {
        if !(self.present)() {
            self.end();
            return;
        }
        self.arm();
    }
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
impl RecordWatch {
    pub(crate) fn start(
        dirs: Vec<PathBuf>,
        files: impl Fn() -> Vec<PathBuf> + Send + Sync + 'static,
        present: impl Fn() -> bool + Send + Sync + 'static,
        gone: impl FnOnce() + Send + 'static,
    ) -> Option<Self> {
        let inner = std::sync::Arc::new(RecordInner {
            dirs,
            files: Box::new(files),
            present: Box::new(present),
            gone: std::sync::Mutex::new(Some(Box::new(gone))),
            watch: std::sync::Mutex::new(None),
        });
        inner.arm().then_some(Self { _inner: inner })
    }
}

/// Elsewhere: the directories' entries, through notify.
#[cfg(not(any(target_os = "linux", target_os = "macos")))]
pub(crate) struct RecordWatch {
    _watch: DirWatch,
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
impl RecordWatch {
    pub(crate) fn start(
        dirs: Vec<PathBuf>,
        files: impl Fn() -> Vec<PathBuf> + Send + Sync + 'static,
        present: impl Fn() -> bool + Send + Sync + 'static,
        gone: impl FnOnce() + Send + 'static,
    ) -> Option<Self> {
        let _ = files;
        let present = std::sync::Arc::new(present);
        let gone = std::sync::Arc::new(std::sync::Mutex::new(Some(
            Box::new(gone) as Box<dyn FnOnce() + Send>
        )));
        let end = {
            let gone = gone.clone();
            move || {
                let taken = gone.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take();
                if let Some(gone) = taken {
                    gone();
                }
            }
        };
        let asked = present.clone();
        let ended = end.clone();
        let watch = DirWatch::start(&dirs, move || {
            if asked() {
                return false;
            }
            ended();
            true
        });
        if !present() {
            end();
        }
        watch.map(|watch| Self { _watch: watch })
    }
}

#[cfg(target_os = "macos")]
impl Drop for DirWatch {
    fn drop(&mut self) {
        use std::os::fd::AsRawFd;
        // Not joined: the callback may be blocked handing its event to a
        // loop that is ending; it returns once that receiver is gone.
        let _ = kevent_change(self.kq.as_raw_fd(), STOP, libc::EVFILT_USER, 0, libc::NOTE_TRIGGER);
    }
}

#[cfg(target_os = "linux")]
impl Drop for DirWatch {
    fn drop(&mut self) {
        use std::os::fd::AsRawFd;
        // Not joined, as on macOS. Any nonzero count makes the eventfd readable.
        let one: u64 = 1;
        // SAFETY: a valid eventfd and an 8-byte value.
        let _ = unsafe {
            libc::write(self.stop.as_raw_fd(), (&raw const one).cast(), std::mem::size_of::<u64>())
        };
    }
}

#[cfg(all(test, any(target_os = "linux", target_os = "macos")))]
mod identity_tests {
    use super::DirWatch;
    use std::sync::mpsc;
    use std::time::Duration;

    #[test]
    fn identity_watch_ignores_sibling_activity_but_reports_ancestor_rename() {
        let dir = tempfile::tempdir().unwrap();
        let ancestor = dir.path().join("ancestor");
        let home = ancestor.join("home");
        std::fs::create_dir_all(&home).unwrap();
        let (tx, rx) = mpsc::channel();
        let _watch = DirWatch::start_identities(
            &[dir.path().to_path_buf(), ancestor.clone(), home],
            move || {
                let _ = tx.send(());
                false
            },
        )
        .expect("identity watch starts");
        // These would wake a directory-entry watcher, even if a later callback discards them.
        let sibling = dir.path().join("unrelated");
        std::fs::create_dir(&sibling).unwrap();
        std::fs::write(sibling.join("file"), "unrelated write").unwrap();
        std::fs::rename(&sibling, dir.path().join("other")).unwrap();
        std::fs::remove_dir_all(dir.path().join("other")).unwrap();
        assert_eq!(
            rx.recv_timeout(Duration::from_millis(200)),
            Err(mpsc::RecvTimeoutError::Timeout)
        );
        std::fs::rename(&ancestor, dir.path().join("moved")).unwrap();
        rx.recv_timeout(Duration::from_secs(5)).expect("ancestor rename wakes the watch");
    }

    #[test]
    fn identity_watch_reports_a_symlink_replacement_and_a_lock_removal() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("target");
        std::fs::create_dir(&target).unwrap();
        let link = dir.path().join("link");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        let (tx, rx) = mpsc::channel();
        let _watch = DirWatch::start_identities(std::slice::from_ref(&link), move || {
            let _ = tx.send(());
            true
        })
        .expect("symlink watch starts");
        let replacement = dir.path().join("replacement");
        std::os::unix::fs::symlink(dir.path(), &replacement).unwrap();
        std::fs::rename(replacement, link).unwrap();
        rx.recv_timeout(Duration::from_secs(5)).expect("symlink replacement wakes the watch");

        let lock = target.join("lock");
        std::fs::write(&lock, "held").unwrap();
        let _held_lock = std::fs::File::open(&lock).unwrap();
        let (tx, rx) = mpsc::channel();
        let _watch = DirWatch::start_identities(std::slice::from_ref(&lock), move || {
            let _ = tx.send(());
            true
        })
        .expect("lock watch starts");
        std::fs::remove_file(lock).unwrap();
        rx.recv_timeout(Duration::from_secs(5)).expect("lock removal wakes the watch");
    }
}

#[cfg(all(test, any(target_os = "linux", target_os = "macos")))]
mod record_tests {
    use super::RecordWatch;
    use std::path::{Path, PathBuf};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::mpsc;
    use std::time::Duration;

    /// Writes `path` as a host record is written: a temporary file renamed over it.
    fn write_by_rename(path: &Path, text: &str) {
        let tmp = path.with_extension("tmp");
        std::fs::write(&tmp, text).unwrap();
        std::fs::rename(&tmp, path).unwrap();
    }

    /// A watch on `own`, present while it holds "mine"; how often it asked, and its end.
    fn watch(
        dir: &Path,
        own: &Path,
    ) -> (Option<RecordWatch>, Arc<AtomicUsize>, mpsc::Receiver<()>) {
        let asked = Arc::new(AtomicUsize::new(0));
        let (tx, rx) = mpsc::channel();
        let (file, read, count) = (own.to_path_buf(), own.to_path_buf(), asked.clone());
        let watch = RecordWatch::start(
            vec![dir.to_path_buf()],
            move || std::iter::once(file.clone()).filter(|f| f.exists()).collect::<Vec<PathBuf>>(),
            move || {
                count.fetch_add(1, Ordering::SeqCst);
                std::fs::read_to_string(&read).is_ok_and(|text| text == "mine")
            },
            move || {
                let _ = tx.send(());
            },
        );
        (watch, asked, rx)
    }

    /// CMUX-571: every agent host watched the whole hosts directory, so each record another
    /// host or the daemon wrote, renamed or removed there woke every host: N hosts, O(N)
    /// wakeups per change, O(N^2) for a burst (1000 chats: ~4000 wakeups/s while they settle).
    /// Other records never wake this one's watch.
    #[test]
    fn a_record_watch_sleeps_through_other_hosts_records() {
        let dir = tempfile::tempdir().unwrap();
        let own = dir.path().join("own.json");
        write_by_rename(&own, "mine");
        let (watch, asked, gone) = watch(dir.path(), &own);
        assert!(watch.is_some(), "the record watch starts");
        std::thread::sleep(Duration::from_millis(100));
        let before = asked.load(Ordering::SeqCst);
        for i in 0..100 {
            write_by_rename(&dir.path().join(format!("other-{i}.json")), "theirs");
            std::thread::sleep(Duration::from_millis(1));
        }
        for i in 0..100 {
            std::fs::remove_file(dir.path().join(format!("other-{i}.json"))).unwrap();
        }
        std::thread::sleep(Duration::from_millis(300));
        let woken = asked.load(Ordering::SeqCst) - before;
        eprintln!("record watch: 200 changes to other records asked the record {woken} times");
        assert_eq!(woken, 0, "changes to other records woke this record's watch");
        std::fs::remove_file(&own).unwrap();
        gone.recv_timeout(Duration::from_secs(5)).expect("its own record's removal ends it");
    }

    /// The record rewritten by rename (a new file each time) stays watched: a later rewrite
    /// that no longer names its owner, its removal, or its directory moved away still ends it.
    #[test]
    fn a_record_watch_follows_its_record_through_rewrites() {
        let dir = tempfile::tempdir().unwrap();
        let own = dir.path().join("own.json");
        write_by_rename(&own, "mine");
        let (_watch, _asked, gone) = watch(dir.path(), &own);
        for _ in 0..3 {
            write_by_rename(&own, "mine");
            std::thread::sleep(Duration::from_millis(50));
        }
        std::thread::sleep(Duration::from_millis(200));
        assert!(gone.try_recv().is_err(), "a rewrite that still names its owner ended it");
        write_by_rename(&own, "a newer host");
        gone.recv_timeout(Duration::from_secs(5)).expect("a record naming another host ends it");

        let second = tempfile::tempdir().unwrap();
        let home = second.path().join("hosts");
        std::fs::create_dir(&home).unwrap();
        let own = home.join("own.json");
        write_by_rename(&own, "mine");
        let (_watch, _asked, gone) = watch(&home, &own);
        write_by_rename(&own, "mine");
        std::thread::sleep(Duration::from_millis(100));
        std::fs::remove_file(&own).unwrap();
        gone.recv_timeout(Duration::from_secs(5)).expect("removal after a rewrite ends it");

        write_by_rename(&own, "mine");
        let (_watch, _asked, gone) = watch(&home, &own);
        std::fs::rename(&home, second.path().join("moved")).unwrap();
        gone.recv_timeout(Duration::from_secs(5)).expect("its directory moved away ends it");
    }

    /// A record missing at the start ends it at once.
    #[test]
    fn a_record_watch_on_a_missing_record_ends_at_once() {
        let dir = tempfile::tempdir().unwrap();
        let own = dir.path().join("own.json");
        let (_watch, _asked, gone) = watch(dir.path(), &own);
        gone.recv_timeout(Duration::from_secs(1)).expect("a missing record ends it at once");
    }
}
