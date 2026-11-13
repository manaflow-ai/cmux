//! I/O-free client state machine for agent-service v2.

pub mod ffi;
pub mod wire;

use acpmux_book::index::Summary;

use serde::{Serialize, de::DeserializeOwned};
use serde_json::Value;
use std::collections::{HashMap, HashSet, VecDeque};
use wire::{
    Anchor, Cursor, DeltaOp, Frame, FrameError, FrameKind, Hello, Limits, ListKey, Page,
    PageResult, Request, Sub, Window,
};

#[derive(Clone, Debug, PartialEq)]
pub enum Change<T> {
    Window(Window<T>),
    Page(PageResult<T>),
    Summary {
        sid: String,
        seq: u64,
        summary: T,
        replay: bool,
    },
    Left {
        sid: String,
        seq: u64,
        summary: T,
        replay: bool,
    },
    Gone {
        sid: String,
        seq: u64,
        origin: String,
        chat_id: String,
        why: Option<String>,
        replay: bool,
    },
    Origin {
        sid: String,
        seq: u64,
        origin: wire::Origin,
        replay: bool,
    },
    Queue {
        sid: String,
        seq: u64,
        bytes: u64,
        replay: bool,
    },
    ResumeEnd {
        sid: String,
        cursor: Cursor,
    },
    Unconfirmed {
        sid: String,
    },
    Dropped {
        sid: String,
        cursor: Option<Cursor>,
        new_sid: Option<String>,
    },
    Error {
        method: String,
        sid: Option<String>,
        id: Option<String>,
        code: String,
    },
    Whole {
        sid: String,
        cursor: Cursor,
    },
    Fallback(Vec<u8>),
}

/// Encodes a list summary using the object shape expected by the v1 app.
/// Opaque extension fields are retained and typed fields win when both exist.
pub fn v1_row(
    summary: &Summary,
    origin_state: wire::OriginState,
    parent: Option<&Summary>,
) -> Value {
    let mut object = serde_json::from_str::<Value>(summary.extra.get())
        .ok()
        .and_then(|value| value.as_object().cloned())
        .unwrap_or_default();
    object.insert("sessionId".into(), Value::String(summary.chat_id.clone()));
    object.insert("title".into(), Value::String(summary.title.clone()));
    object.insert("harness".into(), Value::String(summary.harness.clone()));
    object.insert("status".into(), Value::String(summary.state.clone()));
    object.insert("unread".into(), Value::Bool(summary.unread > 0));
    object.insert("unreadTurns".into(), Value::from(summary.unread));
    object.insert("updatedMs".into(), Value::from(summary.last_activity));
    if let Some(workspace) = &summary.workspace {
        object.insert("workspaceId".into(), Value::String(workspace.clone()));
    } else {
        object.remove("workspaceId");
    }
    if summary.origin != "local" {
        object.insert("peer".into(), Value::String(summary.origin.clone()));
    } else {
        object.remove("peer");
    }
    if matches!(origin_state, wire::OriginState::Stale) {
        object.insert("stale".into(), Value::Bool(true));
    } else {
        object.remove("stale");
    }
    if let Some(fork) = &summary.fork_of {
        object.insert("parentId".into(), Value::String(fork.key.chat_id.to_string()));
        object.insert("forkSeq".into(), Value::from(fork.seq));
    } else {
        object.remove("parentId");
        object.remove("forkSeq");
    }
    let listed_parent =
        parent.is_some_and(|parent| parent.parent.is_none() && parent.state != "closed");
    if listed_parent {
        if let Some(parent) = parent {
            object.insert("spawnedBy".into(), Value::String(parent.chat_id.clone()));
        }
    } else {
        object.remove("spawnedBy");
    }
    Value::Object(object)
}

/// A mirror's reconciliation state. The client stores keys, never row data;
/// rows are delivered to the caller as page or delta changes.
#[derive(Clone, Debug, Default)]
struct MirrorState {
    held: HashMap<(String, String), ListKey>,
    wanted: HashMap<(String, String), ListKey>,
    whole: bool,
    walking: bool,
    seen: HashMap<(String, String), ListKey>,
    pending_wanted: VecDeque<ListKey>,
}

#[derive(Clone, Debug)]
struct SubState {
    initial: Sub,
    request: Sub,
    cursor: Cursor,
    edition: u32,
    consumed: u64,
    credited: u64,
    replaying: bool,
    window_taken: bool,
    mirror: Option<MirrorState>,
}

#[derive(Clone, Debug, Default)]
enum PagePurpose {
    #[default]
    User,
    MirrorWalk,
    Wanted,
}

#[derive(Clone, Debug, Default)]
struct PageState {
    request: Option<Page>,
    changed_keys: HashSet<(String, String)>,
    removed_origins: HashSet<String>,
    purpose: PagePurpose,
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
pub struct Client<T = Summary> {
    phase: Phase,
    surfaces: Vec<String>,
    frame_buf: Vec<u8>,
    frame_total: Option<usize>,
    send: VecDeque<Vec<u8>>,
    changes: VecDeque<QueuedChange<T>>,
    subscriptions: HashMap<String, SubState>,
    retired_sids: HashSet<String>,
    pages: HashMap<String, PageState>,
    limits: Limits,
    line: Vec<u8>,
    next_id: u64,
    next_sid: u64,
    direct_v2: bool,
    upgrade_id: Option<Value>,
    skips: SkipCounters,
}

/// Counts protocol values this client intentionally skips while preserving the
/// stream cursor. These counters are diagnostic, never flow control.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct SkipCounters {
    pub unknown_kind: u64,
    pub unknown_op: u64,
    pub missing_seq: u64,
    pub unheld_sid: u64,
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
    fn sub_view_is_live(sub: &SubState) -> bool {
        matches!(sub.request.view, Some(wire::ListView::Live))
    }

