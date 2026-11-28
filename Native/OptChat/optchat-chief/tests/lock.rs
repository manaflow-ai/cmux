//! The host lock: one host per MUX_HOME, shared with mux/host and the P1 Chief.

use std::process::Command;

use optchat_chief::lock::{HostLock, LockError};

#[test]
fn a_second_host_for_the_same_home_exits_0() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("mux");
    std::fs::create_dir_all(home.join("state")).unwrap();
    let lock_path = home.join("state").join("host.lock");
    let held = HostLock::take(&lock_path, 1234).unwrap();
    assert_eq!(
        std::fs::read_to_string(&lock_path).unwrap(),
        format!("{}\n1234\nflock\n", std::process::id())
    );
    assert!(
        matches!(HostLock::take(&lock_path, 1), Err(LockError::Held)),
        "a second taker in the same process"
    );

    let token = dir.path().join("agent-token");
    std::fs::write(&token, "secret\n").unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_optchat-chief"))
        .args(["host", "--daemon-socket"])
        .arg(dir.path().join("missing.sock"))
        .arg("--mux-home")
        .arg(&home)
        .env("MUX_AGENT_TOKEN_FILE", &token)
        .env_remove("ACPMUX_BIN")
        .output()
        .unwrap();
    assert_eq!(
        out.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(String::from_utf8_lossy(&out.stderr).contains("already running"));
    assert!(lock_path.exists(), "the lock file is never removed");

    drop(held);
    let again = HostLock::take(&lock_path, 5).expect("free once the holder closed it");
    drop(again);
    assert!(lock_path.exists());
}

#[test]
fn without_the_agent_token_the_host_refuses_to_start() {
    let dir = tempfile::tempdir().unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_optchat-chief"))
        .args(["host", "--daemon-socket", "/nonexistent.sock", "--mux-home"])
        .arg(dir.path())
        .env("MUX_AGENT_TOKEN_FILE", dir.path().join("absent"))
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(2));
    assert!(
        !dir.path().join("state").join("host.lock").exists(),
        "refused before taking the lock"
    );
}

#[test]
fn an_older_text_only_host_blocks_the_start() {
    // A lock text without the flock mark naming a live process (this test
    // process, which started before the recorded time) is an older host.
    let dir = tempfile::tempdir().unwrap();
    let lock_path = dir.path().join("host.lock");
    let far_future = 32_503_680_000_000u64; // year 3000
    std::fs::write(
        &lock_path,
        format!("{}\n{far_future}\n", std::process::id()),
    )
    .unwrap();
    // Our own pid is skipped (a host never blocks itself), so use the parent's.
    let parent = std::os::unix::process::parent_id();
    std::fs::write(&lock_path, format!("{parent}\n{far_future}\n")).unwrap();
    match HostLock::take(&lock_path, 1) {
        Err(LockError::Older(pid)) => assert_eq!(pid as u32, parent),
        other => panic!("expected an older host, got {other:?}"),
    }
}
