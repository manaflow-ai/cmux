//! The v2 gate rows of the design doc's row 5h: every `v2.pr05h.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

pub const ROWS: &[GateRow] = &[GateRow {
    pr: "5h",
    name: "v2.pr05h.hub_row_submit",
    done_when: "The tee's turn for one changed hub row (its mark drained to one submit) with 2,048 book rows and 11,000 closed rows against one book row and an empty index: p95 within 1.2x, the sides alternating rounds.",
    measured: false,
    ratio: GOD_SMALL_LIMIT,
    ratio_all: Some(2.0),
    god_max: None,
}];
