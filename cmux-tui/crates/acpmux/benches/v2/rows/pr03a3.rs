//! The v2 gate rows of the design doc's row 3a3: every `v2.pr03a3.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

pub const ROWS: &[GateRow] = &[
    GateRow {
        pr: "3a3",
        name: "v2.pr03a3.actor_line",
        done_when: "One settled line through the actor at 40 rows and 2M rows: best p95 1.2x, aggregate p95 2x.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "3a3",
        name: "v2.pr03a3.checkpoint_open",
        done_when: "Open at the checkpoint reads no row suffix; at 40 rows and 2M rows best p95 1.2x, aggregate p95 2x.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
];
