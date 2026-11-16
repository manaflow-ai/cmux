//! The v2 gate rows of the design doc's row 6: every `v2.pr06.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

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
    // Measured by the web bench harness (webviews/bench/page-row-store.bench.ts), which the Linux
    // gate script does not run.
    GateRow {
        pr: "6c",
        name: "v2.pr06.page_store_apply",
        done_when: "p95 for the page's row store to take one batch holding one settled row op: a chat of 100,000 rows within 1.2x of one of 100, rounds alternating, the same samples a side.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "6c",
        name: "v2.pr06.page_store_text",
        done_when: "p95 for the page's row store to take one batch holding one text op on an open row whose body is 200 KB, within 1.2x of one whose body is 1 KB.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "6c",
        name: "v2.pr06.page_store_held",
        done_when: "The rows and row bytes the page's row store holds after paging through a chat of 20,000 rows against one of 200: at the store's cap or under it.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
];
