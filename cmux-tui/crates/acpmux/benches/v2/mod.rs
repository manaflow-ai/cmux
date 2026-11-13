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

/// One placeholder for every done-when line in the current v2 design table.
pub const GATE_ROWS: &[GateRow] = &[
    GateRow {
        pr: "1",
        name: "v2.pr01.book_append_window_recovery",
        done_when: "Append is O(row): bytes written and time per append within 1.2x at 40 rows and 2M rows. First window read under 5 ms, 1.2x. Recovery after a kill at every byte of a record loses nothing settled.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "1b",
        name: "v2.pr01b.record_layout",
        done_when: "PR 1's gates still pass. An index entry with no record is cleared at open and its row settles once on replay. A kill at every byte around a raw.map line leaves no record naming a file the map lacks. A wrong magic or unknown version opens to the rebuild error. Work at open 1.2x, 2M rows against 40.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "2",
        name: "v2.pr02.translate_line",
        done_when: "Translate cost per line is at most 1.2x god against small.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "2",
        name: "v2.pr02.translate_line_full_state",
        done_when: "Translate cost with the bounded open state is at most 1.2x god against small.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "2",
        name: "v2.pr02.jsonl_peak_rss",
        done_when: "The 1.1 GB JSONL shape stays under 64 MB RSS and within 1.2x god against small.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "2b",
        name: "v2.pr02b.translate_line_queue_full",
        done_when: "fold(a ++ b) == apply(fold(a), b) holds for the queue as for the rows, over 10k random splits. For every settled group in every interleaving, the rows in sight are the group row and out, nothing else. The state is inside its bound with 1,024 entries waiting.",
        measured: false,
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
        pr: "3a",
        name: "v2.pr03a.source_read_bounds",
        done_when: "A 1 GB growth reads one chunk and holds reads one byte at 40 rows and 2M rows. A 10 MB line appended in 100 pieces is read once when its newline arrives.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "4",
        name: "v2.pr04.byte_credit_drop_resume",
        done_when: "1 GB of events to a stopped reader: RSS stays under the connection budget; the reader resumes with no row lost or repeated.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "4",
        name: "v2.pr04.credit_without_read_drop",
        done_when: "A reader that sends credit without reading gets dropped on that sid; the connection stays up and another sid remains ordered.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "4",
        name: "v2.pr04.offer_256_subscriptions",
        done_when: "Offering one frame to 256 subscriptions costs at most 1.2x the one-subscription case.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "4",
        name: "v2.pr04.list_resume_end",
        done_when: "A list resume that missed nothing ends with one empty end frame, and no live op precedes the end mark.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "4",
        name: "v2.pr04.not_fed_bytes",
        done_when: "A subscriber that is not fed retains zero frame bytes through the god run.",
        measured: false,
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
        pr: "5",
        name: "v2.pr05.index_list_stream",
        done_when: "First list window within 200 ms of listen with 11k sessions, 1.2x against 20. One summary change costs O(1): no work proportional to the list.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: None,
    },
    GateRow {
        pr: "5",
        name: "v2.pr05.first_list_window",
        done_when: "First list window from a running hub: best p95 within 1.2x at 11,000 sessions against 20, all-sample p95 within 2x.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5",
        name: "v2.pr05.summary_change",
        done_when: "A summary change copies one tree path: best p95 within 3.7x, all-sample p95 within 6.2x, and god best p95 at most 10 microseconds.",
        measured: false,
        ratio: 3.7,
        ratio_all: Some(6.2),
        god_max: Some(10_000.0),
    },
    GateRow {
        pr: "5b",
        name: "v2.pr05b.start_first_window",
        done_when: "From exec to the first list window out of the snapshot: under 200 ms at 11,000 sessions, 1.2x against 20.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: Some(200_000_000.0),
    },
    GateRow {
        pr: "5b",
        name: "v2.pr05b.start_rss",
        done_when: "Bounded list storage: start rss, measured at 20 and 11,000 sessions.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5b",
        name: "v2.pr05b.hot_rss",
        done_when: "Cold rows leave the hot maps at startup and compaction install; retained RSS at 11,000 stays within 1.2x of 20 at the same writer phase.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5b",
        name: "v2.pr05b.apply_during_compaction",
        done_when: "At 11,000 sessions, the complete writer turn during compaction stays within 1.2x of outside compaction, including group sync and install.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5b",
        name: "v2.pr05b.page_first",
        done_when: "Bounded list storage: page first, measured at 20 and 11,000 sessions.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5b",
        name: "v2.pr05b.page_first_bytes",
        done_when: "Physical page first bytes include all seeks: 15.4x (256/20 rows per block), at most 64 KiB plus 19 fixture rows of at most 160 bytes (decision 110).",
        measured: false,
        ratio: 15.4,
        ratio_all: None,
        god_max: Some((64 * 1024 + 19 * 160) as f64),
    },
    GateRow {
        pr: "5b",
        name: "v2.pr05b.page_first_filter",
        done_when: "Bounded list storage: page first filter, measured at 20 and 11,000 sessions.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5b",
        name: "v2.pr05b.page_middle",
        done_when: "Bounded list storage: page middle, measured at 20 and 11,000 sessions.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5b",
        name: "v2.pr05b.page_middle_bytes",
        done_when: "Physical page middle bytes include all seeks: 15.4x (256/20 rows per block), at most 64 KiB plus 9 fixture rows of at most 160 bytes (decision 110).",
        measured: false,
        ratio: 15.4,
        ratio_all: None,
        god_max: Some((64 * 1024 + 9 * 160) as f64),
    },
    GateRow {
        pr: "5b",
        name: "v2.pr05b.page_middle_filter",
        done_when: "Bounded list storage: page middle filter, measured at 20 and 11,000 sessions.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5b",
        name: "v2.pr05b.page_last",
        done_when: "True last-key page: 14.9x best, 24.8x all-sample, and 400 microseconds; the derived bound accounts for different terminal stride phases (decision 110).",
        measured: false,
        ratio: 14.9,
        ratio_all: Some(24.8),
        god_max: Some(400_000.0),
    },
    GateRow {
        pr: "5b",
        name: "v2.pr05b.page_last_bytes",
        done_when: "Physical page last bytes include all seeks: 15.4x (256/20 rows per block), at most 64 KiB plus 0 fixture rows of at most 160 bytes (decision 110).",
        measured: false,
        ratio: 15.4,
        ratio_all: None,
        god_max: Some((64 * 1024) as f64),
    },
    GateRow {
        pr: "5b",
        name: "v2.pr05b.page_last_filter",
        done_when: "True last-key page: 14.9x best, 24.8x all-sample, and 400 microseconds; the derived bound accounts for different terminal stride phases (decision 110).",
        measured: false,
        ratio: 14.9,
        ratio_all: Some(24.8),
        god_max: Some(400_000.0),
    },
    GateRow {
        pr: "5f",
        name: "v2.pr05f.apply_update",
        done_when: "At 2,000 folders against 5, a folder-newest update and a two-row move stay within 1.2x and under 10 microseconds.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: Some(10_000.0),
    },
    GateRow {
        pr: "5f",
        name: "v2.pr05f.window_page",
        done_when: "The first folders window and a deep cursor page stay within 1.2x at 2,000 folders against 5.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: Some(2.0),
        god_max: None,
    },
    GateRow {
        pr: "5f",
        name: "v2.pr05f.published_bytes_path_copy",
        done_when: "The published folders view stays under 1 MB at 2,000 folders, and one more folder changes one persistent path while the old snapshot remains intact.",
        measured: false,
        ratio: 2_000.0,
        ratio_all: None,
        god_max: Some((1024 * 1024) as f64),
    },
    GateRow {
        pr: "5f",
        name: "v2.pr05f.folder_key_bound",
        done_when: "A folder at 1,024 bytes has a complete row key and is not shortened.",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
        god_max: Some(1_024.0),
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
        pr: "8",
        name: "v2.pr08.peers_list_subscribers",
        done_when: "30 peers reconnecting at once: RSS rise under 20 MB, ack p95 unchanged. Zero whole-list parses (a counter).",
        measured: false,
        ratio: GOD_SMALL_LIMIT,
        ratio_all: None,
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

/// Build the nightly-report JSON. `--measures` is optional while all rows are placeholders.
pub fn report(measure_files: &[PathBuf]) -> Result<Value, String> {
    let required =
        GATE_ROWS.iter().filter(|row| row.measured).map(|row| row.name).collect::<Vec<_>>();
    let measures = merge_measures(&read_measures(measure_files)?, &required)?;
    let rows = GATE_ROWS.iter().map(|row| {
        if let Some(measure) = measures.get(row.name) {
            measured_row(row, measure)
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

#[cfg(test)]
mod tests {
    use super::*;

    const EMITTED_GATE_NAMES: &[&str] = &[
        "v2.pr02.translate_line",
        "v2.pr02.translate_line_full_state",
        "v2.pr02.jsonl_peak_rss",
        "v2.pr02b.translate_line_queue_full",
        "v2.pr03a.source_read_bounds",
        "v2.pr05.first_list_window",
        "v2.pr05.summary_change",
        "v2.pr05b.start_first_window",
        "v2.pr05b.start_rss",
        "v2.pr05b.page_first",
        "v2.pr05b.page_first_bytes",
        "v2.pr05b.page_first_filter",
        "v2.pr05b.page_middle",
        "v2.pr05b.page_middle_bytes",
        "v2.pr05b.page_middle_filter",
        "v2.pr05b.page_last",
        "v2.pr05b.page_last_bytes",
        "v2.pr05b.page_last_filter",
        "v2.pr05b.hot_rss",
        "v2.pr05b.apply_during_compaction",
        "v2.pr05f.apply_update",
        "v2.pr05f.window_page",
        "v2.pr05f.published_bytes_path_copy",
        "v2.pr05f.folder_key_bound",
    ];

    #[test]
    fn every_emitted_gate_has_a_registry_row() {
        let registered = registered_names();
        for name in EMITTED_GATE_NAMES {
            assert!(registered.contains(name), "missing registry row for emitted gate {name}");
        }
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
