//! The v2 gate rows of the design doc's row 5: every `v2.pr05.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

pub const ROWS: &[GateRow] = &[
    GateRow {
        pr: "5",
        name: "v2.pr05.first_list_window",
        done_when: "First list window from a running hub: best p95 within 1.2x at 11,000 sessions against 20, all-sample p95 within 2x.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5",
        name: "v2.pr05.summary_change",
        done_when: "A summary change copies one tree path: best p95 within 3.7x, all-sample p95 within 6.2x, and god best p95 at most 10 microseconds.",
        measured: true,
        ratio: 3.7,
        ratio_all: Some(6.2),
        god_max: Some(10_000.0),
    },
];
