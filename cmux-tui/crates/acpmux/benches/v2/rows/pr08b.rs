//! The v2 gate rows of the design doc's row 8b: every `v2.pr08b.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

pub const ROWS: &[GateRow] = &[GateRow {
    pr: "8b",
    name: "v2.pr08b.serve_page",
    done_when: "A peer's all page on the serving side (decision 266), from the request to the frame: the newest page and the deepest full page of this machine's rows, 20 rows each, with 20 live and 11,000 closed rows of its own against 20 live and 20 closed, both behind a third machine's run of 500 live rows the page skips. p95 within 1.2x for each, best round of ten, rounds alternate.",
    measured: false,
    ratio: GOD_SMALL_LIMIT,
    ratio_all: None,
    god_max: None,
}];
