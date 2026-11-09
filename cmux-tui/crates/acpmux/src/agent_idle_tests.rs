//! A quiet agent costs its reader no wakeups (Leo 2026-11-04: "never ... acceptable ... linear
//! time growth degradation"): over a quiet minute 100 live agents wake their readers no more than
//! 1 does, and a leader that exits while a descendant holds its stdout is still seen at once.

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
    let one = quiet_minute(1).await;
    let hundred = quiet_minute(100).await;
    eprintln!("quiet minute reader wakeups: 1 agent {one}, 100 agents {hundred}");
    assert!(
        hundred <= one + 2,
        "a quiet minute's reader wakeups grow with the live agents: 1 agent {one}, 100 agents \
         {hundred}"
    );
}

/// The leader exits while a background child keeps its stdout open: the reader still reports
/// the exit, ending what the leader left running. Real time: the exit is the kernel's.
#[tokio::test]
async fn a_leader_that_exits_under_a_descendant_is_reported() {
    let (inbound, mut rx) = mpsc::channel(1024);
    let agent = spawn("sleep 600 & exec sleep 600", inbound).await;
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
    assert!(exited.is_ok(), "the leader's exit was never reported");
    eprintln!("leader exit reported after {:?}", killed.elapsed());
    assert!(!agent.is_alive().await);
}
