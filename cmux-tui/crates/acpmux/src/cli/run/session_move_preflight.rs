//! The move's read-only preflight: whether its turn runs and its checkout is dirty, so a caller
//! can offer Move after this turn (`--after-turn`) or Move now (`--interrupt`).

use super::{Value, plan};
use serde::Serialize;

/// Present even on refusal, so a caller can ask about the turn and checkout together.
/// Unknown dirt stays null when the checkout could not be inspected.
#[derive(Default, Serialize)]
pub(super) struct Preflight {
    pub running: bool,
    pub dirty: Option<bool>,
}

pub(super) fn session_refusal_code(info: &Value, interrupt: bool) -> Option<&'static str> {
    (plan::refusal(info, true).is_none() && plan::running(info) && !interrupt)
        .then_some("running_turn")
}

#[cfg(test)]
#[path = "session_move_preflight_tests.rs"]
mod tests;
