//! The v2 gate rows of the design doc's row 13: every `v2.pr13.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

pub const ROWS: &[GateRow] = &[GateRow {
    pr: "13",
    name: "v2.pr13.defaults_kill_list",
    done_when: "Every gate above green on god and small. Leo's nightly: a day of his use under 300 MB RSS, restart to steady under 20 s with zero movement.",
    measured: false,
    ratio: GOD_SMALL_LIMIT,
    ratio_all: None,
    god_max: None,
}];
