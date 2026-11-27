use super::*;

#[test]
fn readiness_reads_one_line_per_provider() {
    let reply = json!({"providers": [
        {"family": "github", "state": "ready", "account": "github:bob", "label": "bob"},
        {"family": "codex", "state": "signInRequired"},
        {"family": "claude", "state": "notInstalled"},
    ]});
    assert_eq!(
        readiness_lines(&reply),
        ["github  ready  bob (github:bob)", "codex   sign-in required", "claude  not installed"]
    );
}
