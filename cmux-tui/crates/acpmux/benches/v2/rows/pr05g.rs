//! The v2 gate rows of the design doc's row 5g: every `v2.pr05g.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

pub const ROWS: &[GateRow] = &[
    GateRow {
        pr: "5g",
        name: "v2.pr05g.open_damage",
        done_when: "1,000 seeded random damages across snapshot heads, checkpoints, log generations and edition markers rebuild at open without a daemon failure and match a first start after the source walk.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5g",
        name: "v2.pr05g.rebuild_cost",
        done_when: "A rebuild walk costs at most 1.2x a first start at 11,000 sessions against 20.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
];
