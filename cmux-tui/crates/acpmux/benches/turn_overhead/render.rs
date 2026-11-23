//! The bench's render stage: what the cmux NEXT app's chat pane does to show a turn.
//!
//! The pane host (`AcpmuxChatRowsHost.swift` over `AcpmuxClientByteConnection.swift`) holds one
//! acpmux-client core handle naming `["chat"]` on a socket of its own to the daemon. On the page's
//! first `chat.rows.open` it subscribes the chat (`{sid, chat, anchor: "end"}`), marks the handle
//! connected, which queues the `_acpmux/v2` upgrade as the connection's first JSON-RPC line, and
//! writes it. The daemon answers that line and the connection is binary v2 frames from then on;
//! the core sends its hello, then the held sub. Every read goes through `received`, each change
//! comes out of `next_change` (which returns the sub's credit) and is encoded as the FFI hands it
//! to Swift, and whatever `take_send` holds is written at once, so the stream never stalls.

use acpmux_client::chat::{ChatChange, ChatSubRequest};
use acpmux_client::wire::{Anchor, ChatOp};
use acpmux_client::{Change, Client};
use serde_json::Value;
use std::collections::HashMap;
use std::io;
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use super::BoxStream;

/// The daemon's `acpmux.v2` for the pane's chat rows: `chat` (the daemon adds `books` itself).
/// The app ships with `acpmux.v2` empty, where the pane's upgrade is refused and it runs v1.
pub const SURFACES: &[&str] = &["chat"];

/// The pane's sid for the one chat it opens.
const SID: &str = "turn-bench-1";
/// One socket read is at most this much, as the host's (its 64 KiB batch).
const READ_BYTES: usize = 64 << 10;

pub struct ChatRender {
    stream: BoxStream,
    client: Client<Value>,
    /// Bytes read that the core has not taken yet (it takes none while a change is queued).
    pending: Vec<u8>,
    /// When the last read came off the socket: the read whose bytes complete a frame.
    read_at: Instant,
    buf: Vec<u8>,
    /// An open row's text so far by rowId, from its `row` op and the `text` ops after it, so a
    /// marker split across text ops is found.
    texts: HashMap<u64, String>,
    /// Changes taken and their encoded bytes, as the pane would have handed them over.
    pub changes: u64,
    pub change_bytes: u64,
}

fn other(message: impl Into<String>) -> io::Error {
    io::Error::other(message.into())
}

