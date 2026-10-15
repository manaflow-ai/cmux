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
//! Elsewhere: notify's recommended watcher (inotify on Linux), which is a
//! kernel queue too.

use std::path::PathBuf;

/// Live while held. `on_change` returns true when it needs no more events.
pub(super) struct DirWatch {
    #[cfg(target_os = "macos")]
    kq: std::sync::Arc<std::os::fd::OwnedFd>,
    #[cfg(not(target_os = "macos"))]
    _watcher: notify::RecommendedWatcher,
}

#[cfg(target_os = "macos")]
const STOP: usize = 1;

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
    /// Watches every directory of `dirs` that can be opened (a missing one
    /// is skipped with a warning). None when no directory is watched.
    #[cfg(target_os = "macos")]
    pub(super) fn start(
        dirs: &[PathBuf],
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
        let fflags = libc::NOTE_WRITE | libc::NOTE_DELETE | libc::NOTE_RENAME | libc::NOTE_REVOKE;
        let mut files = Vec::new();
        for dir in dirs {
            // O_EVTONLY: the open descriptor never keeps the volume from unmounting.
            let opened = std::fs::OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_EVTONLY)
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

    #[cfg(not(target_os = "macos"))]
    pub(super) fn start(
        dirs: &[PathBuf],
        mut on_change: impl FnMut() -> bool + Send + 'static,
    ) -> Option<Self> {
        use notify::Watcher as _;
        let mut done = false;
        let mut watcher =
            notify::recommended_watcher(move |_event: notify::Result<notify::Event>| {
                if !done {
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

#[cfg(target_os = "macos")]
impl Drop for DirWatch {
    fn drop(&mut self) {
        use std::os::fd::AsRawFd;
        // Not joined: the callback may be blocked handing its event to a
        // loop that is ending; it returns once that receiver is gone.
        let _ = kevent_change(self.kq.as_raw_fd(), STOP, libc::EVFILT_USER, 0, libc::NOTE_TRIGGER);
    }
}
