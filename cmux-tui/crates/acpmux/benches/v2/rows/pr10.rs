//! The v2 gate rows of the design doc's row 10: every `v2.pr10.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

pub const ROWS: &[GateRow] = &[GateRow {
    pr: "10",
    name: "v2.pr10.stop_exit_socket_handoff",
    done_when: "Stop under 1 s with 200 requests in flight and a stuck agent host, 50 runs. Restart gap seen by a client under 1 s.",
    measured: false,
    ratio: GOD_SMALL_LIMIT,
    ratio_all: None,
    god_max: None,
}];
