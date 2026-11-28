use super::*;

#[test]
fn text_has_session_host_utc_time_role_and_one_line_preview() {
    let mut answer = json!({"hits": [{
        "session": "peer/s-1", "host": "peer", "at": 1_735_689_605_000_i64,
        "turnStartedAt": 1_735_689_600_000_i64,
        "role": "assistant", "snippet": "first line\nsecond line"
    }]});
    answer["hits"][0]["time"] = json!(utc_time(&answer["hits"][0]));
    assert_eq!(
        text(&answer),
        "peer/s-1 peer 2025-01-01T00:00:00Z assistant first line second line\n"
    );
    assert_eq!(utc_time(&json!({"at": 0})).as_deref(), Some("1970-01-01T00:00:00Z"));
}

#[test]
fn text_reports_unavailable_sessions_without_remote_error_details() {
    let answer = json!({
        "hits": [],
        "unreached": [{"session": "peer/s-1", "host": "peer", "error": "mesh.read_unanswered"}]
    });
    assert_eq!(text(&answer), "unavailable peer/s-1 peer: mesh.read_unanswered\n");
}
