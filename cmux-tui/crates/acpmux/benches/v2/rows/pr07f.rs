//! The v2 gate rows of the design doc's row 7f: every `v2.pr07f.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

pub const ROWS: &[GateRow] = &[
    GateRow {
        pr: "7f",
        name: "v2.pr07f.usage_request",
        done_when: "The bounded usage rank request (20 chats against 11k closed beside them): wall time within 1.2x against the same 20 alone; the no-walk counter is zero outside the clock.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "7f",
        name: "v2.pr07f.usage_request_bytes",
        done_when: "The bounded usage rank request (20 chats against 11k closed beside them): reply bytes within 1.2x against the same 20 alone.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
];
