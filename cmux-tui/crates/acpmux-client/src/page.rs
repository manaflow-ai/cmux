//! The chat page's bounded session-list driver.
//!
//! This is the one place where a page host turns an [`acpmux-client`](crate) handle into page
//! events. TypeScript and Swift receive v1-shaped rows and an opaque question id; they never see
//! the list cursor, edition, credit, or continuation token. A batch is held until [`ListDriver::taken`]
//! acknowledges it, so the daemon's byte credit reaches the page end to end.

use crate::wire::{
    Anchor, FrameError, ListFilter, ListKey, ListView, Page, Position, Stream, Sub, identifier_fits,
};
use crate::{Change, Client, QueuedChange};
use acpmux_list_types::{FolderKey, RowKey};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::cmp::Reverse;
use std::collections::{HashMap, HashSet, VecDeque};

/// The page-host batch limit. A single change larger than this is allowed to travel alone so it
/// cannot be split in the middle of a row.
pub const MAX_BATCH_BYTES: usize = 64 * 1024;
/// Maximum encoded page reply, including its event envelope.
pub const MAX_REPLY_BYTES: usize = 256 * 1024;
/// Maximum wanted keys, including parent keys added by the v1 projection.
pub const MAX_WANTED_KEYS: usize = 4_096;
/// Maximum encoded page-driver request accepted at the ABI door.
pub const MAX_REQUEST_BYTES: usize = 1 << 20;
/// Maximum active page questions on one list handle.
pub const MAX_QUESTIONS: usize = 16;
/// Maximum open list subscriptions on one driver.
pub const MAX_SIDS: usize = 16;
/// Maximum rows in a head or question slot.
pub const MAX_ROWS: usize = 200;
pub const HEAD_WINDOW: u16 = 20;

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OpenRequest {
    pub sid: String,
    pub view: ListView,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PageRequest {
    pub sid: String,
    pub kind: PageKind,
    #[serde(default)]
    pub key: Option<ListKey>,
    #[serde(default)]
    pub folder: Option<String>,
    #[serde(default)]
    pub cold: bool,
}

#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PageKind {
    Older,
    Family,
    Forks,
    Folder,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NextRequest {
    pub sid: String,
    pub id: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CloseRequest {
    pub sid: String,
    #[serde(default)]
    pub id: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DriverError {
    Invalid(InvalidCode),
    Busy,
    Limit(&'static str),
    MissingQuestion,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum InvalidCode {
    Sid,
    Request,
    Page,
    Unsupported,
    Protocol(String),
}

impl InvalidCode {
    pub fn text(&self) -> String {
        match self {
            Self::Sid => "list.sid".into(),
            Self::Request => "list.request".into(),
            Self::Page => "list.page".into(),
            Self::Unsupported => "list.unsupported".into(),
            Self::Protocol(_) => "list.protocol".into(),
        }
    }
}

pub fn error_code(error: &DriverError) -> String {
    match error {
        DriverError::Invalid(code) => code.text(),
        DriverError::Busy => "list.busy".into(),
        DriverError::Limit(code) => (*code).into(),
        DriverError::MissingQuestion => "list.question".into(),
    }
}

/// The page-facing event. The fields deliberately contain no protocol cursor, edition, or
/// continuation value. `complete` is true only after a walk has no next page.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum ListEvent {
    Rows {
        sid: String,
        slot: String,
        upserts: Vec<Value>,
        remove: Vec<RowRef>,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        complete: bool,
    },
    Page {
        sid: String,
        id: String,
        rows: Vec<Value>,
        #[serde(rename = "hasBefore")]
        has_before: bool,
        #[serde(rename = "hasAfter")]
        has_after: bool,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        complete: bool,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        #[serde(rename = "coldUnread")]
        cold_unread: bool,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        deeper: Vec<RowRef>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        missing: Vec<RowRef>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        unknown: Vec<RowRef>,
    },
    Origin {
        sid: String,
        origin: String,
        state: String,
    },
    On {
        sid: String,
    },
    Off {
        sid: Option<String>,
        code: String,
    },
    Error {
        sid: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        id: Option<String>,
        code: String,
    },
}

#[derive(Clone, Debug, Eq, Hash, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RowRef {
    pub origin: String,
    pub chat_id: String,
}

/// An event batch. The number is opaque to the page and is echoed to [`ListDriver::taken`].
#[derive(Clone, Debug, PartialEq)]
pub struct ListBatch {
    pub number: u64,
    pub events: Vec<ListEvent>,
}

impl ListBatch {
    pub fn json(&self) -> Result<Vec<u8>, serde_json::Error> {
        serde_json::to_vec(&json!({"batch": self.number, "changes": &self.events}))
    }
}

#[derive(Clone, Debug)]
struct Question {
    sid: String,
    kind: PageKind,
    request: Page,
    in_flight: bool,
    complete: bool,
    failed: bool,
    rows: usize,
    created: u64,
}

#[derive(Clone, Debug)]
struct Head {
    slot: String,
    before_key: Option<ListKey>,
    edition: u32,
    rows: Vec<RowRef>,
    stopped: bool,
}

struct DeferredChange {
    change: QueuedChange<Value>,
    event: ListEvent,
}

struct HeldBatch {
    number: u64,
    changes: Vec<QueuedChange<Value>>,
}

/// A page host's list handle. It owns one [`Client`] and never shares its queue with a chat
/// handle. All methods are synchronous so a host can serialize them on its utility queue.
pub struct ListDriver {
    client: Client<Value>,
    slots: HashMap<String, String>,
    heads: HashMap<String, Head>,
    questions: HashMap<String, Question>,
    members: HashMap<String, HashSet<RowRef>>,
    deferred: VecDeque<DeferredChange>,
    latest: HashMap<RowRef, u64>,
    row_values: HashMap<RowRef, Value>,
    held: Option<HeldBatch>,
    next_batch: u64,
    next_question: u64,
    visible: bool,
    synthetic: VecDeque<ListEvent>,
    resuming: HashSet<String>,
}

impl Default for ListDriver {
    fn default() -> Self {
        Self::new()
    }
}

impl ListDriver {
    pub fn new() -> Self {
        Self {
            client: Client::new(["list"]),
            slots: HashMap::new(),
            heads: HashMap::new(),
            questions: HashMap::new(),
            members: HashMap::new(),
            deferred: VecDeque::new(),
            latest: HashMap::new(),
            row_values: HashMap::new(),
            held: None,
            next_batch: 1,
            next_question: 1,
            visible: true,
            synthetic: VecDeque::new(),
            resuming: HashSet::new(),
        }
    }

    pub fn with_client(client: Client<Value>) -> Self {
        Self { client, ..Self::new() }
    }

    pub fn client(&self) -> &Client<Value> {
        &self.client
    }

    pub fn client_mut(&mut self) -> &mut Client<Value> {
        &mut self.client
    }

    pub fn connected(&mut self) {
        self.client.connected();
        self.resuming.extend(self.slots.keys().cloned());
    }

    pub fn disconnected(&mut self) {
        // Client::disconnected deliberately retains held rows and wanted keys. A page host may
        // reconnect the same driver without ever showing an empty list.
        self.client.disconnected();
        for (id, question) in self.questions.iter_mut() {
            if question.in_flight {
                question.in_flight = false;
                question.failed = true;
                self.synthetic.push_back(ListEvent::Error {
                    sid: Some(question.sid.clone()),
                    id: Some(id.clone()),
                    code: "list.lost".into(),
                });
            }
        }
        for sid in self.slots.keys() {
            let already_queued = self.synthetic.iter().any(|event| {
                matches!(event, ListEvent::Off { sid: Some(queued), code } if queued == sid && code == "lost")
            });
            if !already_queued {
                self.synthetic
                    .push_back(ListEvent::Off { sid: Some(sid.clone()), code: "lost".into() });
            }
        }
    }

    pub fn is_fallback(&self) -> bool {
        self.client.is_fallback()
    }

    pub fn set_visible(&mut self, visible: bool) {
        self.visible = visible;
    }

    pub fn received(&mut self, bytes: &[u8]) -> usize {
        if self.held.is_some() || !self.visible {
            return 0;
        }
        self.client.received(bytes)
    }

    pub fn take_send(&mut self) -> Option<Vec<u8>> {
        self.client.take_send()
    }

    pub fn open(&mut self, request: OpenRequest) -> Result<String, DriverError> {
        if !identifier_fits(&request.sid) {
            return Err(DriverError::Invalid(InvalidCode::Protocol("sid is too long".into())));
        }
        if matches!(request.view, ListView::Folders) {
            return Err(DriverError::Invalid(InvalidCode::Unsupported));
        }
        let sid = request.sid;
        let slot: String = match request.view {
            ListView::Live => "live",
            ListView::All => "all",
            ListView::Folders => return Err(DriverError::Invalid(InvalidCode::Unsupported)),
        }
        .into();
        if self.slots.len() >= MAX_SIDS {
            return Err(DriverError::Limit("list.sids"));
        }
        let sub = Sub::new(sid.clone(), Stream::new("list")).around(Anchor::End, HEAD_WINDOW);
        let mut sub = sub;
        sub.view = Some(request.view);
        sub.rows = Some("v1".into());
        let mirror = matches!(sub.view, Some(ListView::Live));
        let result = if mirror {
            self.client.subscribe_mirror(sub, [], false)
        } else {
            self.client.subscribe(sub)
        };
        result.map_err(|error| DriverError::Invalid(InvalidCode::Protocol(error.to_string())))?;
        self.slots.insert(sid.clone(), slot.clone());
        self.heads.insert(
            sid.clone(),
            Head { slot, before_key: None, edition: 0, rows: Vec::new(), stopped: false },
        );
        Ok(sid)
    }

    pub fn close(&mut self, sid: &str) -> Result<(), DriverError> {
        self.slots.remove(sid);
        self.heads.remove(sid);
        if let Some(old) = self.members.remove(sid) {
            for key in old {
                if !self.members.values().any(|members| members.contains(&key)) {
                    self.latest.remove(&key);
                    self.row_values.remove(&key);
                }
            }
        }
        self.questions.retain(|_, question| question.sid != sid);
        self.resuming.remove(sid);
        self.client
            .unsubscribe(sid)
            .map_err(|error| DriverError::Invalid(InvalidCode::Protocol(error.to_string())))
    }

    pub fn close_question(&mut self, sid: &str, id: &str) -> Result<(), DriverError> {
        let Some(question) = self.questions.get(id) else {
            return Err(DriverError::MissingQuestion);
        };
        if question.sid != sid {
            return Err(DriverError::Invalid(InvalidCode::Sid));
        }
        self.questions.remove(id);
        Ok(())
    }

    pub fn want(
        &mut self,
        sid: &str,
        keys: impl IntoIterator<Item = ListKey>,
    ) -> Result<(), DriverError> {
        let keys: Vec<_> = keys.into_iter().take(MAX_WANTED_KEYS + 1).collect();
        if keys.len() > MAX_WANTED_KEYS {
            return Err(DriverError::Limit("list.wants"));
        }
        self.client.want(sid, keys).map_err(|error| match error {
            FrameError::InvalidLength(_) => DriverError::Limit("list.wants"),
            other => DriverError::Invalid(InvalidCode::Protocol(other.to_string())),
        })
    }

    pub fn unwant(
        &mut self,
        sid: &str,
        keys: impl IntoIterator<Item = ListKey>,
    ) -> Result<(), DriverError> {
        self.client
            .unwant(sid, keys)
            .map_err(|error| DriverError::Invalid(InvalidCode::Protocol(error.to_string())))
    }

    /// Starts one bounded question. The returned id is opaque and is safe to expose to a page.
    pub fn page(&mut self, request: PageRequest) -> Result<String, DriverError> {
        if !self.slots.contains_key(&request.sid) {
            return Err(DriverError::Invalid(InvalidCode::Sid));
        }
        match request.kind {
            PageKind::Older => {
                if let Some(head) = self.heads.get(&request.sid) {
                    if head.stopped {
                        return Err(DriverError::Limit("list.limit"));
                    }
                    if head.before_key.is_none() {
                        return Err(DriverError::Invalid(InvalidCode::Page));
                    }
                }
            }
            PageKind::Family | PageKind::Forks => {
                if request.key.is_none() {
                    return Err(DriverError::Invalid(InvalidCode::Request));
                }
            }
            PageKind::Folder => {
                if request.folder.is_none() {
                    return Err(DriverError::Invalid(InvalidCode::Request));
                }
            }
        }
        if self.questions.values().filter(|question| !question.complete && !question.failed).count()
            >= MAX_QUESTIONS
        {
            return Err(DriverError::Busy);
        }
        if self.questions.values().any(|question| question.sid == request.sid && question.in_flight)
        {
            return Err(DriverError::Busy);
        }
        if self.questions.len() >= MAX_QUESTIONS {
            if let Some(id) = self
                .questions
                .iter()
                .filter(|(_, q)| q.complete || q.failed)
                .min_by_key(|(_, q)| q.created)
                .map(|(id, _)| id.clone())
            {
                self.questions.remove(&id);
            } else {
                return Err(DriverError::Busy);
            }
        }
        let sid = request.sid.clone();
        let (before, filter) = match request.kind {
            PageKind::Older => {
                let key = self
                    .heads
                    .get(&sid)
                    .and_then(|head| head.before_key.clone())
                    .ok_or(DriverError::Invalid(InvalidCode::Page))?;
                (Some(Position::List(key)), None)
            }
            PageKind::Family => {
                let key = request.key.ok_or(DriverError::Invalid(InvalidCode::Request))?;
                (None, Some(ListFilter::family(RowKey::new(key.origin, key.chat_id))))
            }
            PageKind::Forks => {
                let key = request.key.ok_or(DriverError::Invalid(InvalidCode::Request))?;
                (None, Some(ListFilter::forks(RowKey::new(key.origin, key.chat_id))))
            }
            PageKind::Folder => {
                let folder = request.folder.ok_or(DriverError::Invalid(InvalidCode::Request))?;
                let origin = request.key.map(|key| key.origin).unwrap_or_else(|| "local".into());
                (None, Some(ListFilter::folder(FolderKey::new(origin, folder))))
            }
        };
        let head = self.heads.get(&sid).cloned().ok_or(DriverError::Invalid(InvalidCode::Sid))?;
        let wire = Page {
            sid: sid.clone(),
            stream: Stream::new("list"),
            before,
            after: None,
            keys: None,
            view: Some(ListView::All),
            max_bytes: MAX_REPLY_BYTES as u32,
            filter: filter.map(|mut value| {
                value.cold = request.cold;
                value
            }),
            edition: Some(head.edition),
            fold: None,
            turns: false,
        };
        let created = self.next_question;
        let id = format!("q{created}");
        self.next_question = self.next_question.saturating_add(1);
        self.client
            .page(wire.clone())
            .map_err(|error| DriverError::Invalid(InvalidCode::Protocol(error.to_string())))?;
        self.questions.insert(
            id.clone(),
            Question {
                sid,
                kind: request.kind,
                request: wire,
                in_flight: true,
                complete: false,
                failed: false,
                rows: 0,
                created,
            },
        );
        Ok(id)
    }

    /// Requests the next page for a question, using the continuation held in Rust from its last
    /// result. No cursor or key is returned to the page.
    pub fn next(&mut self, sid: &str, id: &str) -> Result<(), DriverError> {
        if self.questions.values().any(|question| question.sid == sid && question.in_flight) {
            return Err(DriverError::Busy);
        }
        let request = {
            let question = self.questions.get(id).ok_or(DriverError::MissingQuestion)?;
            if question.sid != sid {
                return Err(DriverError::Invalid(InvalidCode::Sid));
            }
            if question.complete || question.failed || question.in_flight {
                return Err(DriverError::Busy);
            }
            if question.rows >= MAX_ROWS {
                return Err(DriverError::Limit("list.limit"));
            }
            question.request.clone()
        };
        self.client
            .page(request)
            .map_err(|error| DriverError::Invalid(InvalidCode::Protocol(error.to_string())))?;
        let question = self.questions.get_mut(id).ok_or(DriverError::MissingQuestion)?;
        question.in_flight = true;
        Ok(())
    }

    /// Forms one host event batch. Calling it again before [`Self::taken`] returns `None`.
    pub fn next_batch(&mut self) -> Result<Option<ListBatch>, DriverError> {
        if !self.visible || self.held.is_some() {
            return Ok(None);
        }
        if self.synthetic.is_empty()
            && !self.client.has_queued_changes()
            && self.deferred.is_empty()
        {
            return Ok(None);
        }
        let mut changes = Vec::new();
        let mut events = Vec::new();
        let mut bytes = 0usize;
        while let Some(event) = self.synthetic.front().cloned() {
            let event_bytes = match serde_json::to_vec(&event) {
                Ok(bytes) => bytes,
                Err(_) => {
                    self.synthetic.pop_front();
                    continue;
                }
            };
            if !events.is_empty() && bytes.saturating_add(event_bytes.len()) > MAX_BATCH_BYTES {
                break;
            }
            self.synthetic.pop_front();
            bytes = bytes.saturating_add(event_bytes.len());
            events.push(event);
            if bytes >= MAX_BATCH_BYTES {
                break;
            }
        }
        while bytes < MAX_BATCH_BYTES {
            let next = if let Some(deferred) = self.deferred.pop_front() {
                Some((deferred.change, deferred.event))
            } else {
                let Some(change) = self.client.next_change_uncredited() else { break };
                match self.project(change.change.clone()) {
                    Ok(Some(event)) => Some((change, event)),
                    Ok(None) => {
                        self.client.acknowledge_change(&change);
                        continue;
                    }
                    Err(error) => {
                        self.client.acknowledge_change(&change);
                        self.synthetic.push_back(ListEvent::Error {
                            sid: change_sid(&change.change),
                            id: None,
                            code: error_code(&error),
                        });
                        continue;
                    }
                }
            };
            let Some((change, event)) = next else { break };
            let event_bytes = match serde_json::to_vec(&event) {
                Ok(bytes) => bytes,
                Err(_) => {
                    self.client.acknowledge_change(&change);
                    self.synthetic.push_back(ListEvent::Error {
                        sid: change_sid(&change.change),
                        id: None,
                        code: "list.protocol".into(),
                    });
                    break;
                }
            };
            if event_bytes.len() > MAX_REPLY_BYTES {
                self.client.acknowledge_change(&change);
                self.synthetic.push_back(ListEvent::Error {
                    sid: change_sid(&change.change),
                    id: None,
                    code: "list.reply".into(),
                });
                break;
            }
            if !events.is_empty() && bytes.saturating_add(event_bytes.len()) > MAX_BATCH_BYTES {
                self.deferred.push_front(DeferredChange { change, event });
                break;
            }
            bytes = bytes.saturating_add(event_bytes.len());
            changes.push(change);
            events.push(event);
            if bytes >= MAX_BATCH_BYTES {
                break;
            }
        }
        if events.is_empty() {
            return Ok(None);
        }
        let batch = ListBatch { number: self.next_batch, events };
        self.next_batch = self.next_batch.saturating_add(1);
        self.held = Some(HeldBatch { number: batch.number, changes });
        Ok(Some(batch))
    }

    /// Acknowledges exactly one batch. Wrong or repeated numbers never release credit.
    pub fn taken(&mut self, number: u64) -> Result<(), DriverError> {
        let Some(held) = self.held.take() else { return Err(DriverError::Busy) };
        if held.number != number {
            self.held = Some(held);
            return Err(DriverError::Invalid(InvalidCode::Protocol("list.taken".into())));
        }
        for change in &held.changes {
            self.client.acknowledge_change(change);
        }
        Ok(())
    }

    fn project(&mut self, change: Change<Value>) -> Result<Option<ListEvent>, DriverError> {
        let event = match change {
            Change::Window(window) => {
                if !self.slots.contains_key(&window.sid) {
                    return Ok(None);
                }
                if window.rows.len() > MAX_ROWS {
                    return Err(DriverError::Limit("list.rows"));
                }
                let sid = window.sid.clone();
                let slot = self.slots.get(&sid).cloned().unwrap_or_else(|| "all".into());
                let mut remove = Vec::new();
                let new_rows: Vec<RowRef> = window.rows.iter().filter_map(row_ref).collect();
                let new_keys: HashSet<RowRef> = new_rows.iter().cloned().collect();
                if let Some(old) = self.members.remove(&sid) {
                    for key in old {
                        if !new_keys.contains(&key) {
                            remove.push(key.clone());
                        }
                        if !new_keys.contains(&key)
                            && !self.members.values().any(|members| members.contains(&key))
                        {
                            self.latest.remove(&key);
                            self.row_values.remove(&key);
                        }
                    }
                }
                let members = self.members.entry(sid.clone()).or_default();
                for row in &window.rows {
                    if let Some(key) = row_ref(row) {
                        members.insert(key.clone());
                        self.row_values.insert(key, row.clone());
                    }
                }
                if let Some(head) = self.heads.get_mut(&sid) {
                    head.before_key = window.before_key.clone();
                    head.edition = window.edition;
                    head.rows = new_rows;
                    head.stopped = false;
                }
                let event_sid = sid.clone();
                let event = ListEvent::Rows {
                    sid,
                    slot,
                    upserts: window.rows,
                    remove,
                    complete: !window.has_before && !window.has_after,
                };
                if self.resuming.remove(&event_sid) {
                    self.synthetic.push_back(ListEvent::On { sid: event_sid });
                }
                event
            }
            Change::Page(page) => {
                let Some((id, question)) = self
                    .questions
                    .iter_mut()
                    .find(|(_, question)| question.sid == page.sid && question.in_flight)
                else {
                    return Ok(None);
                };
                question.in_flight = false;
                let remaining = MAX_ROWS.saturating_sub(question.rows);
                let overflow = page.rows.len() > remaining;
                let rows: Vec<Value> = page.rows.iter().take(remaining).cloned().collect();
                question.rows = question.rows.saturating_add(rows.len());
                let kind = question.kind;
                let continuation = page.before_key.clone().map(|key| Page {
                    sid: page.sid.clone(),
                    stream: question.request.stream.clone(),
                    before: Some(Position::List(key)),
                    after: None,
                    keys: None,
                    view: question.request.view,
                    max_bytes: question.request.max_bytes,
                    filter: question.request.filter.clone(),
                    edition: None,
                    fold: None,
                    turns: false,
                });
                question.complete =
                    !overflow && (!page.has_before || page.before_key.is_none()) && !page.has_after;
                question.failed = false;
                if let Some(next) = continuation {
                    question.request = next;
                }
                let complete = question.complete;
                let page_sid = page.sid.clone();
                let page_event = ListEvent::Page {
                    sid: page.sid,
                    id: id.clone(),
                    rows: if matches!(kind, PageKind::Older) { Vec::new() } else { rows.clone() },
                    has_before: page.has_before,
                    has_after: page.has_after,
                    complete,
                    cold_unread: page.cold_unread,
                    deeper: page.deeper.into_iter().map(row_ref_key).collect(),
                    missing: page.missing.into_iter().map(row_ref_key).collect(),
                    unknown: page.unknown.into_iter().map(row_ref_key).collect(),
                };
                if matches!(kind, PageKind::Older) {
                    let sid = page_sid;
                    let slot = self
                        .heads
                        .get(&sid)
                        .map(|head| head.slot.clone())
                        .unwrap_or_else(|| "all".into());
                    let mut remove = Vec::new();
                    let mut accepted = Vec::new();
                    if let Some(head) = self.heads.get_mut(&sid) {
                        for row in &rows {
                            if let Some(key) = row_ref(row) {
                                self.row_values.insert(key.clone(), row.clone());
                                if !head.rows.contains(&key) {
                                    head.rows.push(key.clone());
                                    self.members.entry(sid.clone()).or_default().insert(key);
                                }
                                accepted.push(row.clone());
                            }
                        }
                        if overflow || head.rows.len() >= MAX_ROWS {
                            head.stopped = true;
                            head.before_key = None;
                        } else {
                            head.before_key = page.before_key;
                        }
                        head.rows.sort_by_key(|key| Reverse(list_key_for(key, &self.row_values)));
                        if head.rows.len() > MAX_ROWS {
                            remove = head.rows.split_off(MAX_ROWS);
                            accepted.retain(|row| {
                                row_ref(row).is_some_and(|key| !remove.contains(&key))
                            });
                        }
                    }
                    for key in &remove {
                        self.remove_member(&sid, key);
                    }
                    self.synthetic.push_back(page_event);
                    ListEvent::Rows { sid, slot, upserts: accepted, remove, complete }
                } else {
                    page_event
                }
            }
            Change::Summary { sid, seq, summary, .. } => {
                return Ok(self.row_change(sid, seq, summary, false));
            }
            Change::Left { sid, seq, summary, .. } => {
                return Ok(self.row_change(sid, seq, summary, true));
            }
            Change::Gone { sid, origin, chat_id, .. } => {
                if !self.slots.contains_key(&sid) {
                    return Ok(None);
                }
                let key = RowRef { origin, chat_id };
                self.remove_member(&sid, &key);
                let slot = self
                    .heads
                    .get(&sid)
                    .map(|head| head.slot.clone())
                    .unwrap_or_else(|| "all".into());
                ListEvent::Rows {
                    sid,
                    slot,
                    upserts: Vec::new(),
                    remove: vec![key],
                    complete: false,
                }
            }
            Change::FolderGone { .. } => return Ok(None),
            Change::Origin { sid, origin, .. } => ListEvent::Origin {
                sid,
                origin: origin.id,
                state: format!("{:?}", origin.state).to_lowercase(),
            },
            Change::Whole { .. } => return Ok(None),
            Change::Fallback(_) => ListEvent::Off { sid: None, code: "unsupported".into() },
            Change::Error { method, sid, code, .. } if method == "sub" && code == "surface_off" => {
                ListEvent::Off { sid, code: "unsupported".into() }
            }
            Change::Error { sid, code, .. } => {
                let question_id = sid.as_ref().and_then(|sid| {
                    self.questions
                        .iter_mut()
                        .find(|(_, question)| question.sid == sid.as_str() && question.in_flight)
                        .map(|(id, question)| {
                            question.in_flight = false;
                            question.failed = true;
                            id.clone()
                        })
                });
                ListEvent::Error { sid, id: question_id, code }
            }
            Change::ResumeEnd { sid, .. } => {
                if self.resuming.remove(&sid) {
                    ListEvent::On { sid }
                } else {
                    return Ok(None);
                }
            }
            Change::Dropped { .. }
            | Change::Unconfirmed { .. }
            | Change::Queue { .. }
            | Change::Folder { .. }
            | Change::FolderWindow(_)
            | Change::FolderPage(_)
            | Change::Chat(_) => return Ok(None),
        };
        Ok(Some(event))
    }

    fn row_change(
        &mut self,
        sid: String,
        seq: u64,
        summary: Value,
        remove: bool,
    ) -> Option<ListEvent> {
        if !self.slots.contains_key(&sid) {
            return None;
        }
        let row = row_ref(&summary);
        if let Some(row) = row.as_ref() {
            self.row_values.insert(row.clone(), summary.clone());
            if remove {
                self.remove_member(&sid, row);
            } else {
                let members = self.members.entry(sid.clone()).or_default();
                let already_held = members.contains(row);
                if already_held && self.latest.get(row).is_some_and(|old| *old >= seq) {
                    return None;
                }
                members.insert(row.clone());
                self.latest.insert(row.clone(), seq);
                let mut rejected = false;
                let trimmed_head = if let Some(head) = self.heads.get_mut(&sid) {
                    let held = head.rows.contains(row);
                    if !held && head.slot != "live" && head.rows.len() >= MAX_ROWS {
                        head.rows.sort_by_key(|key| Reverse(list_key_for(key, &self.row_values)));
                        if head.rows.last().is_some_and(|last| {
                            list_key_for(row, &self.row_values)
                                <= list_key_for(last, &self.row_values)
                        }) {
                            rejected = true;
                        } else {
                            head.rows.push(row.clone());
                        }
                    } else if !held {
                        head.rows.push(row.clone());
                    }
                    if !rejected && head.slot != "live" && head.rows.len() > MAX_ROWS {
                        head.rows.sort_by_key(|key| Reverse(list_key_for(key, &self.row_values)));
                        let trimmed = head.rows.split_off(MAX_ROWS);
                        Some((head.slot.clone(), trimmed))
                    } else {
                        None
                    }
                } else {
                    None
                };
                if rejected {
                    self.remove_member(&sid, row);
                    return None;
                }
                if let Some((slot, trimmed)) = trimmed_head {
                    for key in &trimmed {
                        self.remove_member(sid.as_str(), key);
                    }
                    return Some(ListEvent::Rows {
                        sid,
                        slot,
                        upserts: vec![summary],
                        remove: trimmed,
                        complete: false,
                    });
                }
            }
        }
        let slot =
            self.heads.get(&sid).map(|head| head.slot.clone()).unwrap_or_else(|| "all".into());
        Some(ListEvent::Rows {
            sid,
            slot,
            upserts: if remove { Vec::new() } else { vec![summary] },
            remove: if remove { row.into_iter().collect() } else { Vec::new() },
            complete: false,
        })
    }

    fn remove_member(&mut self, sid: &str, key: &RowRef) {
        if let Some(head) = self.heads.get_mut(sid) {
            head.rows.retain(|held| held != key);
        }
        let empty = self.members.get_mut(sid).map(|members| {
            members.remove(key);
            members.is_empty()
        });
        if empty == Some(true) {
            self.members.remove(sid);
        }
        if !self.members.values().any(|members| members.contains(key)) {
            self.latest.remove(key);
            self.row_values.remove(key);
        }
    }
}

fn row_ref(value: &Value) -> Option<RowRef> {
    Some(RowRef {
        origin: value.get("origin").and_then(Value::as_str).unwrap_or("local").into(),
        chat_id: value.get("chatId").or_else(|| value.get("sessionId"))?.as_str()?.into(),
    })
}

fn row_ref_key(key: ListKey) -> RowRef {
    RowRef { origin: key.origin, chat_id: key.chat_id }
}

fn list_key_for(row: &RowRef, values: &HashMap<RowRef, Value>) -> ListKey {
    let activity = values
        .get(row)
        .and_then(|value| {
            value.get("updatedMs").or_else(|| value.get("lastActivity")).and_then(Value::as_u64)
        })
        .unwrap_or_default();
    ListKey {
        last_activity: activity,
        chat_id: row.chat_id.clone(),
        origin: row.origin.clone(),
        past: false,
    }
}

fn change_sid(change: &Change<Value>) -> Option<String> {
    match change {
        Change::Window(window) => Some(window.sid.clone()),
        Change::Page(page) => Some(page.sid.clone()),
        Change::Summary { sid, .. }
        | Change::Left { sid, .. }
        | Change::Origin { sid, .. }
        | Change::Queue { sid, .. }
        | Change::Folder { sid, .. }
        | Change::FolderGone { sid, .. }
        | Change::ResumeEnd { sid, .. }
        | Change::Unconfirmed { sid }
        | Change::Dropped { sid, .. } => Some(sid.clone()),
        Change::Error { sid, .. } => sid.clone(),
        Change::Gone { sid, .. } => Some(sid.clone()),
        Change::Whole { sid, .. } => Some(sid.clone()),
        Change::Fallback(_) | Change::FolderWindow(_) | Change::FolderPage(_) | Change::Chat(_) => {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn constants_hold_the_page_contract() {
        assert_eq!(MAX_BATCH_BYTES, 64 * 1024);
        assert_eq!(MAX_REPLY_BYTES, 256 * 1024);
        assert_eq!(MAX_WANTED_KEYS, 4096);
        assert_eq!(MAX_QUESTIONS, 16);
        assert_eq!(MAX_ROWS, 200);
    }

    #[test]
    fn page_ids_are_opaque_and_questions_are_bounded() {
        let mut driver = ListDriver::new();
        for index in 0..MAX_QUESTIONS {
            driver.slots.insert(format!("s{index}"), "all".into());
            driver.heads.insert(
                format!("s{index}"),
                Head {
                    slot: "all".into(),
                    before_key: Some(ListKey {
                        last_activity: index as u64,
                        chat_id: index.to_string(),
                        origin: "local".into(),
                        past: false,
                    }),
                    edition: 0,
                    rows: Vec::new(),
                    stopped: false,
                },
            );
        }
        for index in 0..MAX_QUESTIONS {
            let request = PageRequest {
                sid: format!("s{index}"),
                kind: PageKind::Older,
                key: None,
                folder: None,
                cold: false,
            };
            assert!(driver.page(request).is_ok());
        }
        let request = PageRequest {
            sid: "s0".into(),
            kind: PageKind::Older,
            key: None,
            folder: None,
            cold: false,
        };
        assert_eq!(driver.page(request), Err(DriverError::Busy));
    }

    #[test]
    fn wrong_taken_does_not_release_batch() {
        let mut driver = ListDriver::new();
        driver.held = Some(HeldBatch { number: 4, changes: Vec::new() });
        assert!(driver.taken(3).is_err());
        assert!(driver.held.is_some());
        assert!(driver.taken(4).is_ok());
        assert!(driver.held.is_none());
    }

    #[test]
    fn windows_and_whole_report_walk_completion_and_slot_membership() {
        let mut driver = ListDriver::new();
        driver.slots.insert("s".into(), "all".into());
        driver.heads.insert(
            "s".into(),
            Head {
                slot: "all".into(),
                before_key: None,
                edition: 0,
                rows: Vec::new(),
                stopped: false,
            },
        );
        let window = crate::wire::Window {
            sid: "s".into(),
            cursor: 1,
            rows: vec![json!({"chatId":"c","origin":"local"})],
            has_before: true,
            has_after: false,
            edition: 1,
            origins: Vec::new(),
            before_key: None,
            after_key: None,
        };
        let event = driver.project(Change::Window(window)).unwrap().unwrap();
        assert!(matches!(&event, ListEvent::Rows { complete: false, slot, .. } if slot == "all"));
        let whole = driver
            .project(Change::Whole { sid: "s".into(), cursor: crate::wire::Cursor(2) })
            .unwrap();
        assert!(whole.is_none());
        let json = serde_json::to_string(&ListEvent::Page {
            sid: "s".into(),
            id: "q".into(),
            rows: Vec::new(),
            has_before: true,
            has_after: false,
            complete: false,
            cold_unread: false,
            deeper: Vec::new(),
            missing: Vec::new(),
            unknown: Vec::new(),
        })
        .unwrap();
        assert!(json.contains("hasBefore"));
        assert!(!json.contains("has_before"));
    }

    #[test]
    fn question_error_stops_in_flight_question_and_allows_a_new_slot() {
        let mut driver = ListDriver::new();
        driver.questions.insert(
            "q".into(),
            Question {
                sid: "s".into(),
                kind: PageKind::Family,
                request: Page::new("s", "list", crate::wire::PageSide::Before, 1),
                in_flight: true,
                complete: false,
                failed: false,
                rows: 0,
                created: 1,
            },
        );
        let event = driver
            .project(Change::Error {
                method: "page".into(),
                sid: Some("s".into()),
                id: Some("q".into()),
                code: "list.lost".into(),
            })
            .unwrap()
            .unwrap();
        assert!(matches!(event, ListEvent::Error { id: Some(id), .. } if id == "q"));
        assert!(!driver.questions["q"].in_flight);
        assert!(driver.questions["q"].failed);
    }

    #[test]
    fn reconnect_on_is_emitted_after_window_or_resume_end() {
        let mut driver = ListDriver::new();
        driver.slots.insert("s".into(), "all".into());
        driver.heads.insert(
            "s".into(),
            Head {
                slot: "all".into(),
                before_key: None,
                edition: 0,
                rows: Vec::new(),
                stopped: false,
            },
        );
        driver.resuming.insert("s".into());
        let window = crate::wire::Window {
            sid: "s".into(),
            cursor: 1,
            rows: Vec::new(),
            has_before: false,
            has_after: false,
            edition: 1,
            origins: Vec::new(),
            before_key: None,
            after_key: None,
        };
        assert!(matches!(driver.project(Change::Window(window)), Ok(Some(ListEvent::Rows { .. }))));
        assert!(matches!(driver.synthetic.pop_front(), Some(ListEvent::On { sid }) if sid == "s"));

        driver.resuming.insert("s".into());
        assert!(matches!(
            driver.project(Change::ResumeEnd { sid: "s".into(), cursor: crate::wire::Cursor(2) }),
            Ok(Some(ListEvent::On { sid })) if sid == "s"
        ));
    }

    #[test]
    fn deferred_events_cross_batch_without_reprojection() {
        let mut driver = ListDriver::new();
        let row = |chat_id: &str| ListEvent::Rows {
            sid: "s".into(),
            slot: "all".into(),
            upserts: vec![json!({"chatId": chat_id, "body": "x".repeat(40_000)})],
            remove: Vec::new(),
            complete: false,
        };
        for chat_id in ["a", "b"] {
            driver.deferred.push_back(DeferredChange {
                change: QueuedChange {
                    change: Change::Whole { sid: "s".into(), cursor: crate::wire::Cursor(1) },
                    sid: Some("s".into()),
                    bytes: 0,
                    charge: false,
                },
                event: row(chat_id),
            });
        }
        let first = driver.next_batch().unwrap().unwrap();
        assert_eq!(first.events.len(), 1);
        driver.taken(first.number).unwrap();
        let second = driver.next_batch().unwrap().unwrap();
        assert_eq!(second.events.len(), 1);
    }

    #[test]
    fn older_head_stops_at_two_hundred_rows() {
        let mut driver = ListDriver::new();
        driver.slots.insert("s".into(), "all".into());
        driver.heads.insert(
            "s".into(),
            Head {
                slot: "all".into(),
                before_key: Some(ListKey {
                    last_activity: 1,
                    chat_id: "head".into(),
                    origin: "local".into(),
                    past: false,
                }),
                edition: 0,
                rows: Vec::new(),
                stopped: false,
            },
        );
        driver.questions.insert(
            "q".into(),
            Question {
                sid: "s".into(),
                kind: PageKind::Older,
                request: Page::new("s", "list", crate::wire::PageSide::Before, 1),
                in_flight: true,
                complete: false,
                failed: false,
                rows: 0,
                created: 1,
            },
        );
        let rows = (0..200).map(|index| json!({"chatId": format!("c{index}"), "origin": "local", "updatedMs": index})).collect();
        let page = crate::wire::PageResult {
            sid: "s".into(),
            rows,
            has_before: true,
            has_after: false,
            cold_unread: false,
            deeper: Vec::new(),
            before_key: Some(ListKey {
                last_activity: 0,
                chat_id: "older".into(),
                origin: "local".into(),
                past: false,
            }),
            after_key: None,
            missing: Vec::new(),
            unknown: Vec::new(),
            rest: Vec::new(),
        };
        let event = driver.project(Change::Page(page)).unwrap().unwrap();
        assert!(matches!(event, ListEvent::Rows { complete: false, .. }));
        assert!(driver.heads["s"].stopped);
        assert_eq!(
            driver.page(PageRequest {
                sid: "s".into(),
                kind: PageKind::Older,
                key: None,
                folder: None,
                cold: false
            }),
            Err(DriverError::Limit("list.limit"))
        );
    }
}
