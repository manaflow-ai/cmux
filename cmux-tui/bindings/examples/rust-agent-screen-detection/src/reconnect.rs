//! The scanner's reconnect loop: one connection pass, a wait, the next pass.
//!
//! This file uses the standard library only: a test of the cmux-tui
//! workspace compiles it too (`crates/cmux-tui/tests/detector_reconnect.rs`)
//! and counts the passes with a clock of its own.

use std::time::Duration;

/// The wait between two connection passes.
pub const RECONNECT_INTERVAL: Duration = Duration::from_secs(1);

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
/// time that it gets.
pub fn run_passes(mut pass: impl FnMut() -> Pass, mut wait: impl FnMut(Duration)) {
    loop {
        if pass() == Pass::Done {
            return;
        }
        wait(RECONNECT_INTERVAL);
    }
}
