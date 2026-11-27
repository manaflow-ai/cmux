//! The v2 gate rows of the design doc's row 12: every `v2.pr12.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

pub const ROWS: &[GateRow] = &[GateRow {
    pr: "12",
    name: "v2.pr12.follow_driver_views",
    done_when: "Toggle 100 times mid-turn: one harness process throughout, no row lost or doubled.",
    measured: false,
    ratio: GOD_SMALL_LIMIT,
    ratio_all: None,
    god_max: None,
}];
