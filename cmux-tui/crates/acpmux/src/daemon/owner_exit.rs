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
        match imp::wait_exit(pid, || true) {
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

/// Debug builds only: the test process that started this daemon or agent host, as
/// `<pid>:<start>` ([`process_start`]; a bare `<pid>` is followed by pid alone). Hosts
/// outlive their daemon on purpose, and #28319's orphan exit ends a host only once it is idle with
/// everything acked, so a test that panicked, timed out or was killed mid-turn left its daemon, its
/// hosts and their stand-in harnesses running for days: 34 hosts and 8 daemons on one lane VM,
/// 130-144 h old, counted as live lanes. Every process a test starts gets it
/// (`tests/support/daemon_env.rs`), a daemon passes it on to the hosts it starts (`link.rs`), and
/// both end once that process exits, idle or not: the daemon ends its agents and stops
/// ([`test_owner_exit`]), a host ends its harness group as on SIGTERM. Release builds ignore it.
/// The start time matters: a process that inherits the variable may start after its test is gone,
/// and the pid may name a later, unrelated process by then, whose exit it would wait for.
#[cfg(debug_assertions)]
pub(crate) const TEST_OWNER_PID_ENV: &str = "ACPMUX_TEST_OWNER_PID";

/// Debug builds only: runs `on_exit` on a thread of its own once the test process named in
/// [`TEST_OWNER_PID_ENV`] exited (at once when it already did). Nothing happens without one, or
/// when its exit cannot be watched.
#[cfg(debug_assertions)]
pub(crate) fn follow_test_owner(on_exit: impl FnOnce(u32) + Send + 'static) {
    let Some((pid, start)) = test_owner(std::env::var(TEST_OWNER_PID_ENV).ok().as_deref()) else {
        return;
    };
    // Read once the watch is armed: a pid that names another process now (the test is gone and
    // its pid was reused) counts as the test's exit.
    let still_the_test = move || start.is_none_or(|start| process_start(pid) == Some(start));
    let spawned =
        std::thread::Builder::new().name("acpmux-test-owner-watch".into()).spawn(move || {
            match imp::wait_exit(pid, still_the_test) {
                Ok(()) => on_exit(pid),
                Err(error) => tracing::warn!(pid, %error, "cannot watch the test process"),
            }
        });
    if let Err(error) = spawned {
        tracing::warn!(pid, %error, "cannot start the test process watch");
    }
}

/// Resolves with the test process's pid once it exited ([`TEST_OWNER_PID_ENV`]); never without
/// one, when its exit cannot be watched, or in a release build. The watch starts at the call.
pub(super) fn test_owner_exit() -> impl std::future::Future<Output = u32> {
    #[cfg(debug_assertions)]
    let exited = {
        let (tx, rx) = tokio::sync::oneshot::channel();
        follow_test_owner(move |pid| {
            let _ = tx.send(pid);
        });
        rx
    };
    async move {
        #[cfg(debug_assertions)]
        if let Ok(pid) = exited.await {
            return pid;
        }
        std::future::pending().await
    }
}

/// `<pid>[:<start>]` of [`TEST_OWNER_PID_ENV`]: the pid (as [`owner_pid`]) and its start time.
#[cfg(debug_assertions)]
fn test_owner(value: Option<&str>) -> Option<(u32, Option<u64>)> {
    let value = value?.trim();
    match value.split_once(':') {
        Some((pid, start)) => Some((owner_pid(Some(pid))?, Some(start.parse().ok()?))),
        None => Some((owner_pid(Some(value))?, None)),
    }
}

/// The kernel's start time of `pid` in its own units (clock ticks since boot on Linux,
/// microseconds since the epoch on macOS): with the pid it names one process, which a later
/// process under the same pid does not match. None when it cannot be read (no such process).
pub fn process_start(pid: u32) -> Option<u64> {
    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        // Field 22 (`starttime`); the command name before it may hold spaces and parentheses.
        let raw = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        let (_, fields) = raw.rsplit_once(')')?;
        fields.split_whitespace().nth(19)?.parse().ok()
    }
    #[cfg(target_os = "macos")]
    {
        let (sec, usec) = crate::cua_v2::start_time(i32::try_from(pid).ok()?)?;
        sec.checked_mul(1_000_000)?.checked_add(usec)
    }
    #[cfg(not(any(target_os = "linux", target_os = "android", target_os = "macos")))]
    {
        let _ = pid;
        None
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

    /// Blocks until `pid` exits (or was already gone, or `still_ours` says once the watch is
    /// armed that `pid` names another process now).
    pub(super) fn wait_exit(pid: u32, still_ours: impl FnOnce() -> bool) -> io::Result<()> {
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
        let now = libc::timespec { tv_sec: 0, tv_nsec: 0 };
        // Add the watch alone first (no event slot, no wait), so `still_ours` reads a process the
        // watch already holds.
        loop {
            // SAFETY: one change, no event slot, a zero timeout; all valid for the call.
            let n = unsafe {
                libc::kevent(queue.as_raw_fd(), &change, 1, std::ptr::null_mut(), 0, &now)
            };
            if n >= 0 {
                break;
            }
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            // ESRCH: the process was gone before the watch was added.
            return if super::gone(&error) { Ok(()) } else { Err(error) };
        }
        if !still_ours() {
            return Ok(());
        }
        let changes = 0;
        loop {
            // SAFETY: no change (the watch is added) and one event slot, valid for the call; no
            // timeout.
            let n = unsafe {
                libc::kevent(queue.as_raw_fd(), &change, changes, &mut event, 1, std::ptr::null())
            };
            if n < 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
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

    /// Blocks until `pid` exits (or was already gone, or `still_ours` says once the pidfd holds
    /// the process that `pid` names another one now).
    pub(super) fn wait_exit(pid: u32, still_ours: impl FnOnce() -> bool) -> io::Result<()> {
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
        if !still_ours() {
            return Ok(());
        }
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
    pub(super) fn wait_exit(_pid: u32, _still_ours: impl FnOnce() -> bool) -> std::io::Result<()> {
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

    #[cfg(debug_assertions)]
    #[test]
    fn a_test_owner_names_its_pid_and_start_time() {
        assert_eq!(test_owner(Some("4242:917")), Some((4242, Some(917))));
        assert_eq!(test_owner(Some(" 4242\n")), Some((4242, None)));
        assert_eq!(test_owner(Some("4242:x")), None);
        assert_eq!(test_owner(Some("1:917")), None);
        assert_eq!(test_owner(None), None);
    }

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[test]
    fn a_process_keeps_its_start_time_and_a_gone_one_has_none() {
        let mut child = std::process::Command::new("sleep").arg("30").spawn().unwrap();
        let start = process_start(child.id());
        assert!(start.is_some());
        assert_eq!(process_start(child.id()), start);
        assert!(process_start(std::process::id()).is_some_and(|own| Some(own) <= start));
        child.kill().unwrap();
        child.wait().unwrap();
        assert_eq!(process_start(child.id()), None);
    }

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn quit_helpers_the_watch_returns_when_the_process_exits() {
        let mut child = std::process::Command::new("sleep").arg("600").spawn().expect("sleep");
        let pid = child.id();
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(imp::wait_exit(pid, || true).is_ok());
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
        assert!(imp::wait_exit(pid, || true).is_ok());
    }

    /// A pid that names another process once the watch holds it counts as an exit at once.
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn a_watch_whose_process_is_not_ours_returns_at_once() {
        let mut child = std::process::Command::new("sleep").arg("600").spawn().expect("sleep");
        let returned = imp::wait_exit(child.id(), || false).is_ok();
        let _ = child.kill();
        let _ = child.wait();
        assert!(returned);
    }
}
