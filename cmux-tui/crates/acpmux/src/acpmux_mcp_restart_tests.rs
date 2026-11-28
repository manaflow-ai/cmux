//! A send through a daemon update or restart (Leo, 2026-11-27, a lane whose daemon dropped a
//! message mid-update: "ok well we should be able to just hold those messages"): the MCP `send`
//! tool holds the message, dials the next daemon and sends the same prompt id again, so it lands
//! exactly once.
//!
//! A proxy socket stands in front of a real daemon and plays the update: the first connection
//! carries the send to the daemon and closes before its answer comes back (the old daemon took
//! it and went away), the next dial finds nothing there (the gap between daemons), and every
//! later one reaches the daemon (the new one, with the old one's outbox).

use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};

/// The update a send sees: what the proxy does with its `n`th connection.
fn update(n: usize) -> &'static str {
    match n {
        0 => "cut-after-send",
        1 => "gone",
        _ => "through",
    }
}

/// Serve `proxy` in front of `daemon` as `play` says, counting the connections in `dials`.
fn proxy(
    proxy: &std::path::Path,
    daemon: std::path::PathBuf,
    dials: Arc<AtomicUsize>,
    play: fn(usize) -> &'static str,
) {
    let listener = UnixListener::bind(proxy).unwrap();
    tokio::spawn(async move {
        loop {
            let Ok((front, _)) = listener.accept().await else { return };
            let n = dials.fetch_add(1, Ordering::SeqCst);
            let daemon = daemon.clone();
            tokio::spawn(async move {
                if play(n) == "gone" {
                    drop(front);
                    return;
                }
                let back = UnixStream::connect(&daemon).await.unwrap();
                let (front_rd, mut front_wr) = front.into_split();
                let (mut back_rd, mut back_wr) = back.into_split();
                let answers = tokio::spawn(async move {
                    let _ = tokio::io::copy(&mut back_rd, &mut front_wr).await;
                });
                let mut lines = BufReader::new(front_rd).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    let send = line.contains(method::MUX_SEND_QUEUE);
                    if back_wr.write_all(format!("{line}\n").as_bytes()).await.is_err() {
                        break;
                    }
                    if send && play(n) == "cut-after-send" {
                        // The daemon queues it durably; its answer never reaches the sender.
                        answers.abort();
                        tokio::time::sleep(Duration::from_millis(300)).await;
                        return;
                    }
                }
                answers.abort();
            });
        }
    });
}

#[tokio::test]
async fn a_send_through_a_daemon_restart_lands_exactly_once() {
    let (_hub, direct, dir) = super::tests::daemon().await;
    let lane = super::tests::session(&direct, "lane-hold").await;
    let front = dir.path().join("p.sock");
    let dials = Arc::new(AtomicUsize::new(0));
    proxy(&front, dir.path().join("d.sock"), dials.clone(), update);
    let sender = Client::connect(&front).await.unwrap();
    let text = format!("hold-me-{}", uuid::Uuid::now_v7());
    let r = call(&sender, &json!({"name": "send", "arguments": {"to": "lane-hold", "text": text}}))
        .await;
    assert_eq!(r["isError"], false, "the send was dropped across the restart: {r}");
    assert!(dials.load(Ordering::SeqCst) >= 3, "the restart was not played");
    let delivery = r["structuredContent"]["deliveryId"].as_str().unwrap_or_default().to_owned();
    let status = direct
        .request(method::MUX_SEND_STATUS, json!({"deliveryId": delivery, "waitMs": 10_000}))
        .await
        .unwrap();
    assert_eq!(status["status"], "delivered", "{status}");
    assert_eq!(status["promptId"], r["structuredContent"]["promptId"], "{status} {r}");
    // Give a second copy, if the resend made one, time to run before counting.
    tokio::time::sleep(Duration::from_millis(500)).await;
    let replies = last_replies(&direct, &lane, 10).await.unwrap();
    let echoed = replies.iter().filter(|reply| reply.contains(&text)).count();
    assert_eq!(echoed, 1, "delivered {echoed} times, not once: {replies:?}");
}

/// The tools process's connection: a call after its daemon went away waits for the next one,
/// rather than fail at the dial.
#[tokio::test]
async fn a_tool_call_after_the_daemon_went_away_waits_for_the_next() {
    let (_hub, _direct, dir) = super::tests::daemon().await;
    let front = dir.path().join("p.sock");
    let dials = Arc::new(AtomicUsize::new(0));
    // The first dial reaches the daemon, the second finds the gap, the third the next daemon.
    let restart = |n| if n == 1 { "gone" } else { "through" };
    proxy(&front, dir.path().join("d.sock"), dials.clone(), restart);
    let daemon = crate::tools_mcp::Daemon::at(front);
    drop(daemon.client().await.unwrap());
    daemon.release();
    let next = daemon.client().await.expect("the call failed in the daemon's gap");
    next.request(method::MUX_SEND_STATUS, json!({"list": true, "limit": 1})).await.ok();
    assert_eq!(dials.load(Ordering::SeqCst), 3, "the gap was not played");
}
