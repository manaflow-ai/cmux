use super::*;

fn in_bound_line(row: &GateRow) -> Value {
    let value = row.god_max.unwrap_or(1.0).min(1.0);
    json!({"name": row.name, "small_p95": value, "god_p95": value, "god_p95_all": value,
        "unit": "ns"})
}

fn status_of<'a>(value: &'a Value, name: &str) -> &'a Value {
    value["rows"].as_array().unwrap().iter().find(|row| row["name"] == name).unwrap()
}

/// A gate with no measure fails its row and the job's last step, but the home writes every row
/// and exits 0 (run 45590353660: one red gate read as a blind home).
#[test]
fn a_missing_measure_writes_every_row_and_exits_zero() {
    let skip = GATE_ROWS.iter().find(|row| row.measured).unwrap();
    let mut lines = String::new();
    for row in GATE_ROWS.iter().filter(|row| row.measured && row.name != skip.name) {
        lines.push_str(&format!("{}\n", in_bound_line(row)));
    }
    let measures = tempfile::NamedTempFile::new().unwrap();
    fs::write(measures.path(), &lines).unwrap();
    let output = tempfile::NamedTempFile::new().unwrap();
    print_report_with_mode(&[measures.path().to_path_buf()], Some(output.path()), true)
        .expect("a red gate is not the home's stop");
    let value: Value = serde_json::from_str(&fs::read_to_string(output.path()).unwrap())
        .expect("the report is written");
    let row = status_of(&value, skip.name);
    assert_eq!(row["status"], "failed");
    assert_eq!(row["reason"], NO_MEASURE);
    for other in GATE_ROWS.iter().filter(|row| row.measured && row.name != skip.name) {
        assert_eq!(status_of(&value, other.name)["status"], "ok", "{}", other.name);
    }
    assert!(report(&[measures.path().to_path_buf()]).is_err(), "report() stays strict");
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
    let unknown = json!({"name": "v2.pr99.unknown", "small_p95": 1, "god_p95": 1, "unit": "ns"});
    lines.push_str(&format!("{unknown}\n"));
    let measures = tempfile::NamedTempFile::new().unwrap();
    fs::write(measures.path(), &lines).unwrap();
    let output = tempfile::NamedTempFile::new().unwrap();
    let error = print_report_with_mode(&[measures.path().to_path_buf()], Some(output.path()), true)
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
    assert!(status_of(&value, duplicate.name)["reason"].as_str().unwrap().contains("duplicate"));
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
    let row = GATE_ROWS.iter().find(|row| row.name == "v2.pr08.mirror_local_row_thirty").unwrap();
    let line = |god: u64| {
        json!({"name": row.name, "small_p95": 0, "god_p95": god, "god_p95_all": god,
            "capped_p95": god, "capped_p95_all": god, "lifted_p95": god, "origins": 30,
            "unit_changes": 30, "turn_changes": 30, "unit": "ns"})
    };
    let judged = |god| measured_row(row, &parse_measure(line(god), Path::new("thirty")).unwrap());
    assert_eq!(judged(9_000_000)["status"], "ok");
    assert_eq!(judged(10_300_000)["status"], "red");
    assert_eq!(judged(10_300_000)["reason"], "god p95 exceeds the row's absolute maximum");
}
