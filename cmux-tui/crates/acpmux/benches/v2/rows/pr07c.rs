//! The v2 gate rows of the design doc's row 7c: every `v2.pr07c.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

pub const ROWS: &[GateRow] = &[
    GateRow {
        pr: "7c",
        name: "v2.pr07c.update_plan_bytes",
        done_when: "the agent update plan's thread counts (cmux-tui-core), bytes received: 20 live chats with 11k closed beside them against 20 live alone, 1.2x.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    // Best round, with every sample's p95 beside it: a round is 20 runs over a socket (about
    // 0.6 ms each), and a shared runner's one slow round is not the list's.
    GateRow {
        pr: "7c",
        name: "v2.pr07c.update_plan_wall",
        done_when: "the agent update plan's thread counts (cmux-tui-core), wall time: 20 live chats with 11k closed beside them against 20 live alone, best p95 of five rounds 1.2x, every sample's p95 2x.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
];
