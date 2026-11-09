//! The exit of a direct agent's process as a kernel event, so its reader sleeps until the agent
//! exits instead of checking it on a timer (Leo 2026-11-04: "never ... acceptable ... linear time
//! growth degradation"; a 500 ms check per live agent woke the daemon 2 times a second per agent).
//!
//! Linux: a pidfd, readable once the process exits. macOS: a kqueue with one `EVFILT_PROC`
//! `NOTE_EXIT` registration, readable once the event is pending. Both are registered with tokio's
//! reactor, so a quiet agent costs no wakeup and no thread. Opened right after spawn, while the
//! child is held unreaped, so the pid is the agent's own. Where neither exists (Windows, a
//! kernel before 5.3, the simulation's in-process agent) [`LeaderExit::open`] gives `None` and the
//! reader keeps its timed check.

#[cfg(any(target_os = "linux", target_os = "macos"))]
use std::os::fd::{FromRawFd, OwnedFd};

pub(crate) struct LeaderExit {
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    fd: Option<tokio::io::unix::AsyncFd<OwnedFd>>,
}

/// Tests only: this thread's agents start as if the kernel had no exit event, so their readers
/// keep the timed check (`agent_idle_tests.rs`).
#[cfg(test)]
pub(crate) mod timed_check_only {
    thread_local! {
        static ON: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    }
    pub(crate) fn set(on: bool) {
        ON.with(|o| o.set(on));
    }
    pub(super) fn on() -> bool {
        ON.with(std::cell::Cell::get)
    }
}

impl LeaderExit {
    /// The exit event of child `pid`, unreaped; `None` when this kernel has none.
    pub(crate) fn open(pid: u32) -> Option<Self> {
        #[cfg(test)]
        if timed_check_only::on() {
            return None;
        }
        Self::open_native(pid)
    }

    #[cfg(target_os = "linux")]
    fn open_native(pid: u32) -> Option<Self> {
        let pid = libc::pid_t::try_from(pid).ok()?;
        // SAFETY: pidfd_open takes a pid and flags and returns a new descriptor or -1.
        let raw = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0 as libc::c_uint) };
        let raw = libc::c_int::try_from(raw).ok().filter(|fd| *fd >= 0)?;
        // SAFETY: a successful pidfd_open returns a new descriptor owned here.
        let fd = unsafe { OwnedFd::from_raw_fd(raw) };
        let fd = tokio::io::unix::AsyncFd::with_interest(fd, tokio::io::Interest::READABLE).ok()?;
        Some(Self { fd: Some(fd) })
    }

    #[cfg(target_os = "macos")]
    fn open_native(pid: u32) -> Option<Self> {
        use std::os::fd::AsRawFd;
        let pid = libc::pid_t::try_from(pid).ok()?;
        // SAFETY: kqueue has no preconditions.
        let queue = unsafe { libc::kqueue() };
        if queue < 0 {
            return None;
        }
        // SAFETY: a successful kqueue returns a new descriptor owned here.
        let queue = unsafe { OwnedFd::from_raw_fd(queue) };
        // SAFETY: an all-zero kevent is a valid value; the fields are set below.
        let mut change: libc::kevent = unsafe { std::mem::zeroed() };
        change.ident = pid as libc::uintptr_t;
        change.filter = libc::EVFILT_PROC;
        change.flags = libc::EV_ADD | libc::EV_ONESHOT;
        change.fflags = libc::NOTE_EXIT;
        // SAFETY: `change` is initialized and outlives the call; no event is read.
        let added = unsafe {
            libc::kevent(queue.as_raw_fd(), &change, 1, std::ptr::null_mut(), 0, std::ptr::null())
        };
        if added < 0 {
            // ESRCH: it already exited (a zombie waiting to be reaped); the event is now.
            return (std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH))
                .then_some(Self { fd: None });
        }
        let fd =
            tokio::io::unix::AsyncFd::with_interest(queue, tokio::io::Interest::READABLE).ok()?;
        Some(Self { fd: Some(fd) })
    }

    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    fn open_native(_pid: u32) -> Option<Self> {
        None
    }

    /// Resolves once the process exited (at once, every time after that).
    pub(crate) async fn exited(&self) {
        #[cfg(any(target_os = "linux", target_os = "macos"))]
        // The readiness is kept, not cleared: an exit stays an exit.
        if let Some(fd) = &self.fd {
            let _ = fd.readable().await;
        }
    }
}
