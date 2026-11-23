//! Part of `transfer.rs`. A move's connection to a daemon that comes back after the daemon is
//! swapped (`acpmux daemon run --take-over`, an update, a restart) instead of failing the move.
//!
//! 2026-11-22: a coordinator's move to a lane VM died with "daemon connection closed while
//! sending _acpmux/transfer_read: the daemon (pid 19247) is still running but dropped this
//! connection" when the nightly daemon took over mid-copy, and its abort died the same way on the
//! new daemon, which left the chat frozen ("it is being moved already") with no move running.
//!
//! What a move has done lives on disk on both sides (the source's `transfers/<move>` with its
//! epoch, the target's receive or stage), and the new daemon restores the chat's move from its
//! log, so the move goes on against the daemon now at the same socket: the request that lost its
//! connection is sent again there. A page written whose answer was lost is caught by the
//! target's offset check (`transfer.offset` with the size it holds), and the pages go on from
//! there (`transfer_live.rs` `page_files`).

use super::*;
use crate::client::TransportClosed;
use std::time::{Duration, Instant};

/// How long a move waits for a daemon that dropped its connection to answer again.
pub(crate) const RECONNECT_FOR: Duration = Duration::from_secs(120);
const RECONNECT_EVERY: Duration = Duration::from_millis(500);

/// A daemon a move talks to: the client it started with, and the one it reconnected with when
/// that one's connection dropped.
pub(crate) struct Daemon<'a> {
    first: &'a Client,
    socket: std::path::PathBuf,
    /// Which end this is, for the line a reconnect prints (`source`, `target`).
    label: &'static str,
    again: tokio::sync::Mutex<Option<std::sync::Arc<Client>>>,
}

/// Whether `e` is a lost connection, not an answer from the daemon.
pub(crate) fn connection_lost(e: &anyhow::Error) -> bool {
    e.chain().any(|c| c.downcast_ref::<TransportClosed>().is_some())
}

impl<'a> Daemon<'a> {
    pub(crate) fn over(first: &'a Client, label: &'static str) -> Self {
        Self { first, socket: first.socket().to_path_buf(), label, again: Default::default() }
    }

    /// `m` with `params`, sent again on a new connection to the same socket when the daemon
    /// dropped this one, for up to [`RECONNECT_FOR`].
    pub(crate) async fn request(&self, m: &str, params: Value) -> Result<Value> {
        let deadline = Instant::now() + RECONNECT_FOR;
        loop {
            let again = self.again.lock().await.clone();
            let sent = match &again {
                Some(c) => c.request(m, params.clone()).await,
                None => self.first.request(m, params.clone()).await,
            };
            match sent {
                Err(e) if connection_lost(&e) && Instant::now() < deadline => {
                    eprintln!(
                        "move: the {} daemon dropped the connection during {m} ({e}); connecting again",
                        self.label
                    );
                    let client = self.reconnect(deadline).await.map_err(|again| {
                        anyhow!(
                            "the {} daemon did not answer again ({again:#}) after: {e}",
                            self.label
                        )
                    })?;
                    *self.again.lock().await = Some(client);
                }
                other => return other,
            }
        }
    }

    /// A new connection to the socket (its hello included, `Client::connect`), once the daemon
    /// there answers.
    async fn reconnect(&self, deadline: Instant) -> Result<std::sync::Arc<Client>> {
        loop {
            match Client::connect(&self.socket).await {
                Ok(client) => return Ok(client),
                Err(e) if Instant::now() >= deadline => return Err(e),
                Err(_) => tokio::time::sleep(RECONNECT_EVERY).await,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncBufReadExt as _, AsyncWriteExt as _, BufReader};

    /// A daemon swapped mid-move (its first connection drops on the first page) is reached again
    /// at the same socket, and the page is asked again there: the move goes on.
    #[cfg(unix)]
    #[tokio::test]
    async fn a_request_whose_daemon_was_swapped_is_sent_again_to_the_new_one() {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("d.sock");
        let listener = tokio::net::UnixListener::bind(&socket).unwrap();
        let served = tokio::spawn(async move {
            // Each daemon answers what it is asked, the old one until the page: it goes away
            // with that unanswered.
            let mut asked = Vec::new();
            for old in [true, false] {
                let (conn, _) = listener.accept().await.unwrap();
                let (rd, mut wr) = conn.into_split();
                let mut lines = BufReader::new(rd).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    let v: Value = serde_json::from_str(&line).unwrap();
                    let m = v["method"].as_str().unwrap_or_default().to_owned();
                    asked.push(m.clone());
                    if old && m == "_acpmux/transfer_read" {
                        break;
                    }
                    let reply = json!({"jsonrpc": "2.0", "id": v["id"], "result": {"ok": true}});
                    wr.write_all(format!("{reply}\n").as_bytes()).await.unwrap();
                    if m == "_acpmux/transfer_read" {
                        break;
                    }
                }
            }
            asked
        });
        let first = Client::connect(&socket).await.unwrap();
        let daemon = Daemon::over(&first, "source");
        let page = daemon.request("_acpmux/transfer_read", json!({"offset": 0})).await.unwrap();
        assert_eq!(page["ok"], true);
        let asked = served.await.unwrap();
        let (hello, page) = (method::INITIALIZE.to_owned(), "_acpmux/transfer_read".to_owned());
        assert_eq!(
            asked,
            vec![hello.clone(), page.clone(), hello, page],
            "asked again on the new one"
        );
    }
}
