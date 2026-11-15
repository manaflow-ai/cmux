//! The v2 gate rows of the design doc's row 2b: every `v2.pr02b.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

pub const ROWS: &[GateRow] = &[GateRow {
    pr: "2b",
    name: "v2.pr02b.translate_line_queue_full",
    done_when: "fold(a ++ b) == apply(fold(a), b) holds for the queue as for the rows, over 10k random splits. For every settled group in every interleaving, the rows in sight are the group row and out, nothing else. The state is inside its bound with 1,024 entries waiting.",
    measured: true,
    ratio: GOD_SMALL_LIMIT,
    ratio_all: None,
    god_max: None,
}];
