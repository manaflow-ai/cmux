//! The v2 gate rows of the design doc's row 3a: every `v2.pr03a.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

pub const ROWS: &[GateRow] = &[GateRow {
    pr: "3a",
    name: "v2.pr03a.source_read_bounds",
    done_when: "A 1 GB growth reads one chunk and holds reads one byte at 40 rows and 2M rows. A 10 MB line appended in 100 pieces is read once when its newline arrives.",
    measured: true,
    ratio: GOD_SMALL_LIMIT,
    ratio_all: None,
    god_max: None,
}];
