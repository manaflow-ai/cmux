//! The phone's send outbox (design/messaging-grade-send.md, phase 1): what
//! the person sent is acknowledged on the phone at once and reconciled with
//! the Mac later, the way consumer messaging apps show a sent message before
//! the server has it.
//!
//! Every send gets a client id (made on the phone, before anything is
//! written) and a place in its stream (a chat session, a terminal surface).
//! The outbox then answers, without a round trip:
//!
//! - [`Outbox::enqueue`]: the send is [`SendState::Pending`] now, its local
//!   ack; the same id enqueued again is the same send (dedupe), never a
//!   second one;
//! - [`Outbox::take_sendable`]: what to write to the link now, oldest first
//!   in each stream, each at most once per link ([`Outbox::link_up`] starts
//!   a link); written, it is [`SendState::Sent`];
//! - [`Outbox::host_ack`]: the Mac's answer by id: [`SendState::Delivered`],
//!   or [`SendState::Failed`] with its reason;
//! - [`Outbox::link_lost`]: what was written and not answered goes again on
//!   the next link, marked `resend` (the Mac runs an id at most once:
//!   acpmux's `promptId`; for keys, the host's `send_dedupe::SeenIds`);
//! - [`Outbox::expire`]: what waited for a link longer than its kind allows
//!   fails, and with it every later send of its stream, so a stream never
//!   delivers a send after an earlier one failed (a command's tail must not
//!   run alone; termfix-r13 D5: a command typed in an outage ran 15 minutes
//!   later). A send written to a live link never ages: a slow link is not an
//!   outage.
//!
//! Every state change is queued as an [`AckEvent`] ([`Outbox::drain_events`])
//! for the FFI layer to surface. Sends of a [`SendKind`] that
//! [`SendKind::durable`] are kept across an app restart through
//! [`Outbox::snapshot`] and [`Outbox::restore`]; keystrokes never are.
//!
//! Pure: no clock (times are milliseconds of one monotonic clock the caller
//! picks), no I/O, no link. Not wired into the app yet.

use std::collections::{HashMap, VecDeque};

use serde::{Deserialize, Serialize};

/// What a send is: it sets how long it may wait for a link and whether it
/// outlives the app.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SendKind {
    /// Terminal input (`send` on the input lane). Never kept across a
    /// restart: stale keys into whatever runs later are dangerous.
    Keys,
    /// A chat prompt (`session/prompt` with `_meta.acpmux.promptId`).
    Prompt,
}

impl SendKind {
    /// How long a send may wait for a link, in ms, before it fails: the
    /// app's hold today (`DaemonTerminalSession.inputHoldLimit`, the chat's
    /// `heldPromptWindow`, both 10 s).
    pub fn hold_ms(self) -> u64 {
        match self {
            SendKind::Keys => 10_000,
            SendKind::Prompt => 10_000,
        }
    }

    /// Kept across an app restart.
    pub fn durable(self) -> bool {
        matches!(self, SendKind::Prompt)
    }
}

/// Where a send is.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "state", content = "reason")]
pub enum SendState {
    /// Acknowledged on the phone; not written to a link yet (or written to
    /// one that was lost).
    Pending,
    /// Written to the current link; the Mac has not answered.
    Sent,
    /// The Mac has it (ran it, queued it, or had it already).
    Delivered,
    /// It will not be sent: the Mac refused it, or it waited too long.
    Failed(String),
}

impl SendState {
    /// No further change can come.
    pub fn is_final(&self) -> bool {
        matches!(self, SendState::Delivered | SendState::Failed(_))
    }
}

/// One state change, for the UI.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AckEvent {
    pub id: String,
    pub stream: String,
    pub state: SendState,
}

/// One send to write to the link.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Outgoing {
    pub id: String,
    pub stream: String,
    pub kind: SendKind,
    pub payload: Vec<u8>,
    /// It may have reached the Mac on an earlier link: the Mac checks the id.
    pub resend: bool,
}

/// What [`Outbox::enqueue`] answers: the send's local ack.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalAck {
    pub state: SendState,
    /// The id was known already: nothing new was queued.
    pub duplicate: bool,
}

/// The Mac's answer to one send.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostAck {
    Delivered,
    Refused(String),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Item {
    id: String,
    stream: String,
    kind: SendKind,
    payload: Vec<u8>,
    state: SendState,
    /// Written on an earlier link without an answer.
    resend: bool,
    /// The link epoch it was written on (Sent only).
    #[serde(skip)]
    written_on: u64,
    /// When it began to wait for a link (its enqueue, or the loss of the
    /// link it was written on); `None` while written to a live link.
    #[serde(skip)]
    waiting_since: Option<u64>,
}

