//! The v2 gate rows of the design doc's row 6: every `v2.pr06.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

/// The page row store's caps, written as webviews/src/agent-session/acpmux/rows/store.ts writes
/// its `STORE_MAX_ROWS` and `STORE_MAX_BYTES`; the registry test
/// `the_page_store_caps_match_the_store` reads that file and fails when they part.
pub const STORE_MAX_ROWS: f64 = 1_600.0;
pub const STORE_MAX_BYTES: f64 = (4 * 256 * 1024) as f64;

pub const ROWS: &[GateRow] = &[
    GateRow {
        pr: "6e",
        name: "v2.pr06.hold_attach",
        done_when: "A hold attach on the god chat costs at most 1.2x the same hold attach on the small chat, without reading the chat log.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "6a",
        name: "v2.pr06.client_chat_held",
        done_when: "Bytes the client core holds for one chat sub after its window and 10,000 deltas: a chat of 100,000 rows with a 1 MB open row within 1.2x of a chat of 100 rows.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "6a",
        name: "v2.pr06.client_chat_change",
        done_when: "p95 from `received` to `next_change` for one settled row of the same size: the god chat within 1.2x of the small one, rounds alternating, the same samples a side.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    // Measured by the pane host's Swift bench (CmuxNextDaemonTests AcpmuxChatRowsBench) in the
    // fleet build's package test step (`scripts/ci/package-test-lane.sh suite
    // Packages/macOS/CmuxNext AcpmuxChatRows`), which the Linux gate script does not run.
    GateRow {
        pr: "6b",
        name: "v2.pr06.host_chat_change",
        done_when: "p95 from the socket's bytes to the page receiver for one settled row, with the pane host's handle on a chat of 100,000 rows against one of 100: within 1.2x, rounds alternating, the same samples a side.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "6",
        name: "v2.pr06.thin_store_geometry",
        done_when: "DOM mutation probe on open: blank to settled and nothing else. Zero visible-row shifts not caused by input, across open, reconnect, restart and page-up. Scroll-up settle 1.2x.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    // Measured by webviews/bench/page-row-store.bench.ts, which the gate script's `page` group runs
    // a row at a time through webviews/bench/v2-gate.ts (lines in v2-gates.d/pr06.gates).
    GateRow {
        pr: "6c",
        name: "v2.pr06.page_store_apply",
        done_when: "p95 for the page's row store to take one batch holding one settled row op: a chat of 100,000 rows within 1.2x of one of 100, rounds alternating, the same samples a side.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "6c",
        name: "v2.pr06.page_store_text",
        done_when: "p95 for the page's row store to take one batch holding one text op on an open row whose body is 200 KB, within 1.2x of one whose body is 1 KB.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "6c",
        name: "v2.pr06.page_store_held",
        done_when: "The rows and row bytes the page's row store holds after paging through a chat of 20,000 rows against one of 200: at the store's cap or under it. Peak bytes, both sides measured: 9.6x (the god store may hold STORE_MAX_ROWS = 1,600 rows against the small store's 200, 1,600 / 200 x 1.2), at most STORE_MAX_BYTES (1 MiB).",
        // Rows over STORE_MAX_ROWS, a small store that did not hold its 200 rows, or a god store
        // that never reached the cap fail the line's run (webviews/bench/v2-gate.ts), which marks
        // it red.
        measured: true,
        ratio: STORE_MAX_ROWS / 200.0 * GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: Some(STORE_MAX_BYTES),
    },
];