    pub fn new(surfaces: impl IntoIterator<Item = impl Into<String>>) -> Self {
        Self {
            phase: Phase::Upgrade,
            surfaces: surfaces.into_iter().map(Into::into).collect(),
            frame_buf: Vec::new(),
            frame_total: None,
            send: VecDeque::new(),
            changes: VecDeque::new(),
            subscriptions: HashMap::new(),
            retired_sids: HashSet::new(),
            pages: HashMap::new(),
            limits: Limits::default(),
            line: Vec::new(),
            next_id: 1,
            next_sid: 1,
            direct_v2: false,
            upgrade_id: None,
            skips: SkipCounters::default(),
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
            self.upgrade_id = Some(Value::from(id));
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
        self.retired_sids.clear();
        self.pages.clear();
        for sub in self.subscriptions.values_mut() {
            if let Some(mirror) = sub.mirror.as_mut() {
                if mirror.walking {
                    mirror.whole = false;
                }
                mirror.walking = false;
                mirror.seen.clear();
            }
            if sub.window_taken {
                sub.request.cursor = Some(sub.cursor);
                sub.request.edition = Some(sub.edition);
                sub.request.anchor = None;
                sub.replaying = true;
            } else {
                sub.request = sub.initial.clone();
                sub.replaying = sub.request.cursor.is_some();
            }
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
    pub fn is_closed(&self) -> bool {
        self.phase == Phase::Closed
    }
    pub fn skip_counters(&self) -> SkipCounters {
        self.skips
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
            let Ok(value) = serde_json::from_slice::<Value>(&reply) else {
                self.protocol_error("malformed upgrade reply");
                return bytes.len();
            };
            if value.get("error").is_some_and(Value::is_object) {
                self.phase = Phase::Fallback;
                let rest = bytes.get(end.saturating_add(1)..).unwrap_or_default().to_vec();
                self.push_change(Change::Fallback(rest), None, 0, false);
                return bytes.len();
            }
            let valid = value.get("id") == self.upgrade_id.as_ref()
                && value.pointer("/result/upgrade").and_then(Value::as_bool) == Some(true);
            if !valid {
                self.protocol_error("invalid upgrade reply");
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
                initial: sub.clone(),
                request: sub.clone(),
                cursor,
                edition,
                consumed: 0,
                credited: 0,
                replaying: sub.cursor.is_some(),
                window_taken: false,
                mirror: None,
            },
        );
        if self.phase == Phase::Ready {
            self.queue_request(Request::Sub(sub))?;
        }
        Ok(sid)
    }

    /// Subscribes a mirror. `held_keys` is the key set saved by the caller;
    /// `whole` says that it was complete when saved. An incomplete mirror is
    /// deliberately reopened at the head and reconciled by a walk.
    pub fn subscribe_mirror(
        &mut self,
        mut sub: Sub,
        held_keys: impl IntoIterator<Item = ListKey>,
        whole: bool,
    ) -> Result<String, FrameError> {
        if !whole {
            sub.cursor = None;
            sub.edition = None;
            sub.anchor = None;
        }
        if sub.cursor.is_none() {
            sub.anchor.get_or_insert(Anchor::End);
        }
        let keys: HashSet<ListKey> = held_keys.into_iter().collect();
        if keys.len() > 4096 {
            return Err(FrameError::InvalidLength(keys.len()));
        }
        if !wire::identifier_fits(&sub.sid) {
            return Err(FrameError::InvalidLength(sub.sid.len()));
        }
        let sid = sub.sid.clone();
        let cursor = sub.cursor.unwrap_or_default();
        let edition = sub.edition.unwrap_or_default();
        self.subscriptions.insert(
            sid.clone(),
            SubState {
                initial: sub.clone(),
                request: sub.clone(),
                cursor,
                edition,
                consumed: 0,
                credited: 0,
                replaying: sub.cursor.is_some(),
                window_taken: false,
                mirror: Some(MirrorState { held: keys, whole, ..MirrorState::default() }),
            },
        );
        if self.phase == Phase::Ready {
            self.queue_request(Request::Sub(sub))?;
        }
        Ok(sid)
    }

    /// Adds keys to a mirror's wanted set. Reads are batched at 100 keys per
    /// request and are deferred while the mirror is walking.
    pub fn want(
        &mut self,
        sid: &str,
        keys: impl IntoIterator<Item = ListKey>,
    ) -> Result<(), FrameError> {
        let Some(sub) = self.subscriptions.get_mut(sid) else {
            return Err(FrameError::RequestInFlight);
        };
        let Some(mirror) = sub.mirror.as_mut() else {
            return Err(FrameError::RequestInFlight);
        };
        for key in keys {
            let id = Self::row_identity(&key);
            if !mirror.wanted.contains_key(&id) && mirror.wanted.len() >= 4096 {
                return Err(FrameError::InvalidLength(mirror.wanted.len()));
            }
            mirror.wanted.insert(id, key.clone());
            mirror.pending_wanted.push_back(key);
        }
        self.maybe_start_wanted(sid);
        Ok(())
    }

    /// Removes a key from the wanted set. A live held row remains held until
    /// its normal delta or reconcile removes it.
    pub fn unwant(
        &mut self,
        sid: &str,
        keys: impl IntoIterator<Item = ListKey>,
    ) -> Result<(), FrameError> {
        let Some(sub) = self.subscriptions.get_mut(sid) else {
            return Err(FrameError::RequestInFlight);
        };
        let Some(mirror) = sub.mirror.as_mut() else {
            return Err(FrameError::RequestInFlight);
        };
        for key in keys {
            mirror.wanted.remove(&Self::row_identity(&key));
            mirror.pending_wanted.retain(|pending| pending != &key);
        }
        Ok(())
    }

    pub fn unsubscribe(&mut self, sid: &str) -> Result<(), FrameError> {
        self.subscriptions.remove(sid);
        self.pages.remove(sid);
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

    fn row_key(value: &Value) -> Option<ListKey> {
        Some(ListKey {
            last_activity: value.get("lastActivity")?.as_u64()?,
            chat_id: value.get("chatId").or_else(|| value.get("sessionId"))?.as_str()?.to_owned(),
            origin: value.get("origin").and_then(Value::as_str).unwrap_or("local").to_owned(),
        })
    }

    fn value_key<U: Serialize>(row: &U) -> Option<ListKey> {
        serde_json::to_value(row).ok().and_then(|value| Self::row_key(&value))
    }

    fn row_identity(key: &ListKey) -> (String, String) {
        (key.origin.clone(), key.chat_id.clone())
    }

    fn start_mirror_walk(&mut self, sid: &str) {
        if self.pages.contains_key(sid) {
            return;
        }
        let page = {
            let Some(sub) = self.subscriptions.get_mut(sid) else { return };
            let Some(mirror) = sub.mirror.as_mut() else { return };
            mirror.walking = true;
            mirror.seen.clear();
            Page {
                sid: sid.to_owned(),
                stream: sub.request.stream.clone(),
                before: None,
                after: None,
                keys: None,
                view: sub.request.view,
                max_bytes: wire::MAX_PAGE_BYTES as u32,
                filter: sub.request.filter.clone(),
            }
        };
        self.pages.insert(
            sid.to_owned(),
            PageState {
                request: Some(page.clone()),
                purpose: PagePurpose::MirrorWalk,
                ..PageState::default()
            },
        );
        if self.phase == Phase::Ready {
            let _ = self.queue_request(Request::Page(page));
        }
    }

    fn maybe_start_wanted(&mut self, sid: &str) {
        if self.pages.contains_key(sid) || self.phase != Phase::Ready {
            return;
        }
        let page = {
            let Some(sub) = self.subscriptions.get_mut(sid) else { return };
            let Some(mirror) = sub.mirror.as_mut() else { return };
            if mirror.walking || mirror.pending_wanted.is_empty() {
                return;
            }
            let mut keys = Vec::with_capacity(100);
            while keys.len() < 100 {
                let Some(key) = mirror.pending_wanted.pop_front() else { break };
                keys.push(key);
            }
            if keys.is_empty() {
                return;
            }
            Page {
                sid: sid.to_owned(),
                stream: sub.request.stream.clone(),
                before: None,
                after: None,
                keys: Some(keys),
                view: sub.request.view,
                max_bytes: wire::MAX_PAGE_BYTES as u32,
                filter: sub.request.filter.clone(),
            }
        };
        self.pages.insert(
            sid.to_owned(),
            PageState {
                request: Some(page.clone()),
                purpose: PagePurpose::Wanted,
                ..PageState::default()
            },
        );
        let _ = self.queue_request(Request::Page(page));
    }

    fn finish_mirror_walk(&mut self, sid: &str) {
        let (cursor, stale) = {
            let Some(sub) = self.subscriptions.get_mut(sid) else { return };
            let Some(mirror) = sub.mirror.as_mut() else { return };
            let stale: Vec<ListKey> = mirror
                .held
                .iter()
                .filter(|(id, _)| {
                    !mirror.seen.contains_key(*id) && !mirror.wanted.contains_key(*id)
                })
                .map(|(_, key)| key.clone())
                .collect();
            for key in &stale {
                mirror.held.remove(&Self::row_identity(key));
            }
            mirror.walking = false;
            mirror.whole = true;
            mirror.seen.clear();
            (sub.cursor, stale)
        };
        for key in stale {
            self.push_change(
                Change::Gone {
                    sid: sid.to_owned(),
                    seq: cursor.0,
                    origin: key.origin,
                    chat_id: key.chat_id,
                    why: Some("missed".into()),
                    replay: false,
                },
                None,
                0,
                false,
            );
        }
        self.push_change(Change::Whole { sid: sid.to_owned(), cursor }, None, 0, false);
        if let Some(sub) = self.subscriptions.get_mut(sid)
            && let Some(mirror) = sub.mirror.as_mut()
        {
            mirror.pending_wanted.clear();
            mirror.pending_wanted.extend(mirror.wanted.values().cloned());
        }
        self.maybe_start_wanted(sid);
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
                    self.skips.unheld_sid = self.skips.unheld_sid.saturating_add(1);
                    self.charge_frame_now(None, frame_bytes);
                    return;
                }
                let replaying =
                    self.subscriptions.get(&sid).map(|sub| sub.replaying).unwrap_or(false);
                let mirror =
                    self.subscriptions.get(&sid).and_then(|sub| sub.mirror.as_ref()).is_some();
                if let Some(sub) = self.subscriptions.get_mut(&sid) {
                    sub.cursor = Cursor(window.cursor);
                    sub.edition = window.edition;
                    sub.replaying = false;
                    sub.window_taken = true;
                    if let Some(mirror) = sub.mirror.as_mut() {
                        for row in &window.rows {
                            if let Some(key) = Self::value_key(row) {
                                let id = Self::row_identity(&key);
                                mirror.seen.insert(id.clone(), key.clone());
                                mirror.held.insert(id, key);
                            }
                        }
                    }
                }
                self.push_change(Change::Window(window), Some(sid.clone()), frame_bytes, true);
                if replaying {
                    self.push_change(Change::Unconfirmed { sid: sid.clone() }, None, 0, false);
                }
                if mirror {
                    self.start_mirror_walk(&sid);
                }
            }
            FrameKind::Page => {
                let Ok(mut page) = frame.decode_json::<PageResult<T>>() else {
                    self.protocol_error("malformed page");
                    return;
                };
                let sid = page.sid.clone();
                if !self.subscriptions.contains_key(&sid) {
                    self.skips.unheld_sid = self.skips.unheld_sid.saturating_add(1);
                    self.charge_frame_now(None, frame_bytes);
                    return;
                }
                let state = self.pages.remove(&sid).unwrap_or_default();
                if matches!(state.purpose, PagePurpose::User) {
                    page.rows.retain(|row| {
                        let Some(value) = serde_json::to_value(row).ok() else { return true };
                        let key = value
                            .get("chatId")
                            .or_else(|| value.get("sessionId"))
                            .and_then(Value::as_str)
                            .map(str::to_owned);
                        let origin = value.get("origin").and_then(Value::as_str).unwrap_or("local");
                        if let Some(key) = key
                            && state.changed_keys.contains(&(origin.to_owned(), key))
                        {
                            return false;
                        }
                        !state.removed_origins.contains(origin)
                    });
                }
                match state.purpose {
                    PagePurpose::User => {
                        self.push_change(Change::Page(page), Some(sid.clone()), frame_bytes, true);
                        self.maybe_start_wanted(&sid);
                    }
                    PagePurpose::MirrorWalk => self.accept_mirror_walk_page(page, frame_bytes),
                    PagePurpose::Wanted => self.accept_wanted_page(page, frame_bytes),
                }
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
                if sid.as_deref().is_some_and(|sid| !self.subscriptions.contains_key(sid)) {
                    self.skips.unheld_sid = self.skips.unheld_sid.saturating_add(1);
                }
                let method =
                    value.get("method").and_then(Value::as_str).unwrap_or("unknown").to_owned();
                let code = value.get("code").and_then(Value::as_str).unwrap_or("error").to_owned();
                let restart_walk = if method == "page" {
                    sid.as_deref().and_then(|sid| {
                        self.pages.remove(sid).and_then(|state| {
                            (matches!(state.purpose, PagePurpose::MirrorWalk)
                                && self
                                    .subscriptions
                                    .get(sid)
                                    .and_then(|sub| sub.mirror.as_ref())
                                    .is_some())
                            .then_some(sid.to_owned())
                        })
                    })
                } else {
                    None
                };
                if let Some(sid) = restart_walk.as_deref()
                    && let Some(sub) = self.subscriptions.get_mut(sid)
                    && let Some(mirror) = sub.mirror.as_mut()
                {
                    mirror.walking = false;
                    mirror.whole = false;
                }
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
                if let Some(sid) = restart_walk {
                    self.start_mirror_walk(&sid);
                }
            }
            FrameKind::Unknown(kind) => {
                self.skips.unknown_kind = self.skips.unknown_kind.saturating_add(1);
                self.skip_unknown(kind, &frame, frame_bytes);
            }
            _ => self.skip_unknown(0, &frame, frame_bytes),
        }
    }

