use super::*;

#[tokio::test]
async fn offline_peer_snapshot_clear_never_runs_beside_a_live_writer() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-clear-lock");
    let held = acquire_lock(&dir.path().join("daemon.lock")).unwrap();
    let socket = dir.path().join("missing.sock");
    assert!(clear_at(dir.path(), &socket).await.is_err());
    drop(held);
    clear_at(dir.path(), &socket).await.unwrap();
    assert!(!socket.exists(), "clearing must not start a daemon");
}