/// How many settled ids are remembered for dedupe.
pub const SETTLED_MEMORY: usize = 1024;

/// The outbox. See the module docs.
#[derive(Debug, Default)]
pub struct Outbox {
    /// Unsettled sends, oldest first (across streams; each stream's sends
    /// stay in order within it).
    items: VecDeque<Item>,
    /// Settled ids and their final state, oldest first, at most
    /// [`SETTLED_MEMORY`].
    settled: VecDeque<(String, SendState)>,
    settled_index: HashMap<String, SendState>,
    events: Vec<AckEvent>,
    /// The current link's epoch, 0 while no link is up.
    epoch: u64,
    epochs: u64,
}

impl Outbox {
    pub fn new() -> Self {
        Self::default()
    }

    /// Queue a send and acknowledge it locally. An id seen before answers
    /// that send's state and queues nothing.
    pub fn enqueue(
        &mut self,
        id: &str,
        stream: &str,
        kind: SendKind,
        payload: Vec<u8>,
        now_ms: u64,
    ) -> LocalAck {
        if let Some(state) = self.state(id) {
            return LocalAck { state, duplicate: true };
        }
        self.items.push_back(Item {
            id: id.to_owned(),
            stream: stream.to_owned(),
            kind,
            payload,
            state: SendState::Pending,
            resend: false,
            written_on: 0,
            waiting_since: Some(now_ms),
        });
        self.event(id, stream, SendState::Pending);
        LocalAck { state: SendState::Pending, duplicate: false }
    }

    /// A send's state, if the outbox knows its id.
    pub fn state(&self, id: &str) -> Option<SendState> {
        self.items
            .iter()
            .find(|item| item.id == id)
            .map(|item| item.state.clone())
            .or_else(|| self.settled_index.get(id).cloned())
    }

    /// Sends not settled yet, oldest first.
    pub fn unsettled(&self) -> impl Iterator<Item = (&str, &SendState)> {
        self.items.iter().map(|item| (item.id.as_str(), &item.state))
    }

    /// A link is up: what was not written to it goes on it.
    pub fn link_up(&mut self) {
        self.epochs += 1;
        self.epoch = self.epochs;
    }

    /// The link is gone: what it carried without an answer waits again, as
    /// a resend, aged from now.
    pub fn link_lost(&mut self, now_ms: u64) {
        self.epoch = 0;
        let mut changed = Vec::new();
        for item in &mut self.items {
            if item.state == SendState::Sent {
                item.state = SendState::Pending;
                item.resend = true;
                item.waiting_since = Some(now_ms);
                changed.push((item.id.clone(), item.stream.clone()));
            }
        }
        for (id, stream) in changed {
            self.event(&id, &stream, SendState::Pending);
        }
    }

    /// What to write to the link now, in order, at most `max_bytes` of
    /// payload (at least one send when any waits): a resumed link's first
    /// flight takes them with its handshake. Each is [`SendState::Sent`]
    /// on return. Nothing while no link is up.
    pub fn take_sendable(&mut self, max_bytes: usize) -> Vec<Outgoing> {
        let mut out = Vec::new();
        if self.epoch == 0 {
            return out;
        }
        let mut bytes = 0usize;
        let epoch = self.epoch;
        let mut changed = Vec::new();
        for item in &mut self.items {
            if item.state != SendState::Pending {
                continue;
            }
            if !out.is_empty() && bytes + item.payload.len() > max_bytes {
                break;
            }
            bytes += item.payload.len();
            item.state = SendState::Sent;
            item.written_on = epoch;
            item.waiting_since = None;
            changed.push((item.id.clone(), item.stream.clone()));
            out.push(Outgoing {
                id: item.id.clone(),
                stream: item.stream.clone(),
                kind: item.kind,
                payload: item.payload.clone(),
                resend: item.resend,
            });
        }
        for (id, stream) in changed {
            self.event(&id, &stream, SendState::Sent);
        }
        out
    }

    /// The link could not take a send it was given (the write failed): it
    /// and every later send of its stream wait for the next link, in order.
    pub fn write_failed(&mut self, id: &str, now_ms: u64) {
        let Some(at) = self.items.iter().position(|item| item.id == id) else { return };
        let stream = self.items[at].stream.clone();
        let mut changed = Vec::new();
        for item in self.items.iter_mut().skip(at) {
            if item.stream == stream && item.state == SendState::Sent {
                item.state = SendState::Pending;
                item.waiting_since = Some(now_ms);
                changed.push(item.id.clone());
            }
        }
        for id in changed {
            self.event(&id, &stream, SendState::Pending);
        }
    }