impl ChatRender {
    /// On `stream` (the daemon's unix socket, or a relay circuit to it), does the v2 upgrade and
    /// hello the pane host does, and subscribes `chat_id` as the pane does on open. Returns once
    /// the sub's first window came.
    pub async fn open(stream: BoxStream, chat_id: &str) -> io::Result<Self> {
        let mut client = Client::<Value>::new(["chat"]);
        // The host's order: the sub is held first, then the driver starts and connects.
        client
            .subscribe_chat(ChatSubRequest {
                sid: SID.into(),
                chat: chat_id.into(),
                anchor: Some(Anchor::End),
                window: None,
            })
            .map_err(|error| other(format!("subscribe_chat: {error}")))?;
        client.connected();
        let mut render = Self {
            stream,
            client,
            pending: Vec::new(),
            read_at: Instant::now(),
            buf: vec![0; READ_BYTES],
            texts: HashMap::new(),
            changes: 0,
            change_bytes: 0,
        };
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let change = render.next(deadline).await?;
            if let Change::Chat(ChatChange::Window { .. }) = change {
                return Ok(render);
            }
        }
    }

    /// Reads and feeds bytes until the core gives a change that holds `marker` (text the mock
    /// agent's reply contains). Only changes taken during this call count. Returns when the bytes
    /// that completed it were read off the socket, and when `next_change` returned that change.
    pub async fn wait_for_text(
        &mut self,
        marker: &str,
        timeout: Duration,
    ) -> io::Result<(Instant, Instant)> {
        // A row's JSON holds the marker escaped as its stored JSON does.
        let escaped = serde_json::to_string(marker).map_err(io::Error::other)?;
        let escaped = escaped.get(1..escaped.len() - 1).unwrap_or(marker).to_owned();
        let deadline = Instant::now() + timeout;
        loop {
            let change = self.next(deadline).await?;
            let taken = Instant::now();
            let Change::Chat(change) = change else { continue };
            let holds = match &change {
                ChatChange::Op { op: ChatOp::Text { row_id, text, .. }, .. } => {
                    let piece: String = serde_json::from_str(text.get()).unwrap_or_default();
                    let held = self.texts.entry(*row_id).or_default();
                    held.push_str(&piece);
                    held.contains(marker)
                }
                ChatChange::Op {
                    op: ChatOp::Row { row, .. } | ChatOp::Patch { row, .. }, ..
                } => row.get().contains(&escaped),
                ChatChange::Window { window, .. } => {
                    window.rows.iter().any(|row| row.get().contains(&escaped))
                        || window.open.iter().any(|open| open.row.get().contains(&escaped))
                }
                ChatChange::Page { page } => {
                    page.rows.iter().any(|row| row.get().contains(&escaped))
                }
                _ => false,
            };
            if holds {
                return Ok((self.read_at, taken));
            }
        }
    }

    /// The next change, reading the socket as needed and writing what the core queues.
    async fn next(&mut self, deadline: Instant) -> io::Result<Change<Value>> {
        loop {
            self.flush().await?;
            if let Some(change) = self.client.next_change() {
                self.take(&change)?;
                return Ok(change);
            }
            if self.client.is_closed() {
                return Err(other("the chat connection closed"));
            }
            if !self.pending.is_empty() {
                let used = self.client.received(&self.pending);
                self.pending.drain(..used.min(self.pending.len()));
                if used > 0 {
                    continue;
                }
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "no change before the deadline",
                ));
            }
            let n = match tokio::time::timeout(left, self.stream.read(&mut self.buf)).await {
                Ok(read) => read?,
                Err(_) => {
                    return Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        "no change before the deadline",
                    ));
                }
            };
            if n == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "the daemon closed the chat connection",
                ));
            }
            self.read_at = Instant::now();
            self.pending.extend_from_slice(self.buf.get(..n).unwrap_or_default());
        }
    }

    /// What the host does with a change: refuses a fallback or an ended sub, encodes it as the FFI
    /// hands it over, and keeps an open row's text for the marker.
    fn take(&mut self, change: &Change<Value>) -> io::Result<()> {
        match change {
            Change::Fallback(_) => return Err(other("the daemon answered v1: no v2 chat surface")),
            Change::Error { method, code, .. } => {
                return Err(other(format!("v2 error: {method} {code}")));
            }
            Change::Chat(chat) => {
                if let ChatChange::Error { method, code, .. } = chat
                    && (method != "sub" || code != "not_ready")
                {
                    return Err(other(format!("chat error: {method} {code}")));
                }
                if let ChatChange::Op { op: ChatOp::Row { row, .. }, .. } = chat {
                    self.seed_text(row.get());
                }
                // The FFI's change bytes: a chat change from its rows' bytes as they arrived.
                let bytes = serde_json::to_vec(chat).map_err(io::Error::other)?;
                self.change_bytes += bytes.len() as u64;
            }
            _ => {}
        }
        self.changes += 1;
        Ok(())
    }

    /// A `row` op replaces what is held for its rowId: its text starts over from the row's.
    fn seed_text(&mut self, row: &str) {
        let Ok(value) = serde_json::from_str::<Value>(row) else { return };
        let Some(id) = value.get("id").and_then(Value::as_u64) else { return };
        let text = value.pointer("/body/text").and_then(Value::as_str).unwrap_or_default();
        self.texts.insert(id, text.to_owned());
    }

    async fn flush(&mut self) -> io::Result<()> {
        let mut wrote = false;
        while let Some(bytes) = self.client.take_send() {
            self.stream.write_all(&bytes).await?;
            wrote = true;
        }
        if wrote {
            self.stream.flush().await?;
        }
        Ok(())
    }
}
