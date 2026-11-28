//! The restart handoff's entry points off and on Unix, the bound socket's cleanup, the readiness
//! line and the owner-only narrowing the daemon's start uses.

use super::*;

/// `_acpmux/shutdown {restart: true}` with `reason`, before anything changes: whether it execs in
/// place (`daemon/handoff.rs`). None keeps v1's exit (no `start`, a take-over's handover, off
/// Unix); `Some(Err)` is a failed check of the installed build, and the daemon serves on.
pub(crate) async fn prepare_handoff(reason: &str) -> Option<Result<(), String>> {
    #[cfg(unix)]
    {
        handoff::prepare(reason).await
    }
    #[cfg(not(unix))]
    {
        let _ = reason;
        None
    }
}

/// The restart request whose check passed begins the stop now: whether the stop is its exec in
/// place (`daemon/handoff.rs`). Always false off Unix.
pub(crate) fn commit_handoff() -> bool {
    #[cfg(unix)]
    {
        handoff::commit()
    }
    #[cfg(not(unix))]
    {
        false
    }
}

/// Whether the stop under way execs in place and so keeps its listeners listening for the next
/// image (`daemon/handoff.rs`). Always false off Unix.
pub(crate) fn keeps_listeners() -> bool {
    #[cfg(unix)]
    {
        handoff::handing_off()
    }
    #[cfg(not(unix))]
    {
        false
    }
}

/// The log target of a restart's marks (`handoff timing: <mark>`, at debug): the request read, its
/// gates, the check, the stop, the exec and the next image's start. `tests/daemon_handoff.rs`
/// turns it on and times each mark as its line arrives.
pub(crate) const HANDOFF_TIMING: &str = "handoff_timing";

/// How many restarts this process came through as an exec in place (`_acpmux/status`
/// `handoffs`): 0 on a normal start, and always off Unix.
pub(crate) fn handoffs() -> u32 {
    #[cfg(unix)]
    {
        handoff::count()
    }
    #[cfg(not(unix))]
    {
        0
    }
}

// Covers every fallible startup step after bind, including token/config validation. Normal
// shutdown removes the socket explicitly; a replaced socket is never this guard's to remove.
pub(super) struct BoundSocketCleanup(pub(super) Option<home_watch::Owned>);

impl Drop for BoundSocketCleanup {
    fn drop(&mut self) {
        // A stop that execs in place keeps the socket for the next image (`daemon/handoff.rs`).
        #[cfg(unix)]
        if handoff::handing_off() {
            return;
        }
        remove_bound_socket(self.0.as_ref());
    }
}

/// The socket file is the next daemon's: this one handed it the listener
/// (`daemon/listener_handover.rs`), so it stays.
pub(super) fn socket_handed() -> bool {
    #[cfg(unix)]
    return listener_handover::handed_to_live();
    #[cfg(not(unix))]
    false
}

/// A startup that fails after the bind removes the socket only while it is still the one this
/// daemon bound: one replaced since is another daemon's. Off Unix there is no identity to read.
pub(super) fn remove_bound_socket(bound: Option<&home_watch::Owned>) {
    if bound.map_or(!cfg!(unix), |s| s.lost().is_none()) && !socket_handed() {
        let _ = crate::home_fs::remove_file(socket_path());
    }
}

/// Write the readiness line to an inherited descriptor and close it.
#[cfg(unix)]
pub(super) fn write_ready(fd: i32, ready: &Value) {
    use std::io::Write;
    use std::os::fd::FromRawFd;
    if fd < 0 {
        return;
    }
    let mut line = ready.to_string();
    line.push('\n');
    // SAFETY: the launcher passed this descriptor for us to write and close.
    let mut f = unsafe { std::fs::File::from_raw_fd(fd) };
    if let Err(e) = f.write_all(line.as_bytes()) {
        tracing::warn!("--ready-fd {fd}: {e}");
    }
    if fd <= 2 {
        // Never close stdio.
        std::mem::forget(f);
    }
}
/// Windows: an inherited handle (`daemon/windows.rs`).
#[cfg(windows)]
pub(super) fn write_ready(fd: i32, ready: &Value) {
    windows::write_ready(fd, ready)
}

/// Whether `--allow-dev-origin` may take effect: in a debug build, or with
/// an explicit `--dev` that release launchers never pass. A release config
/// refuses it, so a dev page origin never becomes a LocalApp origin there.
pub(crate) fn dev_origins_permitted(debug_build: bool, dev_flag: bool) -> bool {
    debug_build || dev_flag
}

/// Clears the group and other bits of `path`, if it exists.
#[cfg(unix)]
pub(super) fn narrow_to_owner(path: &std::path::Path) {
    use std::os::unix::fs::PermissionsExt;
    let Ok(meta) = std::fs::metadata(path) else { return };
    let mode = meta.permissions().mode();
    if mode & 0o077 != 0
        && let Err(e) =
            crate::home_fs::set_permissions(path, std::fs::Permissions::from_mode(mode & 0o700))
    {
        tracing::warn!("could not make {} owner-only: {e}", path.display());
    }
}
/// Windows: replaces a wider access list with the owner-only one.
#[cfg(windows)]
pub(super) use crate::owner_only::narrow as narrow_to_owner;
