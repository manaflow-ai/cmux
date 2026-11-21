//! The v2 gate rows of the design doc's row 3c: every `v2.pr03c.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

pub const ROWS: &[GateRow] = &[
    GateRow {
        pr: "3c",
        name: "v2.pr03c.fold_window",
        done_when: "A window at the end of a chat whose last turn folded 100,000 rows stays within 1.2x of one folded 10 rows, with the same reply size.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "3c",
        name: "v2.pr03c.blob_range",
        done_when: "A bounded 256 KB range of a 100 MB body stays within 1.2x of one from a 300 KB body, for settled and open bodies.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "3c",
        name: "v2.pr03c.window_folds",
        done_when: "A window at the end of a chat of 100,000 folded turns, against 10: 1.2x. Window time and reads of folds.idx (one search a read, at both sizes). The same rows in the window on both sides.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "3c",
        name: "v2.pr03c.first_window",
        done_when: "First `window` within 50 ms of `sub`, 1.2x. From `sub` on a cold chat to the window taken by the handle; cold on both sides, the book's lock free.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: Some(50_000_000.0),
    },
    GateRow {
        pr: "3c",
        name: "v2.pr03c.resume_missed",
        done_when: "Resume from a cursor costs O(missed). The same records missed on both sides; time and bytes read.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "3c",
        name: "v2.pr03c.subscribed_rss",
        done_when: "RSS with the god chat subscribed within 1.2x of small. The same largest input on both sides, the rise read against a counter of bytes held, `malloc_trim(0)` before the baseline.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "3c",
        name: "v2.pr03c.append_behind_page",
        done_when: "An append that waits behind a cold `page` read: its wait 1.2x on the best p95 of five rounds, as each sample holds a cold read, and 2x on the p95 of all samples. Runs of their own, alternated. The cold segment read is paid on both sides; bytes read and minor faults printed beside the time. Sampled in a child process whose allocator keeps fixed thresholds, so an actor arena's trim (faults that follow the thread, not the chat's length) is not read as god's cost.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "3c",
        name: "v2.pr03c.queue_window",
        done_when: "A window with 64 prompts of 100 KB waiting, against 64 of 16 KB (the head read's bound, so both sides fill each head's one read and both windows carry the same bytes), each on a cold actor: 1.2x. Window time and bytes read. A probe prints the 1 KB and 1 MB sides.",
        // Best p95 time ratio 0.984, 0.965 and 0.945 in three runs, bytes read 1.000; the probe
        // (`queue_window_sizes_probe`) has 1 MB within 1.013 of 16 KB on time and 1.000 on bytes.
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "3c",
        name: "v2.pr03c.prompt_blob_next",
        done_when: "The last 256 KB of a waiting prompt of 100 MB, read on by `next`, against 300 KB: 1.2x. Per request, from a `next` token; the 1 MiB scan bound is a counter test.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
];
