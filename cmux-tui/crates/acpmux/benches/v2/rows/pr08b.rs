//! The v2 gate rows of the design doc's row 8b: every `v2.pr08b.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

pub const ROWS: &[GateRow] = &[GateRow {
    pr: "8b",
    name: "v2.pr08b.serve_page",
    done_when: "A peer's all page on the serving side (decisions 266 and 285), from the request to the frame: the newest page, the deepest full page, and the deepest full page read from a sorted snapshot, 20 rows of this machine each, with 20 live and 11,028 closed rows of its own against 20 live and 20 closed, a third machine's run of 500 live rows just before the last 20 closed on both sides, which the deep pages skip. 11,028 puts each snapshot piece's seek at the same place in its checkpoint's 256-record block as on the small side, so the seeks decode the same records (asserted outside the clock). p95 within 1.2x for each part, best round of ten, rounds alternate; the line carries the worse part's pair.",
    measured: true,
    ratio: GOD_SMALL_LIMIT,
    ratio_all: None,
    god_max: None,
}];
