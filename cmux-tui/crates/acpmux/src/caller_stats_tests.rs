use super::*;

fn caller(client: &str, pid: u32) -> Caller {
    Caller {
        client: client.to_owned(),
        origin: "local",
        pid: Some(pid),
        session: Some("s-1".to_owned()),
        proven: true,
    }
}

#[test]
fn each_caller_and_method_is_counted_with_its_bytes_in_the_window() {
    let stats = CallerStats::new();
    let busy = caller("turn-states", 4242);
    let quiet = caller("cmux agent", 7);
    for _ in 0..30 {
        stats.observe_request_at(&busy, "_acpmux/sessions", 100, 50);
        stats.observe_reply_at(&busy, "_acpmux/sessions", 10_000, 50);
    }
    stats.observe_request_at(&busy, "initialize", 200, 55);
    stats.observe_request_at(&quiet, "_acpmux/status", 40, 58);
    let report = stats.report_at(59, 60, 10);
    let callers = report["callers"].as_array().unwrap();
    assert_eq!(callers.len(), 2);
    assert_eq!(callers[0]["client"], "turn-states");
    assert_eq!(callers[0]["pid"], 4242);
    assert_eq!(callers[0]["session"], "s-1");
    assert_eq!(callers[0]["requests"], 31);
    assert_eq!(callers[0]["requestBytes"], 3200);
    assert_eq!(callers[0]["replyBytes"], 300_000);
    assert_eq!(callers[0]["perMinute"], 31.0);
    assert_eq!(callers[0]["methods"][0]["method"], "_acpmux/sessions");
    assert_eq!(callers[0]["methods"][0]["requests"], 30);
    assert_eq!(callers[0]["methods"][1]["method"], "initialize");
    assert_eq!(callers[1]["client"], "cmux agent");
    let methods = report["methods"].as_array().unwrap();
    assert_eq!(methods[0]["method"], "_acpmux/sessions");
    assert_eq!(methods[0]["callers"], 1);
    assert_eq!(report["windowSecs"], 60);
}

#[test]
fn requests_older_than_the_window_are_left_out_and_buckets_are_reused() {
    let stats = CallerStats::new();
    let c = caller("old", 1);
    stats.observe_request_at(&c, "m", 1, 0);
    stats.observe_request_at(&c, "m", 1, 200);
    // 60 s before 205 holds only the second request.
    assert_eq!(stats.report_at(205, 60, 10)["callers"][0]["requests"], 1);
    // The ten-minute window holds both.
    assert_eq!(stats.report_at(205, 600, 10)["callers"][0]["requests"], 2);
    // A whole ring later the slot of 0 holds 600's count, not 0's.
    stats.observe_request_at(&c, "m", 1, 600);
    let report = stats.report_at(600, 10_000, 10);
    assert_eq!(report["windowSecs"], MAX_WINDOW_SECS);
    assert_eq!(report["callers"][0]["requests"], 2);
    // Past every bucket nothing is listed.
    assert_eq!(stats.report_at(5_000, 600, 10)["callers"].as_array().map(Vec::len), Some(0));
}

#[test]
fn past_its_cap_the_pair_seen_longest_ago_makes_room() {
    let stats = CallerStats::new();
    for i in 0..ENTRIES as u64 + 3 {
        stats.observe_request_at(&caller("c", i as u32), "m", 1, i);
    }
    let report = stats.report_at(ENTRIES as u64 + 3, 600, ENTRIES * 2);
    assert_eq!(report["entries"], ENTRIES);
    assert_eq!(report["evicted"], 3);
    let pids: Vec<u64> =
        report["callers"].as_array().unwrap().iter().filter_map(|c| c["pid"].as_u64()).collect();
    assert!(!pids.contains(&0) && !pids.contains(&2), "the oldest went first: {pids:?}");
    assert!(pids.contains(&(ENTRIES as u64 + 2)));
}

#[test]
fn top_bounds_the_rows_and_the_counts_say_how_many_there_were() {
    let stats = CallerStats::new();
    for i in 0..5u32 {
        for _ in 0..=i {
            stats.observe_request_at(&caller("c", i), &format!("m{i}"), 1, 1);
        }
    }
    let report = stats.report_at(2, 60, 2);
    assert_eq!(report["callerCount"], 5);
    assert_eq!(report["methodCount"], 5);
    assert_eq!(report["callers"][0]["pid"], 4);
    assert_eq!(report["callers"].as_array().map(Vec::len), Some(2));
    assert_eq!(report["methods"][0]["method"], "m4");
}

#[test]
fn params_pick_the_window_and_top() {
    let stats = CallerStats::new();
    stats.observe_request(&caller("c", 1), "m", 1);
    let report = stats.report(&json!({"sinceSecs": 120, "top": 1}));
    assert_eq!(report["windowSecs"], 120);
    assert_eq!(report["callers"][0]["requests"], 1);
    assert_eq!(stats.report(&json!({}))["windowSecs"], 60);
}
