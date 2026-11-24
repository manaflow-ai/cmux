//! The v2 gate rows of the design doc's row 5i: cold kin snapshot tables.

use super::super::GateRow;

pub const ROWS: &[GateRow] = &[
    GateRow {
        pr: "5i",
        name: "v2.pr05i.table_write",
        done_when: "Writing the optional cold kin sidecar at 11,000 rows stays within 1.5x of the same snapshot write without the table; the table has the fixture-implied entries and stays within 64 bytes per entry plus three pages.",
        measured: false,
        ratio: 1.5,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "5i",
        name: "v2.pr05i.table_depth",
        done_when: "For 11,000 closed rows, four-way kin-table closure plus page time per entry stays within 1.2x of the flat fixture and stream time stays within 1.2x; both table headers report the expected entry counts.",
        measured: false,
        ratio: 1.2,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "5i",
        name: "v2.pr05i.cold_family_bytes",
        done_when: "A table-served cold family walk for eight kin (two under a cold parent) at 11,000 snapshot rows reads no more than 1.2x the physical bytes of the same walk at 20 rows.",
        measured: false,
        ratio: 1.2,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "5i",
        name: "v2.pr05i.cold_family",
        done_when: "A table-served cold family walk for eight kin at 11,000 snapshot rows has wall p95 within 1.2x the same walk at 20 rows; every cold page carries closure and no per-cold-row ask is needed.",
        measured: false,
        ratio: 1.2,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "5i",
        name: "v2.pr05i.cold_unread",
        done_when: "coldUnread for the last hot page of a family with no cold kin at 11,000 snapshot rows is false and has wall p95 within 1.2x the same table lookup at 20 rows.",
        measured: false,
        ratio: 1.2,
        ratio_all: None,
        god_max: None,
    },
];
