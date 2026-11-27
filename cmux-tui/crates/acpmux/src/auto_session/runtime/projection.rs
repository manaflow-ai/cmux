//! The Mac's read of a chat the Cloud runs (`_acpmux/auto_session/transcript`).
//!
//! While another holder runs a chat, this laptop's log of it is frozen: the holder loop renews
//! as standby and forwards prompts, and the Cloud's events reach this laptop only when a
//! handback imports them. So that the pane is not left showing a stale transcript (and, with
//! Keep in Cloud, never catching up), the loop keeps a projection of the Cloud's events for
//! each chat it does not hold, read with the owner's `wait` and paginated `events` routes.
//!
//! A projection is read only. It is never written into the chat's own log, which stays the
//! log a local agent runs from, and nothing in it starts an agent. It is dropped when the chat
//! is held here again: the handback's import is the chat's log from then on.
//!
//! - Events are kept by seq, consecutive, each once: a page that repeats a seq is skipped and a
//!   page that skips one stops at the gap and is read again.
//! - A store whose log is shorter than what is kept, or whose record at the kept end is not the
//!   one kept once the epoch changed, starts the projection again (`resets`).
//! - Only the newest [`KEEP_MAX`] events are kept: the pane reads the rest from the chat's log.
//! - What the reply says of the read (`status`, `lagMs`, `behind`) is what the pane shows as
//!   reconnecting or behind.

mod reader;

use std::collections::{HashMap, VecDeque};
use std::sync::Mutex;

use cmux_auto_session::holder::{Chat, Side, State};
use cmux_auto_session::wire::{EventsPage, SeqRecord, SessionView};
use serde_json::{Value, json};
use tokio::sync::watch;

pub(crate) use reader::Stop;

/// The read's version. A client that names a newer one is refused with the one served, and
/// reads the chat's own log as it would from a daemon that has no such read.
pub(crate) const VERSION: u64 = 1;

/// The most events a projection keeps: the newest.
pub(crate) const KEEP_MAX: usize = 2048;

/// The most events one read answers; `more` says there are others after them.
const REPLY_MAX: usize = 256;

/// How a projection's reads go.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Status {
    /// The first read has not answered yet.
    Connecting,
    /// Every event the store had at its last answer is here.
    Live,
    /// The last read failed; the next one is on its way.
    Reconnecting,
}

impl Status {
    fn as_str(self) -> &'static str {
        match self {
            Status::Connecting => "connecting",
            Status::Live => "live",
            Status::Reconnecting => "reconnecting",
        }
    }
}

/// The Cloud's events of one chat, as far as they were read.
#[derive(Debug)]
pub(crate) struct Buffer {
    /// The epoch of the store's last answer; 0 before one.
    pub epoch: u64,
    /// The kept events: consecutive seqs, ending at `have`.
    events: VecDeque<SeqRecord>,
    /// The newest seq read; the events before `from + 1` are not kept.
    pub have: u64,
    pub from: u64,
    /// The store's last seq at its last answer.
    pub store_last: u64,
    pub status: Status,
    /// When the store last answered (ms).
    pub read_at: u64,
    /// When the projection began (ms).
    pub since: u64,
    /// How many times the store's log was found to be another than the kept one.
    pub resets: u64,
    pub error: Option<String>,
}

/// What to read after the store's answer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Next {
    /// Read the store's record at this seq first: the epoch changed, and the kept end must
    /// still be the store's.
    pub verify: Option<u64>,
}

impl Buffer {
    pub fn new(now: u64) -> Buffer {
        Buffer {
            epoch: 0,
            events: VecDeque::new(),
            have: 0,
            from: 0,
            store_last: 0,
            status: Status::Connecting,
            read_at: 0,
            since: now,
            resets: 0,
            error: None,
        }
    }

    /// Starts over: the kept events are not the store's.
    fn reset(&mut self, store_last: u64) {
        self.events.clear();
        self.resets += 1;
        self.start_at(store_last);
    }

    /// The next read begins near the store's end: only the newest events are kept anyway.
    fn start_at(&mut self, store_last: u64) {
        let from = store_last.saturating_sub(KEEP_MAX as u64);
        self.from = from;
        self.have = from;
    }

    /// The store answered `view`.
    pub fn observe(&mut self, view: &SessionView, now: u64) -> Next {
        let first = self.epoch == 0;
        let epoch_changed = !first && view.epoch != self.epoch;
        self.epoch = view.epoch;
        self.store_last = view.last_seq;
        self.read_at = now;
        self.error = None;
        if first {
            self.start_at(view.last_seq);
            return Next { verify: None };
        }
        if view.last_seq < self.have {
            // The store's log is shorter than the kept one: it is another log.
            self.reset(view.last_seq);
            return Next { verify: None };
        }
        let check = epoch_changed && self.have > self.from;
        Next { verify: check.then_some(self.have) }
    }

