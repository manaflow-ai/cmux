use super::*;
use serde_json::json;

fn row(host: &str, id: &str, status: &str) -> Value {
    json!({"qualifiedSessionId": format!("{host}/{id}"), "status": status})
}

fn rows(host: &str, status: &str, n: usize) -> Vec<Value> {
    (0..n).map(|i| row(host, &format!("s{i}"), status)).collect()
}

fn registry() -> Value {
    json!({"machines": {
        "lane-a": {"lanes": {"max_lanes": 6}},
        "lane-b": {"lanes": {"max_lanes": 4}, "status": "idle-stopped since 2026-11-20"},
        "lane-c": {"aliases": ["lane-c.example"], "lanes": {"max_lanes": 2}},
        "laptop": {"roles": ["interactive"]},
    }})
}

fn host<'a>(r: &'a Value, name: &str) -> &'a Value {
    r["hosts"].as_array().unwrap().iter().find(|h| h["host"] == name).unwrap()
}

#[test]
fn a_host_past_its_cap_counts_only_its_live_sessions() {
    let mut s = rows("lane-a", "running", 7);
    s.extend(rows("lane-a", "ready", 2));
    s.extend(rows("lane-a", "idle", 5));
    s.extend(rows("lane-a", "closed", 3));
    let r = report(Some(&registry()), &s, 0);
    let a = host(&r, "lane-a");
    assert_eq!(a["live"], 9);
    assert_eq!(a["over"], 3);
    assert_eq!(a["disagrees"], false);
    assert_eq!(r["schema"], SCHEMA);
    assert_eq!(r["totals"]["overCapHosts"], 1);
    assert_eq!(r["totals"]["liveOverCap"], 3);
    // Worst first.
    assert_eq!(r["hosts"][0]["host"], "lane-a");
    assert!(lines(&r)[0].starts_with("lane-a: 9 live, cap 6, 3 over"));
}

#[test]
fn a_stopped_host_running_sessions_disagrees_with_the_registry() {
    let r = report(Some(&registry()), &rows("lane-b", "waiting", 2), 0);
    let b = host(&r, "lane-b");
    assert_eq!(b["disagrees"], true);
    assert!(b["over"].is_null());
    assert!(b["registry"].as_str().unwrap().starts_with("idle-stopped"));
    assert_eq!(r["totals"]["disagreeingHosts"], 1);
    assert_eq!(r["totals"]["liveOnStopped"], 2);
    // A stopped host with nothing live agrees.
    let quiet = report(Some(&registry()), &[], 0);
    assert_eq!(host(&quiet, "lane-b")["disagrees"], false);
}

#[test]
fn rows_under_an_alias_or_another_case_count_for_the_host() {
    let mut s = rows("lane-c.example", "running", 2);
    s.push(row("LANE-C", "x", "running"));
    let r = report(Some(&registry()), &s, 0);
    let c = host(&r, "lane-c");
    assert_eq!(c["live"], 3);
    assert_eq!(c["over"], 1);
    assert_eq!(r["totals"]["liveElsewhere"], 0);
}

#[test]
fn only_lane_hosts_are_listed_and_the_rest_count_elsewhere() {
    let r = report(Some(&registry()), &rows("laptop", "running", 4), 0);
    assert_eq!(r["totals"]["laneHosts"], 3);
    assert!(r["hosts"].as_array().unwrap().iter().all(|h| h["host"] != "laptop"));
    assert_eq!(r["totals"]["liveElsewhere"], 4);
}

#[test]
fn with_no_registry_every_live_session_counts_elsewhere() {
    let r = report(None, &rows("lane-a", "running", 3), 0);
    assert_eq!(r["totals"]["laneHosts"], 0);
    assert_eq!(r["totals"]["live"], 3);
    assert_eq!(r["totals"]["liveElsewhere"], 3);
    assert_eq!(lines(&r).len(), 1);
}

#[test]
fn a_row_with_no_host_is_skipped() {
    let r = report(Some(&registry()), &[json!({"status": "running", "sessionId": "x"})], 0);
    assert_eq!(r["totals"]["live"], 0);
}
