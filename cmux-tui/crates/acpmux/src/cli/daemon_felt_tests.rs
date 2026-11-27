use super::*;

#[test]
fn the_table_lists_only_metrics_with_samples() {
    let v = json!({"metrics": {
        "prompt_send_to_ack": {
            "last_60s": {"count": 3, "p50_us": 1200, "p90_us": 2000, "p99_us": 9000, "max_us": 9000},
            "since_start": {"count": 3, "p50_us": 1200, "p90_us": 2000, "p99_us": 9000, "max_us": 9000}},
        "terminal_echo": {
            "last_60s": {"count": 0, "p50_us": null, "p90_us": null, "p99_us": null, "max_us": null},
            "since_start": {"count": 0, "p50_us": null, "p90_us": null, "p99_us": null, "max_us": null}},
    }});
    let table = render(&v);
    assert!(table.contains("prompt_send_to_ack"));
    assert!(table.contains("1.2"));
    assert!(!table.contains("terminal_echo"));
}
