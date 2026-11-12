//! Shared fixture and gate metadata for the agent-service v2 bench home.
//!
//! W0 owns the actual god and small homes in [`acpmux::god_fixture`].  This module gives every
//! later v2 bench one place to describe the pair and one stable row name for the nightly report.
//! A row is skipped until its owning PR provides both p95 measurements; the quality report still
//! retains the named row, so a missing gate cannot look like an absent gate.

use acpmux::god_fixture::Shape;
use serde_json::{Value, json};

/// The limit from the v2 design: god p95 may be at most this multiple of small p95.
pub const GOD_SMALL_LIMIT: f64 = 1.2;

/// One done-when line in the v2 PR sequence and its stable quality-report row name.
#[derive(Clone, Copy, Debug)]
pub struct RequiredGodWorkload {
    pub chats: u32,
    pub peers: u32,
}

#[derive(Clone, Copy, Debug)]
pub struct GateRow {
    pub pr: u8,
    pub name: &'static str,
    pub done_when: &'static str,
    /// Workload required by the done-when line, which may be larger than W0's canonical fixture.
    pub required_god: Option<RequiredGodWorkload>,
}

/// The thirteen rows that PR 0 reserves for PRs 1 through 13.
pub const GATE_ROWS: [GateRow; 13] = [
    GateRow {
        pr: 1,
        name: "v2.pr01.book_append_window_recovery",
        done_when: "Append is O(row): bytes written and time per append within 1.2x at 40 rows and 2M rows. First window read under 5 ms, 1.2x. Recovery after a kill at every byte of a record loses nothing settled.",
        required_god: None,
    },
    GateRow {
        pr: 2,
        name: "v2.pr02.translate_properties_and_cost",
        done_when: "fold(a ++ b) == apply(fold(a), b) over 10k random splits. Final reply visible in every interleaving. Translate cost per line 1.2x. The 1.1 GB JSONL shape translates in bounded memory (under 64 MB).",
        required_god: None,
    },
    GateRow {
        pr: 3,
        name: "v2.pr03.chat_actor_window_resume",
        done_when: "First window within 50 ms of sub, 1.2x. Resume from a cursor costs O(missed). RSS with the god chat subscribed within 1.2x of small. An append that waits behind a cold page read: its wait 1.2x, god against small. The actor killed mid-turn 50 times: the replay settles every row once.",
        required_god: None,
    },
    GateRow {
        pr: 4,
        name: "v2.pr04.byte_credit_drop_resume",
        done_when: "1 GB of events to a stopped reader: RSS stays under the connection budget; the reader resumes with no row lost or repeated.",
        required_god: None,
    },
    GateRow {
        pr: 5,
        name: "v2.pr05.index_list_stream",
        done_when: "First list window within 200 ms of listen with 11k sessions, 1.2x against 20. One summary change costs O(1): no work proportional to the list.",
        required_god: None,
    },
    GateRow {
        pr: 6,
        name: "v2.pr06.thin_store_geometry",
        done_when: "DOM mutation probe on open: blank to settled and nothing else. Zero visible-row shifts not caused by input, across open, reconnect, restart and page-up. Scroll-up settle 1.2x.",
        required_god: None,
    },
    GateRow {
        pr: 7,
        name: "v2.pr07.sidebar_list_stream",
        done_when: "No \"Waiting for the agent service\" frame while the socket is up. Sidebar scroll frame time 1.2x at 11k against 20.",
        required_god: None,
    },
    GateRow {
        pr: 8,
        name: "v2.pr08.peers_list_subscribers",
        done_when: "30 peers reconnecting at once: RSS rise under 20 MB, ack p95 unchanged. Zero whole-list parses (a counter).",
        required_god: Some(RequiredGodWorkload { chats: 525, peers: 30 }),
    },
    GateRow {
        pr: 9,
        name: "v2.pr09.chat_actor_start",
        done_when: "Listen within 100 ms of exec and a prompt accepted within 50 ms, with 527 chats and a 4 GB store, 1.2x against one small chat.",
        required_god: Some(RequiredGodWorkload { chats: 527, peers: 26 }),
    },
    GateRow {
        pr: 10,
        name: "v2.pr10.stop_exit_socket_handoff",
        done_when: "Stop under 1 s with 200 requests in flight and a stuck agent host, 50 runs. Restart gap seen by a client under 1 s.",
        required_god: None,
    },
    GateRow {
        pr: 11,
        name: "v2.pr11.act_send_rows",
        done_when: "Daemon killed mid-send 50 times: zero lost and zero doubled prompts.",
        required_god: None,
    },
    GateRow {
        pr: 12,
        name: "v2.pr12.follow_driver_views",
        done_when: "Toggle 100 times mid-turn: one harness process throughout, no row lost or doubled.",
        required_god: None,
    },
    GateRow {
        pr: 13,
        name: "v2.pr13.defaults_kill_list",
        done_when: "Every gate above green on god and small. Leo's nightly: a day of his use under 300 MB RSS, restart to steady under 20 s with zero movement.",
        required_god: None,
    },
];

fn shape_json(shape: Shape) -> Value {
    json!({
        "name": shape.name,
        "chats": shape.chats,
        "god_messages": shape.god_messages,
        "god_bytes": shape.god_bytes,
        "chat_messages": shape.chat_messages,
        "peers": shape.peers,
        "peer_rows": shape.peer_rows,
        "row_keys": shape.row_keys,
    })
}

/// The JSON consumed by `quality-report.py --god-small` and by S1's gate runner.
pub fn report() -> Value {
    let rows = GATE_ROWS
        .iter()
        .map(|row| {
            json!({
                "name": row.name,
                "pr": row.pr,
                "done_when": row.done_when,
                "status": "skipped",
                "reason": format!("PR {} implementation has not landed; turn on {} by this name", row.pr, row.name),
                "small_p95": Value::Null,
                "god_p95": Value::Null,
                "required_god_workload": row.required_god.map(|workload| json!({
                    "chats": workload.chats,
                    "peers": workload.peers,
                })),
            })
        })
        .collect::<Vec<_>>();

    json!({
        "schema": 1,
        "name": "acpmux-agent-service-v2",
        "comparison": "god-vs-small",
        "god_small_limit": GOD_SMALL_LIMIT,
        "fixtures": {
            "small": shape_json(Shape::small()),
            "god": shape_json(Shape::god()),
        },
        "rows": rows,
    })
}

pub fn print_report() {
    println!("{}", report());
}
