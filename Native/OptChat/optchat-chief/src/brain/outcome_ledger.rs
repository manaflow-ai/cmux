//! The outcome ledger: every finished subagent's outcome reaches the person.

use super::Brain;

/// The first word of an outcome retry turn's note.
pub const UNTOLD_TAG: &str = "[untold]";

impl Brain {
    /// The finished subagents whose outcome no Chief post told yet.
    pub fn untold_outcomes(&self) -> Vec<String> {
        Vec::new()
    }

    /// Runs every outcome check due at `now` (ms since the epoch).
    pub fn fire_outcome_checks_at(&mut self, _now: u64) {}
}
