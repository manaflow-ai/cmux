//! A session's harness exits and its systemd scope goes with it (a cloud
//! VM, 2026-11-11: a scope held a type checker's headless server, 3.7 GB, for two days after its
//! harness was gone). A fake `systemd-run` on the profile's PATH runs the harness as the real one
//! does; the fake `systemctl` beside it logs what acpmux asks of the user manager.

use super::*;
use std::time::Duration;

/// A fake `systemd-run` and `systemctl` in `dir`; both log to `dir/scope.log`.
fn fake_systemd(dir: &std::path::Path) {
    crate::test_exec::write_executable(
        dir.join("systemd-run"),
        "#!/bin/sh\necho \"systemd-run $*\" >> \"$(dirname \"$0\")/scope.log\"\n\
         while [ \"$1\" != \"--\" ]; do shift; done\nshift\nexec \"$@\"\n",
    );
    crate::test_exec::write_executable(
        dir.join("systemctl"),
        "#!/bin/sh\necho \"systemctl $*\" >> \"$(dirname \"$0\")/scope.log\"\n",
    );
}

async fn spawn_scoped(
    dir: &std::path::Path,
    script: &str,
    inbound: mpsc::Sender<Inbound>,
) -> Arc<ChildAgent> {
    let path = format!("{}:/usr/bin:/bin", dir.display());
    let profile: HarnessProfile = serde_json::from_value(serde_json::json!({
        "argv": ["/bin/sh"],
        "env": {"PATH": path, "ACPMUX_SESSION_SWAP_MB": "0", "ACPMUX_SESSIONS_SWAP_MAX": "0"},
    }))
    .unwrap();
    let tap: Tap = Arc::new(|_, _, _| true);
    let command = Some(("/bin/sh".to_owned(), vec!["-c".to_owned(), script.to_owned()]));
    ChildAgent::spawn_with(
        "scoped",
        &profile,
        &std::env::temp_dir(),
        inbound,
        tap,
        command,
        None,
        Some(("scope-test-session", "scope test")),
    )
    .await
    .expect("the agent starts")
}

async fn exited(rx: &mut mpsc::Receiver<Inbound>) {
    tokio::time::timeout(Duration::from_secs(30), async {
        while let Some(item) = rx.recv().await {
            if matches!(item, Inbound::Exited { .. }) {
                return;
            }
        }
        panic!("the reader ended without an exit");
    })
    .await
    .expect("the agent's exit is reported");
}

fn stops(log: &str) -> Vec<&str> {
    log.lines().filter(|l| l.starts_with("systemctl --user stop")).collect()
}

#[tokio::test(flavor = "multi_thread")]
async fn a_harness_that_exits_stops_its_own_scope_once() {
    let dir = tempfile::tempdir().unwrap();
    fake_systemd(dir.path());
    let (inbound, mut rx) = mpsc::channel(1024);
    let agent = spawn_scoped(dir.path(), "exit 0", inbound).await;
    let unit = agent.scope_unit().expect("the harness got a scope").to_owned();
    exited(&mut rx).await;
    // Ending it on purpose afterwards (a session close) asks nothing more.
    agent.kill().await;
    let log = std::fs::read_to_string(dir.path().join("scope.log")).unwrap();
    let launch = log.lines().find(|l| l.contains("-- /bin/sh")).expect("a scoped launch");
    assert!(launch.contains(&format!("--unit={unit} ")), "{launch}");
    assert!(launch.contains("--slice=acpmuxsessions.slice"), "{launch}");
    assert_eq!(stops(&log), [format!("systemctl --user stop --no-block -- {unit}")], "{log}");
}

#[tokio::test(flavor = "multi_thread")]
async fn ending_a_running_harness_stops_its_scope() {
    let dir = tempfile::tempdir().unwrap();
    fake_systemd(dir.path());
    let (inbound, mut rx) = mpsc::channel(1024);
    let agent = spawn_scoped(dir.path(), "exec sleep 600", inbound).await;
    let unit = agent.scope_unit().expect("the harness got a scope").to_owned();
    assert!(agent.is_alive().await);
    let log = std::fs::read_to_string(dir.path().join("scope.log")).unwrap();
    assert!(stops(&log).is_empty(), "a live harness's scope stays: {log}");
    agent.kill().await;
    exited(&mut rx).await;
    let log = std::fs::read_to_string(dir.path().join("scope.log")).unwrap();
    assert_eq!(stops(&log), [format!("systemctl --user stop --no-block -- {unit}")], "{log}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_harness_without_a_session_gets_no_scope_and_stops_none() {
    let dir = tempfile::tempdir().unwrap();
    fake_systemd(dir.path());
    let profile: HarnessProfile = serde_json::from_value(serde_json::json!({
        "argv": ["/bin/sh"],
        "env": {"PATH": format!("{}:/usr/bin:/bin", dir.path().display())},
    }))
    .unwrap();
    let (inbound, mut rx) = mpsc::channel(1024);
    let tap: Tap = Arc::new(|_, _, _| true);
    let command = Some(("/bin/sh".to_owned(), vec!["-c".to_owned(), "exit 0".to_owned()]));
    let agent = ChildAgent::spawn_with(
        "unscoped",
        &profile,
        &std::env::temp_dir(),
        inbound,
        tap,
        command,
        None,
        None,
    )
    .await
    .expect("the agent starts");
    assert!(agent.scope_unit().is_none());
    exited(&mut rx).await;
    let log = std::fs::read_to_string(dir.path().join("scope.log")).unwrap_or_default();
    assert!(log.is_empty(), "{log}");
}
