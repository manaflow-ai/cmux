use super::*;

#[test]
fn a_delivery_with_no_such_session_reads_failed_no_session() {
    let v = json!({"pending": 0, "deliveries": [
        {"deliveryId": "d3", "target": "host/proc-title", "status": "failed", "attempts": 1,
         "createdAt": 10_000, "reason": "no_session",
         "error": "no_session: no session proc-title on host; did you mean: feed-lane"},
    ]});
    assert_eq!(
        list_lines(&v, 70_000)[1],
        "failed: no_session  host/proc-title  60s ago  attempt 1  d3  last error: no_session: no session proc-title on host; did you mean: feed-lane"
    );
    assert_eq!(state_label(&json!({"status": "queued", "reason": null})), "queued");
}

#[test]
fn list_lines_show_state_target_age_and_the_waiting_ones_error() {
    assert_eq!(
        list_lines(&json!({"deliveries": []}), 0),
        ["no messages queued or sent in the last day"]
    );
    let v = json!({"pending": 1, "deliveries": [
        {"deliveryId": "d2", "target": "gcp-agent-lane-1/lane", "status": "queued", "attempts": 3,
         "createdAt": 10_000, "error": "peer_unreachable"},
        {"deliveryId": "d1", "target": "lane", "status": "delivered", "attempts": 1,
         "createdAt": 1_000, "error": null},
    ]});
    assert_eq!(
        list_lines(&v, 70_000),
        [
            "1 waiting, 2 in all",
            "queued      gcp-agent-lane-1/lane  60s ago  attempt 3  d2  last error: peer_unreachable",
            "delivered   lane  69s ago  attempt 1  d1",
        ]
    );
}
