//! The v2 gate rows of the design doc's row 7: every `v2.pr07.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

pub const ROWS: &[GateRow] = &[
    GateRow {
        pr: "7",
        name: "v2.pr07.mirror_connect_bytes",
        done_when: "The sidebar's mirror of the live view (`rows: \"v1\"`, 8 wanted closed keys) through the C entry points, 20 live on both sides and 11k closed beside them on god: bytes received on the list stream from connect to idle (`whole`), 1.2x.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "7",
        name: "v2.pr07.mirror_connect_rows_wall",
        done_when: "The same mirror and fixtures: connect to the last row delivered as a change, 1.2x, and under 200 ms.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: Some(200_000_000.0),
    },
];
