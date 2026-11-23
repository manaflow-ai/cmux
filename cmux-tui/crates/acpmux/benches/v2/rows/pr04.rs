//! The v2 gate rows of the design doc's row 4: every `v2.pr04.*` measure.

use super::super::{GOD_SMALL_LIMIT, GateRow};

pub const ROWS: &[GateRow] = &[
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
        done_when: "A chat stream to a stopped reader: RSS under the connection budget, and it resumes with no row lost or repeated. Peak row: small streams 16 MiB and god 1 GiB, each resets its mark before its last 8 MiB, the rise less the baseline; the two sides sample stretches of the same length.",
        measured: true,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
];
