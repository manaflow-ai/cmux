//! I/O-free client state machine for agent-service v2.

pub mod wire;

use serde::{Serialize, de::DeserializeOwned};
use serde_json::Value;
use std::collections::{HashMap, VecDeque};
use wire::{
    Anchor, Cursor, DeltaFrame, DeltaOp, Frame, FrameDecoder, FrameError, FrameKind, Hello, Limits,
    Page, ReplayMark, Request, Sub, Window,
};

#[derive(Clone, Debug, PartialEq)]
pub enum Change<T> {
    Window(Window<T>),
    Summary { sid: String, seq: u64, summary: T },
    Gone { sid: String, seq: u64, chat_id: String, why: Option<String> },
    Origin { sid: String, seq: u64, origin: wire::Origin },
    Queue { sid: String, seq: u64, bytes: u64 },
    ResumeEnd { sid: String, cursor: Cursor },
    Unconfirmed { sid: String },
    Dropped { sid: String, cursor: Option<Cursor> },
    Error { method: String, sid: Option<String>, id: Option<String>, code: String },
    Fallback(Vec<u8>),
}

#[derive(Clone, Debug)]
struct SubState {
    request: Sub,
    cursor: Cursor,
    edition: u32,
    consumed: u64,
    credited: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Phase {
    Upgrade,
    Hello,
    Ready,
    Fallback,
    Closed,
}

/// A connection's protocol state. The transport owns all I/O.
pub struct Client<T = acpmux_book::index::Summary> {
    phase: Phase,
    surfaces: Vec<String>,
    decoder: FrameDecoder,
    send: VecDeque<Vec<u8>>,
    changes: VecDeque<Change<T>>,
    subscriptions: HashMap<String, SubState>,
    limits: Limits,
    line: Vec<u8>,
    next_id: u64,
}

impl<T> Client<T>
where
    T: Serialize + DeserializeOwned + Clone,
{
    pub fn new(surfaces: impl IntoIterator<Item = impl Into<String>>) -> Self {
        Self {
            phase: Phase::Upgrade,
            surfaces: surfaces.into_iter().map(Into::into).collect(),
            decoder: FrameDecoder::default(),
            send: VecDeque::new(),
            changes: VecDeque::new(),
            subscriptions: HashMap::new(),
            limits: Limits::default(),
            line: Vec::new(),
            next_id: 1,
        }
    }

    pub fn connected_v2() -> Self {
        let mut client = Self::new(std::iter::empty::<String>());
        client.phase = Phase::Hello;
        client.queue_hello();
        client
    }

    pub fn connected(&mut self) {
        if self.phase == Phase::Upgrade {
            let id = self.next_id;
            self.next_id += 1;
            let request = serde_json::json!({"jsonrpc":"2.0","id":id,"method":"_acpmux/v2","params":{"protocol":2,"surfaces":self.surfaces}});
            self.send.push_back(format!("{}\n", request).into_bytes());
        }
    }

    pub fn disconnected(&mut self) {
        if self.phase != Phase::Fallback {
            self.phase = Phase::Upgrade;
        }
        self.line.clear();
    }

    pub fn limits(&self) -> &Limits {
        &self.limits
    }
    pub fn is_fallback(&self) -> bool {
        self.phase == Phase::Fallback
    }
    pub fn take_send(&mut self) -> Option<Vec<u8>> {
        self.send.pop_front()
    }
    pub fn next_change(&mut self) -> Option<Change<T>> {
        self.changes.pop_front()
    }

    pub fn received(&mut self, bytes: &[u8]) -> usize {
        if self.phase == Phase::Fallback {
            self.changes.push_back(Change::Fallback(bytes.to_vec()));
            return bytes.len();
        }
        if self.phase == Phase::Upgrade {
            self.line.extend_from_slice(bytes);
            let Some(end) = self.line.iter().position(|b| *b == b'\n') else {
                return bytes.len();
            };
            let reply = self.line.drain(..=end).collect::<Vec<_>>();
            let value: Value = serde_json::from_slice(&reply).unwrap_or(Value::Null);
            if value.pointer("/error/code").and_then(Value::as_i64) == Some(-32601) {
                self.phase = Phase::Fallback;
                self.changes.push_back(Change::Fallback(self.line.split_off(0)));
                return bytes.len();
            }
            self.phase = Phase::Hello;
            self.queue_hello();
            if !self.line.is_empty() {
                let ahead = self.line.split_off(0);
                return self.received(&ahead).min(bytes.len());
            }
            return bytes.len();
        }
        match self.decoder.push(bytes) {
            Ok(frames) => {
                for frame in frames {
                    self.accept_frame(frame);
                }
            }
            Err(error) => {
                self.phase = Phase::Closed;
                self.changes.push_back(Change::Error {
                    method: "frame".into(),
                    sid: None,
                    id: None,
                    code: error.to_string(),
                });
            }
        }
        bytes.len()
    }

    pub fn subscribe(&mut self, mut sub: Sub) -> Result<(), FrameError> {
        if !wire::identifier_fits(&sub.sid) {
            return Err(FrameError::InvalidLength(sub.sid.len()));
        }
        if sub.cursor.is_none() {
            sub.anchor.get_or_insert(Anchor::End);
        }
        let sid = sub.sid.clone();
        let cursor = sub.cursor.unwrap_or_default();
        let edition = sub.edition.unwrap_or_default();
        self.subscriptions.insert(
            sid,
            SubState { request: sub.clone(), cursor, edition, consumed: 0, credited: 0 },
        );
        self.queue_request(Request::Sub(sub))
    }

    pub fn unsubscribe(&mut self, sid: &str) -> Result<(), FrameError> {
        self.subscriptions.remove(sid);
        self.queue_request(Request::Unsub(wire::Unsub { sid: sid.to_owned() }))
    }

    pub fn page(&mut self, page: Page) -> Result<(), FrameError> {
        self.queue_request(Request::Page(page))
    }

    fn queue_request(&mut self, request: Request) -> Result<(), FrameError> {
        self.send.push_back(Frame::json(FrameKind::Request, &request)?.encode());
        Ok(())
    }

    fn queue_hello(&mut self) {
        let _ = self.queue_request(Request::Hello(Hello {
            client_kind: "acpmux-client".into(),
            protocol: 2,
            identity: None,
        }));
    }

    fn accept_frame(&mut self, frame: Frame) {
        match frame.kind {
            FrameKind::Hello => {
                if let Ok(reply) = frame.decode_json::<wire::HelloReply>() {
                    self.limits = reply.limits;
                    self.phase = Phase::Ready;
                }
            }
            FrameKind::Window => {
                if let Ok(window) = frame.decode_json::<Window<T>>() {
                    if let Some(sub) = self.subscriptions.get_mut(&window.sid) {
                        sub.cursor = Cursor(window.cursor);
                        sub.edition = window.edition;
                    }
                    self.changes.push_back(Change::Window(window));
                }
            }
            FrameKind::Delta => {
                if let Ok(delta) = frame.decode_json::<DeltaFrame<T>>() {
                    self.accept_delta(delta);
                }
            }
            FrameKind::Dropped => {
                if let Ok(drop) = frame.decode_json::<wire::Dropped>() {
                    if let Some(sub) = self.subscriptions.remove(&drop.sid) {
                        let mut request = sub.request;
                        request.cursor = Some(sub.cursor);
                        request.edition = Some(sub.edition);
                        request.anchor = None;
                        let _ = self.queue_request(Request::Sub(request));
                    }
                    self.changes.push_back(Change::Dropped { sid: drop.sid, cursor: drop.cursor });
                }
            }
            FrameKind::Error => {
                if let Ok(value) = frame.decode_json::<Value>() {
                    let sid = value.get("sid").and_then(Value::as_str).map(str::to_owned);
                    let method =
                        value.get("method").and_then(Value::as_str).unwrap_or("unknown").to_owned();
                    let code =
                        value.get("code").and_then(Value::as_str).unwrap_or("error").to_owned();
                    self.changes.push_back(Change::Error {
                        method,
                        sid,
                        id: value.get("id").and_then(Value::as_str).map(str::to_owned),
                        code,
                    });
                }
            }
            _ => {}
        }
    }

    fn accept_delta(&mut self, delta: DeltaFrame<T>) {
        let sid = delta.sid.clone();
        let replay = delta.replay;
        for op in delta.ops {
            match op {
                DeltaOp::Summary { seq, summary } => {
                    self.advance(&sid, seq);
                    self.changes.push_back(Change::Summary { sid: sid.clone(), seq, summary });
                }
                DeltaOp::Gone { seq, chat_id } => {
                    self.advance(&sid, seq);
                    self.changes.push_back(Change::Gone {
                        sid: sid.clone(),
                        seq,
                        chat_id,
                        why: None,
                    });
                }
                DeltaOp::Origin { seq, origin } => {
                    self.advance(&sid, seq);
                    self.changes.push_back(Change::Origin { sid: sid.clone(), seq, origin });
                }
                DeltaOp::Queue { seq, bytes } => {
                    self.advance(&sid, seq);
                    self.changes.push_back(Change::Queue { sid: sid.clone(), seq, bytes });
                }
            }
        }
        if replay == Some(ReplayMark::End) {
            let cursor = self.subscriptions.get(&sid).map(|s| s.cursor).unwrap_or_default();
            self.changes.push_back(Change::ResumeEnd { sid, cursor });
        }
    }

    fn advance(&mut self, sid: &str, seq: u64) {
        let mut credit = None;
        if let Some(sub) = self.subscriptions.get_mut(sid) {
            if seq > sub.cursor.0 {
                sub.cursor = Cursor(seq);
            }
            sub.consumed = sub.consumed.saturating_add(1);
            if sub.consumed.saturating_sub(sub.credited) >= self.limits.credit_window / 4 {
                credit = Some(sub.consumed);
                sub.credited = sub.consumed;
            }
        }
        if let Some(consumed) = credit {
            let _ =
                self.queue_request(Request::Credit(wire::Credit { sid: sid.to_owned(), consumed }));
        }
    }
}

#[cfg(feature = "tokio")]
pub mod tokio_driver {
    use super::*;
    use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
    pub async fn drive<T, R, W>(
        mut client: Client<T>,
        mut reader: R,
        mut writer: W,
        tx: tokio::sync::mpsc::Sender<Change<T>>,
    ) -> std::io::Result<()>
    where
        T: Serialize + DeserializeOwned + Clone + Send + 'static,
        R: AsyncRead + Unpin,
        W: AsyncWrite + Unpin,
    {
        client.connected();
        let mut buf = [0_u8; 16 * 1024];
        loop {
            while let Some(bytes) = client.take_send() {
                writer.write_all(&bytes).await?;
            }
            if let Some(change) = client.next_change() {
                if tx.send(change).await.is_err() {
                    return Ok(());
                }
                continue;
            }
            let n = reader.read(&mut buf).await?;
            if n == 0 {
                return Ok(());
            }
            client.received(&buf[..n]);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn upgrade_is_first_output() {
        let mut c = Client::<Value>::new(["list"]);
        c.connected();
        assert!(std::str::from_utf8(&c.take_send().unwrap()).unwrap().contains("_acpmux/v2"));
    }
}
