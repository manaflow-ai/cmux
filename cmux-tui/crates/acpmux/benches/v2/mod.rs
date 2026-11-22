//! Shared fixture and gate metadata for the agent-service v2 bench home.
//!
//! Every crate-local v2 gate writes one JSON object per measure when `V2_GATE_OUT` names a
//! file. The line format is `{"name":"v2.prNN.measure","small_p95":N,"god_p95":N,"unit":"ns"}`.
//! This home joins those files with the registry, computes the ratio and verdict, and prints the
//! JSON consumed by `quality-report.py --god-small`. A missing placeholder remains skipped. No one
//! line stops the report: a line the home cannot read or join reads its row `failed` with the
//! reason, a line with no registered name goes into the report's `errors`, and the report is
//! written; any of those, or a measured row with no input, then fails the run.
//! `run-v2-gates.sh` adds `"gate_failed":true` to every line a gate filter wrote before its test
//! failed; that row reads red with its numbers kept.

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
/// The rows live in `rows/`, one file per row of the design doc's PR table; this file holds none.
pub const GATE_ROWS: &[GateRow] = &rows::ALL;

#[path = "rows/mod.rs"]
mod rows;

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
    /// A test in this row's filter failed: the script marks every line the filter wrote, so the
    /// failed test may be another of the filter's tests than the one that wrote this measure.
    gate_failed: bool,
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
    // Only `true` marks the row: the home took any other value before the mark existed.
    let gate_failed = object.get("gate_failed").and_then(Value::as_bool).unwrap_or(false);
    Ok(Measure {
        name: name.to_string(),
        small_p95,
        god_p95,
        god_p95_all,
        unit: Some(unit.to_string()),
        gate_failed,
    })
}

/// A line the home could not take. `name` is the registered row it names, if any: that row reads
/// `failed` with `reason`; a line with no registered name goes into the report's `errors`.
struct Unreadable {
    name: Option<String>,
    reason: String,
}

/// Read every line, keeping the ones the home can parse and setting the others aside, so no one
/// line stops the report. Only a file that cannot be read stops it.
fn read_lines(paths: &[PathBuf]) -> Result<(Vec<Measure>, Vec<Unreadable>), String> {
    let mut measures = Vec::new();
    let mut unreadable = Vec::new();
    for path in paths {
        let text = fs::read_to_string(path).map_err(|e| format!("{path:?}: {e}"))?;
        for (line_no, line) in text.lines().enumerate() {
            if line.trim().is_empty() {
                continue;
            }
            let value: Value = match serde_json::from_str(line) {
                Ok(value) => value,
                Err(e) => {
                    let reason = format!("{path:?}:{line_no}: {e}");
                    unreadable.push(Unreadable { name: None, reason });
                    continue;
                }
            };
            let name = value.get("name").and_then(Value::as_str).map(str::to_owned);
            match parse_measure(value, path) {
                Ok(measure) => measures.push(measure),
                Err(reason) => unreadable.push(Unreadable { name, reason }),
            }
        }
    }
    Ok((measures, unreadable))
}