    fn accept_mirror_walk_page(&mut self, page: PageResult<T>, frame_bytes: u64) {
        let sid = page.sid.clone();
        let cursor = self.subscriptions.get(&sid).map(|sub| sub.cursor).unwrap_or_default();
        let mut emitted = false;
        for row in page.rows.iter().cloned() {
            let key = Self::value_key(&row);
            if let Some(key) = key.clone()
                && let Some(sub) = self.subscriptions.get_mut(&sid)
                && let Some(mirror) = sub.mirror.as_mut()
            {
                let id = Self::row_identity(&key);
                mirror.seen.insert(id.clone(), key.clone());
                mirror.held.insert(id, key);
            }
            self.push_change(
                Change::Summary { sid: sid.clone(), seq: cursor.0, summary: row, replay: false },
                Some(sid.clone()),
                frame_bytes,
                !emitted,
            );
            emitted = true;
        }
        if !emitted {
            self.charge_frame_now(Some(&sid), frame_bytes);
        }
        if page.has_after {
            let Some(after_key) = page.after_key else {
                self.protocol_error("mirror page hasAfter without afterKey");
                return;
            };
            let next = {
                let Some(sub) = self.subscriptions.get(&sid) else { return };
                Page {
                    sid: sid.clone(),
                    stream: sub.request.stream.clone(),
                    before: None,
                    after: Some(wire::Position::List(after_key)),
                    keys: None,
                    view: sub.request.view,
                    max_bytes: wire::MAX_PAGE_BYTES as u32,
                    filter: sub.request.filter.clone(),
                }
            };
            self.pages.insert(
                sid.clone(),
                PageState {
                    request: Some(next.clone()),
                    purpose: PagePurpose::MirrorWalk,
                    ..PageState::default()
                },
            );
            let _ = self.queue_request(Request::Page(next));
        } else {
            self.finish_mirror_walk(&sid);
        }
    }

