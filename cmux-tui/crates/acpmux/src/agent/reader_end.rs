//! How an agent's reader ends: at the end of the agent's output, or after a
//! panic in the reader (cmux-panic-log `supervise`,
//! plans/cmux-next/rust-panic-free.md section 5). A reader that dies
//! without this would leave every request to the agent waiting forever on a
//! reply no one reads, and the session would never hear that the agent ended.

use super::{ChildAgent, Direction, Inbound};
use crate::rpc::{Message, RpcError};
use std::future::Future;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use tokio::sync::mpsc;

impl ChildAgent {
    /// A direct child's output ended: its background shells end, the Codex
    /// translator answers what waits on the app-server, every pending
    /// request fails with `reason`, then the session hears of the exit.
    pub(super) async fn end_of_output(&self, inbound: &mpsc::Sender<Inbound>, reason: &str) {
        // Claude's background shells ended with it (cx-ncc.84).
        if let Some(tr) = &self.translator {
            for m in tr.end_background_shells().await {
                (self.tap)(Direction::In, &m, None);
                if let Message::Notification { method, params } = m {
                    let _ = inbound.send(Inbound::Notification { method, params }).await;
                }
            }
        }
        // The app-server is gone: the translator answers what waits on
        // it and refuses what comes later.
        if let Some(cx) = &self.codex {
            let closed = crate::codex_app_server::split(cx.tr.server_closed("it exited"));
            self.codex_to_hub(cx, closed.hub).await;
        }
        self.fail_pending(reason).await;
        let code = self.wait_exit().await;
        let _ = inbound.send(Inbound::Exited { pid: self.pid, code, host_seq: None }).await;
    }

    /// Fail every request that waits for an answer from this agent.
    pub(super) async fn fail_pending(&self, reason: &str) {
        for (_, tx) in self.pending.lock().await.map.drain() {
            let _ = tx.send(Err(RpcError::internal(reason)));
        }
    }

    /// Run a direct child's stdout reader. A panic in it ends the agent the
    /// way its exit does, so no request and no session waits for it.
    pub(super) async fn supervise_reader(
        self: Arc<Self>,
        reader: impl Future<Output = ()>,
        inbound: mpsc::Sender<Inbound>,
    ) {
        let label = "acpmux agent reader";
        if cmux_panic_log::supervise::catch_future(label, reader).await.is_err() {
            self.kill().await;
            self.end_of_output(&inbound, "agent reader failed").await;
        }
    }

    /// Run a hosted agent's link reader. A panic stops it like an entry it
    /// could not log (the link is broken, so the next request reattaches),
    /// and the requests that wait fail: an entry that panics again after the
    /// reattach must not leave them waiting forever.
    pub(super) async fn supervise_host_reader(self: Arc<Self>, read: impl Future<Output = ()>) {
        let label = "acpmux agent host reader";
        if cmux_panic_log::supervise::catch_future(label, read).await.is_err() {
            if let Some(hosted) = self.hosted.as_ref() {
                hosted.broken.store(true, Ordering::SeqCst);
            }
            self.fail_pending("agent host reader failed").await;
        }
    }
}