fn read_measures(paths: &[PathBuf]) -> Result<Vec<Measure>, String> {
    let (measures, unreadable) = read_lines(paths)?;
    match unreadable.into_iter().next() {
        Some(line) => Err(line.reason),
        None => Ok(measures),
    }
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
        (measure.gate_failed, "a test in this row's filter failed"),
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

/// What the report could not judge: rows that read `failed` with their reasons, and lines that
/// name no registered row.
#[derive(Default)]
struct Refused {
    rows: HashMap<String, Vec<String>>,
    errors: Vec<String>,
}

impl Refused {
    fn line(&mut self, name: Option<String>, reason: String) {
        match name.filter(|name| registered_names().contains(name.as_str())) {
            Some(name) => self.rows.entry(name).or_default().push(reason),
            None => self.errors.push(reason),
        }
    }
}

fn merge_for_report(
    measures: Vec<Measure>,
    unreadable: Vec<Unreadable>,
    required: &[&str],
) -> (HashMap<String, Measure>, Refused, Vec<String>) {
    let mut refused = Refused::default();
    for line in unreadable {
        refused.line(line.name, line.reason);
    }
    let mut joined = HashMap::new();
    for measure in measures {
        let Some(row) = GATE_ROWS.iter().find(|row| row.name == measure.name) else {
            refused.errors.push(format!("unknown v2 gate row {}", measure.name));
            continue;
        };
        if row.ratio_all.is_some() && measure.god_p95_all.is_none() {
            refused.line(Some(measure.name.clone()), format!("{} requires god_p95_all", row.name));
            continue;
        }
        if joined.contains_key(row.name) {
            refused.line(Some(measure.name.clone()), format!("duplicate v2 gate row {}", row.name));
            continue;
        }
        joined.insert(measure.name.clone(), measure);
    }
    // A refused row is judged by its refusal, not by a line of it that did join.
    for name in refused.rows.keys() {
        joined.remove(name);
    }
    let missing = required
        .iter()
        .copied()
        .filter(|name| !joined.contains_key(*name) && !refused.rows.contains_key(*name))
        .map(str::to_owned)
        .collect();
    (joined, refused, missing)
}

/// The report, and whether it stops the run: a row the home refused, a line with no registered
/// name, or a measured row with no measure. The report names each in its rows or `errors`.
fn report_value(
    measure_files: &[PathBuf],
    measures_requested: bool,
) -> Result<(Value, bool), String> {
    let required =
        GATE_ROWS.iter().filter(|row| row.measured).map(|row| row.name).collect::<Vec<_>>();
    let (measures, unreadable) = read_lines(measure_files)?;
    let (measures, refused, missing) =
        merge_for_report(measures, unreadable, if measures_requested { &required } else { &[] });
    let missing_set: HashSet<_> = missing.iter().map(String::as_str).collect();
    let rows = GATE_ROWS.iter().map(|row| {
        if let Some(reasons) = refused.rows.get(row.name) {
            json!({ "name": row.name, "pr": row.pr, "done_when": row.done_when,
                "status": "failed", "reason": reasons.join("; "),
                "small_p95": Value::Null, "god_p95": Value::Null })
        } else if let Some(measure) = measures.get(row.name) {
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
    let stops = !missing.is_empty() || !refused.rows.is_empty() || !refused.errors.is_empty();
    Ok((
        json!({ "schema": 1, "name": "acpmux-agent-service-v2", "comparison": "god-vs-small", "god_small_limit": GOD_SMALL_LIMIT, "fixtures": { "small": shape_json(small()), "god": shape_json(god()) }, "rows": rows, "errors": refused.errors }),
        stops,
    ))
}

/// Each reason a report stops the run: its `errors`, then every `failed` row with its reason.
fn stop_reasons(value: &Value) -> String {
    let errors = value["errors"].as_array().into_iter().flatten().filter_map(Value::as_str);
    let failed =
        value["rows"].as_array().into_iter().flatten().filter(|row| row["status"] == "failed");
    errors
        .map(str::to_owned)
        .chain(failed.map(|row| {
            format!(
                "{}: {}",
                row["name"].as_str().unwrap_or("?"),
                row["reason"].as_str().unwrap_or("?")
            )
        }))
        .collect::<Vec<_>>()
        .join("; ")
}

/// Build the nightly-report JSON when measures are required.
pub fn report(measure_files: &[PathBuf]) -> Result<Value, String> {
    let (value, stops) = report_value(measure_files, true)?;
    if stops { Err(stop_reasons(&value)) } else { Ok(value) }
}

pub fn validate_measure_files(measure_files: &[PathBuf], required: &[&str]) -> Result<(), String> {
    merge_measures(&read_measures(measure_files)?, required).map(|_| ())
}

pub fn print_report(measure_files: &[PathBuf], output: Option<&Path>) -> Result<(), String> {
    print_report_with_mode(measure_files, output, true)
}

/// Write the report, then fail if it holds a refused row, an unnamed line or a missing measure:
/// no one line keeps the report from being written.
pub fn print_report_with_mode(
    measure_files: &[PathBuf],
    output: Option<&Path>,
    measures_requested: bool,
) -> Result<(), String> {
    let (value, stops) = report_value(measure_files, measures_requested)?;
    let text = serde_json::to_string(&value).map_err(|e| e.to_string())?;
    if let Some(path) = output {
        fs::write(path, format!("{text}\n")).map_err(|e| format!("{path:?}: {e}"))?;
    } else {
        println!("{text}");
    }
    if stops { Err(stop_reasons(&value)) } else { Ok(()) }
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;

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

#[cfg(test)]
mod gate_failed_tests {
    use super::*;

    fn kin_line(mark: Option<Value>) -> Value {
        let mut line = json!({"name": "v2.pr05e.kin_table_change", "small_p95": 1000,
            "god_p95": 1100, "god_p95_all": 1200, "unit": "ns"});
        if let Some(mark) = mark {
            line["gate_failed"] = mark;
        }
        line
    }

    fn kin_row(line: Value) -> Value {
        let row = GATE_ROWS.iter().find(|row| row.name == "v2.pr05e.kin_table_change").unwrap();
        measured_row(row, &parse_measure(line, Path::new("fixture")).unwrap())
    }

    #[test]
    fn a_marked_line_reads_red_with_its_numbers_kept() {
        let row = kin_row(kin_line(Some(json!(true))));
        assert_eq!(row["status"], "red");
        assert_eq!(row["reason"], "a test in this row's filter failed");
        assert_eq!(row["small_p95"], 1000.0);
        assert_eq!(row["god_p95"], 1100.0);
        assert_eq!(row["ratio"], 1.1);
    }

    #[test]
    fn a_line_without_the_mark_reads_as_before() {
        for mark in [None, Some(json!(false)), Some(json!("yes")), Some(Value::Null)] {
            let row = kin_row(kin_line(mark.clone()));
            assert_eq!(row["status"], "ok", "{mark:?}");
            assert_eq!(row["reason"], "within the row's bounds", "{mark:?}");
        }
    }

    /// The gate script with a stand-in cargo (scripts/cmux-next/tests/run-v2-gates.test.sh): a
    /// filter that wrote a line and failed, one that wrote a line and passed, one that failed with
    /// no line. The home reads the file the script left.
    #[cfg(unix)]
    #[test]
    fn the_gate_script_marks_a_failed_filters_rows_red() {
        // affected-reads: scripts/cmux-next cmux-tui
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
        let measures = tempfile::NamedTempFile::new().unwrap();
        let status = std::process::Command::new("bash")
            .arg(root.join("scripts/cmux-next/tests/run-v2-gates.test.sh"))
            .arg(measures.path())
            .status()
            .unwrap();
        assert!(status.success(), "run-v2-gates.test.sh failed: {status}");
        let (value, missing) = report_value(&[measures.path().to_path_buf()], true).unwrap();
        assert!(missing);
        let rows = value["rows"].as_array().unwrap();
        let status_of = |name: &str| {
            let row = rows.iter().find(|row| row["name"] == name).unwrap();
            (row["status"].clone(), row["reason"].clone())
        };
        assert_eq!(
            status_of("v2.pr05e.kin_table_change"),
            (json!("red"), json!("a test in this row's filter failed"))
        );
        assert_eq!(
            status_of("v2.pr05e.sibling_insert"),
            (json!("ok"), json!("within the row's bounds"))
        );
        assert_eq!(
            status_of("v2.pr05e.family_page"),
            (json!("failed"), json!("the gate did not report a measure"))
        );
    }
}

#[cfg(test)]
mod unreadable_line_tests {
    use super::*;

    fn in_bound_line(row: &GateRow) -> Value {
        let value = row.god_max.unwrap_or(1.0).min(1.0);
        json!({"name": row.name, "small_p95": value, "god_p95": value, "god_p95_all": value,
            "unit": "ns"})
    }

    fn status_of<'a>(value: &'a Value, name: &str) -> &'a Value {
        value["rows"].as_array().unwrap().iter().find(|row| row["name"] == name).unwrap()
    }

    /// One malformed line, one that is not JSON and one with no registered name among good
    /// lines: the malformed line's row reads `failed` with the parser's reason, the other two go
    /// into `errors`, every other row is judged, the report is written, and the run fails.
    #[test]
    fn a_line_the_home_cannot_read_fails_its_row_only_and_the_report_is_written() {
        let broken = "v2.pr01.append_time";
        let mut lines = String::new();
        for row in GATE_ROWS.iter().filter(|row| row.measured) {
            let mut line = in_bound_line(row);
            if row.name == broken {
                line.as_object_mut().unwrap().remove("small_p95");
            }
            lines.push_str(&format!("{line}\n"));
        }
        lines.push_str("not json\n");
        let unknown =
            json!({"name": "v2.pr99.unknown", "small_p95": 1, "god_p95": 1, "unit": "ns"});
        lines.push_str(&format!("{unknown}\n"));
        let measures = tempfile::NamedTempFile::new().unwrap();
        fs::write(measures.path(), &lines).unwrap();
        let output = tempfile::NamedTempFile::new().unwrap();
        let error =
            print_report_with_mode(&[measures.path().to_path_buf()], Some(output.path()), true)
                .unwrap_err();
        assert!(error.contains(broken) && error.contains("no numeric small_p95"), "{error}");
        let value: Value = serde_json::from_str(&fs::read_to_string(output.path()).unwrap())
            .expect("the report is written");
        let row = status_of(&value, broken);
        assert_eq!(row["status"], "failed");
        assert!(row["reason"].as_str().unwrap().contains("has no numeric small_p95"), "{row}");
        for other in GATE_ROWS.iter().filter(|row| row.measured && row.name != broken) {
            assert_eq!(status_of(&value, other.name)["status"], "ok", "{}", other.name);
        }
        let errors = value["errors"].as_array().unwrap();
        assert_eq!(errors.len(), 2, "{errors:?}");
        assert!(errors.iter().any(|error| error.as_str().unwrap().contains("unknown v2 gate row")));
    }

    /// A row the home cannot join (a second line of it, or no `god_p95_all` where the row
    /// requires one) reads `failed` with that reason; the report is still built.
    #[test]
    fn a_line_the_home_cannot_join_fails_its_row() {
        let duplicate = GATE_ROWS.iter().find(|row| row.measured).unwrap();
        let needs_all = GATE_ROWS
            .iter()
            .find(|row| row.measured && row.ratio_all.is_some() && row.name != duplicate.name)
            .unwrap();
        let mut lines = String::new();
        for row in GATE_ROWS.iter().filter(|row| row.measured) {
            let mut line = in_bound_line(row);
            if row.name == needs_all.name {
                line.as_object_mut().unwrap().remove("god_p95_all");
            }
            lines.push_str(&format!("{line}\n"));
        }
        lines.push_str(&format!("{}\n", in_bound_line(duplicate)));
        let measures = tempfile::NamedTempFile::new().unwrap();
        fs::write(measures.path(), &lines).unwrap();
        let (value, stops) = report_value(&[measures.path().to_path_buf()], true).unwrap();
        assert!(stops);
        assert_eq!(status_of(&value, duplicate.name)["status"], "failed");
        assert!(
            status_of(&value, duplicate.name)["reason"].as_str().unwrap().contains("duplicate")
        );
        assert_eq!(status_of(&value, needs_all.name)["status"], "failed");
        assert!(
            status_of(&value, needs_all.name)["reason"]
                .as_str()
                .unwrap()
                .contains("requires god_p95_all")
        );
        assert_eq!(value["errors"], json!([]));
    }

    /// The thirty-unit row is one-sided: `small_p95` 0, its capped p95 as `god_p95`, judged by
    /// the row's absolute 10 ms bound, present or not in the measured set.
    #[test]
    fn the_thirty_unit_line_is_judged_by_its_absolute_bound() {
        let row =
            GATE_ROWS.iter().find(|row| row.name == "v2.pr08.mirror_local_row_thirty").unwrap();
        let line = |god: u64| {
            json!({"name": row.name, "small_p95": 0, "god_p95": god, "god_p95_all": god,
                "capped_p95": god, "capped_p95_all": god, "lifted_p95": god, "origins": 30,
                "unit_changes": 30, "turn_changes": 30, "unit": "ns"})
        };
        let judged =
            |god| measured_row(row, &parse_measure(line(god), Path::new("thirty")).unwrap());
        assert_eq!(judged(9_000_000)["status"], "ok");
        assert_eq!(judged(10_300_000)["status"], "red");
        assert_eq!(judged(10_300_000)["reason"], "god p95 exceeds the row's absolute maximum");
    }
}
