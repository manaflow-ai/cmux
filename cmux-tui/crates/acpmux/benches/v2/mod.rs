//! Shared fixture and gate metadata for the agent-service v2 bench home.
//!
//! Every crate-local v2 gate writes one JSON object per measure when `V2_GATE_OUT` names a
//! file. The line format is `{"name":"v2.prNN.measure","small_p95":N,"god_p95":N,"unit":"ns"}`.
//! This home joins those files with the registry, computes the ratio and verdict, and prints the
//! JSON consumed by `quality-report.py --god-small`. A missing placeholder remains skipped; an
//! unknown name or a registered measure with no input is an error.

use acpmux::god_fixture::Shape;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

/// The limit from the v2 design: god p95 may be at most this multiple of small p95.
pub const GOD_SMALL_LIMIT: f64 = 1.2;

/// Measures registered by later PRs. A later PR replaces its placeholder with its concrete rows.
pub const REGISTERED_MEASURE_ROWS: &[&str] = &[];

#[derive(Clone, Copy, Debug)]
pub struct GateRow {
    pub pr: &'static str,
    pub name: &'static str,
    pub done_when: &'static str,
}

/// One placeholder for every done-when line in the current v2 design table.
pub const GATE_ROWS: [GateRow; 14] = [
    GateRow {
        pr: "1",
        name: "v2.pr01.book_append_window_recovery",
        done_when: "Append is O(row): bytes written and time per append within 1.2x at 40 rows and 2M rows. First window read under 5 ms, 1.2x. Recovery after a kill at every byte of a record loses nothing settled.",
    },
    GateRow {
        pr: "1b",
        name: "v2.pr01b.record_layout",
        done_when: "PR 1's gates still pass. An index entry with no record is cleared at open and its row settles once on replay. A kill at every byte around a raw.map line leaves no record naming a file the map lacks. A wrong magic or unknown version opens to the rebuild error. Work at open 1.2x, 2M rows against 40.",
    },
    GateRow {
        pr: "2",
        name: "v2.pr02.translate_properties_and_cost",
        done_when: "fold(a ++ b) == apply(fold(a), b) over 10k random splits. Final reply visible in every interleaving. Translate cost per line 1.2x. The 1.1 GB JSONL shape translates in bounded memory (under 64 MB).",
    },
    GateRow {
        pr: "3",
        name: "v2.pr03.chat_actor_window_resume",
        done_when: "First window within 50 ms of sub, 1.2x. Resume from a cursor costs O(missed). RSS with the god chat subscribed within 1.2x of small. An append that waits behind a cold page read: its wait 1.2x, god against small. The actor killed mid-turn 50 times: the replay settles every row once.",
    },
    GateRow {
        pr: "4",
        name: "v2.pr04.byte_credit_drop_resume",
        done_when: "1 GB of events to a stopped reader: RSS stays under the connection budget; the reader resumes with no row lost or repeated.",
    },
    GateRow {
        pr: "5",
        name: "v2.pr05.index_list_stream",
        done_when: "First list window within 200 ms of listen with 11k sessions, 1.2x against 20. One summary change costs O(1): no work proportional to the list.",
    },
    GateRow {
        pr: "6",
        name: "v2.pr06.thin_store_geometry",
        done_when: "DOM mutation probe on open: blank to settled and nothing else. Zero visible-row shifts not caused by input, across open, reconnect, restart and page-up. Scroll-up settle 1.2x.",
    },
    GateRow {
        pr: "7",
        name: "v2.pr07.sidebar_list_stream",
        done_when: "No \"Waiting for the agent service\" frame while the socket is up. Sidebar scroll frame time 1.2x at 11k against 20.",
    },
    GateRow {
        pr: "8",
        name: "v2.pr08.peers_list_subscribers",
        done_when: "30 peers reconnecting at once: RSS rise under 20 MB, ack p95 unchanged. Zero whole-list parses (a counter).",
    },
    GateRow {
        pr: "9",
        name: "v2.pr09.chat_actor_start",
        done_when: "Listen within 100 ms of exec and a prompt accepted within 50 ms, with 527 chats and a 4 GB store, 1.2x against one small chat.",
    },
    GateRow {
        pr: "10",
        name: "v2.pr10.stop_exit_socket_handoff",
        done_when: "Stop under 1 s with 200 requests in flight and a stuck agent host, 50 runs. Restart gap seen by a client under 1 s.",
    },
    GateRow {
        pr: "11",
        name: "v2.pr11.act_send_rows",
        done_when: "Daemon killed mid-send 50 times: zero lost and zero doubled prompts.",
    },
    GateRow {
        pr: "12",
        name: "v2.pr12.follow_driver_views",
        done_when: "Toggle 100 times mid-turn: one harness process throughout, no row lost or doubled.",
    },
    GateRow {
        pr: "13",
        name: "v2.pr13.defaults_kill_list",
        done_when: "Every gate above green on god and small. Leo's nightly: a day of his use under 300 MB RSS, restart to steady under 20 s with zero movement.",
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
    GATE_ROWS.iter().map(|row| row.name).chain(REGISTERED_MEASURE_ROWS.iter().copied()).collect()
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
    Ok(Measure {
        name: name.to_string(),
        small_p95,
        god_p95,
        unit: object.get("unit").and_then(Value::as_str).map(str::to_string),
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
        if !names.contains(measure.name.as_str()) && !required.contains(&measure.name.as_str()) {
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
    let measures = merge_measures(&read_measures(measure_files)?, REGISTERED_MEASURE_ROWS)?;
    let rows = GATE_ROWS.iter().map(|row| {
        if let Some(measure) = measures.get(row.name) {
            let ratio = measure.god_p95 / measure.small_p95;
            json!({ "name": row.name, "pr": row.pr, "done_when": row.done_when, "status": if ratio <= GOD_SMALL_LIMIT { "ok" } else { "red" }, "reason": if ratio <= GOD_SMALL_LIMIT { "within 1.2x god/small" } else { "god p95 exceeds 1.2x small p95" }, "small_p95": measure.small_p95, "god_p95": measure.god_p95, "ratio": ratio, "unit": measure.unit })
        } else {
            json!({ "name": row.name, "pr": row.pr, "done_when": row.done_when, "status": "skipped", "reason": format!("PR {} implementation has not landed; turn on {} by this name", row.pr, row.name), "small_p95": Value::Null, "god_p95": Value::Null })
        }
    }).collect::<Vec<_>>();
    Ok(
        json!({ "schema": 1, "name": "acpmux-agent-service-v2", "comparison": "god-vs-small", "god_small_limit": GOD_SMALL_LIMIT, "fixtures": { "small": shape_json(small()), "god": shape_json(god()) }, "rows": rows }),
    )
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

#[cfg(test)]
mod tests {
    use super::*;
    fn measure(name: &str) -> Measure {
        Measure { name: name.to_string(), small_p95: 10.0, god_p95: 11.0, unit: Some("ns".into()) }
    }
    #[test]
    fn skipped_placeholder_passes() {
        let report = report(&[]).unwrap();
        assert_eq!(report["rows"][0]["status"], "skipped");
        assert_eq!(report["fixtures"]["god"]["chats"], 527);
        assert_eq!(report["fixtures"]["god"]["peers"], 30);
    }
    #[test]
    fn unknown_name_is_refused() {
        let error = merge_measures(&[measure("v2.pr99.unknown")], &[]).unwrap_err();
        assert!(error.contains("unknown v2 gate row"));
    }
    #[test]
    fn missing_registered_measure_is_refused() {
        let error = merge_measures(&[], &["v2.pr01.append_time"]).unwrap_err();
        assert!(error.contains("was not reported"));
    }
}
