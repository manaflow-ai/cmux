//! I/O-free client state machine for agent-service v2.

pub mod ffi;
pub mod wire;

use acpmux_list_types::Summary;

use serde::{Serialize, de::DeserializeOwned};
use serde_json::Value;
use std::collections::{HashMap, HashSet, VecDeque};
use wire::{
    Anchor, Cursor, DeltaOp, FolderPageResult, FolderWindow, Frame, FrameError, FrameKind, Hello,
    Limits, ListKey, ListView, Page, PageResult, Request, Sub, Window,
};

#[derive(Clone, Debug, PartialEq)]
pub enum Change<T> {
    Window(Window<T>),
    FolderWindow(FolderWindow),
    Page(PageResult<T>),
    FolderPage(FolderPageResult),
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
    Folder {
        sid: String,
        seq: u64,
        row: wire::FolderRow,
        replay: bool,
    },
    FolderGone {
        sid: String,
        seq: u64,
        origin: String,
        folder: String,
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
    if Summary::listed_under(summary, parent) {
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
    touched: HashSet<(String, String)>,
    pending_wanted: VecDeque<ListKey>,
    // Decision 166: a window or a successful page permits one immediate retry.
    read_error_since_progress: bool,
    reads_stopped: bool,
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
    changed_folders: HashSet<(String, String)>,
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
    stale_folder_pages: HashSet<String>,
    deferred_folder_pages: HashMap<String, Page>,
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
        matches!(sub.request.view, Some(ListView::Live))
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
            stale_folder_pages: HashSet::new(),
            deferred_folder_pages: HashMap::new(),
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
        self.stale_folder_pages.clear();
        self.deferred_folder_pages.clear();
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
            if sub.request.view == Some(ListView::Folders) {
                // Folder subscriptions are always reopened at a fresh head;
                // their view sequence is not a resumable history.
                sub.request = sub.initial.clone();
                sub.request.cursor = None;
                sub.request.edition = None;
                sub.request.anchor = Some(Anchor::End);
                sub.cursor = Cursor::default();
                sub.edition = 0;
                sub.replaying = false;
                sub.window_taken = false;
            } else if sub.window_taken {
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
        if sub.view == Some(ListView::Folders) {
            // A folders window is a replacement head snapshot. Cursors and
            // editions belong to resumable summary streams only.
            sub.cursor = None;
            sub.edition = None;
            sub.anchor = Some(Anchor::End);
        } else if sub.cursor.is_none() {
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
        wire::validate_mirror_view(sub.view)?;
        if !whole {
            sub.cursor = None;
            sub.edition = None;
            sub.anchor = None;
        }
        if sub.cursor.is_none() {
            sub.anchor.get_or_insert(Anchor::End);
        }
        let keys: HashMap<(String, String), ListKey> =
            held_keys.into_iter().map(|key| (Self::row_identity(&key), key)).collect();
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
        // An explicit want may read pending keys after a stop, but does not
        // replenish the retry allowance or restart the view's walk.
        mirror.reads_stopped = false;
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
        self.stale_folder_pages.remove(sid);
        self.deferred_folder_pages.remove(sid);
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
        let folder_page = page.view == Some(ListView::Folders)
            || self
                .subscriptions
                .get(&page.sid)
                .is_some_and(|sub| sub.request.view == Some(ListView::Folders));
        if folder_page && self.stale_folder_pages.contains(&page.sid) {
            if self.deferred_folder_pages.contains_key(&page.sid) {
                return Err(FrameError::RequestInFlight);
            }
            // Validate now, before accepting a request whose send is deferred.
            Frame::json(FrameKind::Request, &Request::Page(page.clone()))?;
            self.deferred_folder_pages.insert(page.sid.clone(), page);
            return Ok(());
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

    fn summary_is_live(value: &Value) -> bool {
        value.get("state").and_then(Value::as_str).is_none_or(acpmux_list_types::is_live_state)
    }

    fn row_identity(key: &ListKey) -> (String, String) {
        (key.origin.clone(), key.chat_id.clone())
    }

    fn start_mirror_walk(&mut self, sid: &str) {
        if self
            .subscriptions
            .get(sid)
            .and_then(|sub| sub.mirror.as_ref())
            .is_some_and(|mirror| mirror.reads_stopped)
        {
            return;
        }
        if self.pages.contains_key(sid) {
            if let Some(sub) = self.subscriptions.get_mut(sid)
                && let Some(mirror) = sub.mirror.as_mut()
            {
                mirror.walking = true;
                mirror.whole = false;
            }
            return;
        }
        let page = {
            let Some(sub) = self.subscriptions.get_mut(sid) else { return };
            let Some(mirror) = sub.mirror.as_mut() else { return };
            mirror.walking = true;
            mirror.whole = false;
            mirror.seen.clear();
            mirror.touched.clear();
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
            if mirror.walking || mirror.reads_stopped || mirror.pending_wanted.is_empty() {
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
                keys: Some(keys.into_iter().map(wire::PageKey::Summary).collect()),
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
                    !mirror.seen.contains_key(*id)
                        && !mirror.touched.contains(*id)
                        && !mirror.wanted.contains_key(*id)
                })
                .map(|(_, key)| key.clone())
                .collect();
            for key in &stale {
                mirror.held.remove(&Self::row_identity(key));
            }
            mirror.walking = false;
            mirror.whole = true;
            mirror.seen.clear();
            mirror.touched.clear();
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
                let sid_hint = frame
                    .decode_json::<Value>()
                    .ok()
                    .and_then(|value| value.get("sid").and_then(Value::as_str).map(str::to_owned));
                let is_folders = sid_hint.as_deref().is_some_and(|sid| {
                    self.subscriptions
                        .get(sid)
                        .is_some_and(|sub| sub.request.view == Some(ListView::Folders))
                });
                if is_folders {
                    let Ok(window) = frame.decode_json::<FolderWindow>() else {
                        self.protocol_error("malformed folders window");
                        return;
                    };
                    let sid = window.sid.clone();
                    if !self.subscriptions.contains_key(&sid) {
                        self.skips.unheld_sid = self.skips.unheld_sid.saturating_add(1);
                        self.charge_frame_now(None, frame_bytes);
                        return;
                    }
                    // A new head invalidates every folder page requested from
                    // the previous head. Responses that arrive after this
                    // point are discarded before sending a deferred request.
                    if self.pages.remove(&sid).is_some() {
                        self.stale_folder_pages.insert(sid.clone());
                    }
                    self.deferred_folder_pages.remove(&sid);
                    let replaying =
                        self.subscriptions.get(&sid).map(|sub| sub.replaying).unwrap_or(false);
                    if let Some(sub) = self.subscriptions.get_mut(&sid) {
                        sub.cursor = Cursor(window.cursor);
                        sub.edition = window.edition;
                        sub.replaying = false;
                        sub.window_taken = true;
                    }
                    self.push_change(
                        Change::FolderWindow(window),
                        Some(sid.clone()),
                        frame_bytes,
                        true,
                    );
                    if replaying {
                        self.push_change(Change::Unconfirmed { sid }, None, 0, false);
                    }
                    return;
                }
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
                        mirror.read_error_since_progress = false;
                        mirror.reads_stopped = false;
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
                let sid_hint = frame
                    .decode_json::<Value>()
                    .ok()
                    .and_then(|value| value.get("sid").and_then(Value::as_str).map(str::to_owned));
                if sid_hint.as_deref().is_some_and(|sid| !self.subscriptions.contains_key(sid)) {
                    // An unheld page cannot be applied to any current
                    // subscription. Skip it before generic decoding, since a
                    // Value client could otherwise surface it as a Page.
                    self.skips.unheld_sid = self.skips.unheld_sid.saturating_add(1);
                    self.charge_frame_now(None, frame_bytes);
                    return;
                }
                let is_folders = sid_hint.as_deref().is_some_and(|sid| {
                    self.subscriptions
                        .get(sid)
                        .is_some_and(|sub| sub.request.view == Some(ListView::Folders))
                });
                if is_folders {
                    let Ok(mut page) = frame.decode_json::<FolderPageResult>() else {
                        self.protocol_error("malformed folders page");
                        return;
                    };
                    let sid = page.sid.clone();
                    if !self.subscriptions.contains_key(&sid) {
                        self.skips.unheld_sid = self.skips.unheld_sid.saturating_add(1);
                        self.charge_frame_now(None, frame_bytes);
                        return;
                    }
                    let Some(state) = self.pages.remove(&sid) else {
                        // This is a response to a page invalidated by a
                        // reconnect or a replacement folder window.
                        self.release_folder_tombstone(&sid);
                        self.charge_frame_now(Some(&sid), frame_bytes);
                        return;
                    };
                    page.rows.retain(|row| {
                        !state
                            .changed_folders
                            .contains(&(row.origin.to_string(), row.folder.to_string()))
                            && !state.removed_origins.contains(row.origin.as_ref())
                    });
                    self.push_change(Change::FolderPage(page), Some(sid), frame_bytes, true);
                    return;
                }
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
                if let Some(mirror) =
                    self.subscriptions.get_mut(&sid).and_then(|sub| sub.mirror.as_mut())
                {
                    mirror.read_error_since_progress = false;
                }
                let state = self.pages.remove(&sid).unwrap_or_default();
                if matches!(state.purpose, PagePurpose::User | PagePurpose::MirrorWalk) {
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
                        let restart_walk = self
                            .subscriptions
                            .get(&sid)
                            .and_then(|sub| sub.mirror.as_ref())
                            .is_some_and(|mirror| mirror.walking && !mirror.whole);
                        if restart_walk {
                            self.start_mirror_walk(&sid);
                        } else {
                            self.maybe_start_wanted(&sid);
                        }
                    }
                    PagePurpose::MirrorWalk => self.accept_mirror_walk_page(page, frame_bytes),
                    PagePurpose::Wanted => self.accept_wanted_page(
                        page,
                        frame_bytes,
                        state
                            .request
                            .and_then(|request| request.keys)
                            .unwrap_or_default()
                            .into_iter()
                            .filter_map(|key| match key {
                                wire::PageKey::Summary(key) => Some(key),
                                wire::PageKey::Folder(_) => None,
                            })
                            .collect(),
                    ),
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
                if method == "page"
                    && let Some(sid) = sid.as_deref()
                {
                    // Retired and superseded folder replies cannot reach a new head.
                    if !self.subscriptions.contains_key(sid) {
                        self.charge_frame_now(None, frame_bytes);
                        return;
                    }
                    if self.stale_folder_pages.contains(sid) {
                        self.pages.remove(sid);
                        self.release_folder_tombstone(sid);
                        self.charge_frame_now(Some(sid), frame_bytes);
                        return;
                    }
                }
                let restart_walk = if method == "page" {
                    sid.as_deref().is_some_and(|sid| self.accept_page_error(sid))
                } else {
                    false
                };
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
                    sid.clone(),
                    frame_bytes,
                    true,
                );
                if restart_walk && let Some(sid) = sid {
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

    /// Both automatic read paths share one retry allowance per subscription.
    /// A failed wanted read keeps its keys while the retry walks from the head.
    fn accept_page_error(&mut self, sid: &str) -> bool {
        let state = self.pages.remove(sid);
        let Some(mirror) = self.subscriptions.get_mut(sid).and_then(|sub| sub.mirror.as_mut())
        else {
            return false;
        };
        let Some(state) = state else { return false };
        if matches!(state.purpose, PagePurpose::User) {
            // Freeing the caller's slot may release a waiting walk. The
            // caller's error neither spends nor restores its retry allowance.
            return mirror.walking && !mirror.whole && !mirror.reads_stopped;
        }
        let retry = !mirror.read_error_since_progress;
        mirror.read_error_since_progress = true;
        if matches!(state.purpose, PagePurpose::Wanted)
            && let Some(keys) = state.request.and_then(|request| request.keys)
        {
            for key in keys.into_iter().rev() {
                if let wire::PageKey::Summary(key) = key {
                    mirror.pending_wanted.push_front(key);
                }
            }
        }
        mirror.walking = false;
        mirror.whole = false;
        mirror.reads_stopped = !retry;
        retry
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

    fn accept_wanted_page(
        &mut self,
        page: PageResult<T>,
        frame_bytes: u64,
        requested_keys: Vec<ListKey>,
    ) {
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
        {
            let Some(sub) = self.subscriptions.get_mut(&sid) else { return };
            let Some(mirror) = sub.mirror.as_mut() else { return };
            for key in &requested_keys {
                mirror.pending_wanted.retain(|pending| pending != key);
            }
        }
        if !page.rest.is_empty() {
            if answered == 0 {
                self.protocol_error("wanted page rest made no progress");
                return;
            }
            {
                let Some(sub) = self.subscriptions.get_mut(&sid) else { return };
                let Some(mirror) = sub.mirror.as_mut() else { return };
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
                    self.note_page_summary(&sid, &summary);
                    let value = serde_json::to_value(&summary).ok();
                    let key = value.as_ref().and_then(Self::row_key);
                    let live = value.as_ref().is_some_and(Self::summary_is_live);
                    let (live_view, held, wanted, mirrored) = self
                        .subscriptions
                        .get(&sid)
                        .map(|sub| {
                            let id = key.as_ref().map(Self::row_identity);
                            let mirror = sub.mirror.as_ref();
                            (
                                Self::sub_view_is_live(sub),
                                id.as_ref().is_some_and(|id| {
                                    mirror.is_some_and(|mirror| mirror.held.contains_key(id))
                                }),
                                id.as_ref().is_some_and(|id| {
                                    mirror.is_some_and(|mirror| mirror.wanted.contains_key(id))
                                }),
                                mirror.is_some(),
                            )
                        })
                        .unwrap_or((false, false, false, false));
                    let left = live_view && !live && held && !wanted;
                    let deliver = !mirrored || !live_view || live || held || wanted;
                    if let Some(sub) = self.subscriptions.get_mut(&sid)
                        && let Some(mirror) = sub.mirror.as_mut()
                        && let Some(key) = key
                    {
                        let id = Self::row_identity(&key);
                        if mirror.walking {
                            mirror.touched.insert(id.clone());
                        }
                        if live || mirror.wanted.contains_key(&id) {
                            mirror.held.insert(id, key);
                        } else {
                            mirror.held.remove(&id);
                        }
                    }
                    if left {
                        let charge = !charged;
                        charged = true;
                        emitted = true;
                        self.push_change(
                            Change::Left { sid: sid.clone(), seq, summary, replay },
                            Some(sid.clone()),
                            frame_bytes,
                            charge,
                        );
                    } else if deliver {
                        let charge = !charged;
                        charged = true;
                        emitted = true;
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
                        if mirror.walking {
                            mirror.touched.insert(id.clone());
                        }
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
                Ok(DeltaOp::Folder { seq, row }) => {
                    self.advance(&sid, seq);
                    if !self
                        .subscriptions
                        .get(&sid)
                        .is_some_and(|sub| sub.request.view == Some(ListView::Folders))
                    {
                        self.skips.unknown_op = self.skips.unknown_op.saturating_add(1);
                        continue;
                    }
                    let charge = !charged;
                    charged = true;
                    emitted = true;
                    self.note_page_folder(&sid, &row);
                    self.push_change(
                        Change::Folder { sid: sid.clone(), seq, row, replay },
                        Some(sid.clone()),
                        frame_bytes,
                        charge,
                    );
                }
                Ok(DeltaOp::FolderGone { seq, origin, folder }) => {
                    self.advance(&sid, seq);
                    if !self
                        .subscriptions
                        .get(&sid)
                        .is_some_and(|sub| sub.request.view == Some(ListView::Folders))
                    {
                        self.skips.unknown_op = self.skips.unknown_op.saturating_add(1);
                        continue;
                    }
                    let charge = !charged;
                    charged = true;
                    emitted = true;
                    if let Some(page) = self.pages.get_mut(&sid) {
                        page.changed_folders.insert((origin.clone(), folder.clone()));
                    }
                    self.push_change(
                        Change::FolderGone { sid: sid.clone(), seq, origin, folder, replay },
                        Some(sid.clone()),
                        frame_bytes,
                        charge,
                    );
                }
                Err(_) => {
                    self.skips.unknown_op = self.skips.unknown_op.saturating_add(1);
                    self.advance(&sid, seq);
                    if let Some(page) = self.pages.get_mut(&sid)
                        && let Some(chat_id) = raw.get("chatId").and_then(Value::as_str)
                    {
                        let origin = raw.get("origin").and_then(Value::as_str).unwrap_or("local");
                        if let Some(sub) = self.subscriptions.get_mut(&sid)
                            && let Some(mirror) = sub.mirror.as_mut()
                            && mirror.walking
                        {
                            mirror.touched.insert((origin.to_owned(), chat_id.to_owned()));
                        }
                        page.changed_keys.insert((origin.to_owned(), chat_id.to_owned()));
                    }
                }
            }
        }
        if let Some(cursor) = value.get("cursor").and_then(Value::as_u64) {
            self.advance(&sid, cursor);
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
        let folders = sub.request.view == Some(ListView::Folders);
        if folders {
            self.stale_folder_pages.remove(&drop.sid);
            self.deferred_folder_pages.remove(&drop.sid);
            self.pages.remove(&drop.sid);
        }
        let cursor = (!folders).then_some(drop.cursor).flatten();
        sub.request = sub.initial.clone();
        sub.request.sid = new_sid.clone();
        if folders {
            sub.request.cursor = None;
            sub.request.edition = None;
            sub.request.anchor = Some(Anchor::End);
        } else {
            sub.request.cursor = cursor;
            sub.request.edition = cursor.map(|_| sub.edition);
            if cursor.is_some() {
                sub.request.anchor = None;
            }
        }
        sub.cursor = cursor.unwrap_or_default();
        sub.replaying = !folders && cursor.is_some();
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

    fn note_page_folder(&mut self, sid: &str, row: &wire::FolderRow) {
        if let Some(page) = self.pages.get_mut(sid) {
            page.changed_folders.insert((row.origin.to_string(), row.folder.to_string()));
        }
    }

    fn release_folder_tombstone(&mut self, sid: &str) {
        if !self.stale_folder_pages.remove(sid) {
            return;
        }
        let Some(page) = self.deferred_folder_pages.remove(sid) else {
            return;
        };
        let page_state = PageState { request: Some(page.clone()), ..PageState::default() };
        self.pages.insert(sid.to_owned(), page_state);
        if self.phase == Phase::Ready {
            let _ = self.queue_request(Request::Page(page));
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
    fn folder_subscription_strips_resume_fields_and_uses_head_anchor() {
        let mut client = Client::<Value>::connected_v2();
        let hello_request = Frame::from_encoded(&client.take_send().unwrap()).unwrap();
        assert!(matches!(hello_request.decode_json::<Request>().unwrap(), Request::Hello(_)));
        let hello = Frame::json(
            FrameKind::Hello,
            &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
        )
        .unwrap()
        .encode();
        client.received(&hello);
        let mut sub = Sub::new("folders", "list");
        sub.view = Some(ListView::Folders);
        sub.cursor = Some(Cursor(7));
        sub.edition = Some(3);
        client.subscribe(sub).unwrap();
        let request = Frame::from_encoded(&client.take_send().unwrap()).unwrap();
        let value: Value = request.decode_json().unwrap();
        assert_eq!(value.pointer("/params/anchor"), Some(&Value::String("end".into())));
        assert!(value.pointer("/params/cursor").is_none());
        assert!(value.pointer("/params/edition").is_none());
    }

    #[test]
    fn folders_reconnect_and_drop_start_fresh_and_discard_old_pages() {
        let mut client = Client::<Value>::connected_v2();
        let hello_request = Frame::from_encoded(&client.take_send().unwrap()).unwrap();
        assert!(matches!(hello_request.decode_json::<Request>().unwrap(), Request::Hello(_)));
        let hello = Frame::json(
            FrameKind::Hello,
            &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
        )
        .unwrap()
        .encode();
        client.received(&hello);
        let mut sub = Sub::new("folders", "list");
        sub.view = Some(ListView::Folders);
        client.subscribe(sub).unwrap();
        let _ = client.take_send();

        let window = Frame::json(
            FrameKind::Window,
            &serde_json::json!({
                "sid":"folders","cursor":11,"rows":[],"hasBefore":false,
                "hasAfter":false,"edition":4
            }),
        )
        .unwrap()
        .encode();
        client.received(&window);
        assert!(matches!(client.next_change(), Some(Change::FolderWindow(_))));

        let mut page = Page::new("folders", "list", wire::PageSide::After, 1);
        page.view = Some(ListView::Folders);
        client.page(page).unwrap();
        let _old_page_request = client.take_send().unwrap();

        // A replacement head also invalidates a page that was requested from
        // the previous head, even before a transport reconnect.
        let replacement = Frame::json(
            FrameKind::Window,
            &serde_json::json!({
                "sid":"folders","cursor":12,"rows":[],"hasBefore":false,
                "hasAfter":false,"edition":5
            }),
        )
        .unwrap()
        .encode();
        client.received(&replacement);
        assert!(matches!(client.next_change(), Some(Change::FolderWindow(_))));
        let mut blocked_page = Page::new("folders", "list", wire::PageSide::After, 1);
        blocked_page.view = Some(ListView::Folders);
        assert!(client.page(blocked_page).is_ok());
        assert!(client.take_send().is_none(), "deferred page must wait for stale reply");
        let stale_page = Frame::json(
            FrameKind::Page,
            &serde_json::json!({"sid":"folders","rows":[],"hasBefore":false,"hasAfter":false}),
        )
        .unwrap()
        .encode();
        client.received(&stale_page);
        assert!(client.next_change().is_none());

        let fresh_request = client.take_send().unwrap();
        let request_value: Value =
            Frame::from_encoded(&fresh_request).unwrap().decode_json().unwrap();
        assert_eq!(request_value.get("method"), Some(&Value::String("page".into())));
        let fresh_page = Frame::json(
            FrameKind::Page,
            &serde_json::json!({"sid":"folders","rows":[],"hasBefore":false,"hasAfter":false}),
        )
        .unwrap()
        .encode();
        client.received(&fresh_page);
        assert!(matches!(client.next_change(), Some(Change::FolderPage(_))));

        let mut page = Page::new("folders", "list", wire::PageSide::After, 1);
        page.view = Some(ListView::Folders);
        client.page(page).unwrap();
        client.disconnected();
        let _hello_request = client.take_send().unwrap();
        client.received(&hello);
        let request = Frame::from_encoded(&client.take_send().unwrap()).unwrap();
        let value: Value = request.decode_json().unwrap();
        assert_eq!(value.pointer("/params/anchor"), Some(&Value::String("end".into())));
        assert!(value.pointer("/params/cursor").is_none());
        assert!(value.pointer("/params/edition").is_none());

        // The page was outstanding on the old head and must not reappear.
        let stale_page = Frame::json(
            FrameKind::Page,
            &serde_json::json!({"sid":"folders","rows":[],"hasBefore":false,"hasAfter":false}),
        )
        .unwrap()
        .encode();
        client.received(&stale_page);
        assert!(client.next_change().is_none());

        let dropped =
            Frame::json(FrameKind::Dropped, &serde_json::json!({"sid":"folders","cursor":12}))
                .unwrap()
                .encode();
        client.received(&dropped);
        let new_sid = match client.next_change() {
            Some(Change::Dropped { new_sid: Some(sid), cursor, .. }) => {
                assert!(cursor.is_none());
                sid
            }
            other => panic!("unexpected change: {other:?}"),
        };
        let request = Frame::from_encoded(&client.take_send().unwrap()).unwrap();
        let value: Value = request.decode_json().unwrap();
        assert_eq!(value.pointer("/params/sid"), Some(&Value::String(new_sid)));
        assert_eq!(value.pointer("/params/anchor"), Some(&Value::String("end".into())));
        assert!(value.pointer("/params/cursor").is_none());
        assert!(value.pointer("/params/edition").is_none());

        // A late page for the retired folder SID must not fall through the
        // generic PageResult<Value> decoder.
        let before = client.skip_counters();
        let stale_page = Frame::json(
            FrameKind::Page,
            &serde_json::json!({
                "sid":"folders","rows":[{"chatId":"old"}],
                "hasBefore":false,"hasAfter":false
            }),
        )
        .unwrap()
        .encode();
        client.received(&stale_page);
        assert!(client.next_change().is_none());
        assert_eq!(client.skip_counters().unheld_sid, before.unheld_sid + 1);
        let stale_error = Frame::json(
            FrameKind::Error,
            &serde_json::json!({"method":"page","sid":"folders","code":"invalid_page"}),
        )
        .unwrap()
        .encode();
        client.received(&stale_error);
        assert!(client.next_change().is_none(), "a retired page error is stale too");
        assert_eq!(client.skip_counters().unheld_sid, before.unheld_sid + 2);
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
    fn folder_delta_is_applied_without_unknown_op_skip_or_page_stale_row() {
        let mut client = Client::<Value>::connected_v2();
        let hello = Frame::json(
            FrameKind::Hello,
            &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
        )
        .unwrap()
        .encode();
        client.received(&hello);
        client.subscribe(Sub { view: Some(ListView::Folders), ..Sub::new("s", "list") }).unwrap();
        while client.take_send().is_some() {}
        let page_request = Page {
            sid: "s".into(),
            stream: "list".into(),
            before: None,
            after: None,
            keys: None,
            view: Some(ListView::Folders),
            max_bytes: wire::MAX_PAGE_BYTES as u32,
            filter: None,
        };
        client.page(page_request).unwrap();
        let folder = serde_json::json!({
            "origin":"local", "folder":"/work", "newest":{"origin":"local","chatId":"chat"}, "at": 3, "count": 1
        });
        let delta = Frame::json(
            FrameKind::Delta,
            &serde_json::json!({"sid":"s","ops":[{"op":"folder","seq":2,"row":folder}]}),
        )
        .unwrap()
        .encode();
        let before = client.skip_counters();
        client.received(&delta);
        assert_eq!(client.skip_counters().unknown_op, before.unknown_op);
        assert!(matches!(client.next_change(), Some(Change::Folder { seq: 2, .. })));
        let page = Frame::json(
            FrameKind::Page,
            &serde_json::json!({"sid":"s","rows":[folder],"hasBefore":false,"hasAfter":false}),
        )
        .unwrap()
        .encode();
        client.received(&page);
        let Change::FolderPage(page) = client.next_change().unwrap() else {
            panic!("expected folder page")
        };
        assert!(page.rows.is_empty());
    }

    #[test]
    fn mirror_api_refuses_folders_before_registering_a_sid() {
        let mut client = Client::<Value>::connected_v2();
        let mut sub = Sub::new("folders", "list");
        sub.view = Some(ListView::Folders);
        assert!(client.subscribe_mirror(sub, std::iter::empty(), false).is_err());
        assert!(client.subscriptions.is_empty());
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
        assert!(matches!(client.next_change(), Some(Change::Whole { .. })));
    }

    #[test]
    fn live_mirror_emits_left_for_closed_and_summary_rows() {
        let mut client = Client::<Value>::connected_v2();
        let hello = Frame::json(
            FrameKind::Hello,
            &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
        )
        .unwrap()
        .encode();
        client.received(&hello);
        let mut sub = Sub::new("m", "list");
        sub.view = Some(ListView::Live);
        client.subscribe_mirror(sub, std::iter::empty(), false).unwrap();
        while client.take_send().is_some() {}
        let window = Frame::json(
            FrameKind::Window,
            &serde_json::json!({"sid":"m","cursor":1,"rows":[
                {"chatId":"a","origin":"local","lastActivity":1,"state":"idle"},
                {"chatId":"b","origin":"local","lastActivity":1,"state":"idle"}
            ],"hasBefore":false,"hasAfter":false,"edition":1}),
        )
        .unwrap()
        .encode();
        client.received(&window);
        let _ = client.next_change();
        let _ = client.take_send();
        let delta = Frame::json(
            FrameKind::Delta,
            &serde_json::json!({"sid":"m","ops":[
                {"op":"summary","seq":2,"summary":{"chatId":"a","origin":"local","lastActivity":2,"state":"closed"}},
                {"op":"summary","seq":3,"summary":{"chatId":"b","origin":"local","lastActivity":3}}
            ]}),
        )
        .unwrap()
        .encode();
        client.received(&delta);
        assert!(matches!(client.next_change(), Some(Change::Left { .. })));
        assert!(matches!(client.next_change(), Some(Change::Summary { .. })));
    }

    fn receive_changes(
        client: &mut Client<Value>,
        kind: FrameKind,
        value: Value,
    ) -> Vec<Change<Value>> {
        let bytes = Frame::json(kind, &value).unwrap().encode();
        assert_eq!(client.received(&bytes), bytes.len());
        std::iter::from_fn(|| client.next_change()).collect()
    }

    fn take_pages(client: &mut Client<Value>) -> Vec<Value> {
        std::iter::from_fn(|| client.take_send())
            .map(|bytes| Frame::from_encoded(&bytes).unwrap().decode_json::<Value>().unwrap())
            .filter(|request| request.get("method").and_then(Value::as_str) == Some("page"))
            .collect()
    }

    fn mirror_window(client: &mut Client<Value>) {
        let changes = receive_changes(
            client,
            FrameKind::Window,
            serde_json::json!({
                "sid":"m","cursor":1,"rows":[],"hasBefore":false,"hasAfter":false,"edition":1
            }),
        );
        assert!(matches!(changes.as_slice(), [Change::Window(_)]));
    }

    fn mirror_page_error(client: &mut Client<Value>) {
        let changes = receive_changes(
            client,
            FrameKind::Error,
            serde_json::json!({
                "method":"page","sid":"m","code":"request_failed"
            }),
        );
        assert!(matches!(changes.as_slice(), [Change::Error { .. }]));
    }

    fn finish_empty_walk(client: &mut Client<Value>) {
        let changes = receive_changes(
            client,
            FrameKind::Page,
            serde_json::json!({
                "sid":"m","rows":[],"hasBefore":false,"hasAfter":false
            }),
        );
        assert!(matches!(changes.as_slice(), [Change::Whole { .. }]));
    }

    #[test]
    fn live_subscription_without_mirror_delivers_closing_summary() {
        let mut client = ready_mirror();
        let mut sub = Sub::new("plain", "list");
        sub.view = Some(ListView::Live);
        client.subscribe(sub).unwrap();
        let summary =
            serde_json::json!({"chatId":"a","origin":"local","lastActivity":2,"state":"closed"});
        let changes = receive_changes(
            &mut client,
            FrameKind::Delta,
            serde_json::json!({
                "sid":"plain","ops":[{"op":"summary","seq":2,"summary":summary}]
            }),
        );
        assert!(matches!(changes.as_slice(), [Change::Summary { sid, summary: row, .. }]
            if sid == "plain" && row == &summary));
    }

    #[test]
    fn mirror_read_errors_allow_exactly_two_requests_per_window() {
        let mut client = ready_mirror();
        for _ in 0..3 {
            mirror_window(&mut client);
            assert_eq!(take_pages(&mut client).len(), 1);
            mirror_page_error(&mut client);
            assert_eq!(take_pages(&mut client).len(), 1);
            mirror_page_error(&mut client);
            assert!(take_pages(&mut client).is_empty());
            // Ordinary changes are not page progress and cannot restart reads.
            let changes = receive_changes(
                &mut client,
                FrameKind::Delta,
                serde_json::json!({"sid":"m","ops":[]}),
            );
            assert!(changes.is_empty());
            assert!(take_pages(&mut client).is_empty());
        }
    }

    #[test]
    fn mirror_read_success_between_errors_allows_immediate_head_walk() {
        let mut client = ready_mirror();
        mirror_window(&mut client);
        assert_eq!(take_pages(&mut client).len(), 1);
        mirror_page_error(&mut client);
        assert_eq!(take_pages(&mut client).len(), 1);
        let changes = receive_changes(
            &mut client,
            FrameKind::Page,
            serde_json::json!({
                "sid":"m","rows":[],"hasBefore":false,"hasAfter":true,
                "afterKey":{"chatId":"a","origin":"local","lastActivity":1}
            }),
        );
        assert!(changes.is_empty());
        assert_eq!(take_pages(&mut client).len(), 1);
        mirror_page_error(&mut client);
        let retry = take_pages(&mut client);
        assert_eq!(retry.len(), 1);
        assert!(retry.first().unwrap().pointer("/params/after").is_none());
        mirror_page_error(&mut client);
        assert!(take_pages(&mut client).is_empty());
    }

    #[test]
    fn mirror_read_stop_preserves_wanted_until_window_or_want() {
        for next_window in [true, false] {
            let mut client = ready_mirror();
            mirror_window(&mut client);
            assert_eq!(take_pages(&mut client).len(), 1);
            let key =
                ListKey { last_activity: 1, chat_id: "wanted".into(), origin: "local".into() };
            client.want("m", [key]).unwrap();
            assert!(take_pages(&mut client).is_empty());
            mirror_page_error(&mut client);
            assert_eq!(take_pages(&mut client).len(), 1);
            mirror_page_error(&mut client);
            assert!(take_pages(&mut client).is_empty());
            if next_window {
                mirror_window(&mut client);
                assert_eq!(take_pages(&mut client).len(), 1);
                finish_empty_walk(&mut client);
            } else {
                client.want("m", std::iter::empty()).unwrap();
            }
            let wanted = take_pages(&mut client);
            assert_eq!(wanted.len(), 1);
            assert_eq!(
                wanted.first().unwrap().pointer("/params/keys/0/chatId"),
                Some(&Value::String("wanted".into()))
            );
        }
    }

    #[test]
    fn mirror_wanted_error_retries_from_head_then_stops_without_progress() {
        let mut client = ready_mirror();
        mirror_window(&mut client);
        assert_eq!(take_pages(&mut client).len(), 1);
        finish_empty_walk(&mut client);
        let key = ListKey { last_activity: 1, chat_id: "wanted".into(), origin: "local".into() };
        client.want("m", [key]).unwrap();
        assert_eq!(take_pages(&mut client).len(), 1);
        mirror_page_error(&mut client);
        let retry = take_pages(&mut client);
        assert_eq!(retry.len(), 1);
        assert!(retry.first().unwrap().pointer("/params/keys").is_none());
        mirror_page_error(&mut client);
        assert!(take_pages(&mut client).is_empty());
        client.want("m", std::iter::empty()).unwrap();
        let wanted = take_pages(&mut client);
        assert_eq!(wanted.len(), 1);
        assert_eq!(
            wanted.first().unwrap().pointer("/params/keys/0/chatId"),
            Some(&Value::String("wanted".into()))
        );
        // Explicit want permits a read, not a fresh automatic retry allowance.
        mirror_page_error(&mut client);
        assert!(take_pages(&mut client).is_empty());
    }

    fn request_caller_page(client: &mut Client<Value>) {
        let mut page = Page::new("m", "list", wire::PageSide::After, 0);
        page.after = None;
        client.page(page).unwrap();
        assert_eq!(take_pages(client).len(), 1);
    }

    #[test]
    fn caller_page_error_preserves_mirror_retry_allowance() {
        let mut client = ready_mirror();
        mirror_window(&mut client);
        assert_eq!(take_pages(&mut client).len(), 1);
        finish_empty_walk(&mut client);
        request_caller_page(&mut client);
        mirror_page_error(&mut client);
        assert!(take_pages(&mut client).is_empty());

        let key = ListKey { last_activity: 1, chat_id: "wanted".into(), origin: "local".into() };
        client.want("m", [key]).unwrap();
        assert_eq!(take_pages(&mut client).len(), 1);
        mirror_page_error(&mut client);
        let retry = take_pages(&mut client);
        assert_eq!(retry.len(), 1);
        assert!(retry.first().unwrap().pointer("/params/keys").is_none());
        assert!(retry.first().unwrap().pointer("/params/after").is_none());
        mirror_page_error(&mut client);
        assert!(take_pages(&mut client).is_empty());
    }

    #[test]
    fn caller_page_error_releases_deferred_walk_without_resetting_allowance() {
        for prior_errors in 0..=2 {
            let mut client = ready_mirror();
            mirror_window(&mut client);
            assert_eq!(take_pages(&mut client).len(), 1);
            let key =
                ListKey { last_activity: 1, chat_id: "wanted".into(), origin: "local".into() };
            client.want("m", [key]).unwrap();
            assert!(take_pages(&mut client).is_empty());
            for error in 0..prior_errors {
                mirror_page_error(&mut client);
                assert_eq!(take_pages(&mut client).len(), usize::from(error == 0));
            }

            client.disconnected();
            let changes = receive_changes(
                &mut client,
                FrameKind::Hello,
                serde_json::to_value(wire::HelloReply {
                    daemon_id: "d".into(),
                    limits: Limits::default(),
                })
                .unwrap(),
            );
            assert!(changes.is_empty());
            assert!(take_pages(&mut client).is_empty());
            request_caller_page(&mut client);
            let changes = receive_changes(
                &mut client,
                FrameKind::Delta,
                serde_json::json!({"sid":"m","replay":"end","ops":[]}),
            );
            assert!(matches!(changes.as_slice(), [Change::ResumeEnd { .. }]));
            assert!(take_pages(&mut client).is_empty());

            mirror_page_error(&mut client);
            let walk = take_pages(&mut client);
            assert_eq!(walk.len(), usize::from(prior_errors < 2));
            if let Some(page) = walk.first() {
                assert!(page.pointer("/params/keys").is_none());
                assert!(page.pointer("/params/after").is_none());
            }
            for error in prior_errors..2 {
                mirror_page_error(&mut client);
                assert_eq!(take_pages(&mut client).len(), usize::from(error == 0));
            }
            // Stopping clears the deferred walk but preserves wanted keys.
            client.want("m", std::iter::empty()).unwrap();
            let wanted = take_pages(&mut client);
            assert_eq!(wanted.len(), 1);
            assert_eq!(
                wanted.first().unwrap().pointer("/params/keys/0/chatId"),
                Some(&Value::String("wanted".into()))
            );
        }
    }

    #[test]
    fn mirror_request_can_select_v1_rows() {
        let mut client = Client::<Value>::connected_v2();
        let hello = Frame::json(
            FrameKind::Hello,
            &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
        )
        .unwrap()
        .encode();
        client.received(&hello);
        while client.take_send().is_some() {}
        let mut sub = Sub::new("m", "list");
        sub.rows = Some("v1".into());
        client.subscribe_mirror(sub, std::iter::empty(), false).unwrap();
        let request = client.take_send().unwrap();
        let value: Value = Frame::from_encoded(&request).unwrap().decode_json().unwrap();
        assert_eq!(value.pointer("/params/rows"), Some(&Value::String("v1".into())));
    }

    fn ready_mirror() -> Client<Value> {
        let mut client = Client::<Value>::connected_v2();
        let hello = Frame::json(
            FrameKind::Hello,
            &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
        )
        .unwrap()
        .encode();
        client.received(&hello);
        while client.take_send().is_some() {}
        client.subscribe_mirror(Sub::new("m", "list"), std::iter::empty(), false).unwrap();
        let _ = client.take_send();
        client
    }

    #[test]
    fn mirror_walk_delta_touched_row_survives_reconcile() {
        let mut client = ready_mirror();
        let a = serde_json::json!({"chatId":"a","origin":"local","lastActivity":1,"state":"idle"});
        let b = serde_json::json!({"chatId":"b","origin":"local","lastActivity":2,"state":"idle"});
        let a_key = serde_json::json!({"chatId":"a","origin":"local","lastActivity":1});
        let window = Frame::json(
            FrameKind::Window,
            &serde_json::json!({"sid":"m","cursor":1,"rows":[a,b],"hasBefore":false,"hasAfter":false,"edition":1}),
        )
        .unwrap()
        .encode();
        client.received(&window);
        let _ = client.next_change();
        let _ = client.take_send().expect("first walk page");
        let first_page = Frame::json(
            FrameKind::Page,
            &serde_json::json!({"sid":"m","rows":[a],"hasBefore":false,"hasAfter":true,"afterKey":a_key}),
        )
        .unwrap()
        .encode();
        client.received(&first_page);
        let _ = client.next_change();
        let _ = client.take_send().expect("second walk page");
        let moved_b =
            serde_json::json!({"chatId":"b","origin":"local","lastActivity":3,"state":"idle"});
        let delta = Frame::json(
            FrameKind::Delta,
            &serde_json::json!({"sid":"m","ops":[{"op":"summary","seq":2,"summary":moved_b}]}),
        )
        .unwrap()
        .encode();
        client.received(&delta);
        assert!(matches!(client.next_change(), Some(Change::Summary { .. })));
        let second_page = Frame::json(
            FrameKind::Page,
            &serde_json::json!({"sid":"m","rows":[],"hasBefore":false,"hasAfter":false}),
        )
        .unwrap()
        .encode();
        client.received(&second_page);
        assert!(matches!(client.next_change(), Some(Change::Whole { .. })));
        assert!(client.next_change().is_none());
    }

    #[test]
    fn mirror_walk_delta_new_row_is_not_reconciled_away() {
        let mut client = ready_mirror();
        let _window = Frame::json(
            FrameKind::Window,
            &serde_json::json!({"sid":"m","cursor":1,"rows":[],"hasBefore":false,"hasAfter":false,"edition":1}),
        )
        .unwrap()
        .encode();
        client.received(&_window);
        let _ = client.next_change();
        let _ = client.take_send().expect("walk page");
        let new_row =
            serde_json::json!({"chatId":"new","origin":"local","lastActivity":4,"state":"idle"});
        let delta = Frame::json(
            FrameKind::Delta,
            &serde_json::json!({"sid":"m","ops":[{"op":"summary","seq":2,"summary":new_row}]}),
        )
        .unwrap()
        .encode();
        client.received(&delta);
        assert!(matches!(client.next_change(), Some(Change::Summary { .. })));
        let page = Frame::json(
            FrameKind::Page,
            &serde_json::json!({"sid":"m","rows":[],"hasBefore":false,"hasAfter":false}),
        )
        .unwrap()
        .encode();
        client.received(&page);
        assert!(matches!(client.next_change(), Some(Change::Whole { .. })));
        assert!(client.next_change().is_none());
    }

    #[test]
    fn mirror_walk_drops_rows_changed_while_page_was_out() {
        let mut client = ready_mirror();
        let a = serde_json::json!({"chatId":"a","origin":"local","lastActivity":1,"state":"idle"});
        let d = serde_json::json!({"chatId":"d","origin":"local","lastActivity":1,"state":"idle"});
        let window = Frame::json(
            FrameKind::Window,
            &serde_json::json!({"sid":"m","cursor":1,"rows":[a,d],"hasBefore":false,"hasAfter":false,"edition":1}),
        )
        .unwrap()
        .encode();
        client.received(&window);
        let _ = client.next_change();
        let _ = client.take_send().expect("walk page");
        let newer_a =
            serde_json::json!({"chatId":"a","origin":"local","lastActivity":2,"state":"idle"});
        let delta = Frame::json(
            FrameKind::Delta,
            &serde_json::json!({"sid":"m","ops":[
                {"op":"summary","seq":2,"summary":newer_a},
                {"op":"gone","seq":3,"origin":"local","chatId":"d"}
            ]}),
        )
        .unwrap()
        .encode();
        client.received(&delta);
        assert!(matches!(client.next_change(), Some(Change::Summary { .. })));
        assert!(
            matches!(client.next_change(), Some(Change::Gone { chat_id, .. }) if chat_id == "d")
        );
        let page = Frame::json(
            FrameKind::Page,
            &serde_json::json!({"sid":"m","rows":[a,d],"hasBefore":false,"hasAfter":false}),
        )
        .unwrap()
        .encode();
        client.received(&page);
        assert!(matches!(client.next_change(), Some(Change::Whole { .. })));
        assert!(
            !client.subscriptions["m"]
                .mirror
                .as_ref()
                .unwrap()
                .held
                .contains_key(&("local".into(), "d".into()))
        );
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
        while client.take_send().is_some() {}
        client.subscribe_mirror(Sub::new("m", "list"), std::iter::empty(), true).unwrap();
        let _ = client.take_send();
        let key1 = ListKey { last_activity: 1, chat_id: "a".into(), origin: "local".into() };
        let key2 = ListKey { last_activity: 2, chat_id: "b".into(), origin: "local".into() };
        client.want("m", [key1, key2.clone()]).unwrap();
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
    fn wanted_page_error_requeues_its_keys() {
        let mut client = Client::<Value>::connected_v2();
        let hello = Frame::json(
            FrameKind::Hello,
            &wire::HelloReply { daemon_id: "d".into(), limits: Limits::default() },
        )
        .unwrap()
        .encode();
        client.received(&hello);
        while client.take_send().is_some() {}
        client.subscribe_mirror(Sub::new("m", "list"), std::iter::empty(), true).unwrap();
        let _ = client.take_send();
        let key = ListKey { last_activity: 1, chat_id: "a".into(), origin: "local".into() };
        client.want("m", [key]).unwrap();
        let _ = client.take_send().expect("wanted page");
        let error = Frame::json(
            FrameKind::Error,
            &serde_json::json!({"method":"page","sid":"m","code":"request_failed"}),
        )
        .unwrap()
        .encode();
        client.received(&error);
        assert!(matches!(client.next_change(), Some(Change::Error { .. })));
        let retry = client.take_send().expect("retry walks from the head");
        let value: Value = Frame::from_encoded(&retry).unwrap().decode_json().unwrap();
        assert!(value.pointer("/params/keys").is_none());
        finish_empty_walk(&mut client);
        let wanted = take_pages(&mut client);
        assert_eq!(wanted.len(), 1);
        assert_eq!(
            wanted.first().unwrap().pointer("/params/keys/0/chatId"),
            Some(&Value::String("a".into()))
        );
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
