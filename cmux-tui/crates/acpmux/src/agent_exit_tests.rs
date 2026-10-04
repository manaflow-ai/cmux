//! An agent's exit is reported (the `exited` flag, the notify `terminate`
//! waits on) only after the Exit entry's ack is written to the host, so a
//! daemon that ends an agent and exits at once never leaves the host holding
//! an unacknowledged Exit.

use crate::agent::{ChildAgent, Tap};
use crate::agent_host::link::{Adopted, TestWire};
use crate::agent_host::{ControllerFrame, Entry, HostRecord, PROTOCOL_MAX, PROTOCOL_MIN, RECORD_VERSION};
use std::sync::Arc;

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

async fn settle() {
    for _ in 0..100 {
        tokio::task::yield_now().await;
    }
}

#[tokio::test]
async fn an_exit_is_reported_only_after_its_ack_is_written() {
    let (link, mut wire) = TestWire::link(record());
    let adopted = Adopted {
        version: PROTOCOL_MAX,
        host_build: "test".into(),
        incarnation: "inc".into(),
        harness_pid: None,
        last_h: 0,
        acked_h: 0,
        max_out_id: 0,
        exited: None,
    };
    let (inbound, mut drain) = tokio::sync::mpsc::channel(16);
    tokio::spawn(async move { while drain.recv().await.is_some() {} });
    let tap: Tap = Arc::new(|_, _, _| true);
    let (child, _) = ChildAgent::from_link("t", Arc::new(link), &adopted, 0, Vec::new(), inbound, tap);

    wire.entries.send((1, Entry::Exit { code: Some(0) })).await.unwrap();
    settle().await;
    assert!(!child.has_exited(), "the exit was reported before its ack was written");

    let frames = wire.write_all();
    assert!(frames.iter().any(|f| matches!(f, ControllerFrame::Ack { h: 1 })), "{frames:?}");
    settle().await;
    assert!(child.has_exited(), "the exit was not reported after its ack was written");
}
