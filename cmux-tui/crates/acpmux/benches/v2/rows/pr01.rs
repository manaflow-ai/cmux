//! The v2 gate rows of the design doc's row 1: every `v2.pr01.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

pub const ROWS: &[GateRow] = &[
    GateRow {
        pr: "1",
        name: "v2.pr01.append_time",
        done_when: "Append is O(row): time per append within 1.2x at 2M rows against 40.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "1",
        name: "v2.pr01.append_bytes",
        done_when: "Append is O(row): bytes written per append within 1.2x at 2M rows against 40.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "1",
        name: "v2.pr01.first_window",
        done_when: "First window read (open, window and fill): under 5 ms, 1.2x at 2M rows against 40.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: Some(5_000_000.0),
    },
];
