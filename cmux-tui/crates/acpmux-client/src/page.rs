//! The chat page's bounded session-list driver.
//!
//! This is the one place where a page host turns an [`acpmux-client`](crate) handle into page
//! events. TypeScript and Swift receive v1-shaped rows and an opaque question id; they never see
//! the list cursor, edition, credit, or continuation token. A batch is held until [`ListDriver::taken`]
//! acknowledges it, so the daemon's byte credit reaches the page end to end.

use crate::wire::{Anchor, ListFilter, ListKey, ListView, Page, Position, Stream, Sub};
use crate::{Change, Client, QueuedChange};
use acpmux_list_types::{FolderKey, RowKey};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet, VecDeque};

/// The page-host batch limit. A single change larger than this is allowed to travel alone so it
/// cannot be split in the middle of a row.
pub const MAX_BATCH_BYTES: usize = 64 * 1024;
/// Maximum encoded page reply, including its event envelope.
pub const MAX_REPLY_BYTES: usize = 256 * 1024;
/// Maximum wanted keys, including parent keys added by the v1 projection.
pub const MAX_WANTED_KEYS: usize = 4_096;
/// Maximum active page questions on one list handle.
pub const MAX_QUESTIONS: usize = 16;
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

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DriverError {
    Invalid(String),
    Busy,
    Limit(&'static str),
    MissingQuestion,
}

fn error_code(error: &DriverError) -> String {
    match error {
        DriverError::Invalid(code) => code.clone(),
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
        has_before: bool,
        has_after: bool,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        complete: bool,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Direction {
    Before,
    After,
}

#[derive(Clone, Debug)]
struct Question {
    sid: String,
    request: crate::wire::Page,
    direction: Direction,
    in_flight: bool,
    complete: bool,
    failed: bool,
    created: u64,
}

#[derive(Clone, Debug)]
struct Head {
    slot: String,
    before_key: Option<ListKey>,
    edition: u32,
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
    deferred: VecDeque<QueuedChange<Value>>,
    latest: HashMap<RowRef, u64>,
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
                self.synthetic.push_back(ListEvent::Error {
                    sid: Some(question.sid.clone()),
                    id: Some(id.clone()),
                    code: "list.lost".into(),
                });
            }
        }
        self.synthetic.extend(
            self.slots
                .keys()
                .map(|sid| ListEvent::Off { sid: Some(sid.clone()), code: "lost".into() }),
        );
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
        if !crate::wire::identifier_fits(&request.sid) {
            return Err(DriverError::Invalid("sid is too long".into()));
        }
        if matches!(request.view, ListView::Folders) {
            return Err(DriverError::Invalid("list.unsupported".into()));
        }
        let sid = request.sid;
        let slot: String = match request.view {
            ListView::Live => "live",
            ListView::All => "all",
            ListView::Folders => return Err(DriverError::Invalid("list.unsupported".into())),
        }
        .into();
        let sub = Sub::new(sid.clone(), Stream::new("list")).around(Anchor::End, HEAD_WINDOW);
        let mut sub = sub;
        sub.view = Some(request.view);
        sub.rows = Some("v1".into());
        let mirror = matches!(sub.view, Some(crate::wire::ListView::Live));
        let result = if mirror {
            self.client.subscribe_mirror(sub, [], false)
        } else {
            self.client.subscribe(sub)
        };
        result.map_err(|error| DriverError::Invalid(error.to_string()))?;
        self.slots.insert(sid.clone(), slot.clone());
        self.heads.insert(sid.clone(), Head { slot, before_key: None, edition: 0 });
        Ok(sid)
    }

    pub fn close(&mut self, sid: &str) -> Result<(), DriverError> {
        self.slots.remove(sid);
        self.heads.remove(sid);
        if let Some(old) = self.members.remove(sid) {
            for key in old {
                if !self.members.values().any(|members| members.contains(&key)) {
                    self.latest.remove(&key);
                }
            }
        }
        self.questions.retain(|_, question| question.sid != sid);
        self.client.unsubscribe(sid).map_err(|error| DriverError::Invalid(error.to_string()))
    }

    pub fn want(
        &mut self,
        sid: &str,
        keys: impl IntoIterator<Item = crate::wire::ListKey>,
    ) -> Result<(), DriverError> {
        let keys: Vec<_> = keys.into_iter().collect();
        if keys.len() > MAX_WANTED_KEYS {
            return Err(DriverError::Limit("list.wants"));
        }
        self.client.want(sid, keys).map_err(|error| match error {
            crate::wire::FrameError::InvalidLength(_) => DriverError::Limit("list.wants"),
            other => DriverError::Invalid(other.to_string()),
        })
    }

    pub fn unwant(
        &mut self,
        sid: &str,
        keys: impl IntoIterator<Item = crate::wire::ListKey>,
    ) -> Result<(), DriverError> {
        self.client.unwant(sid, keys).map_err(|error| DriverError::Invalid(error.to_string()))
    }

    /// Starts one bounded question. The returned id is opaque and is safe to expose to a page.
    pub fn page(&mut self, request: PageRequest) -> Result<String, DriverError> {
        if self.questions.values().filter(|question| !question.complete && !question.failed).count()
            >= MAX_QUESTIONS
        {
            return Err(DriverError::Limit("list.busy"));
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
                return Err(DriverError::Limit("list.busy"));
            }
        }
        if !self.slots.contains_key(&request.sid) {
            return Err(DriverError::Invalid("list.sid".into()));
        }
        if self.questions.values().any(|question| question.sid == request.sid && question.in_flight)
        {
            return Err(DriverError::Busy);
        }
        let direction = Direction::Before;
        let sid = request.sid.clone();
        let (before, filter) = match request.kind {
            PageKind::Older => {
                let key = self
                    .heads
                    .get(&sid)
                    .and_then(|head| head.before_key.clone())
                    .ok_or_else(|| DriverError::Invalid("list.page".into()))?;
                (Some(Position::List(key)), None)
            }
            PageKind::Family => {
                let key = request.key.ok_or_else(|| DriverError::Invalid("list.request".into()))?;
                (None, Some(ListFilter::family(RowKey::new(key.origin, key.chat_id))))
            }
            PageKind::Forks => {
                let key = request.key.ok_or_else(|| DriverError::Invalid("list.request".into()))?;
                (None, Some(ListFilter::forks(RowKey::new(key.origin, key.chat_id))))
            }
            PageKind::Folder => {
                let folder =
                    request.folder.ok_or_else(|| DriverError::Invalid("list.request".into()))?;
                let origin = request.key.map(|key| key.origin).unwrap_or_else(|| "local".into());
                (None, Some(ListFilter::folder(FolderKey::new(origin, folder))))
            }
        };
        let head =
            self.heads.get(&sid).cloned().ok_or_else(|| DriverError::Invalid("list.sid".into()))?;
        let wire = Page {
            sid: sid.clone(),
            stream: Stream::new("list"),
            before,
            after: None,
            keys: None,
            view: Some(if matches!(request.kind, PageKind::Folder) {
                ListView::All
            } else {
                ListView::All
            }),
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
        self.client.page(wire.clone()).map_err(|error| DriverError::Invalid(error.to_string()))?;
        self.questions.insert(
            id.clone(),
            Question {
                sid,
                request: wire,
                direction,
                in_flight: true,
                complete: false,
                failed: false,
                created,
            },
        );
        Ok(id)
    }

    /// Requests the next page for a question, using the continuation held in Rust from its last
    /// result. No cursor or key is returned to the page.
    pub fn next(&mut self, sid: &str, id: &str) -> Result<(), DriverError> {
        let request = {
            let question = self.questions.get(id).ok_or(DriverError::MissingQuestion)?;
            if question.sid != sid {
                return Err(DriverError::Invalid("list.sid".into()));
            }
            if question.complete || question.failed || question.in_flight {
                return Err(DriverError::Busy);
            }
            question.request.clone()
        };
        self.client.page(request).map_err(|error| DriverError::Invalid(error.to_string()))?;
        let question = self.questions.get_mut(id).ok_or(DriverError::MissingQuestion)?;
        if question.complete || question.in_flight {
            return Err(DriverError::Busy);
        }
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
        while let Some(change) =
            self.deferred.pop_front().or_else(|| self.client.next_change_uncredited())
        {
            let event = match self.project(change.change.clone()) {
                Ok(Some(event)) => event,
                Ok(None) => {
                    self.client.acknowledge_change(&change);
                    continue;
                }
                Err(error) => {
                    self.client.acknowledge_change(&change);
                    self.synthetic.push_back(ListEvent::Error {
                        sid: None,
                        id: None,
                        code: error_code(&error).into(),
                    });
                    break;
                }
            };
            let event_bytes = serde_json::to_vec(&event)
                .map_err(|error| DriverError::Invalid(error.to_string()))?;
            if event_bytes.len() > MAX_REPLY_BYTES {
                self.client.acknowledge_change(&change);
                return Err(DriverError::Limit("list.reply"));
            }
            if !events.is_empty() && bytes.saturating_add(event_bytes.len()) > MAX_BATCH_BYTES {
                self.deferred.push_front(change);
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
            if let Some(event) = self.synthetic.pop_front() {
                let batch = ListBatch { number: self.next_batch, events: vec![event] };
                self.next_batch = self.next_batch.saturating_add(1);
                self.held = Some(HeldBatch { number: batch.number, changes: Vec::new() });
                return Ok(Some(batch));
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
            return Err(DriverError::Invalid("list.taken".into()));
        }
        for change in &held.changes {
            self.client.acknowledge_change(change);
        }
        Ok(())
    }

    fn project(&mut self, change: Change<Value>) -> Result<Option<ListEvent>, DriverError> {
        let event = match change {
            Change::Window(window) => {
                if window.rows.len() > MAX_ROWS {
                    return Err(DriverError::Limit("list.rows"));
                }
                let sid = window.sid.clone();
                let slot = self.slots.get(&sid).cloned().unwrap_or_else(|| "all".into());
                let mut remove = Vec::new();
                if let Some(old) = self.members.remove(&sid) {
                    for key in old {
                        if !self.members.values().any(|members| members.contains(&key)) {
                            self.latest.remove(&key);
                        }
                        remove.push(key);
                    }
                }
                let members = self.members.entry(sid.clone()).or_default();
                for row in &window.rows {
                    if let Some(key) = row_ref(row) {
                        members.insert(key);
                    }
                }
                if let Some(head) = self.heads.get_mut(&sid) {
                    head.before_key = window.before_key.clone();
                    head.edition = window.edition;
                }
                ListEvent::Rows {
                    sid,
                    slot,
                    upserts: window.rows,
                    remove,
                    complete: !window.has_before && !window.has_after,
                }
            }
            Change::Page(page) => {
                if page.rows.len() > MAX_ROWS {
                    return Err(DriverError::Limit("list.rows"));
                }
                let Some((id, question)) = self
                    .questions
                    .iter_mut()
                    .find(|(_, question)| question.sid == page.sid && question.in_flight)
                else {
                    return Ok(None);
                };
                question.in_flight = false;
                let continuation = match question.direction {
                    Direction::Before => page.before_key.clone().map(|key| crate::wire::Page {
                        sid: page.sid.clone(),
                        stream: question.request.stream.clone(),
                        before: Some(crate::wire::Position::List(key)),
                        after: None,
                        keys: None,
                        view: question.request.view,
                        max_bytes: question.request.max_bytes,
                        filter: question.request.filter.clone(),
                        edition: None,
                        fold: None,
                        turns: false,
                    }),
                    Direction::After => page.after_key.clone().map(|key| crate::wire::Page {
                        sid: page.sid.clone(),
                        stream: question.request.stream.clone(),
                        before: None,
                        after: Some(crate::wire::Position::List(key)),
                        keys: None,
                        view: question.request.view,
                        max_bytes: question.request.max_bytes,
                        filter: question.request.filter.clone(),
                        edition: None,
                        fold: None,
                        turns: false,
                    }),
                };
                question.complete = !page.has_before && !page.has_after;
                question.failed = false;
                if let Some(next) = continuation {
                    question.request = next;
                }
                ListEvent::Page {
                    sid: page.sid,
                    id: id.clone(),
                    rows: page.rows,
                    has_before: page.has_before,
                    has_after: page.has_after,
                    complete: question.complete,
                    cold_unread: page.cold_unread,
                    deeper: page.deeper.into_iter().map(row_ref_key).collect(),
                    missing: page.missing.into_iter().map(row_ref_key).collect(),
                    unknown: page.unknown.into_iter().map(row_ref_key).collect(),
                }
            }
            Change::Summary { sid, seq, summary, .. } => {
                return Ok(self.row_change(sid, seq, summary, false));
            }
            Change::Left { sid, seq, summary, .. } => {
                return Ok(self.row_change(sid, seq, summary, true));
            }
            Change::Gone { sid, origin, chat_id, .. } => {
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
            Change::Origin { sid, origin, .. } => ListEvent::Origin {
                sid,
                origin: origin.id,
                state: format!("{:?}", origin.state).to_lowercase(),
            },
            Change::Whole { sid, .. } => ListEvent::Rows {
                sid,
                slot: self
                    .heads
                    .get(&sid)
                    .map(|head| head.slot.clone())
                    .unwrap_or_else(|| "all".into()),
                upserts: Vec::new(),
                remove: Vec::new(),
                complete: false,
            },
            Change::Fallback(_) => ListEvent::Off { sid: None, code: "unsupported".into() },
            Change::Error { method, sid, code, .. } if method == "sub" && code == "surface_off" => {
                ListEvent::Off { sid, code: "unsupported".into() }
            }
            Change::Error { sid, id, code, .. } => {
                if let Some(id) = id.as_ref() {
                    if let Some(question) = self.questions.get_mut(id) {
                        question.in_flight = false;
                        question.failed = true;
                    }
                }
                ListEvent::Error { sid, id, code }
            }
            Change::ResumeEnd { sid, .. } => {
                if self.resuming.remove(&sid) {
                    ListEvent::Origin { sid, origin: "local".into(), state: "on".into() }
                } else {
                    return Ok(None);
                }
            }
            Change::Dropped { .. }
            | Change::Unconfirmed { .. }
            | Change::Queue { .. }
            | Change::Folder { .. }
            | Change::FolderGone { .. }
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
        let row = row_ref(&summary);
        if let Some(row) = row.as_ref() {
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
            }
        }
        Some(ListEvent::Rows {
            sid,
            slot: "live".into(),
            upserts: (!remove).then_some(vec![summary]).unwrap_or_default(),
            remove: remove.then_some(row.into_iter().collect()).unwrap_or_default(),
            complete: false,
        })
    }

    fn remove_member(&mut self, sid: &str, key: &RowRef) {
        let empty = self.members.get_mut(sid).map(|members| {
            members.remove(key);
            members.is_empty()
        });
        if empty == Some(true) {
            self.members.remove(sid);
        }
        if !self.members.values().any(|members| members.contains(key)) {
            self.latest.remove(key);
        }
    }
}

fn row_ref(value: &Value) -> Option<RowRef> {
    Some(RowRef {
        origin: value.get("origin").and_then(Value::as_str).unwrap_or("local").into(),
        chat_id: value.get("chatId").or_else(|| value.get("sessionId"))?.as_str()?.into(),
    })
}

fn row_ref_key(key: crate::wire::ListKey) -> RowRef {
    RowRef { origin: key.origin, chat_id: key.chat_id }
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
                    before_key: Some(crate::wire::ListKey {
                        last_activity: index as u64,
                        chat_id: index.to_string(),
                        origin: "local".into(),
                        past: false,
                    }),
                    edition: 0,
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
            sid: "s-overflow".into(),
            kind: PageKind::Older,
            key: None,
            folder: None,
            cold: false,
        };
        assert_eq!(driver.page(request), Err(DriverError::Limit("list.busy")));
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
        driver.heads.insert("s".into(), Head { slot: "all".into(), before_key: None, edition: 0 });
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
        assert!(matches!(event, ListEvent::Rows { complete: false, slot, .. } if slot == "all"));
        let whole = driver
            .project(Change::Whole { sid: "s".into(), cursor: crate::wire::Cursor(2) })
            .unwrap()
            .unwrap();
        assert!(matches!(whole, ListEvent::Rows { complete: false, slot, .. } if slot == "all"));
        let json = serde_json::to_string(&event).unwrap();
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
                request: Page::new("s", "list", crate::wire::PageSide::Before, 1),
                direction: Direction::Before,
                in_flight: true,
                complete: false,
                failed: false,
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
}
