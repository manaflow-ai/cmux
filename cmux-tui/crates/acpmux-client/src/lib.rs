//! I/O-free client state machine for agent-service v2.

pub mod wire;

use serde::{Serialize, de::DeserializeOwned};
use serde_json::Value;
use std::collections::{HashMap, VecDeque};
use wire::{
    Anchor, Cursor, DeltaOp, Frame, FrameError, FrameKind, Hello, Limits, Page, Request, Sub,
    Window,
};

#[derive(Clone, Debug, PartialEq)]
pub enum Change<T> {
    Window(Window<T>),
    Page(PageChange<T>),
    Summary { sid: String, seq: u64, summary: T, replay: bool },
    Gone { sid: String, seq: u64, chat_id: String, why: Option<String>, replay: bool },
    Origin { sid: String, seq: u64, origin: wire::Origin, replay: bool },
    Queue { sid: String, seq: u64, bytes: u64, replay: bool },
    ResumeEnd { sid: String, cursor: Cursor },
    Unconfirmed { sid: String },
    Dropped { sid: String, cursor: Option<Cursor>, new_sid: Option<String> },
    Error { method: String, sid: Option<String>, id: Option<String>, code: String },
    Fallback(Vec<u8>),
}

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PageChange<T> {
    pub sid: String,
    #[serde(alias = "data")]
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

#[derive(Clone, Debug, Default)]
struct PageState {
    request: Option<Page>,
    changed_keys: std::collections::HashSet<String>,
    removed_origins: std::collections::HashSet<String>,
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
    frame_buf: Vec<u8>,
    frame_total: Option<usize>,
    send: VecDeque<Vec<u8>>,
    changes: VecDeque<QueuedChange<T>>,
    subscriptions: HashMap<String, SubState>,
    pages: HashMap<String, PageState>,
    limits: Limits,
    line: Vec<u8>,
    next_id: u64,
    next_sid: u64,
    direct_v2: bool,
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
            frame_buf: Vec::new(),
            frame_total: None,
            send: VecDeque::new(),
            changes: VecDeque::new(),
            subscriptions: HashMap::new(),
            pages: HashMap::new(),
            limits: Limits::default(),
            line: Vec::new(),
            next_id: 1,
            next_sid: 1,
            direct_v2: false,
        }
    }

    pub fn connected_v2() -> Self {
        let mut client = Self::new(std::iter::empty::<String>());
        client.phase = Phase::Hello;
        client.direct_v2 = true;
        client.queue_hello();
        client
    }

    pub fn connected(&mut self) {
        if self.phase == Phase::Upgrade {
            let id = self.next_id;
            self.next_id += 1;
            let request = serde_json::json!({"jsonrpc":"2.0","id":id,"method":"_acpmux/v2","params":{"protocol":2,"surfaces":self.surfaces}});
            self.send.push_back(format!("{request}\n").into_bytes());
        }
    }

    pub fn disconnected(&mut self) {
        if self.phase != Phase::Fallback {
            self.phase = if self.direct_v2 { Phase::Hello } else { Phase::Upgrade };
        }
        self.send.clear();
        self.frame_buf.clear();
        self.frame_total = None;
        self.line.clear();
        for sub in self.subscriptions.values_mut() {
            sub.request.cursor = Some(sub.cursor);
            sub.request.edition = Some(sub.edition);
            sub.request.anchor = None;
            sub.replaying = true;
            sub.consumed = 0;
            sub.credited = 0;
        }
        if self.direct_v2 {
            self.queue_hello();
        }
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
        if queued.charge
            && let Some(sid) = queued.sid.as_deref()
        {
            let mut credit = None;
            if let Some(sub) = self.subscriptions.get_mut(sid) {
                sub.consumed = sub.consumed.saturating_add(queued.bytes);
                if sub.consumed.saturating_sub(sub.credited) >= self.limits.credit_window / 4 {
                    sub.credited = sub.consumed;
                    credit = Some(sub.consumed);
                }
            }
            if let Some(consumed) = credit {
                let _ = self
                    .queue_request(Request::Credit(wire::Credit { sid: sid.to_owned(), consumed }));
            }
        }
        Some(queued.change)
    }

    pub fn received(&mut self, bytes: &[u8]) -> usize {
        if matches!(self.phase, Phase::Fallback | Phase::Closed) || !self.changes.is_empty() {
            return 0;
        }
        if self.phase == Phase::Upgrade {
            let Some(end) = bytes.iter().position(|b| *b == b'\n') else {
                self.line.extend_from_slice(bytes);
                if self.line.len() > wire::MAX_FRAME_BYTES {
                    self.protocol_error("upgrade line too large");
                }
                return bytes.len();
            };
            self.line.extend_from_slice(bytes.get(..=end).unwrap_or(bytes));
            let reply = std::mem::take(&mut self.line);
            if reply.len() > wire::MAX_FRAME_BYTES {
                self.protocol_error("upgrade line too large");
                return bytes.len();
            }
            let value: Value = serde_json::from_slice(&reply).unwrap_or(Value::Null);
            if value.pointer("/error/code").and_then(Value::as_i64) == Some(-32601) {
                self.phase = Phase::Fallback;
                let rest = bytes.get(end.saturating_add(1)..).unwrap_or_default().to_vec();
                self.push_change(Change::Fallback(rest), None, 0, false);
                return bytes.len();
            }
            self.phase = Phase::Hello;
            self.queue_hello();
            let remainder = bytes.get(end.saturating_add(1)..).unwrap_or_default();
            if !remainder.is_empty() {
                return end.saturating_add(1).saturating_add(self.received(remainder));
            }
            return end.saturating_add(1);
        }
        match self.take_frame(bytes) {
            Ok((Some(frame), consumed)) => {
                self.accept_frame(frame);
                return consumed;
            }
            Ok((None, consumed)) => return consumed,
            Err(error) => {
                self.protocol_error(&error.to_string());
            }
        }
        bytes.len()
    }

    fn protocol_error(&mut self, code: &str) {
        self.phase = Phase::Closed;
        self.push_change(
            Change::Error { method: "frame".into(), sid: None, id: None, code: code.to_owned() },
            None,
            0,
            false,
        );
    }

    fn take_frame(&mut self, bytes: &[u8]) -> Result<(Option<Frame>, usize), FrameError> {
        if self.frame_buf.is_empty() && self.frame_total.is_none() && bytes.len() >= 4 {
            let header = bytes.get(..4).ok_or(FrameError::Truncated)?;
            let len =
                u32::from_be_bytes(header.try_into().map_err(|_| FrameError::Truncated)?) as usize;
            let max_body = (self.limits.max_frame as usize).saturating_sub(4);
            if !(1..=max_body).contains(&len) {
                return Err(FrameError::InvalidLength(len));
            }
            let total = len.saturating_add(4);
            if bytes.len() >= total {
                return Ok((
                    Some(Frame::from_encoded(bytes.get(..total).ok_or(FrameError::Truncated)?)?),
                    total,
                ));
            }
        }
        let need = self.frame_total.map_or(4, |total| total).saturating_sub(self.frame_buf.len());
        let used = need.min(bytes.len());
        self.frame_buf.extend_from_slice(bytes.get(..used).unwrap_or_default());
        if self.frame_total.is_none() && self.frame_buf.len() >= 4 {
            let header = self.frame_buf.get(..4).ok_or(FrameError::Truncated)?;
            let len =
                u32::from_be_bytes(header.try_into().map_err(|_| FrameError::Truncated)?) as usize;
            let max_body = (self.limits.max_frame as usize).saturating_sub(4);
            if !(1..=max_body).contains(&len) {
                return Err(FrameError::InvalidLength(len));
            }
            self.frame_total = Some(len.saturating_add(4));
        }
        let Some(total) = self.frame_total else {
            return Ok((None, used));
        };
        if self.frame_buf.len() < total {
            return Ok((None, used));
        }
        let encoded = std::mem::take(&mut self.frame_buf);
        self.frame_total = None;
        Ok((Some(Frame::from_encoded(encoded.get(..total).ok_or(FrameError::Truncated)?)?), used))
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
        if !wire::identifier_fits(&page.sid) {
            return Err(FrameError::InvalidLength(page.sid.len()));
        }
        if self.pages.contains_key(&page.sid) {
            return Err(FrameError::RequestInFlight);
        }
        let sid = page.sid.clone();
        self.pages.insert(sid, PageState { request: Some(page.clone()), ..PageState::default() });
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
        let requests: Vec<Page> =
            self.pages.values().filter_map(|page| page.request.clone()).collect();
        for request in requests {
            let _ = self.queue_request(Request::Page(request));
        }
    }

    fn accept_frame(&mut self, frame: Frame) {
        let frame_bytes = frame.encoded_len() as u64;
        match frame.kind {
            FrameKind::Hello => {
                let Ok(reply) = frame.decode_json::<wire::HelloReply>() else {
                    self.protocol_error("malformed hello");
                    return;
                };
                self.limits = reply.limits;
                self.phase = Phase::Ready;
                self.queue_subscriptions();
            }
            FrameKind::Window => {
                let Ok(window) = frame.decode_json::<Window<T>>() else {
                    self.protocol_error("malformed window");
                    return;
                };
                let sid = window.sid.clone();
                if !self.subscriptions.contains_key(&sid) {
                    self.charge_frame_now(None, frame_bytes);
                    return;
                }
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
            FrameKind::Page => {
                let Ok(mut page) = frame.decode_json::<PageChange<T>>() else {
                    self.protocol_error("malformed page");
                    return;
                };
                let sid = page.sid.clone();
                if !self.subscriptions.contains_key(&sid) {
                    self.charge_frame_now(None, frame_bytes);
                    return;
                }
                let state = self.pages.remove(&sid).unwrap_or_default();
                page.rows.retain(|row| {
                    let Some(value) = serde_json::to_value(row).ok() else { return true };
                    let key = value
                        .get("chatId")
                        .or_else(|| value.get("sessionId"))
                        .and_then(Value::as_str)
                        .map(str::to_owned);
                    if let Some(key) = key.as_deref()
                        && state.changed_keys.contains(key)
                    {
                        return false;
                    }
                    let origin = value.get("origin").and_then(Value::as_str);
                    !origin.is_some_and(|origin| state.removed_origins.contains(origin))
                });
                self.push_change(Change::Page(page), Some(sid), frame_bytes, true);
            }
            FrameKind::Delta => {
                let Ok(value) = frame.decode_json::<Value>() else {
                    self.protocol_error("malformed delta");
                    return;
                };
                self.accept_delta_value(value, frame_bytes);
            }
            FrameKind::Dropped => {
                let Ok(drop) = frame.decode_json::<wire::Dropped>() else {
                    self.protocol_error("malformed dropped");
                    return;
                };
                self.accept_dropped(drop, frame_bytes);
            }
            FrameKind::Error => {
                let Ok(value) = frame.decode_json::<Value>() else {
                    self.protocol_error("malformed error");
                    return;
                };
                let sid = value.get("sid").and_then(Value::as_str).map(str::to_owned);
                let method =
                    value.get("method").and_then(Value::as_str).unwrap_or("unknown").to_owned();
                let code = value.get("code").and_then(Value::as_str).unwrap_or("error").to_owned();
                if sid.is_some() && method == "sub" && code != "not_ready" {
                    self.subscriptions.remove(sid.as_deref().unwrap_or_default());
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
            FrameKind::Unknown(kind) => self.skip_unknown(kind, &frame, frame_bytes),
            _ => self.skip_unknown(0, &frame, frame_bytes),
        }
    }

    fn charge_frame_now(&mut self, sid: Option<&str>, bytes: u64) {
        let Some(sid) = sid else { return };
        let consumed = {
            let Some(sub) = self.subscriptions.get_mut(sid) else { return };
            sub.consumed = sub.consumed.saturating_add(bytes);
            if sub.consumed.saturating_sub(sub.credited) >= self.limits.credit_window / 4 {
                sub.credited = sub.consumed;
                Some(sub.consumed)
            } else {
                None
            }
        };
        if let Some(consumed) = consumed {
            let _ =
                self.queue_request(Request::Credit(wire::Credit { sid: sid.to_owned(), consumed }));
        }
    }

    fn skip_unknown(&mut self, _kind: u8, frame: &Frame, frame_bytes: u64) {
        let Ok(value) = frame.decode_json::<Value>() else {
            self.charge_frame_now(None, frame_bytes);
            return;
        };
        let sid = value.get("sid").and_then(Value::as_str);
        if let (Some(sid), Some(seq)) = (sid, value.get("seq").and_then(Value::as_u64)) {
            self.advance(sid, seq);
            if self.subscriptions.contains_key(sid) {
                self.charge_frame_now(Some(sid), frame_bytes);
            }
        } else {
            self.charge_frame_now(sid, frame_bytes);
        }
    }

    fn accept_delta_value(&mut self, value: Value, frame_bytes: u64) {
        let sid = value.get("sid").and_then(Value::as_str).unwrap_or_default().to_owned();
        if !self.subscriptions.contains_key(&sid) {
            self.charge_frame_now(None, frame_bytes);
            return;
        }
        let replay = match value.get("replay").and_then(Value::as_str) {
            Some("replay") => true,
            Some("end") | None => false,
            Some(_) => {
                self.protocol_error("invalid replay mark");
                return;
            }
        };
        let replay_end = value.get("replay").and_then(Value::as_str) == Some("end");
        let Some(ops) = value.get("ops").and_then(Value::as_array) else {
            self.protocol_error("malformed delta operations");
            return;
        };
        let mut charged = false;
        let mut emitted = false;
        for raw in ops {
            let Some(seq) = raw.get("seq").and_then(Value::as_u64) else { continue };
            match serde_json::from_value::<DeltaOp<T>>(raw.clone()) {
                Ok(DeltaOp::Summary { seq, summary }) => {
                    self.advance(&sid, seq);
                    let charge = !charged;
                    charged = true;
                    emitted = true;
                    self.note_page_summary(&sid, &summary);
                    self.push_change(
                        Change::Summary { sid: sid.clone(), seq, summary, replay },
                        Some(sid.clone()),
                        frame_bytes,
                        charge,
                    );
                }
                Ok(DeltaOp::Gone { seq, chat_id }) => {
                    self.advance(&sid, seq);
                    let charge = !charged;
                    charged = true;
                    emitted = true;
                    if let Some(page) = self.pages.get_mut(&sid) {
                        page.changed_keys.insert(chat_id.clone());
                    }
                    self.push_change(
                        Change::Gone { sid: sid.clone(), seq, chat_id, why: None, replay },
                        Some(sid.clone()),
                        frame_bytes,
                        charge,
                    );
                }
                Ok(DeltaOp::Origin { seq, origin }) => {
                    self.advance(&sid, seq);
                    let charge = !charged;
                    charged = true;
                    emitted = true;
                    if origin.state == wire::OriginState::Removed
                        && let Some(page) = self.pages.get_mut(&sid)
                    {
                        page.removed_origins.insert(origin.id.clone());
                    }
                    self.push_change(
                        Change::Origin { sid: sid.clone(), seq, origin, replay },
                        Some(sid.clone()),
                        frame_bytes,
                        charge,
                    );
                }
                Ok(DeltaOp::Queue { seq, bytes }) => {
                    self.advance(&sid, seq);
                    let charge = !charged;
                    charged = true;
                    emitted = true;
                    self.push_change(
                        Change::Queue { sid: sid.clone(), seq, bytes, replay },
                        Some(sid.clone()),
                        frame_bytes,
                        charge,
                    );
                }
                Err(_) => {
                    self.advance(&sid, seq);
                    if let Some(page) = self.pages.get_mut(&sid)
                        && let Some(chat_id) = raw.get("chatId").and_then(Value::as_str)
                    {
                        page.changed_keys.insert(chat_id.to_owned());
                    }
                }
            }
        }
        if !emitted {
            self.charge_frame_now(Some(&sid), frame_bytes);
        }
        if replay_end {
            let cursor = self.subscriptions.get(&sid).map(|sub| sub.cursor).unwrap_or_default();
            if let Some(sub) = self.subscriptions.get_mut(&sid) {
                sub.replaying = false;
            }
            self.push_change(Change::ResumeEnd { sid, cursor }, None, 0, false);
        }
    }

    fn advance(&mut self, sid: &str, seq: u64) {
        if let Some(sub) = self.subscriptions.get_mut(sid)
            && seq > sub.cursor.0
        {
            sub.cursor = Cursor(seq);
        }
    }

    fn accept_dropped(&mut self, drop: wire::Dropped, frame_bytes: u64) {
        let Some(mut sub) = self.subscriptions.remove(&drop.sid) else {
            self.charge_frame_now(None, frame_bytes);
            return;
        };
        let new_sid = loop {
            let candidate = format!("s{}", self.next_sid);
            self.next_sid = self.next_sid.saturating_add(1);
            if wire::identifier_fits(&candidate) && !self.subscriptions.contains_key(&candidate) {
                break candidate;
            }
        };
        let cursor = drop.cursor;
        sub.request.sid = new_sid.clone();
        sub.request.cursor = cursor;
        sub.request.edition = cursor.map(|_| sub.edition);
        if cursor.is_some() {
            sub.request.anchor = None;
        }
        sub.cursor = cursor.unwrap_or_default();
        sub.replaying = cursor.is_some();
        sub.consumed = 0;
        sub.credited = 0;
        self.subscriptions.insert(new_sid.clone(), sub.clone());
        if self.phase == Phase::Ready {
            let _ = self.queue_request(Request::Sub(sub.request));
        }
        self.push_change(
            Change::Dropped { sid: drop.sid, cursor, new_sid: Some(new_sid) },
            None,
            0,
            false,
        );
    }

    fn note_page_summary(&mut self, sid: &str, summary: &T) {
        let Some(page) = self.pages.get_mut(sid) else { return };
        let Ok(value) = serde_json::to_value(summary) else { return };
        if let Some(key) =
            value.get("chatId").or_else(|| value.get("sessionId")).and_then(Value::as_str)
        {
            page.changed_keys.insert(key.to_owned());
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
        let mut pending = Vec::new();
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
            if pending.is_empty() {
                let n = reader.read(&mut buf).await?;
                if n == 0 {
                    return Ok(());
                }
                pending.extend_from_slice(buf.get(..n).unwrap_or_default());
            }
            let consumed = client.received(&pending);
            if consumed > 0 {
                pending.drain(..consumed.min(pending.len()));
            }
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

    #[test]
    fn received_stops_at_one_frame_until_change_is_taken() {
        let mut client = Client::<Value>::connected_v2();
        let hello = Frame::json(
            FrameKind::Hello,
            &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
        )
        .unwrap()
        .encode();
        assert_eq!(client.received(&hello), hello.len());
        let _ = client.subscribe(Sub::new("s", "list")).unwrap();
        let first = Frame::json(
            FrameKind::Window,
            &serde_json::json!({
                "sid":"s","cursor":1,"rows":[],"hasBefore":false,"hasAfter":false,"edition":1
            }),
        )
        .unwrap()
        .encode();
        let second = Frame::json(
            FrameKind::Window,
            &serde_json::json!({
                "sid":"s","cursor":2,"rows":[],"hasBefore":false,"hasAfter":false,"edition":1
            }),
        )
        .unwrap()
        .encode();
        let mut bytes = first.clone();
        bytes.extend_from_slice(&second);
        assert_eq!(client.received(&bytes), first.len());
        assert!(matches!(client.next_change(), Some(Change::Window(_))));
        assert_eq!(client.received(&bytes[first.len()..]), second.len());
        assert!(matches!(client.next_change(), Some(Change::Window(_))));
    }

    #[test]
    fn method_not_found_returns_fallback_bytes_once() {
        let mut client = Client::<Value>::new(["list"]);
        client.connected();
        let reply = b"{\"error\":{\"code\":-32601}}\nrest";
        assert_eq!(client.received(reply), reply.len());
        assert_eq!(client.next_change(), Some(Change::Fallback(b"rest".to_vec())));
        assert_eq!(client.received(b"later"), 0);
    }

    #[test]
    fn unknown_delta_op_advances_cursor_but_keeps_known_ops() {
        let mut client = Client::<Value>::connected_v2();
        let hello = Frame::json(
            FrameKind::Hello,
            &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
        )
        .unwrap()
        .encode();
        client.received(&hello);
        let _ = client.subscribe(Sub::new("s", "list").from_cursor(0)).unwrap();
        let frame = Frame::json(FrameKind::Delta, &serde_json::json!({
            "sid":"s","ops":[{"op":"future","seq":1},{"op":"queue","seq":2,"bytes":4}],"replay":"end"
        })).unwrap().encode();
        assert_eq!(client.received(&frame), frame.len());
        assert!(matches!(client.next_change(), Some(Change::Queue { seq: 2, .. })));
        assert!(matches!(client.next_change(), Some(Change::ResumeEnd { cursor: Cursor(2), .. })));
    }

    #[test]
    fn received_stops_until_the_previous_frame_changes_are_taken() {
        let mut client = Client::<Value>::connected_v2();
        let hello = Frame::json(
            FrameKind::Hello,
            &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
        )
        .unwrap()
        .encode();
        client.received(&hello);
        client.subscribe(Sub::new("s", "list")).unwrap();
        let frame = Frame::json(
            FrameKind::Window,
            &serde_json::json!({"sid":"s","cursor":1,"rows":[],"edition":1}),
        )
        .unwrap()
        .encode();
        assert_eq!(client.received(&frame), frame.len());
        assert_eq!(client.received(&frame), 0);
        while client.next_change().is_some() {}
        assert_eq!(client.received(&frame), frame.len());
    }

    #[test]
    fn reconnect_resends_resume_and_direct_v2_does_not_upgrade() {
        let mut client = Client::<Value>::connected_v2();
        let hello = Frame::json(
            FrameKind::Hello,
            &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
        )
        .unwrap()
        .encode();
        client.received(&hello);
        client.subscribe(Sub::new("s", "list").from_cursor(7)).unwrap();
        client.disconnected();
        let hello_request = String::from_utf8(client.take_send().unwrap()).unwrap();
        assert!(hello_request.contains("hello"));
        client.received(&hello);
        let sub = String::from_utf8(client.take_send().unwrap()).unwrap();
        assert!(sub.contains("\"cursor\":7"));
        assert!(!sub.contains("\"anchor\""));
    }

    #[test]
    fn malformed_window_closes_the_connection() {
        let mut client = Client::<Value>::connected_v2();
        let hello = Frame::json(
            FrameKind::Hello,
            &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
        )
        .unwrap()
        .encode();
        client.received(&hello);
        let malformed = Frame::new(FrameKind::Window, b"{".to_vec()).unwrap().encode();
        client.received(&malformed);
        assert!(matches!(client.next_change(), Some(Change::Error { .. })));
        assert_eq!(client.received(&malformed), 0);
    }

    #[cfg(feature = "tokio")]
    #[tokio::test]
    async fn tokio_driver_preserves_multiple_frames() {
        use tokio::io::{AsyncWriteExt, duplex};
        let (mut tx, rx) = duplex(4096);
        let (_output_reader, output_writer) = duplex(4096);
        let (out_tx, mut out_rx) = tokio::sync::mpsc::channel(8);
        let mut client = Client::<Value>::connected_v2();
        let hello = Frame::json(
            FrameKind::Hello,
            &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
        )
        .unwrap()
        .encode();
        let window = Frame::json(
            FrameKind::Window,
            &serde_json::json!({"sid":"s","cursor":1,"rows":[],"edition":1}),
        )
        .unwrap()
        .encode();
        client.subscribe(Sub::new("s", "list")).unwrap();
        let task = tokio::spawn(tokio_driver::drive(client, rx, output_writer, out_tx));
        tx.write_all(&hello).await.unwrap();
        tx.write_all(&window).await.unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(1), out_rx.recv())
            .await
            .unwrap()
            .unwrap();
        drop(tx);
        let _ = task.await;
    }
}
