//! The effort of each model call the Chief makes. Taelin runs the master on
//! Claude Opus 5.5 at medium ("opus 5.5 medium is the one I use, it scores
//! better"), and the spec runs the compactor at medium (section 4.2). acpmux
//! maps `effort` onto Claude Code's `--effort` and codex's
//! `reasoning_effort`; both take `medium`.

use crate::acpmux::Family;

/// The default effort of turns on both engines.
pub const TURN_EFFORT: &str = "medium";

/// The acpmux turn sessions' effort: `set` (`OPTCHAT_CHIEF_EFFORT`), else
/// `TURN_EFFORT` on a Claude or codex harness; a harness of another family
/// keeps its own default (its effort names are not known here).
pub fn turn_effort(set: Option<String>, family: Family) -> Option<String> {
    set.or(match family {
        Family::Claude | Family::Codex => Some(TURN_EFFORT.to_owned()),
        Family::Other => None,
    })
}

/// The native engine's `output_config.effort`: `set`
/// (`OPTCHAT_CHIEF_EFFORT`), else `TURN_EFFORT`.
pub fn native_effort(set: Option<String>) -> String {
    set.unwrap_or_else(|| TURN_EFFORT.to_owned())
}
