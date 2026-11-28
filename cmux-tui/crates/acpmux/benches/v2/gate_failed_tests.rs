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
