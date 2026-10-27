//! The app the Chief's host serves, and its exit (cp/quit-chief-idle,
//! 2026-10-27: a Cmd-Q left the Chief's host, its acpmux and its owner
//! daemon running, about 300 MB with nothing to do).
//!
//! The app that starts a host (Home's `HomeBrainHost`, or the owner daemon's
//! Chief brain supervisor for a Chief that is not the default) names itself
//! in `OPTCHAT_OWNER_APP_PID`. One thread blocks in the kernel until that
//! process exits (kqueue `EVFILT_PROC` `NOTE_EXIT` on macOS, a pidfd on
//! Linux, as acpmux's `daemon_lifecycle.rs` watches its app; no polling).
//! The next app that opens Home reuses a running host and writes its own pid
//! to `<Chief home>/state/owner-app.pid` ([`pid_file`]): at an exit the watch
//! reads that file and follows a newer app that still runs. When no app is
//! left the brain hears [`crate::brain::Input::OwnerAppExited`] and stops
//! once it is idle (no turn, no queued prompt, no pending permission, no
//! subagent or child at work); live work keeps it, so Keep Sessions Running
//! keeps the Chief working, and it stops when that work ends.
//!
//! A host no app named (`cmux chief`, the always-on brain's LaunchAgent, a
//! VM Chief) watches nothing and runs as before.

use std::path::{Path, PathBuf};

use crate::cli::env;

/// The variable the app names itself in.
pub const OWNER_APP_PID_ENV: &str = "OPTCHAT_OWNER_APP_PID";

/// `<Chief home>/state/owner-app.pid`: the app that last opened this Chief
/// home's Home (`CMUX_CHIEF_HOME`, else the host's own home).
pub fn pid_file(mux_home: &Path) -> PathBuf {
    env("CMUX_CHIEF_HOME")
        .map_or_else(|| mux_home.to_path_buf(), PathBuf::from)
        .join("state/owner-app.pid")
}

/// A pid above 1; anything else names no app.
pub fn parse_pid(text: &str) -> Option<i32> {
    text.trim().parse::<i32>().ok().filter(|pid| *pid > 1)
}

/// The app this host was started for, from its environment.
pub fn from_env() -> Option<i32> {
    env(OWNER_APP_PID_ENV).as_deref().and_then(parse_pid)
}

/// Whether process `pid` exists (a zombie counts: it exited, its parent has
/// not reaped it yet, and the kernel watch reports it as gone).
fn exists(pid: i32) -> bool {
    // SAFETY: signal 0 only checks that the process exists.
    unsafe { libc::kill(pid, 0) == 0 }
}

/// The app to follow after `gone` exited: the pid in `file` when it names
/// another process that still runs.
pub fn next_owner(gone: i32, file: &Path, alive: &dyn Fn(i32) -> bool) -> Option<i32> {
    // Red: no newer app is followed.
    let _ = (gone, file, alive);
    None
}

/// Watches `pid`, then each newer app [`next_owner`] names, on one thread
/// that blocks in the kernel; calls `exited` once none is left. Nothing
/// happens when the platform cannot watch the process (the host then runs
/// until it is stopped, as before).
pub fn watch(pid: i32, file: PathBuf, exited: impl FnOnce() + Send + 'static) -> bool {
    std::thread::Builder::new()
        .name("chief-owner-app-exit".into())
        .spawn(move || {
            let mut pid = pid;
            loop {
                if !wait_for_process_exit(pid) {
                    return;
                }
                match next_owner(pid, &file, &exists) {
                    Some(next) => pid = next,
                    None => break,
                }
            }
            exited();
        })
        .is_ok()
}

/// Blocks until process `pid` exits; true when it exited (or was already
/// gone), false when it cannot be watched. macOS: a kqueue `EVFILT_PROC`
/// `NOTE_EXIT` event, which works for a process that is not this one's
/// child (acpmux `daemon_lifecycle.rs` watches its app the same way).
#[cfg(target_os = "macos")]
pub fn wait_for_process_exit(pid: i32) -> bool {
    // SAFETY: kqueue takes no arguments and returns a new descriptor or -1.
    let queue = unsafe { libc::kqueue() };
    if queue < 0 {
        return false;
    }
    // SAFETY: kevent is a plain C struct; all zero is a valid value of it.
    let mut change: libc::kevent = unsafe { std::mem::zeroed() };
    let Ok(ident) = libc::uintptr_t::try_from(pid) else {
        // SAFETY: closes the descriptor kqueue returned above, once.
        unsafe { libc::close(queue) };
        return false;
    };
    change.ident = ident;
    change.filter = libc::EVFILT_PROC;
    change.flags = libc::EV_ADD | libc::EV_ONESHOT;
    change.fflags = libc::NOTE_EXIT;
    let exited = loop {
        // SAFETY: as above.
        let mut event: libc::kevent = unsafe { std::mem::zeroed() };
        // SAFETY: one change and one event slot, locals that outlive the
        // call; a null timeout blocks until the event.
        let n = unsafe { libc::kevent(queue, &change, 1, &mut event, 1, std::ptr::null()) };
        if n < 0 {
            match std::io::Error::last_os_error().raw_os_error() {
                Some(libc::EINTR) => continue,
                // Already gone.
                Some(libc::ESRCH) => break true,
                _ => break false,
            }
        }
        if n == 0 {
            continue;
        }
        if event.flags & libc::EV_ERROR != 0 {
            break i64::try_from(event.data).ok() == Some(i64::from(libc::ESRCH));
        }
        break event.fflags & libc::NOTE_EXIT != 0;
    };
    // SAFETY: closes the descriptor kqueue returned above, once.
    unsafe { libc::close(queue) };
    exited
}

/// Linux: a pidfd turns readable when the process exits.
#[cfg(target_os = "linux")]
pub fn wait_for_process_exit(pid: i32) -> bool {
    // SAFETY: pidfd_open(pid, 0) returns a new descriptor or -1.
    let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
    if fd < 0 {
        return std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH);
    }
    let Ok(fd) = libc::c_int::try_from(fd) else {
        return false;
    };
    let mut poll = libc::pollfd {
        fd,
        events: libc::POLLIN,
        revents: 0,
    };
    let exited = loop {
        // SAFETY: one pollfd, a local that outlives the call; -1 blocks
        // until it is ready.
        let n = unsafe { libc::poll(&mut poll, 1, -1) };
        if n < 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {
            continue;
        }
        break n > 0;
    };
    // SAFETY: closes the descriptor pidfd_open returned above, once.
    unsafe { libc::close(fd) };
    exited
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub fn wait_for_process_exit(_pid: i32) -> bool {
    false
}
