use super::*;

fn row(id: &str, extra: Value) -> Value {
    let mut v = json!({"sessionId": id, "name": id, "status": "idle"});
    if let (Some(obj), Some(more)) = (v.as_object_mut(), extra.as_object()) {
        obj.extend(more.clone());
    }
    v
}

fn names(rows: &[Value]) -> Vec<(String, Vec<String>)> {
    leaders(rows)
        .iter()
        .map(|l| {
            let reports = l.get("reports").and_then(Value::as_array).unwrap();
            (name(l).to_owned(), reports.iter().map(|r| r.as_str().unwrap().to_owned()).collect())
        })
        .collect()
}

fn owned(pairs: &[(&str, &[&str])]) -> Vec<(String, Vec<String>)> {
    pairs
        .iter()
        .map(|(n, r)| ((*n).to_owned(), r.iter().map(|s| (*s).to_owned()).collect()))
        .collect()
}

#[test]
fn a_leader_is_a_live_session_live_lanes_report_to_once_most_reports_first() {
    let rows = [
        row("coord", json!({})),
        row("owner", json!({"tags": {"area": "acpmux"}})),
        row("lone", json!({})),
        row("a", json!({"tags": {TAG: "owner"}})),
        row("b", json!({"tags": {TAG: "owner"}, "status": "running"})),
        row("c", json!({"tags": {TAG: "coord"}})),
    ];
    assert_eq!(names(&rows), owned(&[("owner", &["a", "b"]), ("coord", &["c"])]));
    let text = render(&leaders(&rows));
    assert!(text.starts_with("NAME"), "{text}");
    assert!(text.contains("owner  local  idle   acpmux  2: a, b"), "{text}");
}

#[test]
fn closed_archived_and_side_chats_do_not_count() {
    let rows = [
        row("gone", json!({"status": "closed"})),
        row("x", json!({"tags": {TAG: "gone"}})),
        row("owner", json!({})),
        row("done", json!({"tags": {TAG: "owner"}, "status": "closed"})),
        row("shelved", json!({"tags": {"archived": "1"}})),
        row("y", json!({"tags": {TAG: "shelved"}})),
        row("self", json!({"tags": {TAG: "self"}})),
        row("btw", json!({"tags": {"side": "owner"}})),
        row("z", json!({"tags": {TAG: "btw"}})),
        row("copy", json!({"tags": {TAG: "owner", "aside": "owner"}})),
    ];
    assert!(names(&rows).is_empty());
    assert!(render(&[]).starts_with("no leaders"));
}

#[test]
fn a_lane_names_its_leader_on_its_own_machine() {
    let rows = [
        row("lead", json!({"peer": "huge-blue", "name": "hb-lead"})),
        row("lead", json!({"name": "here"})),
        row("lane", json!({"peer": "huge-blue", "tags": {TAG: "lead"}})),
    ];
    assert_eq!(names(&rows), owned(&[("hb-lead", &["lane"])]));
}