    /// The Mac answered `id`. Returns false for an id the outbox has no
    /// unsettled send for (a late or doubled answer changes nothing).
    pub fn host_ack(&mut self, id: &str, ack: HostAck) -> bool {
        let Some(at) = self.items.iter().position(|item| item.id == id) else { return false };
        match ack {
            HostAck::Delivered => {
                let item = self.items.remove(at).expect("position is in range");
                self.settle(item, SendState::Delivered);
            }
            HostAck::Refused(reason) => {
                // The Mac refused it: nothing after it in its stream goes either.
                let stream = self.items[at].stream.clone();
                self.fail_stream_from(at, &stream, &reason);
            }
        }
        true
    }

    /// Fail what waited for a link longer than its kind's hold, with every
    /// later send of its stream. Returns how many failed.
    pub fn expire(&mut self, now_ms: u64) -> usize {
        let mut failed = 0;
        loop {
            let expired = self.items.iter().position(|item| {
                item.waiting_since.is_some_and(|since| now_ms.saturating_sub(since) >= item.kind.hold_ms())
            });
            let Some(at) = expired else { return failed };
            let stream = self.items[at].stream.clone();
            let reason =
                format!("not sent: unreachable for more than {} s", self.items[at].kind.hold_ms() / 1000);
            // Later sends of the stream fail with it: none goes after one
            // that did not.
            failed += self.fail_stream_from(at, &stream, &reason);
        }
    }

    /// The ms until the next send would expire, if any waits.
    pub fn next_expiry_in(&self, now_ms: u64) -> Option<u64> {
        self.items
            .iter()
            .filter_map(|item| {
                item.waiting_since.map(|since| (since + item.kind.hold_ms()).saturating_sub(now_ms))
            })
            .min()
    }

    /// State changes since the last call, in order.
    pub fn drain_events(&mut self) -> Vec<AckEvent> {
        std::mem::take(&mut self.events)
    }

    /// The durable sends not settled yet, as bytes to keep (JSON). A send
    /// that was written comes back as a resend.
    pub fn snapshot(&self) -> Vec<u8> {
        let kept: Vec<&Item> = self.items.iter().filter(|item| item.kind.durable()).collect();
        serde_json::to_vec(&kept).unwrap_or_default()
    }

    /// Put back what [`Outbox::snapshot`] kept, before anything else is
    /// queued. Every send waits for a link, aged from `now_ms` (the
    /// monotonic clock does not survive a restart), and a send that was
    /// written is a resend. Unreadable bytes restore nothing.
    pub fn restore(&mut self, bytes: &[u8], now_ms: u64) -> usize {
        let Ok(items) = serde_json::from_slice::<Vec<Item>>(bytes) else { return 0 };
        let mut restored = 0;
        for mut item in items {
            if !item.kind.durable() || self.state(&item.id).is_some() {
                continue;
            }
            if item.state == SendState::Sent {
                item.resend = true;
            }
            if item.state.is_final() {
                continue;
            }
            item.state = SendState::Pending;
            item.waiting_since = Some(now_ms);
            item.written_on = 0;
            self.items.push_back(item);
            restored += 1;
        }
        restored
    }

    fn fail_stream_from(&mut self, at: usize, stream: &str, reason: &str) -> usize {
        let mut failed = Vec::new();
        let mut index = at;
        while index < self.items.len() {
            if self.items[index].stream == stream {
                failed.push(self.items.remove(index).expect("index is in range"));
            } else {
                index += 1;
            }
        }
        let count = failed.len();
        for item in failed {
            self.settle(item, SendState::Failed(reason.to_owned()));
        }
        count
    }

    fn settle(&mut self, item: Item, state: SendState) {
        self.event(&item.id, &item.stream, state.clone());
        self.settled_index.insert(item.id.clone(), state.clone());
        self.settled.push_back((item.id, state));
        while self.settled.len() > SETTLED_MEMORY {
            if let Some((id, _)) = self.settled.pop_front() {
                self.settled_index.remove(&id);
            }
        }
    }

