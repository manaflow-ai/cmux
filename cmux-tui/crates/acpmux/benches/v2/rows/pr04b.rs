//! The v2 gate rows of the design doc's row 4b: every `v2.pr04b.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

pub const ROWS: &[GateRow] = &[GateRow {
    pr: "4b",
    name: "v2.pr04b.mirror_v1_rows",
    done_when: "A live mirror with rows: v1 converts 20 live rows with 11,000 closed rows beside them within 1.2x of 20 alone for received bytes and client time.",
    measured: true,
    ratio: GOD_SMALL_LIMIT,
    ratio_all: Some(2.0),
    god_max: None,
}];
