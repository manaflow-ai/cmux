//! Shared fixture and gate metadata for the agent-service v2 bench home.
//!
//! Every crate-local v2 gate writes one JSON object per measure when `V2_GATE_OUT` names a
//! file. The line format is `{"name":"v2.prNN.measure","small_p95":N,"god_p95":N,"unit":"ns"}`.
//! This home joins those files with the registry, computes the ratio and verdict, and prints the
//! JSON consumed by `quality-report.py --god-small`. A missing placeholder remains skipped; an
//! unknown name or a measured row with no input is an error.

use acpmux::god_fixture::Shape;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

/// The limit from the v2 design: god p95 may be at most this multiple of small p95.
pub const GOD_SMALL_LIMIT: f64 = 1.2;

#[derive(Clone, Copy, Debug)]
pub struct GateRow {
    pub pr: &'static str,
    pub name: &'static str,
    pub done_when: &'static str,
    pub measured: bool,
    pub ratio: f64,
    pub ratio_all: Option<f64>,
    /// Maximum god p95 in the measure's unit.
    pub god_max: Option<f64>,
}

/// One row for every measure a gate writes, and one placeholder for each PR whose gates have not
/// landed. A done-when line that a test holds (a kill at every byte, a wrong magic) has no row.
pub const GATE_ROWS: &[GateRow] = &[
    GateRow {
        pr: "1",
        name: "v2.pr01.append_time",
        done_when: "Append is O(row): time per append within 1.2x at 2M rows against 40.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "1",
        name: "v2.pr01.append_bytes",
        done_when: "Append is O(row): bytes written per append within 1.2x at 2M rows against 40.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "1",
        name: "v2.pr01.first_window",
        done_when: "First window read (open, window and fill): under 5 ms, 1.2x at 2M rows against 40.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: Some(5_000_000.0),
    },
    GateRow {
        pr: "1b",
        name: "v2.pr01b.cold_first_append",
        done_when: "PR 1's gates still pass with the record layout: the first append to a book just opened within 1.2x at 2M rows against 40.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "1b",
        name: "v2.pr01b.torn_open",
        done_when: "Work at open 1.2x, 2M rows against 40: an open that cuts off a torn record.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "2",
        name: "v2.pr02.translate_line",
        done_when: "Translate cost per line is at most 1.2x god against small.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "2",
        name: "v2.pr02.translate_line_full_state",
        done_when: "Translate cost with the bounded open state is at most 1.2x god against small.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "2",
        name: "v2.pr02.jsonl_peak_rss",
        done_when: "The 1.1 GB JSONL shape stays under 64 MB RSS and within 1.2x god against small.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "2b",
        name: "v2.pr02b.translate_line_queue_full",
        done_when: "fold(a ++ b) == apply(fold(a), b) holds for the queue as for the rows, over 10k random splits. For every settled group in every interleaving, the rows in sight are the group row and out, nothing else. The state is inside its bound with 1,024 entries waiting.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "3",
        name: "v2.pr03.chat_actor_window_resume",
        done_when: "First window within 50 ms of sub, 1.2x. Resume from a cursor costs O(missed). RSS with the god chat subscribed within 1.2x of small. An append that waits behind a cold page read: its wait 1.2x, god against small. The actor killed mid-turn 50 times: the replay settles every row once.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "3c",
        name: "v2.pr03c.fold_window",
        done_when: "A window at the end of a chat whose last turn folded 100,000 rows stays within 1.2x of one folded 10 rows, with the same reply size.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "3c",
        name: "v2.pr03c.blob_range",
        done_when: "A bounded 256 KB range of a 100 MB body stays within 1.2x of one from a 300 KB body, for settled and open bodies.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "3a3",
        name: "v2.pr03a3.actor_line",
        done_when: "One settled line through the actor at 40 rows and 2M rows: best p95 1.2x, aggregate p95 2x.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "3a3",
        name: "v2.pr03a3.checkpoint_open",
        done_when: "Open at the checkpoint reads no row suffix; at 40 rows and 2M rows best p95 1.2x, aggregate p95 2x.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "3a",
        name: "v2.pr03a.source_read_bounds",
        done_when: "A 1 GB growth reads one chunk and holds reads one byte at 40 rows and 2M rows. A 10 MB line appended in 100 pieces is read once when its newline arrives.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "3b",
        name: "v2.pr03b.catchup_peak_rss",
        done_when: "The god chat caught up from nothing over the v1 source: peak RSS within 1.2x of small (stretches of the same length, malloc_trim(0) before the baseline), one chunk held, the bytes read within 1.2x of the log, and the book equal to what translate gives.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "4",
        name: "v2.pr04.byte_credit_drop_resume",
        done_when: "1 GB of events to a stopped reader: RSS stays under the connection budget; the reader resumes with no row lost or repeated.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "4",
        name: "v2.pr04.credit_without_read_drop",
        done_when: "A reader that sends credit without reading gets dropped on that sid; the connection stays up and another sid remains ordered.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "4",
        name: "v2.pr04.offer_256_subscriptions",
        done_when: "Offering one frame to 256 subscriptions costs at most 1.2x the one-subscription case.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "4",
        name: "v2.pr04.list_resume_end",
        done_when: "A list resume that missed nothing ends with one empty end frame, and no live op precedes the end mark.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "4",
        name: "v2.pr04.not_fed_bytes",
        done_when: "A subscriber that is not fed retains zero frame bytes through the god run.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "4",
        name: "v2.pr04.chat_stopped_reader",
        done_when: "Chat stopped-reader resume is measured after PR 3c wires chat actors into the connection.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "4b",
        name: "v2.pr04b.bytes_held",
        done_when: "With one frame of changes waiting while the daemon sends 1 GB, the client holds no more than one frame of bytes.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "4b",
        name: "v2.pr04b.credit_slow_taker",
        done_when: "A caller taking one change per 10 ms stays within one credit window of uncredited daemon bytes, sees replay frames and an end, and converges to the hub's rows.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "4b",
        name: "v2.pr04b.mirror_v1_rows",
        done_when: "A live mirror with rows: v1 converts 20 live rows with 11,000 closed rows beside them within 1.2x of 20 alone for received bytes and client time.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "5",
        name: "v2.pr05.first_list_window",
        done_when: "First list window from a running hub: best p95 within 1.2x at 11,000 sessions against 20, all-sample p95 within 2x.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5",
        name: "v2.pr05.summary_change",
        done_when: "A summary change copies one tree path: best p95 within 3.7x, all-sample p95 within 6.2x, and god best p95 at most 10 microseconds.",
        measured: true,
        ratio: 3.7,
        ratio_all: Some(6.2),
        god_max: Some(10_000.0),
    },
    GateRow {
        pr: "5b",
        name: "v2.pr05b.start_first_window",
        done_when: "From exec to the first list window out of the snapshot: under 200 ms at 11,000 sessions, 1.2x against 20.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: Some(200_000_000.0),
    },
    GateRow {
        pr: "5b",
        name: "v2.pr05b.start_rss",
        done_when: "Bounded list storage: start rss, measured at 20 and 11,000 sessions.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5b",
        name: "v2.pr05b.hot_rss",
        done_when: "Cold rows leave the hot maps at startup and compaction install; retained RSS at 11,000 stays within 1.2x of 20 at the same writer phase.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5b",
        name: "v2.pr05b.apply_during_compaction",
        done_when: "At 11,000 sessions, the complete writer turn during compaction stays within 1.2x of outside compaction, including group sync and install.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5b",
        name: "v2.pr05b.page_first",
        done_when: "Bounded list storage: page first, measured at 20 and 11,000 sessions.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5b",
        name: "v2.pr05b.page_first_bytes",
        done_when: "Physical page first bytes include all seeks: 15.4x (256/20 rows per block), at most 64 KiB plus 19 fixture rows of at most 160 bytes (decision 110).",
        measured: true,
        ratio: 15.4,
        ratio_all: None,
        god_max: Some((64 * 1024 + 19 * 160) as f64),
    },
    GateRow {
        pr: "5b",
        name: "v2.pr05b.page_first_filter",
        done_when: "Bounded list storage: page first filter, measured at 20 and 11,000 sessions.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5b",
        name: "v2.pr05b.page_middle",
        done_when: "Bounded list storage: page middle, measured at 20 and 11,000 sessions.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5b",
        name: "v2.pr05b.page_middle_bytes",
        done_when: "Physical page middle bytes include all seeks: 15.4x (256/20 rows per block), at most 64 KiB plus 9 fixture rows of at most 160 bytes (decision 110).",
        measured: true,
        ratio: 15.4,
        ratio_all: None,
        god_max: Some((64 * 1024 + 9 * 160) as f64),
    },
    GateRow {
        pr: "5b",
        name: "v2.pr05b.page_middle_filter",
        done_when: "Bounded list storage: page middle filter, measured at 20 and 11,000 sessions.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5b",
        name: "v2.pr05b.page_last",
        done_when: "True last-key page: 14.9x best, 24.8x all-sample, and 400 microseconds; the derived bound accounts for different terminal stride phases (decision 110).",
        measured: true,
        ratio: 14.9,
        ratio_all: Some(24.8),
        god_max: Some(400_000.0),
    },
    GateRow {
        pr: "5b",
        name: "v2.pr05b.page_last_bytes",
        done_when: "Physical page last bytes include all seeks: 15.4x (256/20 rows per block), at most 64 KiB plus 0 fixture rows of at most 160 bytes (decision 110).",
        measured: true,
        ratio: 15.4,
        ratio_all: None,
        god_max: Some((64 * 1024) as f64),
    },
    GateRow {
        pr: "5b",
        name: "v2.pr05b.page_last_filter",
        done_when: "True last-key page: 14.9x best, 24.8x all-sample, and 400 microseconds; the derived bound accounts for different terminal stride phases (decision 110).",
        measured: true,
        ratio: 14.9,
        ratio_all: Some(24.8),
        god_max: Some(400_000.0),
    },
    GateRow {
        pr: "5c",
        name: "v2.pr05c.tee_change",
        done_when: "A v1 list-changing update reaches the v2 index with one mark and one summary op within 1.2x against 20 sessions.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5c",
        name: "v2.pr05c.stream_chunk",
        done_when: "100,000 streamed text chunks produce zero tee marks and keep append p95 within 1.2x of v1 without the tee.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5c",
        name: "v2.pr05c.walk_rss",
        done_when: "The startup reconciliation walk's RSS at 11,000 sessions stays within one page of the 20-session run.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5c",
        name: "v2.pr05c.live_view",
        done_when: "The live view pages 20 live chats through 11,000 sessions within 1.2x and tracks close/reopen state changes.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5c",
        name: "v2.pr05c.keyed_page",
        done_when: "A keyed page of 100 closed chats returns provider rows and missing/unknown keys within 1.2x at 11,000 sessions.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5c",
        name: "v2.pr05c.replay_frame",
        done_when: "A full 1 MiB ring replay uses frames no larger than 256 KiB, each ending at an operation boundary.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: Some((256 * 1024) as f64),
    },
    GateRow {
        pr: "5c",
        name: "v2.pr05c.replay_append",
        done_when: "Writer append p95 during a full ring replay stays within 1.2x of append with no replay.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5c",
        name: "v2.pr05c.replay_open_hold",
        done_when: "An append overlapping the open copy of a full ring replay stays under 1 ms p95.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: Some(1_000_000.0),
    },
    GateRow {
        pr: "5c",
        name: "v2.pr05c.single_encode",
        done_when: "A change sent to 100 list subscribers is encoded once, with no subscriber-side deep clone or re-encode.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: Some(1.0),
    },
    GateRow {
        pr: "5e",
        name: "v2.pr05e.kin_table_change",
        done_when: "A parent move path-copies tables at 20 versus 11,000 hot rows; unchanged relations write zero paths.",
        measured: true,
        ratio: 3.7,
        ratio_all: Some(6.2),
        god_max: Some(10_000.0),
    },
    GateRow {
        pr: "5e",
        name: "v2.pr05e.folder_change",
        done_when: "A folder move path-copies tables at 20 versus 11,000 hot rows.",
        measured: true,
        ratio: 3.7,
        ratio_all: Some(6.2),
        god_max: Some(10_000.0),
    },
    GateRow {
        pr: "5e",
        name: "v2.pr05e.sibling_insert",
        done_when: "A parent with 5,000 children gains one against a parent with five, under the tree-height bound.",
        measured: true,
        ratio: 6.350435609064215,
        ratio_all: Some(10.58405934844036),
        god_max: Some(10_000.0),
    },
    GateRow {
        pr: "5e",
        name: "v2.pr05e.family_page",
        done_when: "The same first page of 50 hot descendants over four depths with 20 versus 11,000 unrelated rows reads at most limit plus one.",
        measured: true,
        ratio: 1.2,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5e",
        name: "v2.pr05e.family_page_after",
        done_when: "The same anchored family page and cursor depth with 20 versus 11,000 unrelated rows reads at most limit plus one plus the bounded climb.",
        measured: true,
        ratio: 1.2,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5e",
        name: "v2.pr05e.folder_page",
        done_when: "The same page of 50 folder rows with 20 versus 11,000 unrelated rows reads at most limit plus one.",
        measured: true,
        ratio: 1.2,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5e",
        name: "v2.pr05e.random_replay",
        done_when: "After 10,000 randomized starts, forks, moves, closes, residency transitions and deletes, tables equal a fresh build from hot rows.",
        measured: true,
        ratio: 1.2,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "5e",
        name: "v2.pr05e.cold_continuation",
        done_when: "An explicit cold folder walk progresses through every candidate with each request inside the sparse-read and 256 KiB bounds.",
        measured: true,
        ratio: 15.4,
        ratio_all: None,
        god_max: Some(256.0 * 1024.0),
    },
    GateRow {
        pr: "5f",
        name: "v2.pr05f.apply_newest",
        done_when: "A chat made newest in its folder is a persistent path copy: at 2,000 folders against 5, tree-rule ratio 5.7, all-sample ratio 9.4, and under 10 microseconds.",
        measured: true,
        ratio: 5.7,
        ratio_all: Some(9.4),
        god_max: Some(10_000.0),
    },
    GateRow {
        pr: "5g",
        name: "v2.pr05g.open_damage",
        done_when: "1,000 seeded random damages across snapshot heads, checkpoints, log generations and edition markers rebuild at open without a daemon failure and match a first start after the source walk.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5g",
        name: "v2.pr05g.rebuild_cost",
        done_when: "A rebuild walk costs at most 1.2x a first start at 11,000 sessions against 20.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5f",
        name: "v2.pr05f.apply_move",
        done_when: "A chat moved between folders copies two persistent paths: at 2,000 folders against 5, tree-rule ratio 5.7, all-sample ratio 9.4, and under 10 microseconds.",
        measured: true,
        ratio: 5.7,
        ratio_all: Some(9.4),
        god_max: Some(10_000.0),
    },
    GateRow {
        pr: "5f",
        name: "v2.pr05f.first_window",
        done_when: "The first folders window stays within 1.2x at 2,000 folders against 5.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5f",
        name: "v2.pr05f.deep_page",
        done_when: "A deep folders page stays within 1.2x at 2,000 folders against 5.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5f",
        name: "v2.pr05f.serving_window",
        done_when: "The folders serving window returns three rows within 1.2x at 2,000 folders against 5, with pooled samples within 2x.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5f",
        name: "v2.pr05f.serving_page",
        done_when: "A deep folders page returning three rows stays within 1.2x at 2,000 folders against 5, with pooled samples within 2x.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5f",
        name: "v2.pr05f.equal_entry",
        done_when: "An equal folder entry produces zero folder operations.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "5f",
        name: "v2.pr05f.tail_replay",
        done_when: "A live folders sid reads 100 retained steps within 1.2x at 2,000 folders against 5, with pooled samples within 2x.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5d",
        name: "v2.pr05d.origin_state_ops",
        done_when: "A peer down, stale and connected transition writes three origin records and no row operations; god 500 rows stays within 1.2x of 20.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5d",
        name: "v2.pr05d.removed_origin_batch",
        done_when: "Removing a peer with 500 rows emits one origin op and removes rows in bounded batches; god stays within 1.2x of 20.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5d",
        name: "v2.pr05d.submit_time",
        done_when: "One summary preparation and enqueue costs at most 1.2x at 11,000 live rows against 20; pooled god p95 stays within 2x.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
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
    GateRow {
        pr: "7",
        name: "v2.pr07.sidebar_list_stream",
        done_when: "No \"Waiting for the agent service\" frame while the socket is up. Sidebar scroll frame time 1.2x at 11k against 20.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "7b",
        name: "v2.pr07b.info_rows_wall",
        done_when: "100 rows by key (`_acpmux/info` with `sessionIds`): wall time within 1.2x with 11k closed beside them against the same 100 alone.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "7b",
        name: "v2.pr07b.info_rows_bytes",
        done_when: "100 rows by key (`_acpmux/info` with `sessionIds`): reply bytes within 1.2x with 11k closed beside them against the same 100 alone.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "8",
        name: "v2.pr08.reconnect_30",
        done_when: "30 link clients with a subscription and a saved cursor reconnect at once at 11k chats and 500 live, in two storms: to the daemon they left, nothing missed (one empty frame marked end to each), and to a restarted daemon whose new peer store has every saved cursor under its floor (a window to each). RSS rise under 20 MB over a trimmed baseline in both. A peak row: only the absolute bound applies.",
        measured: true,
        ratio: f64::INFINITY,
        ratio_all: None,
        god_max: Some(20.0 * 1024.0 * 1024.0),
    },
    GateRow {
        pr: "8",
        name: "v2.pr08.v1_ack_peers_on_off",
        done_when: "v1's ack p95 on 30 links during the reconnect, peers on against off: 1.2x, rounds alternating.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "8",
        name: "v2.pr08.fanout_30",
        done_when: "One local change to 30 peer subscribers, submit to the last link's slot, 11k chats and 500 live against 20 live: 1.2x. Encoded once, zero secret scans and zero extra parses (counters).",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "9",
        name: "v2.pr09.chat_actor_start",
        done_when: "Listen within 100 ms of exec and a prompt accepted within 50 ms, with 527 chats and a 4 GB store, 1.2x against one small chat.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "10",
        name: "v2.pr10.stop_exit_socket_handoff",
        done_when: "Stop under 1 s with 200 requests in flight and a stuck agent host, 50 runs. Restart gap seen by a client under 1 s.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "11",
        name: "v2.pr11.act_send_rows",
        done_when: "Daemon killed mid-send 50 times: zero lost and zero doubled prompts.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "12",
        name: "v2.pr12.follow_driver_views",
        done_when: "Toggle 100 times mid-turn: one harness process throughout, no row lost or doubled.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "13",
        name: "v2.pr13.defaults_kill_list",
        done_when: "Every gate above green on god and small. Leo's nightly: a day of his use under 300 MB RSS, restart to steady under 20 s with zero movement.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
];

pub fn god() -> Shape {
    let mut shape = Shape::god();
    shape.chats = 527;
    shape.peers = 30;
    shape
}

pub fn small() -> Shape {
    Shape::small()
}

fn shape_json(shape: Shape) -> Value {
    json!({ "name": shape.name, "chats": shape.chats, "god_messages": shape.god_messages, "god_bytes": shape.god_bytes,
        "chat_messages": shape.chat_messages, "peers": shape.peers, "peer_rows": shape.peer_rows, "row_keys": shape.row_keys })
}

#[derive(Debug, Clone)]
struct Measure {
    name: String,
    small_p95: f64,
    god_p95: f64,
    god_p95_all: Option<f64>,
    unit: Option<String>,
}

fn registered_names() -> HashSet<&'static str> {
    GATE_ROWS.iter().map(|row| row.name).collect()
}

fn parse_measure(value: Value, source: &Path) -> Result<Measure, String> {
    let object =
        value.as_object().ok_or_else(|| format!("{source:?}: measure is not a JSON object"))?;
    let name = object
        .get("name")
        .and_then(Value::as_str)
        .ok_or_else(|| format!("{source:?}: measure has no name"))?;
    let small_p95 = object
        .get("small_p95")
        .and_then(Value::as_f64)
        .ok_or_else(|| format!("{source:?}: {name} has no numeric small_p95"))?;
    let god_p95 = object
        .get("god_p95")
        .and_then(Value::as_f64)
        .ok_or_else(|| format!("{source:?}: {name} has no numeric god_p95"))?;
    if !small_p95.is_finite() || small_p95 < 0.0 || !god_p95.is_finite() || god_p95 < 0.0 {
        return Err(format!("{source:?}: {name} has invalid p95 values"));
    }
    let god_p95_all = object
        .get("god_p95_all")
        .map(|value| {
            value
                .as_f64()
                .filter(|value| value.is_finite() && *value >= 0.0)
                .ok_or_else(|| format!("{source:?}: {name} has invalid god_p95_all"))
        })
        .transpose()?;
    let unit = object
        .get("unit")
        .and_then(Value::as_str)
        .filter(|unit| !unit.is_empty())
        .ok_or_else(|| format!("{source:?}: {name} has no unit"))?;
    Ok(Measure {
        name: name.to_string(),
        small_p95,
        god_p95,
        god_p95_all,
        unit: Some(unit.to_string()),
    })
}

fn read_measures(paths: &[PathBuf]) -> Result<Vec<Measure>, String> {
    let mut measures = Vec::new();
    for path in paths {
        let text = fs::read_to_string(path).map_err(|e| format!("{path:?}: {e}"))?;
        for (line_no, line) in text.lines().enumerate() {
            if line.trim().is_empty() {
                continue;
            }
            let value =
                serde_json::from_str(line).map_err(|e| format!("{path:?}:{line_no}: {e}"))?;
            measures.push(parse_measure(value, path)?);
        }
    }
    Ok(measures)
}

fn merge_measures(
    measures: &[Measure],
    required: &[&str],
) -> Result<HashMap<String, Measure>, String> {
    let names = registered_names();
    let mut joined = HashMap::new();
    for measure in measures {
        if !names.contains(measure.name.as_str()) {
            return Err(format!("unknown v2 gate row {}", measure.name));
        }
        let row = GATE_ROWS
            .iter()
            .find(|row| row.name == measure.name)
            .ok_or_else(|| format!("unknown v2 gate row {}", measure.name))?;
        if row.ratio_all.is_some() && measure.god_p95_all.is_none() {
            return Err(format!("{} requires god_p95_all", measure.name));
        }
        if joined.insert(measure.name.clone(), measure.clone()).is_some() {
            return Err(format!("duplicate v2 gate row {}", measure.name));
        }
    }
    for name in required {
        if !joined.contains_key(*name) {
            return Err(format!("registered v2 gate row {name} was not reported"));
        }
    }
    Ok(joined)
}

fn measured_row(row: &GateRow, measure: &Measure) -> Value {
    let ratio = if measure.small_p95 == 0.0 {
        if measure.god_p95 == 0.0 { 1.0 } else { f64::INFINITY }
    } else {
        measure.god_p95 / measure.small_p95
    };
    let ratio_all = measure.god_p95_all.map(|value| value / measure.small_p95);
    let failures = [
        (ratio > row.ratio, "god p95 exceeds the row's ratio"),
        (
            row.ratio_all.is_some_and(|limit| ratio_all.is_none_or(|value| value > limit)),
            "god all-sample p95 exceeds the row's ratio_all",
        ),
        (
            row.god_max.is_some_and(|limit| measure.god_p95 > limit),
            "god p95 exceeds the row's absolute maximum",
        ),
    ];
    let reasons: Vec<_> =
        failures.into_iter().filter_map(|(failed, reason)| failed.then_some(reason)).collect();
    let ok = reasons.is_empty();
    json!({ "name": row.name, "pr": row.pr, "done_when": row.done_when,
        "status": if ok { "ok" } else { "red" },
        "reason": if ok { "within the row's bounds".to_owned() } else { reasons.join("; ") },
        "small_p95": measure.small_p95, "god_p95": measure.god_p95,
        "god_p95_all": measure.god_p95_all, "ratio": ratio, "ratio_all": ratio_all,
        "limit": row.ratio, "limit_all": row.ratio_all, "god_max": row.god_max, "unit": measure.unit })
}

fn merge_for_report(
    measures: &[Measure],
    required: &[&str],
) -> Result<(HashMap<String, Measure>, Vec<String>), String> {
    let names = registered_names();
    let mut joined = HashMap::new();
    for measure in measures {
        if !names.contains(measure.name.as_str()) {
            return Err(format!("unknown v2 gate row {}", measure.name));
        }
        let row = GATE_ROWS
            .iter()
            .find(|row| row.name == measure.name)
            .ok_or_else(|| format!("unknown v2 gate row {}", measure.name))?;
        if row.ratio_all.is_some() && measure.god_p95_all.is_none() {
            return Err(format!("{} requires god_p95_all", measure.name));
        }
        if joined.insert(measure.name.clone(), measure.clone()).is_some() {
            return Err(format!("duplicate v2 gate row {}", measure.name));
        }
    }
    let missing = required
        .iter()
        .copied()
        .filter(|name| !joined.contains_key(*name))
        .map(str::to_owned)
        .collect();
    Ok((joined, missing))
}

fn report_value(
    measure_files: &[PathBuf],
    measures_requested: bool,
) -> Result<(Value, bool), String> {
    let required =
        GATE_ROWS.iter().filter(|row| row.measured).map(|row| row.name).collect::<Vec<_>>();
    let measures = read_measures(measure_files)?;
    let (measures, missing) =
        merge_for_report(&measures, if measures_requested { &required } else { &[] })?;
    let missing_set: HashSet<_> = missing.iter().map(String::as_str).collect();
    let rows = GATE_ROWS.iter().map(|row| {
        if let Some(measure) = measures.get(row.name) {
            measured_row(row, measure)
        } else if row.measured && measures_requested && missing_set.contains(row.name) {
            json!({ "name": row.name, "pr": row.pr, "done_when": row.done_when,
                "status": "failed", "reason": "the gate did not report a measure",
                "small_p95": Value::Null, "god_p95": Value::Null })
        } else if row.measured {
            json!({ "name": row.name, "pr": row.pr, "done_when": row.done_when,
                "status": "not_run", "reason": "the spec check did not request gate measures",
                "small_p95": Value::Null, "god_p95": Value::Null })
        } else {
            json!({ "name": row.name, "pr": row.pr, "done_when": row.done_when, "status": "skipped", "reason": format!("PR {} implementation has not landed; turn on {} by this name", row.pr, row.name), "small_p95": Value::Null, "god_p95": Value::Null })
        }
    }).collect::<Vec<_>>();
    Ok((
        json!({ "schema": 1, "name": "acpmux-agent-service-v2", "comparison": "god-vs-small", "god_small_limit": GOD_SMALL_LIMIT, "fixtures": { "small": shape_json(small()), "god": shape_json(god()) }, "rows": rows }),
        !missing.is_empty(),
    ))
}

/// Build the nightly-report JSON when measures are required.
pub fn report(measure_files: &[PathBuf]) -> Result<Value, String> {
    let (value, missing) = report_value(measure_files, true)?;
    if missing {
        Err("one or more measured v2 gate rows did not report a measure".to_owned())
    } else {
        Ok(value)
    }
}

pub fn validate_measure_files(measure_files: &[PathBuf], required: &[&str]) -> Result<(), String> {
    merge_measures(&read_measures(measure_files)?, required).map(|_| ())
}

pub fn print_report(measure_files: &[PathBuf], output: Option<&Path>) -> Result<(), String> {
    print_report_with_mode(measure_files, output, true)
}

pub fn print_report_with_mode(
    measure_files: &[PathBuf],
    output: Option<&Path>,
    measures_requested: bool,
) -> Result<(), String> {
    let (value, missing) = report_value(measure_files, measures_requested)?;
    let text = serde_json::to_string(&value).map_err(|e| e.to_string())?;
    if let Some(path) = output {
        fs::write(path, format!("{text}\n")).map_err(|e| format!("{path:?}: {e}"))?;
    } else {
        println!("{text}");
    }
    if missing {
        Err("one or more measured v2 gate rows did not report a measure".to_owned())
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A row of a PR whose other rows are written, held for a gate a later PR adds.
    const WAITS_ON_ANOTHER_PR: &[&str] = &["v2.pr04.chat_stopped_reader"];

    /// A gate name as a source spells it. A `{..}` hole is a name built by `format!`.
    const NAME_IN_SOURCE: &str = r"v2\.pr[0-9]+[a-z]?\.(?:[a-z0-9_]|\{[^{}]*\})+";

    fn rust_sources(dir: &Path, found: &mut Vec<PathBuf>) {
        let entries = fs::read_dir(dir).unwrap_or_else(|e| panic!("{dir:?}: {e}"));
        for entry in entries {
            let path = entry.unwrap_or_else(|e| panic!("{dir:?}: {e}")).path();
            if path.is_dir() {
                rust_sources(&path, found);
            } else if path.extension().is_some_and(|extension| extension == "rs") {
                found.push(path);
            }
        }
    }

    /// Every gate name the acpmux crates' sources hold, with the file that holds it. This file is
    /// left out: its rows are what the names are checked against. `v2.pr99` is the made-up PR
    /// the report's own tests use.
    fn names_in_sources() -> Vec<(String, PathBuf)> {
        let crates = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap().to_path_buf();
        let registry = Path::new(env!("CARGO_MANIFEST_DIR")).join("benches/v2/mod.rs");
        let mut files = Vec::new();
        for entry in fs::read_dir(&crates).unwrap() {
            let path = entry.unwrap().path();
            let is_ours = path
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("acpmux"));
            for part in ["src", "tests", "benches"] {
                if is_ours && path.join(part).is_dir() {
                    rust_sources(&path.join(part), &mut files);
                }
            }
        }
        let pattern = regex::Regex::new(NAME_IN_SOURCE).unwrap();
        let mut names = Vec::new();
        for file in files {
            if file == registry {
                continue;
            }
            let text = fs::read_to_string(&file).unwrap_or_else(|e| panic!("{file:?}: {e}"));
            for found in pattern.find_iter(&text) {
                if !found.as_str().starts_with("v2.pr99.") {
                    names.push((found.as_str().to_owned(), file.clone()));
                }
            }
        }
        names
    }

    /// Whether a source's name is this row's: equal, or a `format!` whose holes fit.
    fn spells(in_source: &str, row: &str) -> bool {
        if !in_source.contains('{') {
            return in_source == row;
        }
        let hole = regex::Regex::new(r"\\\{[^{}]*\\\}").unwrap();
        let escaped = regex::escape(in_source);
        regex::Regex::new(&format!("^{}$", hole.replace_all(&escaped, "[a-z0-9_]+")))
            .unwrap()
            .is_match(row)
    }

    #[test]
    fn every_gate_name_in_a_source_has_a_registry_row() {
        let names = names_in_sources();
        assert!(names.len() >= 20, "the scan read too few gate names: {names:?}");
        for (name, file) in &names {
            assert!(
                GATE_ROWS.iter().any(|row| spells(name, row.name)),
                "{file:?} names the gate {name}, and the registry has no row for it"
            );
        }
    }

    #[test]
    fn a_pr_that_writes_a_row_has_no_placeholder_left() {
        let names = names_in_sources();
        let written = |row: &GateRow| names.iter().any(|(name, _)| spells(name, row.name));
        for row in GATE_ROWS {
            if written(row) {
                continue;
            }
            assert!(!row.measured, "{} is marked measured and no source writes it", row.name);
            let pr_writes = GATE_ROWS.iter().any(|other| other.pr == row.pr && written(other));
            assert!(
                !pr_writes || WAITS_ON_ANOTHER_PR.contains(&row.name),
                "PR {} writes its rows and no source writes {}: remove the placeholder",
                row.pr,
                row.name
            );
        }
    }

    #[test]
    fn a_format_built_name_fits_only_its_own_rows() {
        assert!(spells("v2.pr05b.page_{label}_bytes", "v2.pr05b.page_first_bytes"));
        assert!(!spells("v2.pr05b.page_{label}_bytes", "v2.pr05b.page_first"));
        assert!(!spells("v2.pr05b.page_{label}", "v2.pr05b.hot_rss"));
        assert!(spells("v2.pr01.append_time", "v2.pr01.append_time"));
        assert!(!spells("v2.pr01.append", "v2.pr01.append_time"));
    }

    fn change_row() -> &'static GateRow {
        GATE_ROWS.iter().find(|row| row.name == "v2.pr05.summary_change").unwrap()
    }

    fn sample(small: f64, god: f64, all: Option<f64>) -> Measure {
        Measure {
            name: change_row().name.to_owned(),
            small_p95: small,
            god_p95: god,
            god_p95_all: all,
            unit: Some("ns".to_owned()),
        }
    }

    #[test]
    fn summary_change_uses_each_of_its_own_bounds() {
        let row = change_row();
        assert_eq!(measured_row(row, &sample(1800.0, 3470.0, Some(5000.0)))["status"], "ok");
        assert_eq!(measured_row(row, &sample(1000.0, 3701.0, Some(5000.0)))["status"], "red");
        assert_eq!(measured_row(row, &sample(1000.0, 3000.0, Some(6201.0)))["status"], "red");
        assert_eq!(measured_row(row, &sample(10000.0, 10001.0, Some(10001.0)))["status"], "red");
    }

    #[test]
    fn best_of_rounds_rows_require_the_all_sample_measure() {
        assert!(
            merge_measures(&[sample(1000.0, 3000.0, None)], &[])
                .unwrap_err()
                .contains("requires god_p95_all")
        );
        assert!(merge_measures(&[sample(1000.0, 3000.0, Some(5000.0))], &[]).is_ok());
    }

    #[test]
    fn page_byte_rows_enforce_block_ratio_and_absolute_read_budget() {
        for name in ["first", "middle", "last"] {
            let row = GATE_ROWS
                .iter()
                .find(|row| row.name == format!("v2.pr05b.page_{name}_bytes"))
                .unwrap();
            let measure = |small, god| Measure {
                name: row.name.to_owned(),
                small_p95: small,
                god_p95: god,
                god_p95_all: None,
                unit: Some("bytes".to_owned()),
            };
            assert_eq!(measured_row(row, &measure(4000.0, 47_870.0))["status"], "ok");
            assert_eq!(measured_row(row, &measure(1000.0, 15_401.0))["status"], "red");
            let maximum = row.god_max.unwrap();
            assert_eq!(measured_row(row, &measure(10_000.0, maximum))["status"], "ok");
            assert_eq!(measured_row(row, &measure(10_000.0, maximum + 1.0))["status"], "red");
        }
    }

    #[test]
    fn terminal_page_rows_enforce_phase_ratio_and_absolute_time_budget() {
        for name in ["v2.pr05b.page_last", "v2.pr05b.page_last_filter"] {
            let row = GATE_ROWS.iter().find(|row| row.name == name).unwrap();
            assert_eq!(
                measured_row(row, &sample(1000.0, 14_900.0, Some(24_800.0)))["status"],
                "ok"
            );
            assert_eq!(
                measured_row(row, &sample(1000.0, 14_901.0, Some(24_800.0)))["status"],
                "red"
            );
            assert_eq!(
                measured_row(row, &sample(1000.0, 14_900.0, Some(24_801.0)))["status"],
                "red"
            );
            assert_eq!(
                measured_row(row, &sample(100_000.0, 400_001.0, Some(400_001.0)))["status"],
                "red"
            );
        }
    }

    #[test]
    fn parser_rejects_invalid_optional_all_sample_values() {
        for invalid in [json!(-1), json!("not a number"), Value::Null] {
            let value = json!({"name": change_row().name, "small_p95": 1,
                "god_p95": 1, "god_p95_all": invalid, "unit": "ns"});
            assert!(parse_measure(value, Path::new("fixture")).is_err());
        }
    }
}

