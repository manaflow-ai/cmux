//! The v2 gate rows of the design doc's row 3: every `v2.pr03.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

pub const ROWS: &[GateRow] = &[GateRow {
    pr: "3",
    name: "v2.pr03.chat_actor_killed_mid_turn",
    done_when: "The actor killed mid-turn 50 times: the replay settles every row once.",
    measured: false,
    ratio: GOD_SMALL_LIMIT,
    ratio_all: None,
    god_max: None,
}];
