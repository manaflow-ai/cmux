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
    Page(PageChange<T>),
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

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PageChange<T> {
    pub sid: String,
    pub rows: Vec<T>,
    #[serde(default)]
    pub has_before: bool,
    #[serde(default)]
    pub has_after: bool,
    #[serde(default)]
    pub cursor: Option<Cursor>,
}

#[derive(Clone, Debug)]
struct SubState {
    request: Sub,
    cursor: Cursor,
    edition: u32,
    consumed: u64,
    credited: u64,
    replaying: bool,
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
    changes: VecDeque<QueuedChange<T>>,
    subscriptions: HashMap<String, SubState>,
    limits: Limits,
    line: Vec<u8>,
    next_id: u64,
    next_sid: u64,
}

struct QueuedChange<T> {
    change: Change<T>,
    sid: Option<String>,
    bytes: u64,
    charge: bool,
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
            next_sid: 1,
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
        let queued = self.changes.pop_front()?;
        if queued.charge {
            if let Some(sid) = queued.sid.as_deref() {
                let mut credit = None;
                if let Some(sub) = self.subscriptions.get_mut(sid) {
                    sub.consumed = sub.consumed.saturating_add(queued.bytes);
                    if sub.consumed.saturating_sub(sub.credited) >= self.limits.credit_window / 4 {
                        sub.credited = sub.consumed;
                        credit = Some(sub.consumed);
                    }
                }
                if let Some(consumed) = credit {
                    let _ = self.queue_request(Request::Credit(wire::Credit {
                        sid: sid.to_owned(),
                        consumed,
                    }));
                }
            }
        }
        Some(queued.change)
    }

    pub fn received(&mut self, bytes: &[u8]) -> usize {
        if self.phase == Phase::Fallback {
            return 0;
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
                let rest = bytes.get(end.saturating_add(1)..).unwrap_or_default().to_vec();
                if !rest.is_empty() {
                    self.push_change(Change::Fallback(rest), None, 0, false);
                }
                return end.saturating_add(1);
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
                    if !self.changes.is_empty() {
                        break;
                    }
                }
            }
            Err(error) => {
                self.phase = Phase::Closed;
                self.push_change(
                    Change::Error {
                        method: "frame".into(),
                        sid: None,
                        id: None,
                        code: error.to_string(),
                    },
                    None,
                    0,
                    false,
                );
            }
        }
        bytes.len()
    }

    pub fn subscribe(&mut self, mut sub: Sub) -> Result<String, FrameError> {
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
            sid.clone(),
            SubState {
                request: sub.clone(),
                cursor,
                edition,
                consumed: 0,
                credited: 0,
                replaying: sub.cursor.is_some(),
            },
        );
        if self.phase == Phase::Ready {
            self.queue_request(Request::Sub(sub))?;
        }
        Ok(sid)
    }

    pub fn unsubscribe(&mut self, sid: &str) -> Result<(), FrameError> {
        self.subscriptions.remove(sid);
        if self.phase == Phase::Ready {
            self.queue_request(Request::Unsub(wire::Unsub { sid: sid.to_owned() }))?;
        }
        Ok(())
    }

    pub fn page(&mut self, page: Page) -> Result<(), FrameError> {
        if self.phase == Phase::Ready {
            self.queue_request(Request::Page(page))?;
        }
        Ok(())
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

    fn push_change(&mut self, change: Change<T>, sid: Option<String>, bytes: u64, charge: bool) {
        self.changes.push_back(QueuedChange { change, sid, bytes, charge });
    }

    fn queue_subscriptions(&mut self) {
        let requests: Vec<Sub> =
            self.subscriptions.values().map(|state| state.request.clone()).collect();
        for request in requests {
            let _ = self.queue_request(Request::Sub(request));
        }
    }

    fn accept_frame(&mut self, frame: Frame) {
        let frame_bytes = frame.encoded_len() as u64;
        match frame.kind {
            FrameKind::Hello => {
                if let Ok(reply) = frame.decode_json::<wire::HelloReply>() {
                    self.limits = reply.limits;
                    self.phase = Phase::Ready;
                    self.queue_subscriptions();
                }
            }
            FrameKind::Window => {
                if let Ok(window) = frame.decode_json::<Window<T>>() {
                    let sid = window.sid.clone();
                    let replaying =
                        self.subscriptions.get(&sid).map(|sub| sub.replaying).unwrap_or(false);
                    if let Some(sub) = self.subscriptions.get_mut(&sid) {
                        sub.cursor = Cursor(window.cursor);
                        sub.edition = window.edition;
                        sub.replaying = false;
                    }
                    self.push_change(Change::Window(window), Some(sid.clone()), frame_bytes, true);
                    if replaying {
                        self.push_change(Change::Unconfirmed { sid }, None, 0, false);
                    }
                }
            }
            FrameKind::Page => {
                if let Ok(page) = frame.decode_json::<PageChange<T>>() {
                    let sid = page.sid.clone();
                    self.push_change(Change::Page(page), Some(sid), frame_bytes, true);
                }
            }
            FrameKind::Delta => {
                if let Ok(delta) = frame.decode_json::<DeltaFrame<T>>() {
                    self.accept_delta(delta, frame_bytes);
                }
            }
            FrameKind::Dropped => {
                if let Ok(drop) = frame.decode_json::<wire::Dropped>() {
                    self.accept_dropped(drop);
                }
            }
            FrameKind::Error => {
                if let Ok(value) = frame.decode_json::<Value>() {
                    let sid = value.get("sid").and_then(Value::as_str).map(str::to_owned);
                    let method =
                        value.get("method").and_then(Value::as_str).unwrap_or("unknown").to_owned();
                    let code =
                        value.get("code").and_then(Value::as_str).unwrap_or("error").to_owned();
                    if let Some(ref sid) = sid {
                        self.subscriptions.remove(sid);
                    }
                    self.push_change(
                        Change::Error {
                            method,
                            sid: sid.clone(),
                            id: value.get("id").and_then(Value::as_str).map(str::to_owned),
                            code,
                        },
                        sid,
                        frame_bytes,
                        true,
                    );
                }
            }
            FrameKind::Unknown(_) => {}
            _ => self.push_change(
                Change::Error {
                    method: "frame".into(),
                    sid: None,
                    id: None,
                    code: "unsupported_frame".into(),
                },
                None,
                frame_bytes,
                false,
            ),
        }
    }

    fn accept_delta(&mut self, delta: DeltaFrame<T>, frame_bytes: u64) {
        let sid = delta.sid.clone();
        let replay = delta.replay;
        let mut first = true;
        for op in delta.ops {
            let charge = first;
            first = false;
            match op {
                DeltaOp::Summary { seq, summary } => {
                    self.advance(&sid, seq);
                    self.push_change(
                        Change::Summary { sid: sid.clone(), seq, summary },
                        Some(sid.clone()),
                        frame_bytes,
                        charge,
                    );
                }
                DeltaOp::Gone { seq, chat_id } => {
                    self.advance(&sid, seq);
                    self.push_change(
                        Change::Gone { sid: sid.clone(), seq, chat_id, why: None },
                        Some(sid.clone()),
                        frame_bytes,
                        charge,
                    );
                }
                DeltaOp::Origin { seq, origin } => {
                    self.advance(&sid, seq);
                    self.push_change(
                        Change::Origin { sid: sid.clone(), seq, origin },
                        Some(sid.clone()),
                        frame_bytes,
                        charge,
                    );
                }
                DeltaOp::Queue { seq, bytes } => {
                    self.advance(&sid, seq);
                    self.push_change(
                        Change::Queue { sid: sid.clone(), seq, bytes },
                        Some(sid.clone()),
                        frame_bytes,
                        charge,
                    );
                }
            }
        }
        if replay == Some(ReplayMark::End) {
            let cursor = self.subscriptions.get(&sid).map(|s| s.cursor).unwrap_or_default();
            if let Some(sub) = self.subscriptions.get_mut(&sid) {
                sub.replaying = false;
            }
            self.push_change(Change::ResumeEnd { sid, cursor }, None, 0, false);
        }
    }

    fn advance(&mut self, sid: &str, seq: u64) {
        if let Some(sub) = self.subscriptions.get_mut(sid) {
            if seq > sub.cursor.0 {
                sub.cursor = Cursor(seq);
            }
        }
    }

    fn accept_dropped(&mut self, drop: wire::Dropped) {
        let Some(mut sub) = self.subscriptions.remove(&drop.sid) else {
            self.push_change(
                Change::Dropped { sid: drop.sid, cursor: drop.cursor },
                None,
                0,
                false,
            );
            return;
        };
        let new_sid = loop {
            let candidate = format!("{}~{}", drop.sid, self.next_sid);
            self.next_sid = self.next_sid.saturating_add(1);
            if wire::identifier_fits(&candidate) && !self.subscriptions.contains_key(&candidate) {
                break candidate;
            }
        };
        sub.request.sid = new_sid.clone();
        sub.request.cursor = Some(sub.cursor);
        sub.request.edition = Some(sub.edition);
        sub.request.anchor = None;
        sub.replaying = true;
        self.subscriptions.insert(new_sid, sub.clone());
        if self.phase == Phase::Ready {
            let _ = self.queue_request(Request::Sub(sub.request));
        }
        self.push_change(Change::Dropped { sid: drop.sid, cursor: drop.cursor }, None, 0, false);
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
