//! The clock of a turn's compaction bound (`SETTLE_BOUND`): when the bound
//! starts (the message reaches the brain) and how long the turn worker has
//! waited. Injected with `Brain::with_turn_clock`, so a test moves time
//! itself and never measures a real wait.

use std::time::Instant;

/// Where a turn's settle bound reads the time.
pub trait TurnClock: Send + Sync {
    /// The time now.
    fn now(&self) -> Instant;
}

/// Real time (the default).
#[derive(Clone, Copy, Debug, Default)]
pub struct SystemTurnClock;

impl TurnClock for SystemTurnClock {
    fn now(&self) -> Instant {
        Instant::now()
    }
}
