//! The v2 gate rows of the design doc's row 5d: every `v2.pr05d.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

pub const ROWS: &[GateRow] = &[
    GateRow {
        pr: "5d",
        name: "v2.pr05d.origin_state_ops",
        done_when: "A peer down, stale and connected transition writes three origin records and no row operations; god 500 rows stays within 1.2x of 20.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5d",
        name: "v2.pr05d.removed_origin_batch",
        done_when: "Removing a peer with 500 rows emits one origin op and removes rows in bounded batches; god stays within 1.2x of 20.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5d",
        name: "v2.pr05d.submit_time",
        done_when: "One summary preparation and enqueue costs at most 1.2x at 11,000 live rows against 20; pooled god p95 stays within 2x.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
];
