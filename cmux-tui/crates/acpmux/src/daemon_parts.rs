//! Small daemon pieces lower modules use without the daemon itself (`daemon.rs` re-exports
//! them): the host binary's `daemon run` prefix, the first-run
//! dashboard address, the not-dumpable switch (`daemon/person_key.rs`) and an agent host's
//! end of the router owner FIFO (`daemon/router_owner/fifo.rs`).

static DAEMON_PREFIX: std::sync::OnceLock<Vec<std::ffi::OsString>> = std::sync::OnceLock::new();

/// Arguments placed before `daemon run` when a client starts the daemon, for
/// a host binary that runs acpmux under a subcommand (`cmux acp daemon run`).
/// Set once, before the first `connect`.
pub fn set_daemon_prefix(prefix: Vec<std::ffi::OsString>) {
    let _ = DAEMON_PREFIX.set(prefix);
}

/// The prefix set by [`set_daemon_prefix`]; agent hosts start with it too.
pub fn daemon_prefix() -> Vec<std::ffi::OsString> {
    DAEMON_PREFIX.get().cloned().unwrap_or_default()
}

/// The fixed dashboard port belongs to the shared daemon (`~/.acpmux`). Any other home (a
/// tagged dev build's, `ACPMUX_HOME`) listens on a free port and never saves the fixed one,
/// so it can never take the release daemon's port; a home that saved it before is moved off.
/// Returns the address to save: the saved one when it is fine, else the default.
pub(crate) fn first_run_listen(shared_home: bool, saved: Option<&str>) -> &str {
    const SHARED: &str = "127.0.0.1:47811";
    const ANY: &str = "127.0.0.1:0";
    match saved {
        Some(saved) if shared_home || !saved.ends_with(":47811") => saved,
        _ if shared_home => SHARED,
        _ => ANY,
    }
}

/// Makes this process not dumpable before it holds a person key (cx-0q7o):
/// on Linux, a same-uid process (an agent the daemon starts) can then not
/// ptrace it or read its memory through /proc, and the kernel owns its
/// /proc files. Also logs yama's ptrace_scope, the host's other ptrace rule.
#[cfg(target_os = "linux")]
pub(crate) fn not_dumpable() -> std::io::Result<()> {
    // SAFETY: PR_SET_DUMPABLE takes an integer and changes only this
    // process's dumpable flag.
    if unsafe { libc::prctl(libc::PR_SET_DUMPABLE, 0, 0, 0, 0) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: PR_GET_DUMPABLE reads this process's flag.
    if unsafe { libc::prctl(libc::PR_GET_DUMPABLE, 0, 0, 0, 0) } != 0 {
        return Err(std::io::Error::other("PR_GET_DUMPABLE is not 0 after PR_SET_DUMPABLE 0"));
    }
    match std::fs::read_to_string("/proc/sys/kernel/yama/ptrace_scope") {
        Ok(scope) => tracing::info!("person key: not dumpable; yama ptrace_scope {}", scope.trim()),
        Err(_) => tracing::info!("person key: not dumpable; yama is not active"),
    }
    Ok(())
}

/// macOS and other Unix: no dumpable flag. A DEV daemon is unsigned and
/// takes the key at spawn; a Release daemon is hardened-runtime signed,
/// which refuses a debugger without the get-task-allow entitlement, and
/// ignores the key descriptor (it enrolls the signed app instead).
#[cfg(all(unix, not(target_os = "linux")))]
pub(crate) fn not_dumpable() -> std::io::Result<()> {
    Ok(())
}

/// An agent host's owner end of the local router: held for the host's
/// whole life (close-on-exec, so the harness never inherits it). None when
/// no router runs (no reader: the open fails at once) or there is no FIFO.
#[cfg(unix)]
pub(crate) fn open_router_owner(fifo: &std::path::Path) -> Option<std::fs::File> {
    use std::os::unix::fs::{FileTypeExt, OpenOptionsExt};
    if !std::fs::symlink_metadata(fifo).ok()?.file_type().is_fifo() {
        return None;
    }
    std::fs::OpenOptions::new().write(true).custom_flags(libc::O_NONBLOCK).open(fifo).ok()
}
