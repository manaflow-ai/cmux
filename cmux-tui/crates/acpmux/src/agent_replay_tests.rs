//! Adoption waits for a host's replay as long as entries keep arriving: a
//! large backlog that takes longer than one stall period is still logged in
//! full before recovery reads the log (a partial log marks a running turn
//! outcome_unknown).

use crate::agent::{ChildAgent, Tap};
use crate::agent_host::link::{Adopted, TestWire};
use crate::agent_host::{Entry, HostRecord, PROTOCOL_MAX, PROTOCOL_MIN, RECORD_VERSION};
use std::sync::Arc;
use std::time::Duration;

fn record() -> HostRecord {
    HostRecord {
        record_version: RECORD_VERSION,
        session_id: "s".into(),
        incarnation: "inc".into(),
        host_pid: std::process::id(),
        start_nonce: "n".into(),
        harness_pid: None,
        owner_token: "00".into(),
        protocol_min: PROTOCOL_MIN,
        protocol_max: PROTOCOL_MAX,
        host_build: "test".into(),
        socket: "/nonexistent".into(),
    }
}

#[tokio::test]
async fn a_replay_that_keeps_progressing_is_waited_for_past_one_stall_period() {
    let (link, wire) = TestWire::link(record());
    let adopted = Adopted {
        version: PROTOCOL_MAX,
        host_build: "test".into(),
        incarnation: "inc".into(),
        harness_pid: None,
        last_h: 5,
        acked_h: 0,
        max_out_id: 0,
        exited: None,
    };
    let (inbound, mut drain) = tokio::sync::mpsc::channel(16);
    tokio::spawn(async move { while drain.recv().await.is_some() {} });
    let tap: Tap = Arc::new(|_, _, _| true);
    let (child, _) =
        ChildAgent::from_link("t", Arc::new(link), &adopted, 0, Vec::new(), inbound, tap);
    // Five entries, 300 ms apart: 1.5 s in all, each well inside a 1 s stall.
    let feeder = tokio::spawn(async move {
        for h in 1..=5u64 {
            tokio::time::sleep(Duration::from_millis(300)).await;
            let line = format!("line {h}");
            wire.entries.send((h, Entry::Err { line })).await.unwrap();
        }
        wire
    });
    assert!(
        child.wait_replayed(5, Duration::from_secs(1)).await,
        "adoption gave up on a replay that was still progressing"
    );
    let _ = feeder.await;
}
