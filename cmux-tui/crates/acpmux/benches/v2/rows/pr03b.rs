//! The v2 gate rows of the design doc's row 3b: every `v2.pr03b.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

pub const ROWS: &[GateRow] = &[
    GateRow {
        pr: "3b",
        name: "v2.pr03b.catchup_peak_rss",
        done_when: "The god chat caught up from nothing over the v1 source: the most bytes the actor's thread holds at once (the test allocator's count, over its first chunk's, in any stretch of the same length or at the end) within 1.2x of small, after one catch-up nobody measures; god's resident anonymous bytes grow at most 64 KiB from the stretch a quarter of the way through to its last (no small side: what the thread count cannot see); one chunk held, the bytes read within 1.2x of the log, and the book equal to what translate gives. Resident size's rise is printed, not gated: glibc's held free pages and rows.idx's page cache move it.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "3b",
        name: "v2.pr03b.tee_append_added",
        done_when: "The hook's time inside v1's append (write_record_locked), god home against small, books on, each chat's book caught up first: best p95 of five rounds 1.2x, every sample's p95 2x. Rounds alternate.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "3b",
        name: "v2.pr03b.append_on_off",
        done_when: "v1's append p95 in the god home with books on (god side) against off (small side): 1.2x, the hook's own time inside it. Rounds alternate.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "3b",
        name: "v2.pr03b.catchup_ack",
        done_when: "v1's ack p95 of an agent host's line (tap.rs append_logged(..).1) on a live chat while the god chat catches up from nothing, against the same with no catch-up: 1.2x. Rounds alternate.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
];
