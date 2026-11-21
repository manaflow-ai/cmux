//! The v2 gate rows of the design doc's row 11: every `v2.pr11.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

pub const ROWS: &[GateRow] = &[GateRow {
    pr: "11",
    name: "v2.pr11.act_send_rows",
    done_when: "Daemon killed mid-send 50 times: zero lost and zero doubled prompts.",
    measured: false,
    ratio: GOD_SMALL_LIMIT,
    ratio_all: None,
    god_max: None,
}];
