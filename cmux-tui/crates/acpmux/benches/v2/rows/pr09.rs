//! The v2 gate rows of the design doc's row 9: every `v2.pr09.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

pub const ROWS: &[GateRow] = &[GateRow {
    pr: "9",
    name: "v2.pr09.listen_start",
    done_when: "Listener ready within 100 ms of exec; god fixture is 527 chats with a 4 GB store.",
    measured: true,
    ratio: GOD_SMALL_LIMIT,
    ratio_all: None,
    god_max: Some(100_000_000.0),
}];
