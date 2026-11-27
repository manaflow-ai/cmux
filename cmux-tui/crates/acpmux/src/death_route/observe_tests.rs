use super::*;
use crate::death_route::{Facts, Route, route};

fn peers() -> Value {
    json!({"peers": [
        {"name": "vm-a", "connected": false, "downSince": 1_000_000},
        {"name": "b", "connected": true, "downSince": null},
        {"name": "c", "connected": true},
    ]})
}

#[test]
fn a_down_host_reads_down_since_its_down_since() {
    let f = observe("vm-a/lane", &peers(), None, 1_000_000 + 2_400_000);
    assert_eq!(f["host"], "vm-a");
    assert_eq!(f["host_down"], true);
    assert_eq!(f["dead_seconds"], 2400.0);
    assert_eq!(f["hosts"]["answering"], json!(["b", "c"]));
}

#[test]
fn an_up_host_reads_up_and_no_dead_time() {
    let f = observe("b/lane", &peers(), None, 5);
    assert_eq!(f["host_down"], false);
    assert!(f.get("dead_seconds").is_none());
}

#[test]
fn a_host_with_no_peer_row_gets_no_host_facts() {
    let f = observe("elsewhere/lane", &peers(), None, 5);
    assert!(f.get("host_down").is_none(), "{f}");
    assert_eq!(f["host"], "elsewhere");
}

#[test]
fn the_copy_gives_its_row_and_records() {
    let snap = json!({"summary": {"sessionId": "lane"}, "events": [{"seq": 1}, {"seq": 2}]});
    let f = observe("vm-a/lane", &peers(), Some(&snap), 5);
    assert_eq!(f["has_row"], true);
    assert_eq!(f["snapshot_records"], 2);
    let none = json!({"summary": null, "events": []});
    let g = observe("vm-a/lane", &peers(), Some(&none), 5);
    assert_eq!(g["has_row"], false);
    assert!(g.get("snapshot_records").is_none());
}

#[test]
fn the_callers_word_wins_field_by_field() {
    let seen = observe("vm-a/lane", &peers(), None, 1_000_000 + 60_000);
    let caller = json!({"dead_seconds": 7200.0, "hosts": {"move_to": ["b"]}, "max_failovers": 1});
    let m = merge(seen, caller);
    assert_eq!(m["dead_seconds"], 7200.0);
    assert_eq!(m["host_down"], true);
    assert_eq!(m["hosts"]["answering"], json!(["b", "c"]));
    assert_eq!(m["hosts"]["move_to"], json!(["b"]));
}

/// The whole path: a host down past the grace with a copy of the chat here moves it from the
/// copy, with no fact about the host or the copy coming from the caller.
#[test]
fn a_dead_hosts_session_moves_from_the_copy_on_the_hubs_facts_alone() {
    let snap = json!({"summary": {"sessionId": "lane"}, "events": [{"seq": 9}]});
    let seen = observe("vm-a/lane", &peers(), Some(&snap), 1_000_000 + 3_600_000);
    let caller = json!({
        "host_grace_seconds": 1800.0, "max_restarts": 2, "max_failovers": 2,
        "hosts": {"move_to": ["b", "c"], "room_known": true, "admitted": ["b", "c"]},
    });
    let f: Facts = serde_json::from_value(merge(seen, caller)).unwrap();
    assert_eq!(route(&f), Route::MoveFromCopy { to: "b".into() });
}
