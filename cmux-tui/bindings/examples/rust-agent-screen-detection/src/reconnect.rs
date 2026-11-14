//! The scanner's reconnect loop: one connection pass, a wait, the next pass.
//!
//! A pass that scanned nothing (no socket, a refused manifest, a refused wake
//! stream) costs the daemon a connection and its requests, so the wait
//! doubles after each such pass, from 1 second to 30 seconds. A pass that
//! scanned puts the wait back to 1 second.
//!
//! This file uses the standard library only: a test of the cmux-tui
//! workspace compiles it too (`crates/cmux-tui/tests/detector_reconnect.rs`)
//! and counts the passes with a clock of its own.

use std::time::Duration;

/// The wait after a pass that scanned, and the first wait of the loop.
pub const RECONNECT_WAIT_MIN: Duration = Duration::from_secs(1);
/// The longest wait between two passes.
pub const RECONNECT_WAIT_MAX: Duration = Duration::from_secs(30);

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
/// time that it gets: [`RECONNECT_WAIT_MIN`] after a pass that scanned, and
/// 2 times the last wait, to [`RECONNECT_WAIT_MAX`], after each pass that
/// did not.
pub fn run_passes(mut pass: impl FnMut() -> Pass, mut wait: impl FnMut(Duration)) {
    let mut next = RECONNECT_WAIT_MIN;
    loop {
        match pass() {
            Pass::Done => return,
            Pass::Scanned => next = RECONNECT_WAIT_MIN,
            Pass::NotScanned => {}
        }
        wait(next);
        next = next.saturating_mul(2).min(RECONNECT_WAIT_MAX);
    }
}