    fn accept_wanted_page(&mut self, page: PageResult<T>, frame_bytes: u64) {
        let sid = page.sid.clone();
        let mut emitted = false;
        let mut answered = 0usize;
        for row in page.rows.iter().cloned() {
            let Some(key) = Self::value_key(&row) else { continue };
            let id = Self::row_identity(&key);
            answered = answered.saturating_add(1);
            if let Some(sub) = self.subscriptions.get_mut(&sid)
                && let Some(mirror) = sub.mirror.as_mut()
            {
                mirror.held.insert(id, key);
            }
            let cursor = self.subscriptions.get(&sid).map(|sub| sub.cursor.0).unwrap_or_default();
            self.push_change(
                Change::Summary { sid: sid.clone(), seq: cursor, summary: row, replay: false },
                Some(sid.clone()),
                frame_bytes,
                !emitted,
            );
            emitted = true;
        }
        for key in page.missing {
            answered = answered.saturating_add(1);
            let held = self
                .subscriptions
                .get(&sid)
                .and_then(|sub| sub.mirror.as_ref())
                .is_some_and(|mirror| mirror.held.contains_key(&Self::row_identity(&key)));
            if held {
                if let Some(sub) = self.subscriptions.get_mut(&sid)
                    && let Some(mirror) = sub.mirror.as_mut()
                {
                    let id = Self::row_identity(&key);
                    mirror.held.remove(&id);
                    mirror.wanted.remove(&id);
                }
                let cursor =
                    self.subscriptions.get(&sid).map(|sub| sub.cursor.0).unwrap_or_default();
                self.push_change(
                    Change::Gone {
                        sid: sid.clone(),
                        seq: cursor,
                        origin: key.origin,
                        chat_id: key.chat_id,
                        why: Some("removed".into()),
                        replay: false,
                    },
                    None,
                    0,
                    false,
                );
                emitted = true;
            } else if let Some(sub) = self.subscriptions.get_mut(&sid)
                && let Some(mirror) = sub.mirror.as_mut()
            {
                mirror.wanted.remove(&Self::row_identity(&key));
            }
        }
        for key in page.unknown {
            answered = answered.saturating_add(1);
            if let Some(sub) = self.subscriptions.get_mut(&sid)
                && let Some(mirror) = sub.mirror.as_mut()
            {
                mirror.wanted.insert(Self::row_identity(&key), key);
            }
        }
        if !emitted {
            self.charge_frame_now(Some(&sid), frame_bytes);
        }
        if !page.rest.is_empty() {
            if answered == 0 {
                self.protocol_error("wanted page rest made no progress");
                return;
            }
            {
                let Some(sub) = self.subscriptions.get_mut(&sid) else { return };
                let Some(mirror) = sub.mirror.as_mut() else { return };
                mirror.pending_wanted.retain(|key| !page.rest.contains(key));
                for key in page.rest.iter().rev() {
                    mirror.pending_wanted.push_front(key.clone());
                }
            }
            self.maybe_start_wanted(&sid);
        } else {
            self.maybe_start_wanted(&sid);
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
        if sid.is_some_and(|sid| !self.subscriptions.contains_key(sid)) {
            self.skips.unheld_sid = self.skips.unheld_sid.saturating_add(1);
        }
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
            self.skips.unheld_sid = self.skips.unheld_sid.saturating_add(1);
            self.charge_frame_now(None, frame_bytes);
            return;
        }
        let replay = match value.get("replay").and_then(Value::as_str) {
            Some("replay") | Some("end") => {
                self.subscriptions.get(&sid).is_some_and(|sub| sub.replaying)
            }
            None => false,
            Some(_) => {
                self.protocol_error("invalid replay mark");
                return;
            }
        };
        let replay_end = value.get("replay").and_then(Value::as_str) == Some("end");
        if let Some(sub) = self.subscriptions.get_mut(&sid) {
            sub.window_taken = true;
        }
        let Some(ops) = value.get("ops").and_then(Value::as_array) else {
            self.protocol_error("malformed delta operations");
            return;
        };
        let mut charged = false;
        let mut emitted = false;
        for raw in ops {
            let Some(seq) = raw.get("seq").and_then(Value::as_u64) else {
                self.skips.missing_seq = self.skips.missing_seq.saturating_add(1);
                continue;
            };
            match serde_json::from_value::<DeltaOp<T>>(raw.clone()) {
                Ok(DeltaOp::Summary { seq, summary }) => {
                    self.advance(&sid, seq);
                    let charge = !charged;
                    charged = true;
                    emitted = true;
                    self.note_page_summary(&sid, &summary);
                    let key = Self::value_key(&summary);
                    let live = serde_json::to_value(&summary)
                        .ok()
                        .and_then(|value| {
                            value
                                .get("state")
                                .and_then(Value::as_str)
                                .map(|state| state != "closed")
                        })
                        .unwrap_or(true);
                    let left = self.subscriptions.get(&sid).is_some_and(|sub| {
                        Self::sub_view_is_live(sub)
                            && !live
                            && sub.mirror.as_ref().is_some_and(|mirror| {
                                key.as_ref().is_some_and(|key| {
                                    let id = Self::row_identity(key);
                                    mirror.held.contains_key(&id)
                                        && !mirror.wanted.contains_key(&id)
                                })
                            })
                    });
                    if let Some(sub) = self.subscriptions.get_mut(&sid)
                        && let Some(mirror) = sub.mirror.as_mut()
                        && let Some(key) = key
                    {
                        let id = Self::row_identity(&key);
                        if live || mirror.wanted.contains_key(&id) {
                            mirror.held.insert(id, key);
                        } else {
                            mirror.held.remove(&id);
                        }
                    }
                    if left {
                        self.push_change(
                            Change::Left { sid: sid.clone(), seq, summary, replay },
                            Some(sid.clone()),
                            frame_bytes,
                            charge,
                        );
                    } else {
                        self.push_change(
                            Change::Summary { sid: sid.clone(), seq, summary, replay },
                            Some(sid.clone()),
                            frame_bytes,
                            charge,
                        );
                    }
                }
                Ok(DeltaOp::Gone { seq, origin, chat_id }) => {
                    self.advance(&sid, seq);
                    let charge = !charged;
                    charged = true;
                    emitted = true;
                    if let Some(page) = self.pages.get_mut(&sid) {
                        page.changed_keys.insert((origin.clone(), chat_id.clone()));
                    }
                    if let Some(sub) = self.subscriptions.get_mut(&sid)
                        && let Some(mirror) = sub.mirror.as_mut()
                    {
                        let id = (origin.clone(), chat_id.clone());
                        mirror.held.remove(&id);
                        mirror.wanted.remove(&id);
                    }
                    let why = raw.get("why").and_then(Value::as_str).map(str::to_owned);
                    self.push_change(
                        Change::Gone { sid: sid.clone(), seq, origin, chat_id, why, replay },
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
                Ok(DeltaOp::Folder { seq, .. }) | Ok(DeltaOp::FolderGone { seq, .. }) => {
                    self.skips.unknown_op = self.skips.unknown_op.saturating_add(1);
                    self.advance(&sid, seq);
                }
                Err(_) => {
                    self.skips.unknown_op = self.skips.unknown_op.saturating_add(1);
                    self.advance(&sid, seq);
                    if let Some(page) = self.pages.get_mut(&sid)
                        && let Some(chat_id) = raw.get("chatId").and_then(Value::as_str)
                    {
                        let origin = raw.get("origin").and_then(Value::as_str).unwrap_or("local");
                        page.changed_keys.insert((origin.to_owned(), chat_id.to_owned()));
                    }
                }
            }
        }
        if !emitted {
            self.charge_frame_now(Some(&sid), frame_bytes);
        }
        if replay_end {
            let was_replaying = self.subscriptions.get(&sid).is_some_and(|sub| sub.replaying);
            let cursor = self.subscriptions.get(&sid).map(|sub| sub.cursor).unwrap_or_default();
            if was_replaying && let Some(sub) = self.subscriptions.get_mut(&sid) {
                sub.replaying = false;
            }
            if was_replaying {
                self.push_change(Change::ResumeEnd { sid: sid.clone(), cursor }, None, 0, false);
                if self
                    .subscriptions
                    .get(&sid)
                    .and_then(|sub| sub.mirror.as_ref())
                    .is_some_and(|mirror| !mirror.whole)
                {
                    self.start_mirror_walk(&sid);
                }
            }
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
        self.pages.remove(&drop.sid);
        let Some(mut sub) = self.subscriptions.remove(&drop.sid) else {
            self.skips.unheld_sid = self.skips.unheld_sid.saturating_add(1);
            self.charge_frame_now(None, frame_bytes);
            return;
        };
        let new_sid = loop {
            let candidate = format!("s{}", self.next_sid);
            self.next_sid = self.next_sid.saturating_add(1);
            if wire::identifier_fits(&candidate)
                && !self.subscriptions.contains_key(&candidate)
                && !self.retired_sids.contains(&candidate)
                && candidate != drop.sid
            {
                break candidate;
            }
        };
        self.retired_sids.insert(drop.sid.clone());
        let cursor = drop.cursor;
        sub.request = sub.initial.clone();
        sub.request.sid = new_sid.clone();
        sub.request.cursor = cursor;
        sub.request.edition = cursor.map(|_| sub.edition);
        if cursor.is_some() {
            sub.request.anchor = None;
        }
        sub.cursor = cursor.unwrap_or_default();
        sub.replaying = cursor.is_some();
        if let Some(mirror) = sub.mirror.as_mut() {
            mirror.walking = false;
            mirror.whole = false;
            mirror.seen.clear();
        }
        sub.initial.sid = new_sid.clone();
        sub.window_taken = false;
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
            let origin = value.get("origin").and_then(Value::as_str).unwrap_or("local");
            page.changed_keys.insert((origin.to_owned(), key.to_owned()));
        }
    }
}

#[cfg(feature = "tokio")]
pub mod tokio_driver {
    use super::*;
    use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

    /// The transport is returned when the protocol hands control to a v1
    /// caller or closes. `bytes` are unread bytes already held by the driver.
    pub enum DriveExit<R, W> {
        Fallback { reader: R, writer: W, bytes: Vec<u8> },
        Closed { reader: R, writer: W, bytes: Vec<u8> },
        Eof { reader: R, writer: W, bytes: Vec<u8> },
    }

    pub async fn drive<T, R, W>(
        mut client: Client<T>,
        mut reader: R,
        mut writer: W,
        tx: tokio::sync::mpsc::Sender<Change<T>>,
    ) -> std::io::Result<DriveExit<R, W>>
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
                if let Change::Fallback(bytes) = change {
                    return Ok(DriveExit::Fallback { reader, writer, bytes });
                }
                let closed = client.is_closed();
                if tx.send(change).await.is_err() {
                    return Ok(DriveExit::Closed { reader, writer, bytes: pending });
                }
                if closed {
                    return Ok(DriveExit::Closed { reader, writer, bytes: pending });
                }
                continue;
            }
            if pending.is_empty() {
                let n = reader.read(&mut buf).await?;
                if n == 0 {
                    return Ok(DriveExit::Eof { reader, writer, bytes: pending });
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
    fn upgrade_requires_matching_id_and_true_result() {
        let mut client = Client::<Value>::new(["list"]);
        client.connected();
        let wrong_id = br#"{"jsonrpc":"2.0","id":99,"result":{"upgrade":true}}
"#;
        assert_eq!(client.received(wrong_id), wrong_id.len());
        assert!(matches!(client.next_change(), Some(Change::Error { .. })));

        let mut client = Client::<Value>::new(["list"]);
        client.connected();
        let reply = br#"{"jsonrpc":"2.0","id":1,"result":{"upgrade":true}}
"#;
        assert_eq!(client.received(reply), reply.len());
        assert!(!client.is_fallback());

        let mut client = Client::<Value>::new(["list"]);
        client.connected();
        let reply = br#"{"jsonrpc":"2.0","id":1,"error":{"code":-32000}}
tail"#;
        assert_eq!(client.received(reply), reply.len());
        assert_eq!(client.next_change(), Some(Change::Fallback(b"tail".to_vec())));
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
            &serde_json::json!({"sid":"s","cursor":1,"rows":[],"hasBefore":false,"hasAfter":false,"edition":1}),
        )
        .unwrap()
        .encode();
        assert_eq!(client.received(&frame), frame.len());
        assert_eq!(client.received(&frame), 0);
        assert!(matches!(client.next_change(), Some(Change::Window(_))));
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
    fn reconnect_before_window_keeps_the_initial_anchor_request() {
        let mut client = Client::<Value>::connected_v2();
        let hello = Frame::json(
            FrameKind::Hello,
            &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
        )
        .unwrap()
        .encode();
        client.received(&hello);
        client.subscribe(Sub::new("s", "list").around(Anchor::End, 10)).unwrap();
        while client.take_send().is_some() {}
        client.disconnected();
        let _ = client.take_send();
        client.received(&hello);
        let request = String::from_utf8(client.take_send().unwrap()).unwrap();
        assert!(request.contains("\"anchor\":\"end\""));
        assert!(!request.contains("\"cursor\""));
    }

    #[test]
    fn skip_counters_cover_unknown_kind_op_missing_seq_and_unheld_sid() {
        let mut client = Client::<Value>::connected_v2();
        let hello = Frame::json(
            FrameKind::Hello,
            &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
        )
        .unwrap()
        .encode();
        client.received(&hello);
        client.subscribe(Sub::new("s", "list")).unwrap();
        while client.take_send().is_some() {}
        let unknown = Frame::new(FrameKind::Unknown(200), br#"{"sid":"s","seq":1}"#.to_vec())
            .unwrap()
            .encode();
        client.received(&unknown);
        let delta = Frame::json(
            FrameKind::Delta,
            &serde_json::json!({"sid":"s","ops":[{"op":"future","seq":2},{"op":"queue","bytes":1}]}),
        )
        .unwrap()
        .encode();
        client.received(&delta);
        let unheld = Frame::json(FrameKind::Delta, &serde_json::json!({"sid":"old","ops":[]}))
            .unwrap()
            .encode();
        client.received(&unheld);
        let counters = client.skip_counters();
        assert_eq!(counters.unknown_kind, 1);
        assert_eq!(counters.unknown_op, 1);
        assert_eq!(counters.missing_seq, 1);
        assert_eq!(counters.unheld_sid, 1);
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

    #[test]
    fn byte_credit_is_queued_when_taken_changes_cross_quarter_window() {
        let mut client = Client::<Value>::connected_v2();
        let hello = Frame::json(
            FrameKind::Hello,
            &wire::HelloReply {
                daemon_id: "d".into(),
                limits: Limits { credit_window: 40, ..Limits::default() },
            },
        )
        .unwrap()
        .encode();
        client.received(&hello);
        client.subscribe(Sub::new("s", "list")).unwrap();
        while client.take_send().is_some() {}
        let window = Frame::json(
            FrameKind::Window,
            &serde_json::json!({"sid":"s","cursor":1,"rows":[],"hasBefore":false,"hasAfter":false,"edition":1}),
        )
        .unwrap()
        .encode();
        client.received(&window);
        let _ = client.next_change();
        let credit = String::from_utf8(client.take_send().unwrap()).unwrap();
        assert!(credit.contains("credit"));
    }

    #[test]
    fn dropped_replaces_sid_and_old_frames_are_ignored() {
        let mut client = Client::<Value>::connected_v2();
        let hello = Frame::json(
            FrameKind::Hello,
            &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
        )
        .unwrap()
        .encode();
        client.received(&hello);
        client.subscribe(Sub::new("s1", "list").from_cursor(3)).unwrap();
        while client.take_send().is_some() {}
        let dropped = Frame::json(FrameKind::Dropped, &serde_json::json!({"sid":"s1","cursor":3}))
            .unwrap()
            .encode();
        client.received(&dropped);
        let change = client.next_change().unwrap();
        let new_sid = match change {
            Change::Dropped { new_sid: Some(new_sid), .. } => new_sid,
            other => panic!("unexpected change: {other:?}"),
        };
        assert!(new_sid != "s1");
        assert!(String::from_utf8(client.take_send().unwrap()).unwrap().contains(&new_sid));
        let old_frame = Frame::json(
            FrameKind::Window,
            &serde_json::json!({"sid":"s1","cursor":4,"rows":[],"hasBefore":false,"hasAfter":false,"edition":1}),
        )
        .unwrap()
        .encode();
        client.received(&old_frame);
        assert!(client.next_change().is_none());
    }

    #[test]
    fn page_error_releases_the_request_slot() {
        let mut client = Client::<Value>::connected_v2();
        let hello = Frame::json(
            FrameKind::Hello,
            &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
        )
        .unwrap()
        .encode();
        client.received(&hello);
        client.subscribe(Sub::new("s", "list")).unwrap();
        while client.take_send().is_some() {}
        client.page(Page::new("s", "list", wire::PageSide::After, 1)).unwrap();
        let error = Frame::json(
            FrameKind::Error,
            &serde_json::json!({"method":"page","sid":"s","code":"invalid_page"}),
        )
        .unwrap()
        .encode();
        client.received(&error);
        let _ = client.next_change();
        assert!(client.page(Page::new("s", "list", wire::PageSide::After, 1)).is_ok());
    }

    #[test]
    fn final_replay_frame_marks_its_operations_as_replay() {
        let mut client = Client::<Value>::connected_v2();
        let hello = Frame::json(
            FrameKind::Hello,
            &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
        )
        .unwrap()
        .encode();
        client.received(&hello);
        client.subscribe(Sub::new("s", "list").from_cursor(0)).unwrap();
        while client.take_send().is_some() {}
        let frame = Frame::json(
            FrameKind::Delta,
            &serde_json::json!({"sid":"s","replay":"end","ops":[{"op":"queue","seq":1,"bytes":1}]}),
        )
        .unwrap()
        .encode();
        client.received(&frame);
        assert!(matches!(client.next_change(), Some(Change::Queue { replay: true, .. })));
        assert!(matches!(client.next_change(), Some(Change::ResumeEnd { .. })));
    }

    #[test]
    fn not_ready_keeps_the_subscription_for_a_later_window() {
        let mut client = Client::<Value>::connected_v2();
        let hello = Frame::json(
            FrameKind::Hello,
            &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
        )
        .unwrap()
        .encode();
        client.received(&hello);
        client.subscribe(Sub::new("s", "list")).unwrap();
        while client.take_send().is_some() {}
        let error = Frame::json(
            FrameKind::Error,
            &serde_json::json!({"method":"sub","sid":"s","code":"not_ready"}),
        )
        .unwrap()
        .encode();
        client.received(&error);
        assert!(matches!(client.next_change(), Some(Change::Error { .. })));
        let window = Frame::json(
            FrameKind::Window,
            &serde_json::json!({"sid":"s","cursor":1,"rows":[],"hasBefore":false,"hasAfter":false,"edition":1}),
        )
        .unwrap()
        .encode();
        client.received(&window);
        assert!(matches!(client.next_change(), Some(Change::Window(_))));
    }

    #[test]
    fn page_drops_rows_changed_while_request_was_out_and_origin_is_one_change() {
        let mut client = Client::<Value>::connected_v2();
        let hello = Frame::json(
            FrameKind::Hello,
            &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
        )
        .unwrap()
        .encode();
        client.received(&hello);
        client.subscribe(Sub::new("s", "list")).unwrap();
        while client.take_send().is_some() {}
        client.page(Page::new("s", "list", wire::PageSide::After, 1)).unwrap();
        let delta = Frame::json(
            FrameKind::Delta,
            &serde_json::json!({"sid":"s","ops":[{"op":"summary","seq":2,"summary":{"chatId":"changed"}}]}),
        )
        .unwrap()
        .encode();
        client.received(&delta);
        let _ = client.next_change();
        let page = Frame::json(
            FrameKind::Page,
            &serde_json::json!({"sid":"s","rows":[{"chatId":"changed"},{"chatId":"kept"}],"hasBefore":false,"hasAfter":false}),
        )
        .unwrap()
        .encode();
        client.received(&page);
        let Change::Page(page) = client.next_change().unwrap() else { panic!("expected page") };
        assert_eq!(page.rows, vec![serde_json::json!({"chatId":"kept"})]);
        let origin = Frame::json(
            FrameKind::Delta,
            &serde_json::json!({"sid":"s","ops":[{"op":"origin","seq":3,"id":"p","state":"removed","since":3}]}),
        )
        .unwrap()
        .encode();
        client.received(&origin);
        assert!(matches!(client.next_change(), Some(Change::Origin { .. })));
    }

    #[test]
    fn mirror_walk_reconciles_and_emits_whole_after_rows() {
        let mut client = Client::<Value>::connected_v2();
        let hello = Frame::json(
            FrameKind::Hello,
            &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
        )
        .unwrap()
        .encode();
        assert_eq!(client.received(&hello), hello.len());
        client.subscribe_mirror(Sub::new("m", "list"), std::iter::empty(), false).unwrap();
        let _ = client.take_send();
        let window = Frame::json(
            FrameKind::Window,
            &serde_json::json!({"sid":"m","cursor":4,"rows":[],"hasBefore":false,"hasAfter":false,"edition":1}),
        )
        .unwrap()
        .encode();
        client.received(&window);
        assert!(matches!(client.next_change(), Some(Change::Window(_))));
        let page_request = client.take_send().expect("mirror starts a walk");
        let page = Frame::json(
            FrameKind::Page,
            &serde_json::json!({
                "sid":"m","rows":[{"chatId":"chat","origin":"local","lastActivity":9,"state":"idle"}],
                "hasBefore":false,"hasAfter":false
            }),
        )
        .unwrap()
        .encode();
        assert!(!page_request.is_empty());
        client.received(&page);
        assert!(matches!(client.next_change(), Some(Change::Summary { .. })));
        assert!(matches!(client.next_change(), Some(Change::ResumeEnd { .. })));
    }

    #[test]
    fn wanted_page_rest_is_requested_until_answered() {
        let mut client = Client::<Value>::connected_v2();
        let hello = Frame::json(
            FrameKind::Hello,
            &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
        )
        .unwrap()
        .encode();
        client.received(&hello);
        client.subscribe_mirror(Sub::new("m", "list"), std::iter::empty(), true).unwrap();
        let _ = client.take_send();
        let key1 = ListKey { last_activity: 1, chat_id: "a".into(), origin: "local".into() };
        let key2 = ListKey { last_activity: 2, chat_id: "b".into(), origin: "local".into() };
        client.want("m", [key1.clone(), key2.clone()]).unwrap();
        let _ = client.take_send().expect("wanted read");
        let partial = Frame::json(
            FrameKind::Page,
            &serde_json::json!({
                "sid":"m","rows":[{"chatId":"a","origin":"local","lastActivity":1,"state":"idle"}],
                "hasBefore":false,"hasAfter":false,"rest":[key2]
            }),
        )
        .unwrap()
        .encode();
        client.received(&partial);
        let _ = client.next_change();
        let retry = client.take_send().expect("rest is retried");
        let retry_frame = Frame::from_encoded(&retry).unwrap();
        let retry_value: Value = retry_frame.decode_json().unwrap();
        assert_eq!(retry_value.pointer("/params/keys/0/chatId"), Some(&Value::String("b".into())));
    }

    #[test]
    fn v1_row_overlays_typed_fields_and_spawned_by() {
        let mut parent = Summary::new("parent");
        parent.state = "idle".into();
        let mut child = Summary::new("child");
        child.state = "waiting".into();
        child.parent = Some(parent.key());
        child.extra =
            serde_json::value::RawValue::from_string(r#"{"sessionId":"old","custom":true}"#.into())
                .unwrap();
        let row = v1_row(&child, wire::OriginState::Stale, Some(&parent));
        assert_eq!(row.get("sessionId"), Some(&Value::String("child".into())));
        assert_eq!(row.get("unread"), Some(&Value::Bool(false)));
        assert_eq!(row.get("spawnedBy"), Some(&Value::String("parent".into())));
        assert_eq!(row.get("stale"), Some(&Value::Bool(true)));
        assert_eq!(row.get("custom"), Some(&Value::Bool(true)));
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
            &serde_json::json!({"sid":"s","cursor":1,"rows":[],"hasBefore":false,"hasAfter":false,"edition":1}),
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

    #[cfg(feature = "tokio")]
    #[tokio::test]
    async fn tokio_driver_returns_fallback_transport_and_held_bytes() {
        use tokio::io::{AsyncWriteExt, duplex, sink};
        let (mut input, reader) = duplex(4096);
        let (out_tx, _out_rx) = tokio::sync::mpsc::channel(2);
        let task = tokio::spawn(tokio_driver::drive(
            Client::<Value>::new(["list"]),
            reader,
            sink(),
            out_tx,
        ));
        input
            .write_all(
                br#"{"jsonrpc":"2.0","id":1,"error":{"code":-32601}}
tail"#,
            )
            .await
            .unwrap();
        let exit = task.await.unwrap().unwrap();
        let tokio_driver::DriveExit::Fallback { bytes, .. } = exit else {
            panic!("driver did not return fallback transport")
        };
        assert_eq!(bytes, b"tail");
    }
}