    /// The store's record at the kept end, read after an epoch change: another one starts the
    /// projection over.
    pub fn verify(&mut self, page: &EventsPage) {
        let theirs = page.events.iter().find(|event| event.seq == self.have);
        let ours = self.events.back();
        if theirs.map(|event| &event.record) != ours.map(|event| &event.record) {
            self.reset(page.last_seq);
        }
    }

    /// Takes a page of events: each seq once, in order. Answers false at a gap: the rest is
    /// read again from `have`.
    pub fn take(&mut self, page: EventsPage) -> bool {
        self.store_last = self.store_last.max(page.last_seq);
        for event in page.events {
            if event.seq <= self.have {
                continue;
            }
            if event.seq != self.have + 1 {
                return false;
            }
            self.have = event.seq;
            self.events.push_back(event);
        }
        while self.events.len() > KEEP_MAX {
            if let Some(dropped) = self.events.pop_front() {
                self.from = dropped.seq;
            }
        }
        true
    }

    /// Every event the store had is here.
    pub fn caught_up(&self) -> bool {
        self.have >= self.store_last
    }

    /// A read failed.
    pub fn failed(&mut self, error: String) {
        self.status = Status::Reconnecting;
        self.error = Some(error);
    }

    /// The read's answer: the events after `after`, and how the projection stands at `now`.
    pub fn reply(&self, after: u64, now: u64) -> Value {
        let mut events = self.events.iter().filter(|event| event.seq > after);
        let page: Vec<&SeqRecord> = events.by_ref().take(REPLY_MAX).collect();
        let more = events.next().is_some();
        let last_heard = if self.read_at == 0 { self.since } else { self.read_at };
        let lag = match self.status {
            Status::Live => 0,
            Status::Connecting | Status::Reconnecting => now.saturating_sub(last_heard),
        };
        json!({
            "version": VERSION,
            "projection": {
                "source": "cloud",
                "readOnly": true,
                "epoch": self.epoch,
                "from": self.from,
                "lastSeq": self.have,
                "storeLastSeq": self.store_last,
                "behind": self.store_last.saturating_sub(self.have),
                "status": self.status.as_str(),
                "lagMs": lag,
                "resets": self.resets,
                "error": self.error,
            },
            "events": page,
            "more": more,
        })
    }
}

/// One chat's projection: its buffer, and what stops its reader.
struct Projection {
    generation: u64,
    buffer: Buffer,
    /// Dropped with the projection, which ends its reader at its next await.
    _stop: watch::Sender<()>,
}

/// Every projection of a daemon, shared by the holder loop (which starts and drops them) and
/// the daemon's read.
#[derive(Default)]
pub(crate) struct Projections {
    chats: Mutex<HashMap<String, Projection>>,
    generations: std::sync::atomic::AtomicU64,
}

impl Projections {
    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, Projection>> {
        self.chats.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Opens a projection of chat `id` when it has none; answers its generation and its stop.
    pub fn open(&self, id: &str, now: u64) -> Option<(u64, Stop)> {
        let mut chats = self.lock();
        if chats.contains_key(id) {
            return None;
        }
        let generation =
            self.generations.fetch_add(1, std::sync::atomic::Ordering::Relaxed).saturating_add(1);
        let (stop, stopped) = watch::channel(());
        let buffer = Buffer::new(now);
        chats.insert(id.to_owned(), Projection { generation, buffer, _stop: stop });
        Some((generation, Stop(stopped)))
    }

    /// Drops chat `id`'s projection: its reader ends.
    pub fn close(&self, id: &str) {
        self.lock().remove(id);
    }

    /// Changes the buffer of generation `generation` of chat `id`. None: that projection is
    /// gone, and its reader ends.
    pub fn with<T>(
        &self,
        id: &str,
        generation: u64,
        f: impl FnOnce(&mut Buffer) -> T,
    ) -> Option<T> {
        let mut chats = self.lock();
        let projection = chats.get_mut(id).filter(|p| p.generation == generation)?;
        Some(f(&mut projection.buffer))
    }

    /// The daemon's read: None when the chat is held here (or Auto is off for it).
    pub fn reply(&self, id: &str, after: u64, now: u64) -> Option<Value> {
        self.lock().get(id).map(|projection| projection.buffer.reply(after, now))
    }
}

/// The chat runs elsewhere and this laptop keeps its own log frozen: its transcript is the
/// Cloud's. A handback in progress keeps it until the import lands.
pub(super) fn projected(chat: &Chat) -> bool {
    chat.side() == Side::Laptop
        && matches!(chat.state, State::Standby { .. } | State::Away | State::ComingHome { .. })
}

#[cfg(test)]
mod tests;
