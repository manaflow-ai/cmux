//! The v2 gate rows of the design doc's row 2: every `v2.pr02.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

pub const ROWS: &[GateRow] = &[
    GateRow {
        pr: "2",
        name: "v2.pr02.translate_line",
        done_when: "Translate cost per line is at most 1.2x god against small.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "2",
        name: "v2.pr02.translate_line_full_state",
        done_when: "Translate cost with the bounded open state is at most 1.2x god against small.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "2",
        name: "v2.pr02.jsonl_peak_rss",
        done_when: "The 1.1 GB JSONL shape stays under 64 MB RSS and within 1.2x god against small.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
];
