//! The daemon follows the app that started it. The app starts its daemon detached (its own
//! session, adopted by launchd) so durable agents outlive a quit, and names itself in
//! [`OWNER_APP_PID_ENV`]. Without this, a daemon whose app quit with nothing left to do ran on for
//! the whole unused grace (60 min) on a home of its own and forever on the shared `~/.acpmux` (P0
//! journey quit-leaves-no-helpers: 5 s after a normal quit the app's acpmux still ran).
//!
//! One thread blocks in the kernel until the owner exits (kqueue `EVFILT_PROC` `NOTE_EXIT` on
//! macOS, a pidfd on Linux; no polling), as a Chromium child ends when its browser process goes.
//! After that, the stop rule in `unused_exit.rs` waits only [`OWNER_EXIT_GRACE`] with no client
//! instead of its grace, and still stops only when nothing keeps the daemon
//! ([`crate::hub::Hub::in_use`]): a running agent, a turn, a pending permission or a background
//! task keeps it, so Keep Sessions Running keeps working agents. A daemon with no owner named (the
//! CLI's, a service unit's, a Cloud machine's) is unchanged.

use std::time::Duration;
use tokio::sync::watch;

/// The pid of the app that started this daemon (`AcpmuxDaemonLauncher`).
pub(crate) const OWNER_APP_PID_ENV: &str = "ACPMUX_OWNER_APP_PID";

/// After the owner app exited: how long the daemon goes with no client before it asks what keeps
/// it. Short: the app is gone, so only a command or a peer can still arrive.
pub(crate) const OWNER_EXIT_GRACE: Duration = Duration::from_secs(2);

/// After the owner app exited and something kept the daemon (an agent at work): when it asks
/// again. A turn that ends after the quit stops the daemon within this time.
pub(crate) const OWNER_KEPT_RECHECK: Duration = Duration::from_secs(60);

/// The owner app named in the environment, if any: its pid and a receiver that turns true once it
/// has exited. A pid that does not parse, is 0 or 1, or is this process names no owner.
pub(super) fn follow() -> Option<(u32, watch::Receiver<bool>)> {
    let pid = owner_pid(std::env::var(OWNER_APP_PID_ENV).ok().as_deref())?;
    let (gone, receiver) = watch::channel(false);
    let spawned = std::thread::Builder::new().name("acpmux-owner-watch".into()).spawn(move || {
        match imp::wait_exit(pid) {
            Ok(()) => {
                tracing::info!(pid, "the owner app exited");
                let _ = gone.send(true);
            }
            // No exit event: the daemon keeps its grace, as without an owner.
            Err(error) => {
                tracing::warn!(pid, %error, "cannot watch the owner app; it is not followed");
                // Keep the sender alive so the receiver never reads a close as an exit.
                std::mem::forget(gone);
            }
        }
    });
    match spawned {
        Ok(_) => Some((pid, receiver)),
        Err(error) => {
            tracing::warn!(pid, %error, "cannot start the owner app watch; it is not followed");
            None
        }
    }
}

fn owner_pid(value: Option<&str>) -> Option<u32> {
    let pid = value?.trim().parse::<u32>().ok()?;
    (pid > 1 && pid != std::process::id() && i32::try_from(pid).is_ok()).then_some(pid)
}

#[cfg(any(target_os = "macos", target_os = "linux", target_os = "android"))]
fn gone(error: &std::io::Error) -> bool {
    error.raw_os_error() == Some(libc::ESRCH)
}

#[cfg(target_os = "macos")]
mod imp {
    use std::io;
    use std::os::fd::{AsRawFd as _, FromRawFd as _, OwnedFd};

