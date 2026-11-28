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
