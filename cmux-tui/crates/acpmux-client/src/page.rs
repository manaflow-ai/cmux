//! The chat page's bounded session-list driver.
//!
//! This is the one place where a page host turns an [`acpmux-client`](crate) handle into page
//! events. TypeScript and Swift receive v1-shaped rows and an opaque question id; they never see
//! the list cursor, edition, credit, or continuation token. A batch is held until [`ListDriver::taken`]
//! acknowledges it, so the daemon's byte credit reaches the page end to end.

use crate::{Change, Client, QueuedChange};
use serde::Serialize;
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};

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

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DriverError {
    Invalid(String),
    Busy,
    Limit(&'static str),
    MissingQuestion,
}

/// The page-facing event. The fields deliberately contain no protocol cursor, edition, or
/// continuation value. `complete` is true only after a walk has no next page.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
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
    questions: HashMap<String, Question>,
    deferred: VecDeque<QueuedChange<Value>>,
    latest: HashMap<RowRef, u64>,
    held: Option<HeldBatch>,
    next_batch: u64,
    next_question: u64,
    visible: bool,
}

impl ListDriver {
    pub fn new() -> Self {
        Self {
            client: Client::new(["list"]),
            slots: HashMap::new(),
            questions: HashMap::new(),
            deferred: VecDeque::new(),
            latest: HashMap::new(),
            held: None,
            next_batch: 1,
            next_question: 1,
            visible: true,
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
    }

    pub fn disconnected(&mut self) {
        // Client::disconnected deliberately retains held rows and wanted keys. A page host may
        // reconnect the same driver without ever showing an empty list.
        self.client.disconnected();
        self.deferred.clear();
        self.held = None;
        for question in self.questions.values_mut() {
            question.in_flight = false;
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

    pub fn open(&mut self, mut sub: crate::wire::Sub) -> Result<String, DriverError> {
        if !crate::wire::identifier_fits(&sub.sid) {
            return Err(DriverError::Invalid("sid is too long".into()));
        }
        let slot = slot_name(&sub);
        let sid = sub.sid.clone();
        let mirror = matches!(sub.view, Some(crate::wire::ListView::Live));
        let result = if mirror {
            self.client.subscribe_mirror(sub, [], false)
        } else {
            self.client.subscribe(sub)
        };
        result.map_err(|error| DriverError::Invalid(error.to_string()))?;
        self.slots.insert(sid.clone(), slot);
        Ok(sid)
    }

    pub fn close(&mut self, sid: &str) -> Result<(), DriverError> {
        self.slots.remove(sid);
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
    pub fn page(&mut self, mut request: crate::wire::Page) -> Result<String, DriverError> {
        if request.max_bytes as usize > MAX_REPLY_BYTES {
            return Err(DriverError::Limit("list.reply"));
        }
        if self.questions.values().filter(|question| !question.complete).count() >= MAX_QUESTIONS {
            return Err(DriverError::Limit("list.busy"));
        }
        if !self.slots.contains_key(&request.sid) {
            return Err(DriverError::Invalid("list.sid".into()));
        }
        if self.questions.values().any(|question| question.sid == request.sid && question.in_flight)
        {
            return Err(DriverError::Busy);
        }
        let direction = if request.before.is_some() {
            Direction::Before
        } else if request.after.is_some() {
            Direction::After
        } else {
            return Err(DriverError::Invalid("list.page needs before or after".into()));
        };
        let id = format!("q{}", self.next_question);
        self.next_question = self.next_question.saturating_add(1);
        request.max_bytes = request.max_bytes.min(MAX_REPLY_BYTES as u32);
        self.client
            .page(request.clone())
            .map_err(|error| DriverError::Invalid(error.to_string()))?;
        self.questions.insert(
            id.clone(),
            Question {
                sid: request.sid.clone(),
                request,
                direction,
                in_flight: true,
                complete: false,
            },
        );
        Ok(id)
    }

    /// Requests the next page for a question, using the continuation held in Rust from its last
    /// result. No cursor or key is returned to the page.
    pub fn next(&mut self, id: &str) -> Result<(), DriverError> {
        let request = {
            let question = self.questions.get(id).ok_or(DriverError::MissingQuestion)?;
            if question.complete || question.in_flight {
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
        if !self.client.has_queued_changes() && self.deferred.is_empty() {
            return Ok(None);
        }
        let mut changes = Vec::new();
        let mut events = Vec::new();
        let mut bytes = 0usize;
        while let Some(change) =
            self.deferred.pop_front().or_else(|| self.client.next_change_uncredited())
        {
            let Some(event) = self.project(change.change.clone())? else {
                self.client.acknowledge_change(&change);
                continue;
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
                ListEvent::Rows {
                    sid,
                    slot,
                    upserts: window.rows,
                    remove: Vec::new(),
                    complete: !window.has_after,
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
                let has_more = match question.direction {
                    Direction::Before => page.has_before,
                    Direction::After => page.has_after,
                };
                question.complete = !has_more || continuation.is_none();
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
            Change::Gone { sid, origin, chat_id, .. } => ListEvent::Rows {
                sid,
                slot: "live".into(),
                upserts: Vec::new(),
                remove: vec![RowRef { origin, chat_id }],
                complete: false,
            },
            Change::Origin { sid, origin, .. } => ListEvent::Origin {
                sid,
                origin: origin.id,
                state: format!("{:?}", origin.state).to_lowercase(),
            },
            Change::Whole { sid, .. } => ListEvent::Rows {
                sid,
                slot: "live".into(),
                upserts: Vec::new(),
                remove: Vec::new(),
                complete: true,
            },
            Change::Fallback(_) => ListEvent::Off { sid: None, code: "unsupported".into() },
            Change::Error { method, sid, code, .. } if method == "sub" && code == "surface_off" => {
                ListEvent::Off { sid, code: "unsupported".into() }
            }
            Change::Error { sid, code, .. } => ListEvent::Error { sid, code },
            Change::Dropped { .. }
            | Change::ResumeEnd { .. }
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
            if self.latest.get(row).is_some_and(|old| *old >= seq) {
                return None;
            }
            self.latest.insert(row.clone(), seq);
        }
        Some(ListEvent::Rows {
            sid,
            slot: "live".into(),
            upserts: (!remove).then_some(vec![summary]).unwrap_or_default(),
            remove: remove.then_some(row.into_iter().collect()).unwrap_or_default(),
            complete: false,
        })
    }
}

fn slot_name(sub: &crate::wire::Sub) -> String {
    match sub.view {
        Some(crate::wire::ListView::Live) => "live",
        Some(crate::wire::ListView::Folders) => "folders",
        Some(crate::wire::ListView::All) | None => "all",
    }
    .into()
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
    use crate::wire::{Anchor, ListView, Page, Position, Stream, Sub};

    fn sub(sid: &str, view: ListView) -> Sub {
        Sub {
            sid: sid.into(),
            stream: Stream::new("list"),
            cursor: None,
            edition: None,
            anchor: Some(Anchor::End),
            window: Some(20),
            view: Some(view),
            rows: Some("v1".into()),
            filter: None,
        }
    }

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
        }
        for index in 0..MAX_QUESTIONS {
            let request = Page {
                sid: format!("s{index}"),
                stream: Stream::new("list"),
                before: Some(Position::List(crate::wire::ListKey {
                    last_activity: index as u64,
                    chat_id: index.to_string(),
                    origin: "local".into(),
                    past: false,
                })),
                after: None,
                keys: None,
                view: Some(ListView::All),
                max_bytes: MAX_REPLY_BYTES as u32,
                filter: None,
                edition: None,
                fold: None,
                turns: false,
            };
            assert!(driver.page(request).is_ok());
        }
        let request = Page {
            sid: "s-overflow".into(),
            stream: Stream::new("list"),
            before: Some(Position::List(crate::wire::ListKey {
                last_activity: 0,
                chat_id: "overflow".into(),
                origin: "local".into(),
                past: false,
            })),
            after: None,
            keys: None,
            view: Some(ListView::All),
            max_bytes: MAX_REPLY_BYTES as u32,
            filter: None,
            edition: None,
            fold: None,
            turns: false,
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
}
