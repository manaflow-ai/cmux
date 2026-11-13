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
}

/// One placeholder for every done-when line in the current v2 design table.
pub const GATE_ROWS: &[GateRow] = &[
    GateRow {
        pr: "1",
        name: "v2.pr01.book_append_window_recovery",
        done_when: "Append is O(row): bytes written and time per append within 1.2x at 40 rows and 2M rows. First window read under 5 ms, 1.2x. Recovery after a kill at every byte of a record loses nothing settled.",
        measured: false,
    },
    GateRow {
        pr: "1b",
        name: "v2.pr01b.record_layout",
        done_when: "PR 1's gates still pass. An index entry with no record is cleared at open and its row settles once on replay. A kill at every byte around a raw.map line leaves no record naming a file the map lacks. A wrong magic or unknown version opens to the rebuild error. Work at open 1.2x, 2M rows against 40.",
        measured: false,
    },
    GateRow {
        pr: "2",
        name: "v2.pr02.translate_properties_and_cost",
        done_when: "fold(a ++ b) == apply(fold(a), b) over 10k random splits. Final reply visible in every interleaving. Translate cost per line 1.2x. The 1.1 GB JSONL shape translates in bounded memory (under 64 MB).",
        measured: false,
    },
    GateRow {
        pr: "2b",
        name: "v2.pr02b.translate_line_queue_full",
        done_when: "fold(a ++ b) == apply(fold(a), b) holds for the queue as for the rows, over 10k random splits. For every settled group in every interleaving, the rows in sight are the group row and out, nothing else. The state is inside its bound with 1,024 entries waiting.",
        measured: false,
    },
    GateRow {
        pr: "3",
        name: "v2.pr03.chat_actor_window_resume",
        done_when: "First window within 50 ms of sub, 1.2x. Resume from a cursor costs O(missed). RSS with the god chat subscribed within 1.2x of small. An append that waits behind a cold page read: its wait 1.2x, god against small. The actor killed mid-turn 50 times: the replay settles every row once.",
        measured: false,
    },
    GateRow {
        pr: "4",
        name: "v2.pr04.byte_credit_drop_resume",
        done_when: "1 GB of events to a stopped reader: RSS stays under the connection budget; the reader resumes with no row lost or repeated.",
        measured: false,
    },
    GateRow {
        pr: "4",
        name: "v2.pr04.credit_without_read_drop",
        done_when: "A reader that sends credit without reading gets dropped on that sid; the connection stays up and another sid remains ordered.",
        measured: false,
    },
    GateRow {
        pr: "4",
        name: "v2.pr04.offer_256_subscriptions",
        done_when: "Offering one frame to 256 subscriptions costs at most 1.2x the one-subscription case.",
        measured: false,
    },
    GateRow {
        pr: "4",
        name: "v2.pr04.list_resume_end",
        done_when: "A list resume that missed nothing ends with one empty end frame, and no live op precedes the end mark.",
        measured: false,
    },
    GateRow {
        pr: "4",
        name: "v2.pr04.not_fed_bytes",
        done_when: "A subscriber that is not fed retains zero frame bytes through the god run.",
        measured: false,
    },
    GateRow {
        pr: "4",
        name: "v2.pr04.chat_stopped_reader",
        done_when: "Chat stopped-reader resume is measured after PR 3c wires chat actors into the connection.",
        measured: false,
    },
    GateRow {
        pr: "5",
        name: "v2.pr05.index_list_stream",
        done_when: "First list window within 200 ms of listen with 11k sessions, 1.2x against 20. One summary change costs O(1): no work proportional to the list.",
        measured: false,
    },
    GateRow {
        pr: "5b",
        name: "v2.pr05b.start_first_window",
        done_when: "From exec to the first list window out of the snapshot: under 200 ms at 11,000 sessions, 1.2x against 20.",
        measured: false,
    },
    GateRow {
        pr: "6",
        name: "v2.pr06.thin_store_geometry",
        done_when: "DOM mutation probe on open: blank to settled and nothing else. Zero visible-row shifts not caused by input, across open, reconnect, restart and page-up. Scroll-up settle 1.2x.",
        measured: false,
    },
    GateRow {
        pr: "7",
        name: "v2.pr07.sidebar_list_stream",
        done_when: "No \"Waiting for the agent service\" frame while the socket is up. Sidebar scroll frame time 1.2x at 11k against 20.",
        measured: false,
    },
    GateRow {
        pr: "8",
        name: "v2.pr08.peers_list_subscribers",
        done_when: "30 peers reconnecting at once: RSS rise under 20 MB, ack p95 unchanged. Zero whole-list parses (a counter).",
        measured: false,
    },
    GateRow {
        pr: "9",
        name: "v2.pr09.chat_actor_start",
        done_when: "Listen within 100 ms of exec and a prompt accepted within 50 ms, with 527 chats and a 4 GB store, 1.2x against one small chat.",
        measured: false,
    },
    GateRow {
        pr: "10",
        name: "v2.pr10.stop_exit_socket_handoff",
        done_when: "Stop under 1 s with 200 requests in flight and a stuck agent host, 50 runs. Restart gap seen by a client under 1 s.",
        measured: false,
    },
    GateRow {
        pr: "11",
        name: "v2.pr11.act_send_rows",
        done_when: "Daemon killed mid-send 50 times: zero lost and zero doubled prompts.",
        measured: false,
    },
    GateRow {
        pr: "12",
        name: "v2.pr12.follow_driver_views",
        done_when: "Toggle 100 times mid-turn: one harness process throughout, no row lost or doubled.",
        measured: false,
    },
    GateRow {
        pr: "13",
        name: "v2.pr13.defaults_kill_list",
        done_when: "Every gate above green on god and small. Leo's nightly: a day of his use under 300 MB RSS, restart to steady under 20 s with zero movement.",
        measured: false,
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
    if !small_p95.is_finite() || small_p95 <= 0.0 || !god_p95.is_finite() || god_p95 < 0.0 {
        return Err(format!("{source:?}: {name} has invalid p95 values"));
    }
    let unit = object
        .get("unit")
        .and_then(Value::as_str)
        .filter(|unit| !unit.is_empty())
        .ok_or_else(|| format!("{source:?}: {name} has no unit"))?;
    Ok(Measure { name: name.to_string(), small_p95, god_p95, unit: Some(unit.to_string()) })
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

/// Build the nightly-report JSON. `--measures` is optional while all rows are placeholders.
pub fn report(measure_files: &[PathBuf]) -> Result<Value, String> {
    let required =
        GATE_ROWS.iter().filter(|row| row.measured).map(|row| row.name).collect::<Vec<_>>();
    let measures = merge_measures(&read_measures(measure_files)?, &required)?;
    let rows = GATE_ROWS.iter().map(|row| {
        if let Some(measure) = measures.get(row.name) {
            let ratio = measure.god_p95 / measure.small_p95;
            json!({ "name": row.name, "pr": row.pr, "done_when": row.done_when, "status": if ratio <= GOD_SMALL_LIMIT { "ok" } else { "red" }, "reason": if ratio <= GOD_SMALL_LIMIT { "within 1.2x god/small" } else { "god p95 exceeds 1.2x small p95" }, "small_p95": measure.small_p95, "god_p95": measure.god_p95, "ratio": ratio, "unit": measure.unit })
        } else if row.measured {
            unreachable!("measured rows are checked before rendering")
        } else {
            json!({ "name": row.name, "pr": row.pr, "done_when": row.done_when, "status": "skipped", "reason": format!("PR {} implementation has not landed; turn on {} by this name", row.pr, row.name), "small_p95": Value::Null, "god_p95": Value::Null })
        }
    }).collect::<Vec<_>>();
    Ok(
        json!({ "schema": 1, "name": "acpmux-agent-service-v2", "comparison": "god-vs-small", "god_small_limit": GOD_SMALL_LIMIT, "fixtures": { "small": shape_json(small()), "god": shape_json(god()) }, "rows": rows }),
    )
}

pub fn validate_measure_files(measure_files: &[PathBuf], required: &[&str]) -> Result<(), String> {
    merge_measures(&read_measures(measure_files)?, required).map(|_| ())
}

pub fn print_report(measure_files: &[PathBuf], output: Option<&Path>) -> Result<(), String> {
    let text = serde_json::to_string(&report(measure_files)?).map_err(|e| e.to_string())?;
    if let Some(path) = output {
        fs::write(path, format!("{text}\n")).map_err(|e| format!("{path:?}: {e}"))?;
    } else {
        println!("{text}");
    }
    Ok(())
}
