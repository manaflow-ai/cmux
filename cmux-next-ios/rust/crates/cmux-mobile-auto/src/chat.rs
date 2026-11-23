//! One open Auto chat: its events page by page, the held wait that keeps it current, sending.
//!
//! The phone calls [`ChatSession::next`] again and again (the first call opens the chat, as
//! [`ChatSession::open`] does). Each
//! answers a [`Batch`]: the records to draw and where the chat is now. `next` reads a page when
//! the store has more than the phone, and otherwise holds one `wait` request until the chat
//! changes or the store's deadline passes. Nothing else waits.
//!
//! A send may run while a `next` is held, so the chat's state sits behind a lock that is never
//! held across a request.

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Mutex, MutexGuard, PoisonError};

use cmux_auto_session::cloud::{AutoCloud, CloudResult};
use cmux_auto_session::consts::WAIT_MAX_MS;
use cmux_auto_session::wire::{EventsPage, InboxPost, InboxPosted, SessionView};
use serde::Serialize;
use serde_json::Value;

use crate::backoff::retry_after_ms;
use crate::outbox::Outbox;
use crate::records::transcript_record;
use crate::rows::ChatRow;

/// What one call answers: records to draw, in order, and the chat as it is now.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Batch {
    /// The chat's header: its title, where it is, whether it is kept in the Cloud. None only
    /// before the chat was read once.
    pub chat: Option<ChatRow>,
    /// Transcript records (acpmux's `{sessionId, seq, at, dir, kind, msg}`), oldest first.
    pub records: Vec<Value>,
    /// The phone has every event the store has.
    pub caught_up: bool,
    /// Nothing more will arrive under this chat: Auto was switched off for it, or it was
    /// started over. The caller stops calling `next`.
    pub ended: bool,
    /// The read got no answer. The caller calls `next` again after this many milliseconds.
    pub retry_after_ms: Option<u64>,
}

#[derive(Debug)]
struct State {
    view: SessionView,
    /// The last event the phone has.
    seq: u64,
    /// The last event the store said it has.
    last_seq: u64,
    outbox: Outbox,
    /// Reads in a row that got no answer.
    failures: u32,
    ended: bool,
}

impl State {
    fn new(view: SessionView) -> State {
        State { view, seq: 0, last_seq: 0, outbox: Outbox::default(), failures: 0, ended: false }
    }

    fn batch(&self, records: Vec<Value>) -> Batch {
        Batch {
            chat: Some(ChatRow::of(&self.view, self.outbox.waiting())),
            records,
            caught_up: self.seq >= self.last_seq,
            ended: self.ended,
            retry_after_ms: None,
        }
    }
}

/// What `next` does, decided from what the phone has.
enum Step {
    Open,
    Done,
    Page,
    Wait { version: u64 },
}

/// One open chat over the store `C`.
#[derive(Debug)]
pub struct ChatSession<C> {
    cloud: C,
    id: String,
    state: Mutex<Option<State>>,
    /// Reads in a row that got no answer before the chat was read once.
    unopened: AtomicU32,
}

impl<C: AutoCloud> ChatSession<C> {
    pub fn new(cloud: C, id: impl Into<String>) -> ChatSession<C> {
        ChatSession { cloud, id: id.into(), state: Mutex::new(None), unopened: AtomicU32::new(0) }
    }

    pub fn id(&self) -> &str {
        &self.id
    }

    /// The store this chat reads.
    pub fn cloud(&self) -> &C {
        &self.cloud
    }

    fn lock(&self) -> MutexGuard<'_, Option<State>> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Reads the chat and its first page of events. A chat the store does not have, or one the
    /// person may not read, is the store's error.
    pub async fn open(&self) -> CloudResult<Batch> {
        let view = self.cloud.get(&self.id).await?;
        self.viewed(view);
        self.page().await
    }

    /// The next thing to draw. Behind the store: one more page. Otherwise one held `wait`,
    /// then a page when the chat got new events. A read that got no answer is no error: the
    /// batch says when to call again. An error is the store refusing the chat.
    pub async fn next(&self) -> CloudResult<Batch> {
        let answer = self.step().await;
        let mut guard = self.lock();
        let Some(state) = guard.as_mut() else {
            // The chat was never read: no network is a wait here too, with nothing to draw yet.
            return match answer {
                Err(error) if error.retryable() => {
                    let failures = self.unopened.fetch_add(1, Ordering::SeqCst).saturating_add(1);
                    Ok(Batch {
                        chat: None,
                        records: Vec::new(),
                        caught_up: false,
                        ended: false,
                        retry_after_ms: Some(retry_after_ms(failures)),
                    })
                }
                answer => answer,
            };
        };
        match answer {
            Ok(batch) => {
                state.failures = 0;
                Ok(batch)
            }
            Err(error) if error.retryable() => {
                state.failures = state.failures.saturating_add(1);
                let mut batch = state.batch(Vec::new());
                batch.retry_after_ms = Some(retry_after_ms(state.failures));
                Ok(batch)
            }
            Err(error) => Err(error),
        }
    }