#[cfg(test)]
mod zero_baseline_tests {
    use super::*;

    #[test]
    fn missing_nightly_measure_is_named_as_a_failure() {
        let (value, missing) = report_value(&[], true).unwrap();
        assert!(missing);
        assert!(report(&[]).is_err());
        let rows = value["rows"].as_array().unwrap();
        let row = rows.iter().find(|row| row["name"] == "v2.pr01.append_time").unwrap();
        assert_eq!(row["status"], "failed");
        assert_eq!(row["reason"], "the gate did not report a measure");
    }

    #[test]
    fn the_spec_run_marks_measured_rows_not_run_without_input() {
        let (value, missing) = report_value(&[], false).unwrap();
        assert!(!missing);
        let rows = value["rows"].as_array().unwrap();
        assert!(rows.iter().any(|row| row["status"] == "not_run"));
        assert!(!rows.iter().any(|row| row["status"] == "ok"));
    }

    fn zero_measure(god: f64) -> Value {
        let row = GATE_ROWS.first().unwrap();
        let measure = parse_measure(
            json!({"name":row.name,"small_p95":0,"god_p95":god,"unit":"bytes"}),
            Path::new("zero-test"),
        )
        .unwrap();
        let joined = merge_measures(&[measure], &[row.name]).unwrap();
        measured_row(row, joined.get(row.name).unwrap())
    }
    #[test]
    fn zero_at_both_sizes_is_in_bound() {
        let row = zero_measure(0.0);
        assert_eq!(row.get("status"), Some(&json!("ok")));
        assert_eq!(row.get("ratio"), Some(&json!(1.0)));
    }
    #[test]
    fn zero_small_and_nonzero_god_is_red() {
        assert_eq!(zero_measure(1.0).get("status"), Some(&json!("red")));
    }
}
