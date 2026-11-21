//! The v2 gate rows of the design doc's row 1b: every `v2.pr01b.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

pub const ROWS: &[GateRow] = &[
    GateRow {
        pr: "1b",
        name: "v2.pr01b.cold_first_append",
        done_when: "PR 1's gates still pass with the record layout: the first append to a book just opened within 1.2x at 2M rows against 40.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "1b",
        name: "v2.pr01b.torn_open",
        done_when: "Work at open 1.2x, 2M rows against 40: an open that cuts off a torn record.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
];
