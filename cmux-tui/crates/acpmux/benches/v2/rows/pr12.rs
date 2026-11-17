//! The v2 gate rows of the design doc's row 12: every `v2.pr12.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

pub const ROWS: &[GateRow] = &[
    GateRow {
        pr: "12",
        name: "v2.pr12.follow_driver_views",
        done_when: "Toggle 100 times mid-turn: one harness process throughout, no row lost or doubled.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "12",
        name: "v2.pr12.follow_append",
        done_when: "A caught-up follow appends one transcript line with read_chunk p95 within 1.2x.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "12",
        name: "v2.pr12.follow_scan_bytes",
        done_when: "Chunked partial-tail follow scans each byte once and accounts the one completed-line reread.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "12",
        name: "v2.pr12.follow_read_at",
        done_when: "A fixed-size followed-source body slice stays bounded and within 1.2x at god history.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
];
