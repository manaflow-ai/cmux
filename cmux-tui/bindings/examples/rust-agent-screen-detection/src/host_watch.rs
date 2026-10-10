//! Exit when the supervising daemon exits.
//!
//! The daemon stops its plugin process group on a normal shutdown. A `kill -9`
//! skips that, and the scanner would then reconnect forever and duplicate the
//! scanner of the next daemon on the same socket. The daemon passes its pid in
//! `CMUX_PLUGIN_HOST_PID`. An older daemon passes only
//! `CMUX_PLUGIN_GENERATION`; the plugin then watches its parent. A standalone
//! run sets neither and is not watched.

use std::io;
use std::thread;
use std::time::Duration;

const HOST_PID_ENV: &str = "CMUX_PLUGIN_HOST_PID";
const GENERATION_ENV: &str = "CMUX_PLUGIN_GENERATION";
const POLL_INTERVAL: Duration = Duration::from_secs(1);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Plan {
    /// No supervisor environment: run without a host watch.
    Standalone,
    /// The host is already gone (the parent is init).
    ExitNow,
    /// Watch this pid. `parent` also treats a changed `getppid()` as exit.
    Watch { pid: libc::pid_t, parent: bool },
}

/// Chooses what to watch from the environment values and the parent pid.
pub fn plan(
    host_pid: Option<&str>,
    generation: Option<&str>,
    parent_pid: libc::pid_t,
) -> Result<Plan, String> {
    if let Some(value) = host_pid.filter(|value| !value.is_empty()) {
        return match value.parse::<libc::pid_t>() {
            Ok(pid) if pid > 1 => Ok(Plan::Watch { pid, parent: false }),
            _ => Err(format!("invalid {HOST_PID_ENV}: {value:?}")),
        };
    }
    if generation.is_some_and(|value| !value.is_empty()) {
        if parent_pid <= 1 {
            return Ok(Plan::ExitNow);
        }
        return Ok(Plan::Watch { pid: parent_pid, parent: true });
    }
    Ok(Plan::Standalone)
}

/// Starts the host watch from the process environment.
pub fn start() -> Result<(), String> {
    let host_pid = std::env::var(HOST_PID_ENV).ok();
    let generation = std::env::var(GENERATION_ENV).ok();
    // SAFETY: getppid has no preconditions.
    let parent_pid = unsafe { libc::getppid() };
    match plan(host_pid.as_deref(), generation.as_deref(), parent_pid)? {
        Plan::Standalone => Ok(()),
        Plan::ExitNow => host_exited(parent_pid),
        Plan::Watch { pid, parent } => thread::Builder::new()
            .name("host-watch".into())
            .spawn(move || {
                wait_for_exit(pid, parent);
                host_exited(pid)
            })
            .map(drop)
            .map_err(|error| format!("start host watch: {error}")),
    }
}

fn host_exited(pid: libc::pid_t) -> ! {
    eprintln!("cmux-agent-screen-detection: host process {pid} exited; stopping");
    std::process::exit(0)
}

/// Blocks until `pid` exits. Uses the kernel exit notification and falls back
/// to polling when it is not available.
fn wait_for_exit(pid: libc::pid_t, parent: bool) {
    match wait_native(pid) {
        Ok(()) => {}
        Err(error) if error.raw_os_error() == Some(libc::ESRCH) => {}
        Err(_) => wait_by_polling(pid, parent),
    }
}

/// Polls once per `POLL_INTERVAL` until `pid` is gone or, in parent mode, the
/// process was reparented.
pub fn wait_by_polling(pid: libc::pid_t, parent: bool) {
    loop {
        // SAFETY: getppid has no preconditions.
        if parent && unsafe { libc::getppid() } != pid {
            return;
        }
        // SAFETY: signal 0 only checks that the pid exists.
        if unsafe { libc::kill(pid, 0) } != 0
            && io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
        {
            return;
        }
        thread::sleep(POLL_INTERVAL);
    }
}

#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "freebsd",
    target_os = "netbsd",
    target_os = "openbsd",
    target_os = "dragonfly"
))]
fn wait_native(pid: libc::pid_t) -> io::Result<()> {
    // SAFETY: kqueue returns a new descriptor or -1.
    let queue = unsafe { libc::kqueue() };
    if queue < 0 {
        return Err(io::Error::last_os_error());
    }
    let result = wait_kqueue(queue, pid);
    // SAFETY: `queue` is a descriptor this function owns.
    unsafe { libc::close(queue) };
    result
}

#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "freebsd",
    target_os = "netbsd",
    target_os = "openbsd",
    target_os = "dragonfly"
))]
fn wait_kqueue(queue: libc::c_int, pid: libc::pid_t) -> io::Result<()> {
    // SAFETY: an all-zero kevent is a valid value; the fields are set below.
    let mut change: libc::kevent = unsafe { std::mem::zeroed() };
    change.ident = pid as _;
    change.filter = libc::EVFILT_PROC as _;
    change.flags = (libc::EV_ADD | libc::EV_ONESHOT) as _;
    change.fflags = libc::NOTE_EXIT as _;
    // SAFETY: one valid change, no output buffer, no timeout.
    let registered =
        unsafe { libc::kevent(queue, &change, 1, std::ptr::null_mut(), 0, std::ptr::null()) };
    if registered < 0 {
        return Err(io::Error::last_os_error());
    }
    loop {
        // SAFETY: an all-zero kevent is a valid output buffer.
        let mut event: libc::kevent = unsafe { std::mem::zeroed() };
        // SAFETY: no changes, one output slot, block without a timeout.
        let count =
            unsafe { libc::kevent(queue, std::ptr::null(), 0, &mut event, 1, std::ptr::null()) };
        if count > 0 {
            if event.flags & libc::EV_ERROR != 0 && event.data != 0 {
                return Err(io::Error::from_raw_os_error(event.data as i32));
            }
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if count < 0 && error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn wait_native(pid: libc::pid_t) -> io::Result<()> {
    // SAFETY: pidfd_open takes a pid and flags and returns a descriptor or -1.
    let descriptor = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
    if descriptor < 0 {
        return Err(io::Error::last_os_error());
    }
    let descriptor = descriptor as libc::c_int;
    let result = loop {
        let mut poll = libc::pollfd { fd: descriptor, events: libc::POLLIN, revents: 0 };
        // SAFETY: one valid pollfd, no timeout.
        let count = unsafe { libc::poll(&mut poll, 1, -1) };
        if count > 0 {
            break Ok(());
        }
        let error = io::Error::last_os_error();
        if count < 0 && error.kind() != io::ErrorKind::Interrupted {
            break Err(error);
        }
    };
    // SAFETY: `descriptor` is a pidfd this function owns.
    unsafe { libc::close(descriptor) };
    result
}

#[cfg(not(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "freebsd",
    target_os = "netbsd",
    target_os = "openbsd",
    target_os = "dragonfly",
    target_os = "linux",
    target_os = "android"
)))]
fn wait_native(_pid: libc::pid_t) -> io::Result<()> {
    Err(io::Error::from(io::ErrorKind::Unsupported))
}
