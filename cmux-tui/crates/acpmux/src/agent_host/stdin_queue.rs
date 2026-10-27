//! The lines on their way to a harness's stdin. A writer task drains them
//! into the pipe, so a full pipe never blocks the host's event loop; the
//! bytes still waiting are counted, and past [`STDIN_PENDING_CAP`] the
//! harness counts as stuck (it stopped reading), and the host ends it
//! rather than keep growing. Chrome's input hang monitor marks a renderer
//! that stops taking its input unresponsive in the same way
//! (content/browser/renderer_host/render_widget_host_impl.cc,
//! `RendererIsUnresponsive`); with no person to ask, the host ends it.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use tokio::io::AsyncWriteExt;
use tokio::sync::mpsc;

/// Bytes waiting for a harness's stdin past which it counts as stuck. A
/// harness reads its stdin as the controller writes; this is far above any
/// prompt with its attachments.
pub(super) const STDIN_PENDING_CAP: usize = 64 << 20;

/// The harness stopped reading: this many bytes wait for its stdin.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct StdinStuck {
    pub(super) waiting: usize,
}

/// The sending side of a harness's stdin.
pub(super) struct StdinQueue {
    tx: mpsc::UnboundedSender<String>,
    pending: Arc<AtomicUsize>,
    cap: usize,
}

impl StdinQueue {
    /// Starts the writer task for `stdin`; it ends when the pipe fails or
    /// the queue is dropped.
    pub(super) fn start<W>(stdin: W, cap: usize) -> StdinQueue
    where
        W: tokio::io::AsyncWrite + Unpin + Send + 'static,
    {
        let pending = Arc::new(AtomicUsize::new(0));
        // unbounded-allow: `pending` counts the queued bytes and `send` refuses a line past `cap`
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let written = pending.clone();
        // task-owner: drains into the harness's pipe; ends with the pipe or the queue.
        tokio::spawn(async move {
            let mut stdin = stdin;
            while let Some(line) = rx.recv().await {
                if stdin.write_all(line.as_bytes()).await.is_err() || stdin.flush().await.is_err() {
                    break;
                }
                written.fetch_sub(line.len(), Ordering::AcqRel);
            }
        });
        StdinQueue { tx, pending, cap }
    }

    /// Queues `line`, or refuses it when it would put more than the cap in
    /// waiting bytes. A line after the writer ended is dropped: the harness
    /// closed its stdin.
    pub(super) fn send(&self, line: String) -> Result<(), StdinStuck> {
        let len = line.len();
        let waiting = self.pending.fetch_add(len, Ordering::AcqRel) + len;
        if waiting > self.cap {
            self.pending.fetch_sub(len, Ordering::AcqRel);
            return Err(StdinStuck { waiting: waiting - len });
        }
        if self.tx.send(line).is_err() {
            self.pending.fetch_sub(len, Ordering::AcqRel);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncReadExt;

    #[tokio::test]
    async fn a_harness_that_stops_reading_is_refused_past_the_cap() {
        // A 16-byte pipe nobody reads: the writer blocks once it is full.
        let (writer, _reader) = tokio::io::duplex(16);
        let queue = StdinQueue::start(writer, 64);
        for _ in 0..4 {
            queue.send("x".repeat(16)).unwrap();
        }
        assert_eq!(queue.send("y".into()), Err(StdinStuck { waiting: 64 }));
    }

    #[tokio::test]
    async fn written_bytes_free_their_room() {
        let (writer, mut reader) = tokio::io::duplex(1024);
        let queue = StdinQueue::start(writer, 8);
        let mut got = Vec::new();
        for line in ["aaaaaa\n", "bbbbbb\n", "cccccc\n"] {
            queue.send(line.to_owned()).unwrap();
            let mut buf = [0u8; 7];
            reader.read_exact(&mut buf).await.unwrap();
            got.extend_from_slice(&buf);
        }
        assert_eq!(got, b"aaaaaa\nbbbbbb\ncccccc\n");
    }
}