    /// Blocks until `pid` exits (or was already gone).
    pub(super) fn wait_exit(pid: u32) -> io::Result<()> {
        // SAFETY: kqueue has no preconditions.
        let raw = unsafe { libc::kqueue() };
        if raw < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: `raw` is a new descriptor this function owns.
        let queue = unsafe { OwnedFd::from_raw_fd(raw) };
        // SAFETY: kevent is plain data; all-zero is a valid value.
        let mut change: libc::kevent = unsafe { std::mem::zeroed() };
        change.ident = pid as usize;
        change.filter = libc::EVFILT_PROC;
        change.flags = libc::EV_ADD | libc::EV_ONESHOT;
        change.fflags = libc::NOTE_EXIT;
        // SAFETY: as above.
        let mut event: libc::kevent = unsafe { std::mem::zeroed() };
        // The watch is added with the first call; a call after an interruption only waits.
        let mut changes = 1;
        loop {
            // SAFETY: `changes` (0 or 1) changes and one event slot, all valid for the call; no
            // timeout.
            let n = unsafe {
                libc::kevent(queue.as_raw_fd(), &change, changes, &mut event, 1, std::ptr::null())
            };
            if n < 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    // Registered already: wait on, without adding it again.
                    changes = 0;
                    continue;
                }
                // ESRCH: the process was gone before the watch was added.
                return if super::gone(&error) { Ok(()) } else { Err(error) };
            }
            if n > 0 && event.flags & libc::EV_ERROR != 0 {
                let error = io::Error::from_raw_os_error(event.data as i32);
                return if super::gone(&error) { Ok(()) } else { Err(error) };
            }
            if n > 0 {
                return Ok(());
            }
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
mod imp {
    use std::io;
    use std::os::fd::{AsRawFd as _, FromRawFd as _, OwnedFd};

    /// Blocks until `pid` exits (or was already gone).
    pub(super) fn wait_exit(pid: u32) -> io::Result<()> {
        let pid =
            libc::pid_t::try_from(pid).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
        // SAFETY: pidfd_open takes a pid and flags 0.
        let raw = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
        if raw < 0 {
            let error = io::Error::last_os_error();
            return if super::gone(&error) { Ok(()) } else { Err(error) };
        }
        let raw = i32::try_from(raw).map_err(|_| io::Error::from(io::ErrorKind::InvalidData))?;
        // SAFETY: `raw` is a new descriptor this function owns.
        let fd = unsafe { OwnedFd::from_raw_fd(raw) };
        let mut poll = libc::pollfd { fd: fd.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        loop {
            // SAFETY: one pollfd, valid for the call; no timeout.
            let n = unsafe { libc::poll(&mut poll, 1, -1) };
            if n < 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(error);
            }
            // The pidfd is readable once the process has exited.
            if n > 0 {
                return Ok(());
            }
        }
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "android")))]
mod imp {
    /// No exit event here: the owner is not followed.
    pub(super) fn wait_exit(_pid: u32) -> std::io::Result<()> {
        Err(std::io::Error::from(std::io::ErrorKind::Unsupported))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quit_helpers_only_another_real_pid_names_an_owner() {
        assert_eq!(owner_pid(Some("4242")), Some(4242));
        assert_eq!(owner_pid(Some(" 4242\n")), Some(4242));
        assert_eq!(owner_pid(None), None);
        assert_eq!(owner_pid(Some("")), None);
        assert_eq!(owner_pid(Some("app")), None);
        assert_eq!(owner_pid(Some("0")), None);
        assert_eq!(owner_pid(Some("1")), None);
        assert_eq!(owner_pid(Some(&std::process::id().to_string())), None);
        assert_eq!(owner_pid(Some("4294967295")), None);
    }

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn quit_helpers_the_watch_returns_when_the_process_exits() {
        let mut child = std::process::Command::new("sleep").arg("600").spawn().expect("sleep");
        let pid = child.id();
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(imp::wait_exit(pid).is_ok());
        });
        assert!(rx.recv_timeout(Duration::from_millis(300)).is_err(), "returned while it runs");
        let _ = child.kill();
        let _ = child.wait();
        assert_eq!(rx.recv_timeout(Duration::from_secs(5)), Ok(true));
    }

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn quit_helpers_the_watch_returns_at_once_for_a_process_already_gone() {
        let mut child = std::process::Command::new("true").spawn().expect("true");
        let pid = child.id();
        let _ = child.wait();
        assert!(imp::wait_exit(pid).is_ok());
    }
}