    fn event(&mut self, id: &str, stream: &str, state: SendState) {
        self.events.push(AckEvent { id: id.to_owned(), stream: stream.to_owned(), state });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids(out: &[Outgoing]) -> Vec<&str> {
        out.iter().map(|o| o.id.as_str()).collect()
    }

    fn states(outbox: &mut Outbox) -> Vec<(String, SendState)> {
        outbox.drain_events().into_iter().map(|e| (e.id, e.state)).collect()
    }

    #[test]
    fn enqueue_acks_locally_at_once_with_no_link() {
        let mut outbox = Outbox::new();
        let ack = outbox.enqueue("p1", "chat:a", SendKind::Prompt, b"hi".to_vec(), 0);
        assert_eq!(ack, LocalAck { state: SendState::Pending, duplicate: false });
        assert_eq!(states(&mut outbox), [("p1".into(), SendState::Pending)]);
        // No link: nothing is written.
        assert!(outbox.take_sendable(usize::MAX).is_empty());
    }

    #[test]
    fn the_same_id_is_one_send() {
        let mut outbox = Outbox::new();
        outbox.enqueue("p1", "chat:a", SendKind::Prompt, b"hi".to_vec(), 0);
        let again = outbox.enqueue("p1", "chat:a", SendKind::Prompt, b"hi".to_vec(), 5);
        assert!(again.duplicate);
        outbox.link_up();
        assert_eq!(ids(&outbox.take_sendable(usize::MAX)), ["p1"]);
        assert!(outbox.host_ack("p1", HostAck::Delivered));
        // Settled: a third enqueue answers Delivered, and queues nothing.
        let late = outbox.enqueue("p1", "chat:a", SendKind::Prompt, b"hi".to_vec(), 9);
        assert_eq!(late, LocalAck { state: SendState::Delivered, duplicate: true });
        assert!(outbox.take_sendable(usize::MAX).is_empty());
        // A doubled answer changes nothing.
        assert!(!outbox.host_ack("p1", HostAck::Delivered));
    }

    #[test]
    fn sends_go_in_order_once_per_link_and_settle_on_the_host_ack() {
        let mut outbox = Outbox::new();
        outbox.link_up();
        for id in ["k1", "k2", "k3"] {
            outbox.enqueue(id, "term:1", SendKind::Keys, id.as_bytes().to_vec(), 0);
        }
        assert_eq!(ids(&outbox.take_sendable(usize::MAX)), ["k1", "k2", "k3"]);
        assert!(outbox.take_sendable(usize::MAX).is_empty(), "written once per link");
        assert_eq!(outbox.state("k2"), Some(SendState::Sent));
        outbox.host_ack("k1", HostAck::Delivered);
        outbox.host_ack("k2", HostAck::Delivered);
        assert_eq!(outbox.state("k1"), Some(SendState::Delivered));
        assert_eq!(outbox.unsettled().map(|(id, _)| id).collect::<Vec<_>>(), ["k3"]);
        let events = states(&mut outbox);
        assert_eq!(events.iter().filter(|(_, s)| *s == SendState::Delivered).count(), 2);
    }

    #[test]
    fn a_lost_link_resends_what_it_did_not_answer_on_the_next_one() {
        let mut outbox = Outbox::new();
        outbox.link_up();
        outbox.enqueue("p1", "chat:a", SendKind::Prompt, b"one".to_vec(), 0);
        outbox.enqueue("p2", "chat:a", SendKind::Prompt, b"two".to_vec(), 0);
        let first = outbox.take_sendable(usize::MAX);
        assert!(first.iter().all(|o| !o.resend));
        outbox.host_ack("p1", HostAck::Delivered);
        outbox.link_lost(100);
        assert_eq!(outbox.state("p2"), Some(SendState::Pending));
        // Queued while down: goes after p2.
        outbox.enqueue("p3", "chat:a", SendKind::Prompt, b"three".to_vec(), 200);
        assert!(outbox.take_sendable(usize::MAX).is_empty());
        outbox.link_up();
        let again = outbox.take_sendable(usize::MAX);
        assert_eq!(ids(&again), ["p2", "p3"]);
        assert!(again[0].resend, "p2 may have reached the Mac");
        assert!(!again[1].resend);
    }

    #[test]
    fn the_first_flight_carries_queued_sends_up_to_its_budget() {
        let mut outbox = Outbox::new();
        outbox.enqueue("a", "s", SendKind::Prompt, vec![0; 600], 0);
        outbox.enqueue("b", "s", SendKind::Prompt, vec![0; 600], 0);
        outbox.enqueue("c", "s", SendKind::Prompt, vec![0; 600], 0);
        outbox.link_up();
        // The first send always goes, even past the budget.
        assert_eq!(ids(&outbox.take_sendable(100)), ["a"]);
        assert_eq!(ids(&outbox.take_sendable(1200)), ["b", "c"]);
    }

    #[test]
    fn a_refusal_fails_the_send_and_everything_after_it_in_its_stream() {
        let mut outbox = Outbox::new();
        outbox.link_up();
        outbox.enqueue("a1", "chat:a", SendKind::Prompt, vec![], 0);
        outbox.enqueue("b1", "chat:b", SendKind::Prompt, vec![], 0);
        outbox.enqueue("a2", "chat:a", SendKind::Prompt, vec![], 0);
        outbox.take_sendable(usize::MAX);
        outbox.host_ack("a1", HostAck::Refused("remote.full_access_required".into()));
        let failed = SendState::Failed("remote.full_access_required".into());
        assert_eq!(outbox.state("a1"), Some(failed.clone()));
        assert_eq!(outbox.state("a2"), Some(failed));
        assert_eq!(outbox.state("b1"), Some(SendState::Sent), "other streams go on");
    }

    #[test]
    fn a_failed_write_requeues_its_stream_in_order() {
        let mut outbox = Outbox::new();
        outbox.link_up();
        outbox.enqueue("a1", "s", SendKind::Keys, vec![1], 0);
        outbox.enqueue("a2", "s", SendKind::Keys, vec![2], 0);
        outbox.take_sendable(usize::MAX);
        outbox.write_failed("a1", 10);
        assert_eq!(ids(&outbox.take_sendable(usize::MAX)), ["a1", "a2"]);
    }

    #[test]
    fn a_send_that_waits_past_its_hold_fails_with_its_stream_tail() {
        let mut outbox = Outbox::new();
        outbox.enqueue("k1", "term:1", SendKind::Keys, b"rm -rf build".to_vec(), 0);
        outbox.enqueue("x1", "term:2", SendKind::Keys, b"ls".to_vec(), 5_000);
        outbox.enqueue("k2", "term:1", SendKind::Keys, b"\r".to_vec(), 6_000);
        assert_eq!(outbox.next_expiry_in(1_000), Some(9_000));
        assert_eq!(outbox.expire(9_999), 0);
        // k1 expires: k2 (the Return) must not run alone.
        assert_eq!(outbox.expire(10_000), 2);
        assert!(matches!(outbox.state("k1"), Some(SendState::Failed(_))));
        assert!(matches!(outbox.state("k2"), Some(SendState::Failed(_))));
        assert_eq!(outbox.state("x1"), Some(SendState::Pending));
        outbox.link_up();
        assert_eq!(ids(&outbox.take_sendable(usize::MAX)), ["x1"]);
    }

    #[test]
    fn a_send_written_to_a_live_link_never_ages() {
        let mut outbox = Outbox::new();
        outbox.link_up();
        outbox.enqueue("k1", "term:1", SendKind::Keys, vec![1], 0);
        outbox.take_sendable(usize::MAX);
        // A slow link: no answer for a minute, still not failed.
        assert_eq!(outbox.expire(60_000), 0);
        assert_eq!(outbox.next_expiry_in(60_000), None);
        // Lost: it ages from the loss, not from its send.
        outbox.link_lost(60_000);
        assert_eq!(outbox.expire(69_999), 0);
        assert_eq!(outbox.expire(70_000), 1);
    }

    #[test]
    fn prompts_survive_a_restart_and_keys_do_not() {
        let mut outbox = Outbox::new();
        outbox.link_up();
        outbox.enqueue("p1", "chat:a", SendKind::Prompt, b"written".to_vec(), 0);
        outbox.take_sendable(usize::MAX);
        outbox.enqueue("p2", "chat:a", SendKind::Prompt, b"queued".to_vec(), 0);
        outbox.enqueue("k1", "term:1", SendKind::Keys, b"x".to_vec(), 0);
        let kept = outbox.snapshot();

        let mut restarted = Outbox::new();
        assert_eq!(restarted.restore(&kept, 500), 2);
        assert_eq!(restarted.state("k1"), None);
        restarted.link_up();
        let out = restarted.take_sendable(usize::MAX);
        assert_eq!(ids(&out), ["p1", "p2"]);
        assert!(out[0].resend, "written before the restart: the Mac checks its id");
        assert!(!out[1].resend);
        assert_eq!(out[1].payload, b"queued");
        // Restored sends age from the restore.
        restarted.link_lost(600);
        assert_eq!(restarted.expire(10_499), 0);
        assert_eq!(Outbox::new().restore(b"not json", 0), 0);
    }

    #[test]
    fn settled_ids_are_remembered_up_to_a_bound() {
        let mut outbox = Outbox::new();
        outbox.link_up();
        for n in 0..=SETTLED_MEMORY {
            let id = format!("id{n}");
            outbox.enqueue(&id, "s", SendKind::Keys, vec![], 0);
            outbox.take_sendable(usize::MAX);
            outbox.host_ack(&id, HostAck::Delivered);
        }
        assert_eq!(outbox.state("id0"), None, "the oldest is forgotten");
        assert_eq!(outbox.state("id1"), Some(SendState::Delivered));
    }
}
