//! The v2 gate rows of the design doc's row 3d: every `v2.pr03d.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

pub const ROWS: &[GateRow] = &[GateRow {
    pr: "3d",
    name: "v2.pr03d.turns_page",
    done_when: "One page of turns at the newest end of the god chat stays within 1.2x of one from the small chat, with the same reply.",
    measured: true,
    ratio: GOD_SMALL_LIMIT,
    ratio_all: Some(2.0),
    god_max: None,
}];
