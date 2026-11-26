//! Keeps this Mac's display awake while an agent uses Computer Use on it.
//!
//! Leo, 2026-11-18: "even if you have, you know, whatever locked screen or whatever, like you can
//! still do things. I want that."
//!
//! On macOS 14 and later a display that dims for idle locks the session (loginwindow's
//! `kLWLockFromDisplayDim`), even with "require password" set to never, and nothing gets past a
//! lock: every app's AX windows go empty, input lands on the password field, and the worker
//! answers that the Mac is locked. Keep Mac Awake (`sessions.keepAwake`) holds off idle *system*
//! sleep only, so a person who walks away from an agent driving their apps came back to a locked
//! Mac and a stopped task after the display's idle time (measured on a fleet mini, macOS 27: a
//! display sleep alone locked it, then AX listed 0 elements, every input was refused and the
//! desktop capture was black).
//!
//! So every tool call through this bridge (`acpmux computer-use-mcp`, [`super::mcp`]) arms a
//! display hold: `/usr/bin/caffeinate -d -i -u` for [`WINDOW`], tied to this bridge with `-w` (it
//! exits when the bridge does, so a crash never leaks one) and bounded with `-t`. `-u` declares
//! the user active, which restarts the idle timer the screen saver counts, and wakes a display
//! that dimmed but has not locked. A call less than half a window after the hold started reuses
//! it, so a busy agent starts one short process every [`WINDOW`] / 2 at most. The hold ends
//! [`WINDOW`] after the last call, or with the bridge.
//!
//! It never unlocks a locked Mac and never changes a setting: a Mac that is already locked stays
//! locked, and its calls keep answering that it is locked.

use std::time::{Duration, Instant};

/// How long one call keeps the display awake.
pub const WINDOW: Duration = Duration::from_secs(300);

/// The `caffeinate` arguments for a hold tied to `pid`, lasting `window`.
pub fn caffeinate_args(pid: u32, window: Duration) -> Vec<String> {
    ["-d", "-i", "-u", "-w"]
        .into_iter()
        .map(str::to_owned)
        .chain([pid.to_string(), "-t".to_owned(), window.as_secs().max(1).to_string()])
        .collect()
}

/// Whether a hold started at `started` (none: no hold) must be renewed at `now`: none runs, it
/// exited, or half its window has passed.
pub fn needs_renewal(
    started: Option<Instant>,
    alive: bool,
    now: Instant,
    window: Duration,
) -> bool {
    match started {
        Some(started) if alive => now.saturating_duration_since(started) >= window / 2,
        _ => true,
    }
}

/// The bridge's display hold. Its `caffeinate` is an owned [`cmux_process::Child`]: dropping it
/// (a renewal, or the bridge ending) ends that process.
#[derive(Default)]
pub struct DisplayAwake {
    #[cfg(target_os = "macos")]
    held: Option<(cmux_process::Child, Instant)>,
}

impl DisplayAwake {
    /// One Computer Use call is about to run: make sure the display stays awake for [`WINDOW`].
    #[cfg(target_os = "macos")]
    pub fn touch(&mut self) {
        let now = Instant::now();
        let alive =
            self.held.as_mut().is_some_and(|(child, _)| matches!(child.try_wait(), Ok(None)));
        if !needs_renewal(self.held.as_ref().map(|(_, at)| *at), alive, now, WINDOW) {
            return;
        }
        let spawned = cmux_process::Command::new("/usr/bin/caffeinate")
            .args(caffeinate_args(std::process::id(), WINDOW))
            .stdin(cmux_process::Stdio::null())
            .stdout(cmux_process::Stdio::null())
            .stderr(cmux_process::Stdio::null())
            .spawn();
        match spawned {
            // The new hold is up before the old one is dropped, so the display never drops between.
            Ok(child) => drop(self.held.replace((child, now))),
            Err(error) => {
                tracing::warn!(%error, "computer use bridge: caffeinate did not start; the display may sleep")
            }
        }
    }

    /// Other platforms: Linux Computer Use targets a display of its own; nothing to hold.
    #[cfg(not(target_os = "macos"))]
    pub fn touch(&mut self) {}
}

#[cfg(test)]
#[path = "awake_tests.rs"]
mod tests;
