//! A quiet agent costs its reader no wakeups (Leo 2026-11-04: "never ... acceptable ... linear
//! time growth degradation"): where the kernel gives an exit event (a pidfd, kqueue
//! `NOTE_EXIT`), 100 live agents wake their readers over a quiet minute no more than 1 does, and a
//! leader that exits while a descendant holds its stdout is still seen at once. Where it gives
//! none (Linux before 5.3, a denied `pidfd_open`), the reader keeps its timed check, which still
//! reports the exit (review F2 of #39357).

use super::leader_exit::{LeaderExit, timed_check_only};
use super::*;
use std::time::Duration;

async fn spawn(script: &str, inbound: mpsc::Sender<Inbound>) -> Arc<ChildAgent> {
    let profile: HarnessProfile =
        serde_json::from_value(serde_json::json!({"argv": ["/bin/sh"]})).unwrap();
    let tap: Tap = Arc::new(|_, _, _| true);
    let command = Some(("/bin/sh".to_owned(), vec!["-c".to_owned(), script.to_owned()]));
    ChildAgent::spawn_with(
        "quiet",
        &profile,
        &std::env::temp_dir(),
        inbound,
        tap,
        command,
        None,
        None,
    )
    .await
    .expect("the agent starts")
}

/// Whether this kernel gives a child's exit as an event (else readers use the timed check).
async fn exit_events() -> bool {
    let mut child = tokio::process::Command::new("/bin/sh")
        .args(["-c", "exec sleep 600"])
        .kill_on_drop(true)
        .spawn()
        .expect("a probe child starts");
    let events = child.id().and_then(LeaderExit::open).is_some();
    let _ = child.kill().await;
    events
}

/// The reader wakeups of `n` live, silent agents over a quiet minute.
async fn quiet_minute(n: usize) -> u64 {
    let (inbound, _rx) = mpsc::channel(1024);
    let mut agents = Vec::new();
    for _ in 0..n {
        agents.push(spawn("exec sleep 600", inbound.clone()).await);
    }
    tokio::time::sleep(Duration::from_secs(2)).await;
    leader_wakeups::take();
    tokio::time::sleep(Duration::from_secs(60)).await;
    let wakeups = leader_wakeups::take();
    for agent in &agents {
        assert!(agent.is_alive().await, "a quiet agent ended");
        agent.kill().await;
    }
    wakeups
}

#[tokio::test(start_paused = true)]
async fn quiet_agents_wake_their_readers_the_same_for_1_and_100() {
    if !exit_events().await {
        eprintln!("no exit events on this kernel: readers use the timed check (tested below)");
        return;
    }
    let one = quiet_minute(1).await;
    let hundred = quiet_minute(100).await;
    eprintln!("quiet minute reader wakeups: 1 agent {one}, 100 agents {hundred}");
    assert!(
        hundred <= one + 2,
        "a quiet minute's reader wakeups grow with the live agents: 1 agent {one}, 100 agents \
         {hundred}"
    );
}

/// With no exit event, the reader checks its agent every LEADER_CHECK: about 120 times in a
/// quiet minute.
#[tokio::test(start_paused = true)]
async fn without_exit_events_a_reader_keeps_its_timed_check() {
    timed_check_only::set(true);
    let wakeups = quiet_minute(1).await;
    timed_check_only::set(false);
    eprintln!("timed check: 1 agent woke its reader {wakeups} times in a quiet minute");
    let expected = (60_000 / LEADER_CHECK.as_millis()) as u64;
    assert!(
        wakeups.abs_diff(expected) <= 2,
        "the timed check woke {wakeups} times in a quiet minute, not about {expected}"
    );
}

/// The leader exits while a background child keeps its stdout open: the reader still reports
/// the exit, ending what the leader left running. Real time: the exit is the kernel's.
async fn leader_exit_under_a_descendant(timed: bool) -> Duration {
    timed_check_only::set(timed);
    let (inbound, mut rx) = mpsc::channel(1024);
    let agent = spawn("sleep 600 & exec sleep 600", inbound).await;
    timed_check_only::set(false);
    tokio::time::sleep(Duration::from_millis(500)).await;
    let pid = agent.pid.expect("a direct agent has a pid");
    // SAFETY: the leader this test started; its slot holds it unreaped.
    unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
    let killed = tokio::time::Instant::now();
    let exited = tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            match rx.recv().await {
                Some(Inbound::Exited { .. }) | None => break,
                Some(_) => {}
            }
        }
    })
    .await;
    assert!(exited.is_ok(), "the leader's exit was never reported (timed check: {timed})");
    assert!(!agent.is_alive().await);
    killed.elapsed()
}

#[tokio::test]
async fn a_leader_that_exits_under_a_descendant_is_reported() {
    let took = leader_exit_under_a_descendant(false).await;
    eprintln!("leader exit reported after {took:?}");
}

#[tokio::test]
async fn without_exit_events_a_leader_that_exits_under_a_descendant_is_reported() {
    let took = leader_exit_under_a_descendant(true).await;
    eprintln!("leader exit reported after {took:?} (timed check)");
}
