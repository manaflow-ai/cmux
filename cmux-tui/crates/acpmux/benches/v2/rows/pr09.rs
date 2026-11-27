//! The v2 gate rows of the design doc's row 9: every `v2.pr09.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

pub const ROWS: &[GateRow] = &[GateRow {
    pr: "9",
    name: "v2.pr09.chat_actor_start",
    done_when: "Listen within 100 ms of exec and a prompt accepted within 50 ms, with 527 chats and a 4 GB store, 1.2x against one small chat.",
    measured: false,
    ratio: GOD_SMALL_LIMIT,
    ratio_all: None,
    god_max: None,
}];