    fn decide(&self) -> Step {
        match self.lock().as_ref() {
            None => Step::Open,
            Some(state) if state.ended => Step::Done,
            Some(state) if state.seq < state.last_seq => Step::Page,
            Some(state) => Step::Wait { version: state.view.version },
        }
    }

    async fn step(&self) -> CloudResult<Batch> {
        match self.decide() {
            Step::Open => self.open().await,
            Step::Done => Ok(self.batch(Vec::new())),
            Step::Page => self.page().await,
            Step::Wait { version } => {
                let view = self.cloud.wait(&self.id, version, WAIT_MAX_MS).await?;
                if self.viewed(view) { self.page().await } else { Ok(self.batch(Vec::new())) }
            }
        }
    }

    /// Sends `text` to the chat under `message_id`. The store takes one id once, so the same
    /// call again after a lost answer is not a second message; a send that got no answer is
    /// tried once more here with the same id. The batch draws the message as waiting.
    pub async fn send(&self, message_id: &str, text: &str) -> CloudResult<Batch> {
        let message = InboxPost { id: message_id.to_owned(), text: text.to_owned() };
        let posted = match self.cloud.post_inbox(&self.id, &message).await {
            Err(error) if error.retryable() => self.cloud.post_inbox(&self.id, &message).await?,
            answer => answer?,
        };
        let record = self.sent(message_id, text, &posted);
        self.viewed(posted.session);
        Ok(self.batch(record.into_iter().collect()))
    }

    /// Keeps the chat in the Cloud when a Mac returns, or stops keeping it.
    pub async fn keep(&self, keep_in_cloud: bool) -> CloudResult<Batch> {
        let view = self.cloud.keep(&self.id, keep_in_cloud).await?;
        self.viewed(view);
        Ok(self.batch(Vec::new()))
    }

    /// One page of the events after the phone's last.
    async fn page(&self) -> CloudResult<Batch> {
        let after = self.lock().as_ref().map_or(0, |state| state.seq);
        let page = self.cloud.events(&self.id, after, None).await?;
        Ok(self.took(&page))
    }

    /// Remembers a message the store took, and answers the record that draws it as waiting.
    fn sent(&self, message_id: &str, text: &str, posted: &InboxPosted) -> Option<Value> {
        let mut guard = self.lock();
        let state = guard.get_or_insert_with(|| State::new(posted.session.clone()));
        state.outbox.posted(&self.id, message_id, text, posted)
    }

    /// Takes the chat as the store answered it. An older answer than the one the phone has
    /// changes nothing. Answers whether the store has events the phone does not.
    fn viewed(&self, view: SessionView) -> bool {
        let mut guard = self.lock();
        let state = guard.get_or_insert_with(|| State::new(view.clone()));
        if view.version >= state.view.version {
            // A chat switched off and on again starts over, empty: this view of it is done.
            state.ended = state.ended || !view.auto || view.last_seq < state.seq;
            state.last_seq = view.last_seq;
            state.outbox.viewed(&view);
            state.view = view;
        }
        !state.ended && state.seq < state.last_seq
    }

    /// Takes one page: its records to draw, and how far the phone is now.
    fn took(&self, page: &EventsPage) -> Batch {
        let mut guard = self.lock();
        let Some(state) = guard.as_mut() else { return self.unread(Vec::new()) };
        let have = state.seq;
        let mut records: Vec<Value> = Vec::new();
        for event in page.events.iter().filter(|event| event.seq > have) {
            if let Some(record) = transcript_record(&self.id, event) {
                records.extend(state.outbox.recorded(&self.id, &record));
                records.push(record);
            }
        }
        state.seq = match page.events.last() {
            Some(last) => have.max(last.seq),
            // The store said it has more and gave none: take its word that this is all.
            None => have.max(state.last_seq.min(page.last_seq)),
        };
        state.last_seq = state.last_seq.max(page.last_seq);
        state.batch(records)
    }

    fn batch(&self, records: Vec<Value>) -> Batch {
        match self.lock().as_ref() {
            Some(state) => state.batch(records),
            None => self.unread(records),
        }
    }

    /// A batch of a chat the phone has not read yet.
    fn unread(&self, records: Vec<Value>) -> Batch {
        Batch { chat: None, records, caught_up: false, ended: false, retry_after_ms: None }
    }
}
