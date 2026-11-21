//! The scanner's reconnect loop: one connection pass, a wait, the next pass.
//!
//! A pass that ends at once costs the daemon its connections and its
//! requests, so the wait doubles after each pass, from 1 second to 30
//! seconds. Only a pass that scanned and lived for 30 seconds puts the wait
//! back to 1 second. A pass that scanned and ended sooner does not: an error
//! that comes back just after each first read of the terminals would
//! otherwise keep the wait at 1 second for as long as the daemon lives. The
//! daemon's supervisor has the same rule for a plugin process that ends
//! (`cmux-tui-core/src/journal_plugin.rs`, `STABLE_RUNTIME`).
//!
//! This file uses the standard library only: a test of the cmux-tui
//! workspace compiles it too (`crates/cmux-tui/tests/detector_reconnect.rs`)
//! and counts the passes with a clock of its own.

use std::time::Duration;

/// The first wait of the loop, and the wait after a stable pass.
pub const RECONNECT_WAIT_MIN: Duration = Duration::from_secs(1);
/// The longest wait between two passes.
pub const RECONNECT_WAIT_MAX: Duration = Duration::from_secs(30);
/// A pass that scanned is stable when it lived for this long.
pub const RECONNECT_STABLE_PASS: Duration = Duration::from_secs(30);

/// How one connection pass ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Pass {
    /// The pass got its wake streams and read the terminals of the session;
    /// its connection ended later.
    Scanned,
    /// The pass ended before it read the terminals: no connection, a refused
    /// manifest or a refused wake stream.
    NotScanned,
    /// The daemon closed the session: the loop ends.
    Done,
}

/// Runs connection passes until one is [`Pass::Done`]. `wait` blocks for the
/// time that it gets: [`RECONNECT_WAIT_MIN`] after a pass that scanned and
/// lived for [`RECONNECT_STABLE_PASS`], and 2 times the last wait, to
/// [`RECONNECT_WAIT_MAX`], after each other pass. `now` is a clock that only
/// goes up; the loop reads it at the start and at the end of each pass.
pub fn run_passes(
    mut pass: impl FnMut() -> Pass,
    mut wait: impl FnMut(Duration),
    mut now: impl FnMut() -> Duration,
) {
    let mut next = RECONNECT_WAIT_MIN;
    loop {
        let started = now();
        match pass() {
            Pass::Done => return,
            Pass::Scanned if now().saturating_sub(started) >= RECONNECT_STABLE_PASS => {
                next = RECONNECT_WAIT_MIN;
            }
            Pass::Scanned | Pass::NotScanned => {}
        }
        wait(next);
        next = next.saturating_mul(2).min(RECONNECT_WAIT_MAX);
    }
}
