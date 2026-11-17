//! The v2 gate rows of the design doc's row 5i: cold kin snapshot tables.

use super::super::GateRow;

pub const ROWS: &[GateRow] = &[GateRow {
    pr: "5i",
    name: "v2.pr05i.table_write",
    done_when: "Writing the optional cold kin sidecar at 11,000 rows stays within 1.5x of the same snapshot write without the table; the table has the fixture-implied entries and stays within 64 bytes per entry plus three pages.",
    measured: false,
    ratio: 1.5,
    ratio_all: None,
    god_max: None,
}];
