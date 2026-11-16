use super::background_cause::Causes;
use std::collections::VecDeque;

/// One running background turn.
#[derive(Debug, Clone)]
pub struct Running {
    pub id: String,
    pub trigger: &'static str,
    pub text: String,
    /// Its reply outgrew [`TEXT_KEPT`]: not quiet, whatever the kept part says.
    pub long: bool,
    /// A permission or structured question needs the person's attention.
    pub attention: bool,
}

/// A session's background-turn state, read and written by its tap.
#[derive(Debug, Default)]
pub struct BackgroundTurns {
    /// What the next `system/init` with no acpmux turn was started by, if a line said so.
    pub hint: Option<&'static str>,
    /// A `system/init` with no acpmux turn came, and what started it: the turn starts at its
    /// first word or tool call (a harness that only says `system/init`, as at its start, ran
    /// none).
    pub pending: Option<(&'static str, u64)>,
    pub running: Option<Running>,
    /// Reply message ids of background turns, newest last.
    pub messages: VecDeque<String>,
    /// The tasks started and the notifications heard: a turn's `cause`.
    pub causes: Causes,
    /// An adopted host's replay is being read while the chat's log has an acpmux turn open
    /// ([`Hub::hold_adopted_turn`]): its model work is that turn's, which adoption rebuilds
    /// only once the replay is in the log, never a turn the person did not start.
    pub adopted_turn: bool,
}
