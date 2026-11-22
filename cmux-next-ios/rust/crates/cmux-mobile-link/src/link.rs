//! One link: reliable ordered byte streams carrying multiplexed channels
//! (PROTOCOL.md "Link"). The transport underneath (WebRTC data channels or
//! TCP streams inside WireGuard) is invisible here.
//!
//! A link has a main stream and, when both sides support it, an input lane:
//! a second stream for keystrokes, resizes and their replies (PROTOCOL.md
//! "Lanes"). Each stream's writer sends, in order of priority, control
//! frames (ping, pong, refusals), input-lane frames, then bulk channel data
//! round robin across channels in chunks of [`DATA_CHUNK`], so a keystroke
//! never waits behind a large write.

use std::any::Any;
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use bytes::Bytes;
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::{Notify, mpsc, oneshot, watch};
use tokio::task::JoinHandle;
use tokio::time::Instant;
use tokio_util::codec::{FramedRead, FramedWrite};

use crate::frame::{Frame, FrameCodec, FrameType};
use crate::reliable::{self as rel, Carrier, Hello, HelloKind, ReliableConfig, ReliableStats, Token};
use cmux_remote_protocol::reliable::{Cursors, Inbound, ReplayLog};

/// Events queued per channel before the link reader waits for the owner.
const CHANNEL_DEPTH: usize = 1024;
/// Largest data frame payload this side writes. Larger writes are split, so
/// one write cannot hold a stream for longer than one chunk. (The decoder
/// still accepts frames up to [`crate::frame::MAX_PAYLOAD`] from older peers.)
pub const DATA_CHUNK: usize = 16 * 1024;
/// Bytes one channel may have queued for the writer before its sender waits.
/// Bounds how much stale output sits in front of the link (a ^C stops a
/// flood sooner) and keeps the memory of a fast producer bounded.
const CHANNEL_QUEUE_BYTES: usize = 256 * 1024;
/// The writer flushes after this many bytes, so the transport sees frames
/// in priority order rather than one large batch.
const FLUSH_BYTES: usize = 64 * 1024;
/// How long an attached lane may stay silent before it is given up.
const LANE_CONFIRM: Duration = Duration::from_secs(10);
/// How long opening an input-lane channel waits for a negotiated lane that
/// is still connecting before it falls back to the main stream.
const LANE_WAIT: Duration = Duration::from_secs(2);
/// How long a channel's owner may leave its full queue unread before that
/// channel is closed (`overflow`).
const CHANNEL_STALL: Duration = Duration::from_secs(3);
/// Bytes one channel may hold between the link reader and its owner's queue
/// ([`Inbox`]) before the reader waits for it. Above the god sessions' bursts
/// (20,000 deltas after an outage is about 20 MB), so a channel read slowly
/// never holds the others; still a bound on what one channel can hold.
const CHANNEL_BUFFER_BYTES: usize = 64 * 1024 * 1024;

/// Which end of the link this is: the phone opens odd channel ids, the Mac
/// even ones. Channel 0 carries pings.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Phone,
    Mac,
}

impl Role {
    fn first_channel(self) -> u32 {
        match self {
            Self::Phone => 1,
            Self::Mac => 2,
        }
    }

    /// Whether the peer may open `channel`.
    fn peer_owns(self, channel: u32) -> bool {
        channel != 0
            && match self {
                Self::Phone => channel.is_multiple_of(2),
                Self::Mac => !channel.is_multiple_of(2),
            }
    }
}

/// The lane a channel rides (PROTOCOL.md "Lanes"). `Input` is for small,
/// latency-bound traffic (terminal keystrokes and resizes and their
/// replies); everything else is `Bulk`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Lane {
    #[default]
    Bulk,
    Input,
}

impl Lane {
    fn is_bulk(&self) -> bool {
        *self == Self::Bulk
    }
}

/// The name both sides advertise in signaling when they support the input
/// lane (`lanes: ["input"]`).
pub const INPUT_LANE: &str = "input";

/// Whether the input lane exists on this link.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LaneState {
    /// The peer does not support it (or the lane failed): input-lane
    /// channels ride the main stream at input priority.
    Unavailable,
    /// Negotiated; the second stream is opening, or attached but the peer
    /// has not been heard on it yet.
    Pending,
    /// Attached.
    Ready,
}

#[derive(Debug, Clone)]
pub struct LinkConfig {
    /// Interval between keepalive pings; `None` disables them.
    pub keepalive: Option<Duration>,
    /// How long the link may go without receiving anything (a pong or any
    /// other frame) after a keepalive ping before it closes.
    pub keepalive_timeout: Duration,
    /// Pings go out on the beats of `keepalive` ([`crate::keepalive`]), the
    /// same instants as the phone's other keepalives, instead of
    /// `keepalive` after the last pong.
    pub aligned: bool,
    /// The reliable link ([`crate::reliable`]): set only when both sides
    /// listed [`crate::reliable::RELIABLE_LANE`]. `None` (the default) sends
    /// exactly the frames of a link without it.
    pub reliable: Option<ReliableConfig>,
}

impl Default for LinkConfig {
    fn default() -> Self {
        Self {
            keepalive: Some(Duration::from_secs(15)),
            keepalive_timeout: Duration::from_secs(20),
            aligned: false,
            reliable: None,
        }
    }
}

impl LinkConfig {
    /// A phone link with Align Keepalives on: a ping on every 10 s beat. Its
    /// tunnel then sends no WireGuard keepalive of its own
    /// (`DialOptions::aligned_keepalives`): each ping is a tunnel datagram on
    /// the same routes, as often, so NAT bindings and the peer's `reach`
    /// answers keep today's 10 s rhythm.
    pub fn aligned() -> Self {
        Self { keepalive: Some(crate::keepalive::BEAT), aligned: true, ..Self::default() }
    }
}

/// `open` payload.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OpenRequest {
    pub service: String,
    #[serde(default)]
    pub args: serde_json::Value,
    /// Absent (bulk) on the wire unless `input`; older peers ignore it.
    #[serde(default, skip_serializing_if = "Lane::is_bulk")]
    pub lane: Lane,
}

/// `close` payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CloseInfo {
    pub code: String,
    #[serde(default)]
    pub reason: String,
}

impl CloseInfo {
    pub fn new(code: impl Into<String>, reason: impl Into<String>) -> Self {
        Self { code: code.into(), reason: reason.into() }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChannelEvent {
    Data(Bytes),
    Closed(CloseInfo),
}

#[derive(Debug, thiserror::Error, Clone, PartialEq, Eq)]
pub enum LinkError {
    #[error("the link is closed: {0}")]
    Closed(String),
    #[error("the channel is closed")]
    ChannelClosed,
    #[error("timed out")]
    Timeout,
}

/// A frame's scheduling class on its stream.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Class {
    /// Ping, pong, refusals: first.
    Control,
    /// Input-lane channels: before any bulk data.
    Input,
    /// Everything else, round robin per channel.
    Bulk,
}

impl From<Lane> for Class {
    fn from(lane: Lane) -> Self {
        match lane {
            Lane::Bulk => Self::Bulk,
            Lane::Input => Self::Input,
        }
    }
}

/// Main stream and input lane.
const MAIN: usize = 0;
const INPUT: usize = 1;

#[derive(Default)]
struct Queues {
    control: VecDeque<Frame>,
    input: VecDeque<Frame>,
    bulk: HashMap<u32, VecDeque<Frame>>,
    /// Bulk channels with queued frames, in round-robin order.
    turns: VecDeque<u32>,
    /// Queued payload bytes per channel (input and bulk).
    bytes: HashMap<u32, usize>,
    shutdown: bool,
}

enum Next {
    Frame(Frame),
    Shutdown,
}

/// What became of a data frame [`Outbox::push_data`] was given.
enum Pushed {
    Queued,
    /// The writer is gone.
    Shutdown,
    /// Its channel closed while it waited for room.
    ChannelClosed,
}

/// One stream's outgoing frames, by priority.
#[derive(Default)]
struct Outbox {
    queues: Mutex<Queues>,
    /// Wakes the writer.
    ready: Notify,
    /// Wakes senders waiting for room in their channel's queue.
    room: Notify,
}

impl Outbox {
    fn lock(&self) -> std::sync::MutexGuard<'_, Queues> {
        self.queues.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn enqueue(queues: &mut Queues, class: Class, frame: Frame) {
        match class {
            Class::Control => queues.control.push_back(frame),
            Class::Input => {
                *queues.bytes.entry(frame.channel).or_default() += frame.payload.len();
                queues.input.push_back(frame);
            }
            Class::Bulk => {
                let channel = frame.channel;
                *queues.bytes.entry(channel).or_default() += frame.payload.len();
                let queue = queues.bulk.entry(channel).or_default();
                if queue.is_empty() {
                    queues.turns.push_back(channel);
                }
                queue.push_back(frame);
            }
        }
    }

    /// Queue without waiting (control frames, open, close). `false` once
    /// the writer is gone.
    fn push(&self, class: Class, frame: Frame) -> bool {
        {
            let mut queues = self.lock();
            if queues.shutdown {
                return false;
            }
            Self::enqueue(&mut queues, class, frame);
        }
        self.ready.notify_one();
        true
    }

    /// Queue a channel's data frame, waiting while that channel already
    /// has [`CHANNEL_QUEUE_BYTES`] queued. Gives up once the writer is gone
    /// or the channel is `closed` (its close wakes the wait).
    ///
    /// A reliable link also counts what the channel sent and the peer has not
    /// acked (`logged`), up to `budget`: the replay buffer's bound. Without one
    /// `logged` is 0 and `budget` unbounded, so the check is today's.
    async fn push_data(
        &self,
        class: Class,
        frame: Frame,
        closed: &AtomicBool,
        logged: &(dyn Fn(u32) -> usize + Sync),
        budget: usize,
    ) -> Pushed {
        loop {
            let room = self.room.notified();
            tokio::pin!(room);
            room.as_mut().enable();
            {
                let mut queues = self.lock();
                if queues.shutdown {
                    return Pushed::Shutdown;
                }
                if closed.load(Ordering::Acquire) {
                    return Pushed::ChannelClosed;
                }
                let used = queues.bytes.get(&frame.channel).copied().unwrap_or(0);
                let held = used + logged(frame.channel);
                if (used == 0 || used + frame.payload.len() <= CHANNEL_QUEUE_BYTES)
                    && (held == 0 || held.saturating_add(frame.payload.len()) <= budget)
                {
                    Self::enqueue(&mut queues, class, frame);
                    drop(queues);
                    self.ready.notify_one();
                    return Pushed::Queued;
                }
            }
            room.await;
        }
    }

    /// The next frame by priority, without waiting.
    fn pop(&self) -> Option<Next> {
        let mut queues = self.lock();
        if let Some(frame) = queues.control.pop_front() {
            return Some(Next::Frame(frame));
        }
        let frame = if let Some(frame) = queues.input.pop_front() {
            frame
        } else if let Some(channel) = queues.turns.pop_front() {
            let queue = queues.bulk.get_mut(&channel).expect("a turn has a queue");
            let frame = queue.pop_front().expect("a turn has a frame");
            if queue.is_empty() {
                queues.bulk.remove(&channel);
            } else {
                queues.turns.push_back(channel);
            }
            frame
        } else if queues.shutdown {
            return Some(Next::Shutdown);
        } else {
            return None;
        };
        if let Some(used) = queues.bytes.get_mut(&frame.channel) {
            *used = used.saturating_sub(frame.payload.len());
            if *used == 0 {
                queues.bytes.remove(&frame.channel);
            }
            drop(queues);
            self.room.notify_waiters();
        }
        Some(Next::Frame(frame))
    }

    async fn next(&self) -> Next {
        loop {
            let ready = self.ready.notified();
            tokio::pin!(ready);
            ready.as_mut().enable();
            if let Some(next) = self.pop() {
                return next;
            }
            ready.await;
        }
    }

    /// Stop accepting frames; the writer sends what is queued, then closes.
    fn shut(&self) {
        self.lock().shutdown = true;
        self.ready.notify_one();
        self.room.notify_waiters();
    }
}

/// Where a channel's inbound events go.
struct Route {
    inbox: Inbox,
    /// The channel's sender's closed flag: the peer's close sets it, so a send
    /// in progress stops instead of streaming into a channel the peer dropped.
    closed: Arc<AtomicBool>,
}

/// A channel's inbound events on their way to its owner. The link reader
/// hands each one over without waiting (up to [`CHANNEL_BUFFER_BYTES`]), and
/// a task per channel delivers them, in order, into the owner's queue. One
/// channel read slowly (a god session's backlog applied on a busy main
/// actor) used to hold the reader, so every other channel and the link's
/// pongs waited behind it, and the phone's 2 s probe redialed a healthy link
/// (iOS reliability matrix, degenerate_slow_consumer_after_outage). A channel
/// whose owner leaves its queue unread for [`CHANNEL_STALL`] is still closed
/// `overflow`.
#[derive(Clone)]
struct Inbox {
    tx: mpsc::UnboundedSender<ChannelEvent>,
    owner: mpsc::Sender<ChannelEvent>,
    buffered: Arc<AtomicUsize>,
    room: Arc<Notify>,
}

fn event_bytes(event: &ChannelEvent) -> usize {
    match event {
        ChannelEvent::Data(data) => data.len(),
        ChannelEvent::Closed(_) => 0,
    }
}

impl Inbox {
    fn new(owner: mpsc::Sender<ChannelEvent>, inner: &Arc<Inner>, stream: usize, channel: u32) -> Self {
        let (tx, mut rx) = mpsc::unbounded_channel::<ChannelEvent>();
        let buffered = Arc::new(AtomicUsize::new(0));
        let room = Arc::new(Notify::new());
        let link = Arc::downgrade(inner);
        let deliver = owner.clone();
        let (counted, woken) = (Arc::clone(&buffered), Arc::clone(&room));
        tokio::spawn(async move {
            while let Some(event) = rx.recv().await {
                let size = event_bytes(&event);
                let closing = matches!(event, ChannelEvent::Closed(_));
                let sent = tokio::time::timeout(CHANNEL_STALL, deliver.send(event)).await;
                counted.fetch_sub(size, Ordering::AcqRel);
                woken.notify_waiters();
                match sent {
                    Ok(Ok(())) if !closing => {}
                    // Delivered the close, or the owner dropped its receiver.
                    Ok(Ok(())) | Ok(Err(_)) => {
                        if let Some(inner) = link.upgrade() {
                            inner.lock_channels().remove(&channel);
                        }
                        return;
                    }
                    Err(_) => {
                        if !closing && let Some(inner) = link.upgrade() {
                            tracing::warn!(channel, "channel not read for {CHANNEL_STALL:?}; closing it");
                            if inner.lock_channels().remove(&channel).is_some() {
                                refuse(&inner, stream, channel, "overflow", "the channel was not read");
                            }
                        }
                        return;
                    }
                }
            }
        });
        Self { tx, owner, buffered, room }
    }

    /// Hands `event` to the channel. Waits only while the channel already
    /// holds [`CHANNEL_BUFFER_BYTES`], at most [`CHANNEL_STALL`]; false when
    /// it stayed full or is gone.
    async fn push(&self, event: ChannelEvent) -> bool {
        let size = event_bytes(&event);
        let deadline = Instant::now() + CHANNEL_STALL;
        loop {
            let room = self.room.notified();
            let held = self.buffered.load(Ordering::Acquire);
            if held == 0 || held + size <= CHANNEL_BUFFER_BYTES {
                break;
            }
            if tokio::time::timeout_at(deadline, room).await.is_err() {
                return false;
            }
        }
        self.buffered.fetch_add(size, Ordering::AcqRel);
        if self.tx.send(event).is_err() {
            self.buffered.fetch_sub(size, Ordering::AcqRel);
            return false;
        }
        true
    }

    /// Queues `event` behind what the channel holds, without waiting (a close).
    fn push_now(&self, event: ChannelEvent) {
        let _ = self.tx.send(event);
    }

    fn owner_gone(&self) -> bool {
        self.owner.is_closed()
    }
}

/// A reliable link's state ([`crate::reliable`]).
struct Reliable {
    config: ReliableConfig,
    token: Token,
    state: Mutex<RelState>,
    carrier: watch::Sender<Carrier>,
    /// The current carrier's generation; a carrier's tasks stop once it moves
    /// on (the carrier dropped or another took its place).
    generation: watch::Sender<u64>,
    /// Wakes the ack task: frames arrived and wait for their ack.
    ack_wake: Notify,
    /// Taken by a reader while it judges and delivers one frame, so the
    /// reader of a dropped carrier that is still delivering finishes before
    /// the next carrier's reader delivers anything.
    deliver: tokio::sync::Mutex<()>,
    /// Link::close was called: the writer ends the carrier with `bye`.
    bye: AtomicBool,
    /// A frame of the peer arrived on some carrier of this link: the peer
    /// has the link (a phone resumes it with `Resume`, not `Reopen`).
    heard: AtomicBool,
    stats: Mutex<ReliableStats>,
    /// Per channel: unacked payload bytes when carriers dropped, and bytes
    /// replayed, summed over resumes.
    channel_stats: Mutex<HashMap<u32, ChannelResume>>,
}

/// One channel's share of a reliable link's resumes ([`Link::channel_resume`]).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ChannelResume {
    /// Payload bytes of this channel sent and not acked when carriers dropped.
    pub unacked_at_drop_bytes: u64,
    /// Payload bytes of this channel replayed.
    pub replayed_bytes: u64,
    pub replayed_frames: u64,
}

#[derive(Default)]
struct RelState {
    log: ReplayLog<u32, rel::Logged>,
    cursors: Cursors<u32>,
    /// The highest channel the peer opened that this side has seen.
    max_peer_opened: u32,
    /// Per channel, the highest sequence received and not yet acked.
    pending: HashMap<u32, u64>,
    pending_bytes: usize,
    forgotten: rel::Forgotten,
}

impl Reliable {
    fn lock(&self) -> std::sync::MutexGuard<'_, RelState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn stats(&self) -> std::sync::MutexGuard<'_, ReliableStats> {
        self.stats.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// A carrier's generation and the watch that says when it is over.
type CarrierTag = Option<(watch::Receiver<u64>, u64)>;

/// Resolves once the carrier `tag` names is over; never without one.
async fn superseded(tag: &mut CarrierTag) {
    match tag {
        None => std::future::pending().await,
        Some((generation, mine)) => {
            let mine = *mine;
            let _ = generation.wait_for(|current| *current != mine).await;
        }
    }
}

pub(crate) struct Inner {
    role: Role,
    /// `Some` on a reliable link only.
    reliable: Option<Reliable>,
    /// Per stream: [`MAIN`] and [`INPUT`].
    outboxes: [Outbox; 2],
    lane: watch::Sender<LaneState>,
    /// The lane's stream was attached (at most once).
    lane_attached: AtomicBool,
    /// When the reader last received a frame. Any inbound frame proves the
    /// peer is alive, so a busy link never times out on a slow pong.
    last_rx: Mutex<Instant>,
    /// When the reader last received a frame other than a ping or a pong:
    /// the link carries traffic, not only keepalives.
    last_traffic: Mutex<Instant>,
    channels: Mutex<HashMap<u32, Route>>,
    next_channel: AtomicU32,
    next_nonce: AtomicU64,
    pings: Mutex<HashMap<u64, oneshot::Sender<Instant>>>,
    rtt: watch::Sender<Option<Duration>>,
    closed: watch::Sender<Option<String>>,
    incoming: tokio::sync::Mutex<mpsc::Receiver<IncomingChannel>>,
    /// A sender for the input lane's reader; dropped when the link closes so
    /// `accept` ends once the readers are gone.
    incoming_tx: Mutex<Option<mpsc::Sender<IncomingChannel>>>,
    tasks: Mutex<Vec<JoinHandle<()>>>,
    /// Keeps the transport (peer connection, tunnel) alive with the link.
    transport: Mutex<Option<Box<dyn Any + Send>>>,
    /// The media lane, when the dial negotiated one.
    media: Mutex<Option<crate::media::MediaLane>>,
}

impl Inner {
    fn lock_channels(&self) -> std::sync::MutexGuard<'_, HashMap<u32, Route>> {
        self.channels.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn closed_reason(&self) -> Option<String> {
        self.closed.borrow().clone()
    }

    fn closed_error(&self) -> LinkError {
        LinkError::Closed(self.closed_reason().unwrap_or_else(|| "writer stopped".into()))
    }

    /// Unacked bytes of `channel` (0 without the reliable link).
    fn logged_bytes(&self, channel: u32) -> usize {
        self.reliable.as_ref().map_or(0, |reliable| reliable.lock().log.stream_bytes(channel))
    }

    /// On a reliable link, gives a channel frame its sequence and keeps it
    /// for replay; `None` drops it (its channel was closed by the peer).
    /// Runs as the writer takes the frame, so sequences follow wire order.
    fn seal(&self, frame: Frame) -> Option<Frame> {
        let Some(reliable) = &self.reliable else { return Some(frame) };
        if frame.channel == 0 || !matches!(frame.kind, FrameType::Open | FrameType::Data | FrameType::Close) {
            return Some(frame);
        }
        let channel = frame.channel;
        let last = frame.kind == FrameType::Close;
        let (sequence, over) = {
            let mut state = reliable.lock();
            if state.forgotten.contains(channel) {
                return None;
            }
            let logged = rel::Logged { kind: frame.kind, payload: frame.payload.clone() };
            let sequence = state.log.record(channel, logged, last);
            if last {
                // Nothing of the peer's on this channel matters here any more.
                state.cursors.close(channel);
            }
            // Senders wait at the budget; only control-class frames bypass
            // it, so this is a peer that never acks.
            let over =
                state.log.stream_bytes(channel) > 4 * reliable.config.replay_bytes_per_channel + DATA_CHUNK;
            (sequence, over)
        };
        if over {
            self.shut("replay budget exceeded");
            return None;
        }
        Some(Frame::new(channel, FrameType::Seq, rel::seq_payload(sequence, frame.kind, &frame.payload)))
    }

    /// Sends what arrived and is not yet acked.
    fn flush_acks(&self) {
        let Some(reliable) = &self.reliable else { return };
        let acks: Vec<(u32, u64)> = {
            let mut state = reliable.lock();
            state.pending_bytes = 0;
            state.pending.drain().collect()
        };
        if !acks.is_empty() {
            let _ = self.send_control(Frame::new(0, FrameType::Ack, rel::ack_payload(&acks)));
        }
    }

    /// This side's hello: its token, cursors and what it saw the peer open.
    fn hello(&self, kind: HelloKind) -> Hello {
        let reliable = self.reliable.as_ref().expect("a reliable link");
        let state = reliable.lock();
        Hello {
            kind,
            token: reliable.token,
            max_peer_opened: state.max_peer_opened,
            cursors: state.cursors.snapshot(),
        }
    }

    /// The carrier `generation` failed: a reliable link waits for the next
    /// one, any other link closes as today.
    fn carrier_failed(self: &Arc<Self>, tag: &CarrierTag, reason: &str) {
        match tag {
            Some((_, generation)) if self.reliable.is_some() => {
                self.suspend(*generation, reason);
            }
            _ => self.shut(reason),
        }
    }

    /// Drops the current carrier, whatever it is.
    fn lose_carrier(self: &Arc<Self>, reason: &str) {
        if let Some(reliable) = &self.reliable {
            let generation = *reliable.generation.borrow();
            self.suspend(generation, reason);
        }
    }

    /// Ends carrier `generation` (if it is still the current one and up):
    /// its tasks stop, channels stay open, and the link closes as today
    /// unless a new carrier resumes it within the resume window.
    fn suspend(self: &Arc<Self>, generation: u64, reason: &str) -> bool {
        let Some(reliable) = &self.reliable else { return false };
        if self.closed_reason().is_some() {
            return false;
        }
        let moved = reliable.generation.send_if_modified(|current| {
            let mine = *current == generation;
            if mine {
                *current += 1;
            }
            mine
        });
        if !moved {
            return false;
        }
        reliable.carrier.send_replace(Carrier::Down);
        let (unacked, per_channel) = {
            let state = reliable.lock();
            let per_channel: Vec<(u32, usize)> =
                state.log.streams().map(|channel| (channel, state.log.stream_bytes(channel))).collect();
            (state.log.bytes() as u64, per_channel)
        };
        {
            let mut channels = reliable.channel_stats.lock().unwrap_or_else(PoisonError::into_inner);
            for (channel, bytes) in per_channel {
                channels.entry(channel).or_default().unacked_at_drop_bytes += bytes as u64;
            }
        }
        reliable.stats().unacked_at_drop_bytes += unacked;
        tracing::info!(reason, unacked, "link carrier dropped; waiting for a resume");
        let transport = self.transport.lock().unwrap_or_else(PoisonError::into_inner).take();
        drop(transport);
        self.tasks.lock().unwrap_or_else(PoisonError::into_inner).retain(|task| !task.is_finished());
        let link = Arc::downgrade(self);
        let window = reliable.config.resume_window;
        let next = generation + 1;
        let reason = reason.to_owned();
        tokio::spawn(async move {
            tokio::time::sleep(window).await;
            if let Some(inner) = link.upgrade()
                && let Some(reliable) = &inner.reliable
                && *reliable.generation.borrow() == next
                && *reliable.carrier.borrow() == Carrier::Down
            {
                inner.shut(&format!("no resume within {window:?} ({reason})"));
            }
        });
        true
    }

    /// Waits while a reliable link's carrier is down.
    async fn carrier_up(&self) {
        if let Some(reliable) = &self.reliable {
            let mut carrier = reliable.carrier.subscribe();
            let mut closed = self.closed.subscribe();
            tokio::select! {
                _ = carrier.wait_for(|carrier| *carrier == Carrier::Up) => {}
                _ = closed.wait_for(Option::is_some) => {}
            }
        }
    }

    fn carrier_is_down(&self) -> bool {
        self.reliable.as_ref().is_some_and(|reliable| *reliable.carrier.borrow() == Carrier::Down)
    }

    /// What the peer (whose hello is `peer`) lacks, oldest first per channel.
    /// Everything at or below its cursors is acked by the same step.
    fn replay_frames(&self, peer: &Hello) -> Vec<Frame> {
        let reliable = self.reliable.as_ref().expect("a reliable link");
        let cursors: HashMap<u32, u64> = peer.cursors.iter().copied().collect();
        let mut state = reliable.lock();
        let streams: Vec<u32> = state.log.streams().collect();
        let mut frames = Vec::new();
        for channel in streams {
            let ours = !self.role.peer_owns(channel);
            let from = match cursors.get(&channel) {
                Some(cursor) => Some(*cursor),
                // The peer never saw this channel's open: all of it.
                None if ours && channel > peer.max_peer_opened => Some(0),
                // The peer closed it: nothing of it matters.
                None => None,
            };
            match from {
                Some(cursor) => {
                    for (sequence, logged) in state.log.resume_from(channel, cursor) {
                        let payload = rel::seq_payload(sequence, logged.kind, &logged.payload);
                        frames.push(Frame::new(channel, FrameType::Seq, payload));
                    }
                }
                None => {
                    state.log.forget(channel);
                }
            }
        }
        frames
    }

    /// Writes `peer`'s missing frames to the new carrier.
    async fn replay<W>(&self, sink: &mut FramedWrite<W, FrameCodec>, peer: &Hello) -> Result<(), LinkError>
    where
        W: AsyncWrite + Send + Unpin,
    {
        let reliable = self.reliable.as_ref().expect("a reliable link");
        let frames = self.replay_frames(peer);
        let count = frames.len() as u64;
        // Payload bytes of the replayed channel frames (what the log holds).
        let mut bytes = 0u64;
        {
            let mut channels = reliable.channel_stats.lock().unwrap_or_else(PoisonError::into_inner);
            for frame in &frames {
                let size = frame.payload.len().saturating_sub(9) as u64;
                bytes += size;
                let entry = channels.entry(frame.channel).or_default();
                entry.replayed_bytes += size;
                entry.replayed_frames += 1;
            }
        }
        for frame in frames {
            sink.feed(frame).await.map_err(|error| LinkError::Closed(format!("replay failed: {error}")))?;
        }
        sink.flush().await.map_err(|error| LinkError::Closed(format!("replay failed: {error}")))?;
        let mut stats = reliable.stats();
        stats.replayed_frames += count;
        stats.replayed_bytes += bytes;
        drop(stats);
        for outbox in &self.outboxes {
            outbox.room.notify_waiters();
        }
        Ok(())
    }

    /// Runs carrier `generation` of a reliable link (or the only carrier of
    /// any link, `tag` `None`) over `sink` and `source`.
    fn run_carrier<R, W>(
        self: &Arc<Self>,
        tag: CarrierTag,
        sink: FramedWrite<W, FrameCodec>,
        source: FramedRead<R, FrameCodec>,
    ) where
        R: AsyncRead + Send + Unpin + 'static,
        W: AsyncWrite + Send + Unpin + 'static,
    {
        let Some(incoming) = self.incoming_tx.lock().unwrap_or_else(PoisonError::into_inner).clone() else {
            return;
        };
        self.received();
        let writer = tokio::spawn(write_loop(Arc::clone(self), MAIN, sink, tag.clone()));
        let reader = tokio::spawn(read_loop(Arc::clone(self), MAIN, source, incoming, tag));
        let mut tasks = self.tasks.lock().unwrap_or_else(PoisonError::into_inner);
        tasks.retain(|task| !task.is_finished());
        tasks.extend([writer, reader]);
        drop(tasks);
        if let Some(reliable) = &self.reliable {
            reliable.carrier.send_replace(Carrier::Up);
        }
    }

    /// Queue a frame that never waits (control, open, close).
    fn push(&self, stream: usize, class: Class, frame: Frame) -> Result<(), LinkError> {
        if self.closed_reason().is_some() || !self.outboxes[stream].push(class, frame) {
            return Err(self.closed_error());
        }
        Ok(())
    }

    /// Queue a ping or pong ahead of channel data.
    fn send_control(&self, frame: Frame) -> Result<(), LinkError> {
        self.push(MAIN, Class::Control, frame)
    }

    fn received(&self) {
        *self.last_rx.lock().unwrap_or_else(PoisonError::into_inner) = Instant::now();
    }

    fn received_traffic(&self) {
        *self.last_traffic.lock().unwrap_or_else(PoisonError::into_inner) = Instant::now();
    }

    fn last_received(&self) -> Instant {
        *self.last_rx.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Mark the link closed (once) and tell every channel.
    fn shut(&self, reason: &str) {
        let first = self.closed.send_if_modified(|state| {
            if state.is_none() {
                *state = Some(reason.to_owned());
                true
            } else {
                false
            }
        });
        if !first {
            return;
        }
        tracing::debug!(reason, "link closed");
        if let Some(reliable) = &self.reliable
            && let Some(registry) = &reliable.config.registry
        {
            registry.remove(&reliable.token);
        }
        let channels: Vec<_> = self.lock_channels().drain().map(|(_, route)| route.inbox).collect();
        for inbox in channels {
            inbox.push_now(ChannelEvent::Closed(CloseInfo::new("link_closed", reason)));
        }
        self.pings.lock().unwrap_or_else(PoisonError::into_inner).clear();
        self.incoming_tx.lock().unwrap_or_else(PoisonError::into_inner).take();
        for outbox in &self.outboxes {
            outbox.shut();
        }
        self.lane.send_if_modified(|state| {
            let changed = *state == LaneState::Pending;
            if changed {
                *state = LaneState::Unavailable;
            }
            changed
        });
        self.media.lock().unwrap_or_else(PoisonError::into_inner).take();
        // Dropping the transport tears down the peer connection or tunnel.
        let transport = self.transport.lock().unwrap_or_else(PoisonError::into_inner).take();
        drop(transport);
    }
}

/// A channel the peer opened.
pub struct IncomingChannel {
    pub service: String,
    pub args: serde_json::Value,
    /// The lane the peer asked for.
    pub lane: Lane,
    pub channel: Channel,
}

/// What [`Link::accept_reliable`] made of a carrier.
pub enum Accepted {
    /// A new link: serve it. Also a phone's `Reopen` of a link whose first
    /// carrier dropped before this Mac read its hello.
    New(Link),
    /// The carrier resumed this (already served) link.
    Resumed(Link),
}

/// What one [`Link::resume`] did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ResumeReport {
    /// Round trips before channel data flowed again.
    pub round_trips: u64,
    /// Frames and payload bytes this side replayed.
    pub replayed_frames: u64,
    pub replayed_bytes: u64,
    pub took: Duration,
}

async fn read_hello<R>(source: &mut FramedRead<R, FrameCodec>) -> Result<Hello, LinkError>
where
    R: AsyncRead + Send + Unpin,
{
    let first =
        tokio::time::timeout(rel::HELLO_TIMEOUT, source.next()).await.map_err(|_| LinkError::Timeout)?;
    match first {
        Some(Ok(frame)) if frame.kind == FrameType::Hello && frame.channel == 0 => {
            Hello::decode(frame.payload).ok_or_else(|| LinkError::Closed("bad hello".into()))
        }
        Some(Ok(_)) => Err(LinkError::Closed("the carrier did not open with a hello".into())),
        Some(Err(error)) => Err(LinkError::Closed(format!("read failed: {error}"))),
        None => Err(LinkError::Closed("the carrier ended before its hello".into())),
    }
}

/// A running link. Cheap to clone; every clone is the same link. Call
/// [`Link::close`] to end it; it also ends when the transport does.
#[derive(Clone)]
pub struct Link {
    inner: Arc<Inner>,
}

impl std::fmt::Debug for Link {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Link").field("role", &self.inner.role).finish_non_exhaustive()
    }
}

impl Link {
    /// Run a link over `stream`. `transport` is kept alive until the link
    /// closes (a peer connection, a tunnel, a task guard).
    ///
    /// With [`LinkConfig::reliable`] a phone's link opens with its `hello`;
    /// a Mac takes a reliable link's carriers with [`Link::accept_reliable`].
    pub fn new<S>(stream: S, role: Role, config: LinkConfig, transport: Option<Box<dyn Any + Send>>) -> Self
    where
        S: AsyncRead + AsyncWrite + Send + 'static,
    {
        let token = config.reliable.as_ref().map(|_| rel::new_token());
        let inner = Self::build(role, &config, transport, token);
        if inner.reliable.is_some() && role == Role::Phone {
            let _ = inner.send_control(Frame::new(0, FrameType::Hello, inner.hello(HelloKind::New).encode()));
        }
        let (read_half, write_half) = tokio::io::split(stream);
        let tag = inner.reliable.as_ref().map(|reliable| (reliable.generation.subscribe(), 0));
        inner.run_carrier(
            tag,
            FramedWrite::new(write_half, FrameCodec),
            FramedRead::new(read_half, FrameCodec),
        );
        Self::start(inner, &config)
    }

    fn build(
        role: Role,
        config: &LinkConfig,
        transport: Option<Box<dyn Any + Send>>,
        token: Option<Token>,
    ) -> Arc<Inner> {
        let (incoming_tx, incoming_rx) = mpsc::channel(64);
        let reliable = config.reliable.clone().zip(token).map(|(config, token)| Reliable {
            config,
            token,
            state: Mutex::new(RelState::default()),
            carrier: watch::channel(Carrier::Up).0,
            generation: watch::channel(0).0,
            ack_wake: Notify::new(),
            deliver: tokio::sync::Mutex::new(()),
            bye: AtomicBool::new(false),
            heard: AtomicBool::new(false),
            stats: Mutex::new(ReliableStats::default()),
            channel_stats: Mutex::new(HashMap::new()),
        });
        Arc::new(Inner {
            role,
            reliable,
            outboxes: [Outbox::default(), Outbox::default()],
            lane: watch::channel(LaneState::Unavailable).0,
            lane_attached: AtomicBool::new(false),
            last_rx: Mutex::new(Instant::now()),
            last_traffic: Mutex::new(Instant::now()),
            channels: Mutex::new(HashMap::new()),
            next_channel: AtomicU32::new(role.first_channel()),
            next_nonce: AtomicU64::new(1),
            pings: Mutex::new(HashMap::new()),
            rtt: watch::channel(None).0,
            closed: watch::channel(None).0,
            incoming: tokio::sync::Mutex::new(incoming_rx),
            incoming_tx: Mutex::new(Some(incoming_tx)),
            tasks: Mutex::new(Vec::new()),
            transport: Mutex::new(transport),
            media: Mutex::new(None),
        })
    }

    /// The link's own tasks beside its carrier: the keepalive and, on a
    /// reliable link, the ack timer.
    fn start(inner: Arc<Inner>, config: &LinkConfig) -> Self {
        let mut tasks = Vec::new();
        if let Some(interval) = config.keepalive
            && config.aligned
        {
            let link = Self { inner: Arc::clone(&inner) };
            tasks.push(tokio::spawn(aligned_keepalive(link, interval, config.keepalive_timeout)));
        } else if let Some(interval) = config.keepalive {
            let link = Self { inner: Arc::clone(&inner) };
            let timeout = config.keepalive_timeout;
            tasks.push(tokio::spawn(async move {
                let mut closed = link.inner.closed.subscribe();
                'beat: loop {
                    tokio::select! {
                        () = tokio::time::sleep(interval) => {}
                        _ = closed.wait_for(Option::is_some) => return,
                    }
                    // A reliable link's dropped carrier is not pinged.
                    link.inner.carrier_up().await;
                    let sent = Instant::now();
                    let ping = link.ping();
                    tokio::pin!(ping);
                    loop {
                        // Wait for the pong, but count any inbound frame as
                        // life: a pong can trail a full transmit queue.
                        let deadline = link.inner.last_received().max(sent) + timeout;
                        tokio::select! {
                            result = &mut ping => {
                                if result.is_err() {
                                    return;
                                }
                                break;
                            }
                            () = tokio::time::sleep_until(deadline) => {
                                let quiet_since = link.inner.last_received().max(sent);
                                if quiet_since + timeout <= Instant::now() {
                                    if link.inner.reliable.is_some() {
                                        link.inner.lose_carrier("keepalive timed out");
                                        continue 'beat;
                                    }
                                    link.inner.shut("keepalive timed out");
                                    return;
                                }
                            }
                        }
                    }
                }
            }));
        }
        if inner.reliable.is_some() {
            let link = Arc::clone(&inner);
            tasks.push(tokio::spawn(async move {
                let Some(reliable) = &link.reliable else { return };
                let mut closed = link.closed.subscribe();
                loop {
                    tokio::select! {
                        () = reliable.ack_wake.notified() => {}
                        _ = closed.wait_for(Option::is_some) => return,
                    }
                    tokio::time::sleep(rel::ACK_DELAY).await;
                    link.flush_acks();
                }
            }));
        }
        inner.tasks.lock().unwrap_or_else(PoisonError::into_inner).extend(tasks);
        Self { inner }
    }

    /// Mac side of a reliable link: takes a new carrier, which opens with
    /// the phone's `hello`. A new link is [`Accepted::New`] (serve it like
    /// any link); a resume moves the carrier into the link it names
    /// ([`Accepted::Resumed`], already being served), which replays what the
    /// phone lacks. A resume of a link this Mac no longer has is refused, and
    /// the phone opens a new link, as today.
    pub async fn accept_reliable<S>(
        stream: S,
        config: LinkConfig,
        transport: Option<Box<dyn Any + Send>>,
    ) -> Result<Accepted, LinkError>
    where
        S: AsyncRead + AsyncWrite + Send + 'static,
    {
        let registry = config
            .reliable
            .as_ref()
            .and_then(|reliable| reliable.registry.clone())
            .ok_or_else(|| LinkError::Closed("a reliable Mac link needs a resume registry".into()))?;
        let (read_half, write_half) = tokio::io::split(stream);
        let mut sink = FramedWrite::new(write_half, FrameCodec);
        let mut source = FramedRead::new(read_half, FrameCodec);
        let hello = read_hello(&mut source).await?;
        match hello.kind {
            HelloKind::New => {
                let inner = Self::build(Role::Mac, &config, transport, Some(hello.token));
                if !registry.claim(hello.token, Arc::downgrade(&inner)) {
                    return Err(LinkError::Closed("a late carrier of a link already open".into()));
                }
                let tag = inner.reliable.as_ref().map(|reliable| (reliable.generation.subscribe(), 0));
                inner.run_carrier(tag, sink, source);
                Ok(Accepted::New(Self::start(inner, &config)))
            }
            HelloKind::Resume | HelloKind::Reopen => {
                let target = registry.get(&hello.token).filter(|target| target.closed_reason().is_none());
                if target.is_none() && hello.kind == HelloKind::Reopen {
                    // The link's first carrier dropped before this Mac read
                    // its `New`: open it now. The phone replays all of it.
                    let inner = Self::build(Role::Mac, &config, transport, Some(hello.token));
                    if !registry.claim(hello.token, Arc::downgrade(&inner)) {
                        return Err(LinkError::Closed("another carrier opened the link".into()));
                    }
                    sink.send(Frame::new(0, FrameType::Hello, inner.hello(HelloKind::ResumeOk).encode()))
                        .await
                        .map_err(|error| LinkError::Closed(format!("reopen failed: {error}")))?;
                    let tag = inner.reliable.as_ref().map(|reliable| (reliable.generation.subscribe(), 0));
                    inner.run_carrier(tag, sink, source);
                    return Ok(Accepted::New(Self::start(inner, &config)));
                }
                let Some(target) = target else {
                    let refused = Hello {
                        kind: HelloKind::Refused,
                        token: hello.token,
                        max_peer_opened: 0,
                        cursors: Vec::new(),
                    };
                    let _ = sink.send(Frame::new(0, FrameType::Hello, refused.encode())).await;
                    return Err(LinkError::Closed("no link to resume".into()));
                };
                // The old carrier may not have noticed it is gone yet.
                target.lose_carrier("the phone resumed over a new carrier");
                let reliable = target.reliable.as_ref().expect("a registered link is reliable");
                let generation = *reliable.generation.borrow();
                let ok = target.hello(HelloKind::ResumeOk);
                sink.send(Frame::new(0, FrameType::Hello, ok.encode()))
                    .await
                    .map_err(|error| LinkError::Closed(format!("resume failed: {error}")))?;
                target.replay(&mut sink, &hello).await?;
                if *reliable.generation.borrow() != generation || target.closed_reason().is_some() {
                    return Err(LinkError::Closed("another carrier resumed the link".into()));
                }
                *target.transport.lock().unwrap_or_else(PoisonError::into_inner) = transport;
                reliable.stats().resumes += 1;
                target.run_carrier(Some((reliable.generation.subscribe(), generation)), sink, source);
                Ok(Accepted::Resumed(Self { inner: target }))
            }
            HelloKind::ResumeOk | HelloKind::Refused => Err(LinkError::Closed("unexpected hello".into())),
        }
    }

    /// Phone side of a reliable link: resume it over a new carrier
    /// (`stream`, from a new dial; `transport` as in [`Link::new`]). Sends
    /// this side's cursors, waits one round trip for the Mac's, replays
    /// only what the Mac lacks, and the channels carry on where they were.
    /// When the Mac no longer has the link, the link closes as today and the
    /// caller opens a new one.
    pub async fn resume<S>(
        &self,
        stream: S,
        transport: Option<Box<dyn Any + Send>>,
    ) -> Result<ResumeReport, LinkError>
    where
        S: AsyncRead + AsyncWrite + Send + 'static,
    {
        let Some(reliable) = &self.inner.reliable else {
            return Err(LinkError::Closed("not a reliable link".into()));
        };
        if self.is_closed() {
            return Err(self.inner.closed_error());
        }
        let started = Instant::now();
        self.inner.lose_carrier("resuming over a new carrier");
        let generation = *reliable.generation.borrow();
        let (read_half, write_half) = tokio::io::split(stream);
        let mut sink = FramedWrite::new(write_half, FrameCodec);
        let mut source = FramedRead::new(read_half, FrameCodec);
        // Until the Mac is heard on this link it may never have read the
        // link's `New` (the first carrier dropped first).
        let kind = if reliable.heard.load(Ordering::Acquire) { HelloKind::Resume } else { HelloKind::Reopen };
        let hello = self.inner.hello(kind);
        sink.send(Frame::new(0, FrameType::Hello, hello.encode()))
            .await
            .map_err(|error| LinkError::Closed(format!("resume failed: {error}")))?;
        let reply = read_hello(&mut source).await?;
        match reply.kind {
            HelloKind::ResumeOk if reply.token == reliable.token => {
                reliable.heard.store(true, Ordering::Release);
            }
            HelloKind::Refused => {
                self.inner.shut("the Mac no longer has this link");
                return Err(self.inner.closed_error());
            }
            _ => return Err(LinkError::Closed("unexpected hello".into())),
        }
        if *reliable.generation.borrow() != generation || self.is_closed() {
            return Err(LinkError::Closed("another carrier resumed the link".into()));
        }
        let before = *reliable.stats();
        self.inner.replay(&mut sink, &reply).await?;
        *self.inner.transport.lock().unwrap_or_else(PoisonError::into_inner) = transport;
        self.inner.run_carrier(Some((reliable.generation.subscribe(), generation)), sink, source);
        let mut stats = reliable.stats();
        stats.resumes += 1;
        stats.resume_round_trips = 1;
        Ok(ResumeReport {
            round_trips: 1,
            replayed_frames: stats.replayed_frames - before.replayed_frames,
            replayed_bytes: stats.replayed_bytes - before.replayed_bytes,
            took: started.elapsed(),
        })
    }

    /// A reliable link's counters (`None` without it).
    pub fn reliable_stats(&self) -> Option<ReliableStats> {
        let reliable = self.inner.reliable.as_ref()?;
        let mut stats = *reliable.stats();
        stats.unacked_bytes = reliable.lock().log.bytes() as u64;
        Some(stats)
    }

    /// Channel `id`'s share of a reliable link's resumes (`None` without it).
    pub fn channel_resume(&self, id: u32) -> Option<ChannelResume> {
        let reliable = self.inner.reliable.as_ref()?;
        let channels = reliable.channel_stats.lock().unwrap_or_else(PoisonError::into_inner);
        Some(channels.get(&id).copied().unwrap_or_default())
    }

    /// Whether a reliable link's carrier is up (`None` without it). A
    /// dropped carrier waits for [`Link::resume`] (phone) or
    /// [`Link::accept_reliable`] (Mac) up to the resume window.
    pub fn carrier(&self) -> Option<watch::Receiver<Carrier>> {
        self.inner.reliable.as_ref().map(|reliable| reliable.carrier.subscribe())
    }

    /// Drops the current carrier now, as if the network had (tests, and a
    /// phone that knows its path changed).
    pub fn drop_carrier(&self, reason: &str) {
        self.inner.lose_carrier(reason);
    }

    /// Attaches the media lane the dial negotiated.
    pub fn attach_media(&self, lane: crate::media::MediaLane) {
        *self.inner.media.lock().unwrap_or_else(PoisonError::into_inner) = Some(lane);
    }

    /// The media lane (browser video as RTP), if this link has one.
    pub fn media(&self) -> Option<crate::media::MediaLane> {
        self.inner.media.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    pub fn role(&self) -> Role {
        self.inner.role
    }

    /// The input lane was negotiated and its stream is on the way. Until
    /// [`Link::attach_input_lane`] (or [`Link::input_lane_failed`]), opening
    /// an input-lane channel waits briefly for it.
    pub fn expect_input_lane(&self) {
        // A reliable link resumes one stream: its input-lane channels ride
        // the main stream at input priority.
        if !self.is_closed() && self.inner.reliable.is_none() {
            self.inner.lane.send_if_modified(|state| {
                let changed = *state == LaneState::Unavailable;
                if changed {
                    *state = LaneState::Pending;
                }
                changed
            });
        }
    }

    /// The negotiated input lane could not be opened: input-lane channels
    /// ride the main stream.
    pub fn input_lane_failed(&self, why: &str) {
        let changed = self.inner.lane.send_if_modified(|state| {
            let changed = *state == LaneState::Pending;
            if changed {
                *state = LaneState::Unavailable;
            }
            changed
        });
        if changed {
            tracing::info!(why, "input lane unavailable; input rides the main stream");
        }
    }

    /// Run the input lane over `stream` (the second data channel or TCP
    /// stream of the same transport). A second attach is ignored.
    pub fn attach_input_lane<S>(&self, stream: S)
    where
        S: AsyncRead + AsyncWrite + Send + 'static,
    {
        if self.is_closed()
            || self.inner.reliable.is_some()
            || self.inner.lane_attached.swap(true, Ordering::AcqRel)
        {
            return;
        }
        let (read_half, write_half) = tokio::io::split(stream);
        // Channels the peer opens on the lane arrive through the same
        // accept queue.
        let Some(incoming) = self.inner.incoming_tx.lock().unwrap_or_else(PoisonError::into_inner).clone()
        else {
            return;
        };
        let writer = tokio::spawn(write_loop(
            Arc::clone(&self.inner),
            INPUT,
            FramedWrite::new(write_half, FrameCodec),
            None,
        ));
        let reader = tokio::spawn(read_loop(
            Arc::clone(&self.inner),
            INPUT,
            FramedRead::new(read_half, FrameCodec),
            incoming,
            None,
        ));
        // The lane is used only once the peer is heard on it: each side
        // says hello (a ping) when it attaches, and the first frame that
        // arrives on the lane confirms it. A lane only one side attached
        // (one side's 10 s wait ran out) is never used.
        self.inner.lane.send_if_modified(|state| {
            let changed = *state == LaneState::Unavailable;
            if changed {
                *state = LaneState::Pending;
            }
            changed
        });
        let _ = self.inner.push(
            INPUT,
            Class::Control,
            Frame::new(0, FrameType::Ping, 0u64.to_be_bytes().to_vec()),
        );
        let link = self.clone();
        let confirm = tokio::spawn(async move {
            let mut state = link.inner.lane.subscribe();
            let confirmed =
                tokio::time::timeout(LANE_CONFIRM, state.wait_for(|state| *state != LaneState::Pending))
                    .await;
            if confirmed.is_err() {
                link.input_lane_failed("the peer never answered on the lane");
            }
        });
        self.inner.tasks.lock().unwrap_or_else(PoisonError::into_inner).extend([writer, reader, confirm]);
        tracing::debug!(role = ?self.inner.role, "input lane attached");
    }

    /// The input lane's state.
    pub fn input_lane(&self) -> LaneState {
        *self.inner.lane.borrow()
    }

    /// Open a channel to `service` on the main stream. A refusal arrives as
    /// a `Closed` event.
    pub async fn open(&self, service: &str, args: serde_json::Value) -> Result<Channel, LinkError> {
        self.open_on(service, args, Lane::Bulk).await
    }

    /// Open a channel on `lane`. An input-lane channel rides the input lane
    /// when the link has one (waiting up to 2 s for a lane that is still
    /// opening), else the main stream ahead of bulk data. The `open` frame
    /// carries the lane, so the peer schedules its replies the same way.
    pub async fn open_on(
        &self,
        service: &str,
        args: serde_json::Value,
        lane: Lane,
    ) -> Result<Channel, LinkError> {
        let stream = match lane {
            Lane::Bulk => MAIN,
            Lane::Input => {
                let mut state = self.inner.lane.subscribe();
                let settled =
                    tokio::time::timeout(LANE_WAIT, state.wait_for(|state| *state != LaneState::Pending))
                        .await;
                match settled {
                    Ok(Ok(state)) if *state == LaneState::Ready => INPUT,
                    _ => MAIN,
                }
            }
        };
        let class = Class::from(lane);
        let id = self.inner.next_channel.fetch_add(2, Ordering::Relaxed);
        let (tx, rx) = mpsc::channel(CHANNEL_DEPTH);
        let closed = Arc::new(AtomicBool::new(false));
        let inbox = Inbox::new(tx, &self.inner, stream, id);
        if let Some(reliable) = &self.inner.reliable {
            reliable.lock().cursors.open(id);
        }
        self.inner.lock_channels().insert(id, Route { inbox, closed: Arc::clone(&closed) });
        let payload = serde_json::to_vec(&OpenRequest { service: service.to_owned(), args, lane })
            .expect("open request serializes");
        if let Err(error) = self.inner.push(stream, class, Frame::new(id, FrameType::Open, payload)) {
            self.inner.lock_channels().remove(&id);
            return Err(error);
        }
        Ok(Channel::new(id, stream, class, Arc::clone(&self.inner), rx, closed))
    }

    /// The next channel the peer opened, or `None` once the link is closed.
    pub async fn accept(&self) -> Option<IncomingChannel> {
        self.inner.incoming.lock().await.recv().await
    }

    /// Round-trip one ping.
    pub async fn ping(&self) -> Result<Duration, LinkError> {
        let nonce = self.inner.next_nonce.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        self.inner.pings.lock().unwrap_or_else(PoisonError::into_inner).insert(nonce, tx);
        // A caller that stops waiting (a probe's timeout) takes its entry out.
        struct Pending<'a>(&'a Inner, u64);
        impl Drop for Pending<'_> {
            fn drop(&mut self) {
                self.0.pings.lock().unwrap_or_else(PoisonError::into_inner).remove(&self.1);
            }
        }
        let _pending = Pending(&self.inner, nonce);
        let started = Instant::now();
        self.inner.send_control(Frame::new(0, FrameType::Ping, nonce.to_be_bytes().to_vec()))?;
        let answered = rx
            .await
            .map_err(|_| LinkError::Closed(self.inner.closed_reason().unwrap_or_else(|| "closed".into())))?;
        let rtt = answered.saturating_duration_since(started);
        self.inner.rtt.send_replace(Some(rtt));
        Ok(rtt)
    }

    /// Whether the link is alive, within `timeout`: `Ok(Some(rtt))` on the
    /// pong, `Ok(None)` as soon as any other frame arrives after the ping went
    /// out (a pong can trail a full transmit queue on a slow relay; the link's
    /// own keepalive counts any inbound frame as life too), `Err(Timeout)`
    /// only when nothing at all came back, `Err(Closed)` once closed.
    ///
    /// Any frame proves only the peer-to-us direction: a link whose uplink
    /// alone broke still reads alive here until the peer's own keepalive
    /// closes it (15 s ping, 20 s timeout), the bound the link already had.
    pub async fn probe(&self, timeout: Duration) -> Result<Option<Duration>, LinkError> {
        /// How often arrivals are checked while the pong is outstanding.
        const TRAFFIC_CHECK: Duration = Duration::from_millis(50);
        let sent = Instant::now();
        let deadline = sent + timeout;
        let ping = self.ping();
        tokio::pin!(ping);
        loop {
            let next = (Instant::now() + TRAFFIC_CHECK).min(deadline);
            tokio::select! {
                // The pong (or the close) first when both are ready.
                biased;
                result = &mut ping => return result.map(Some),
                () = tokio::time::sleep_until(next) => {
                    if self.inner.last_received() > sent {
                        return Ok(None);
                    }
                    if Instant::now() >= deadline {
                        return Err(LinkError::Timeout);
                    }
                }
            }
        }
    }

    /// The latest measured round-trip time.
    pub fn rtt(&self) -> watch::Receiver<Option<Duration>> {
        self.inner.rtt.subscribe()
    }

    /// `Some(reason)` once closed.
    pub fn closed_state(&self) -> watch::Receiver<Option<String>> {
        self.inner.closed.subscribe()
    }

    pub fn is_closed(&self) -> bool {
        self.inner.closed_reason().is_some()
    }

    /// How long ago the reader last received any frame (a pong, channel
    /// data, a control frame). Measured where frames arrive, so a channel
    /// whose reader lags its buffer still shows a dead link going quiet.
    pub fn received_ago(&self) -> Duration {
        self.inner.last_received().elapsed()
    }

    /// How long ago the reader last received a frame other than a ping or a
    /// pong. A link whose only frames are keepalives is idle: with Align
    /// Keepalives on, the foreground heartbeat probes it on the beat.
    pub fn traffic_ago(&self) -> Duration {
        self.inner.last_traffic.lock().unwrap_or_else(PoisonError::into_inner).elapsed()
    }

    /// Resolves with the reason once the link is closed.
    pub async fn closed(&self) -> String {
        let mut state = self.inner.closed.subscribe();
        match state.wait_for(Option::is_some).await {
            Ok(reason) => reason.clone().unwrap_or_default(),
            Err(_) => "closed".into(),
        }
    }

    /// Close the link and its transport.
    pub fn close(&self, reason: &str) {
        if let Some(reliable) = &self.inner.reliable {
            // The peer closes too instead of waiting for a resume.
            reliable.bye.store(true, Ordering::Release);
        }
        self.inner.shut(reason);
    }
}

async fn write_loop<W>(
    inner: Arc<Inner>,
    stream: usize,
    mut sink: FramedWrite<W, FrameCodec>,
    mut tag: CarrierTag,
) where
    W: AsyncWrite + Send + Unpin,
{
    let outbox = &inner.outboxes[stream];
    loop {
        // Highest priority first; feed what is queued, flushing every
        // FLUSH_BYTES so the transport sees frames in priority order. A
        // reliable link logs each channel frame as it is taken (`seal`), so
        // a carrier that drops mid-write loses nothing: the next replays it.
        let next = tokio::select! {
            next = outbox.next() => next,
            () = superseded(&mut tag) => return,
        };
        let frame = match next {
            Next::Frame(frame) => frame,
            Next::Shutdown => {
                say_bye(&inner, &mut sink).await;
                let _ = sink.close().await;
                return;
            }
        };
        let Some(frame) = inner.seal(frame) else { continue };
        let batch = async {
            let mut pending = frame.payload.len();
            let mut result = sink.feed(frame).await;
            let mut shutdown = false;
            while result.is_ok() && pending < FLUSH_BYTES {
                match outbox.pop() {
                    Some(Next::Frame(frame)) => {
                        let Some(frame) = inner.seal(frame) else { continue };
                        pending += frame.payload.len();
                        result = sink.feed(frame).await;
                    }
                    Some(Next::Shutdown) => {
                        shutdown = true;
                        break;
                    }
                    None => break,
                }
            }
            if shutdown {
                let _ = sink.flush().await;
                say_bye(&inner, &mut sink).await;
                let _ = sink.close().await;
                return None;
            }
            Some(result.and(sink.flush().await))
        };
        let written = tokio::select! {
            written = batch => written,
            () = superseded(&mut tag) => return,
        };
        match written {
            None => return,
            Some(Ok(())) => {}
            Some(Err(error)) => {
                inner.carrier_failed(&tag, &format!("write failed: {error}"));
                return;
            }
        }
    }
}

/// A reliable link closed on purpose tells the peer, so it closes too
/// instead of waiting for a resume.
async fn say_bye<W>(inner: &Inner, sink: &mut FramedWrite<W, FrameCodec>)
where
    W: AsyncWrite + Send + Unpin,
{
    if inner.reliable.as_ref().is_some_and(|reliable| reliable.bye.load(Ordering::Acquire)) {
        let _ = sink.send(Frame::new(0, FrameType::Bye, Bytes::new())).await;
    }
}

/// The keepalive with Align Keepalives on: a ping on every beat of
/// `interval` ([`crate::keepalive::next_beat`]), whether or not the last one
/// was answered, so the link's datagrams keep the beat even while a pong is
/// late. The link closes, as with the unaligned keepalive, only when
/// nothing at all arrived for `timeout` after the oldest ping that no frame
/// has answered since.
async fn aligned_keepalive(link: Link, interval: Duration, timeout: Duration) {
    let mut closed = link.inner.closed.subscribe();
    // When the oldest ping that no inbound frame followed went out.
    let mut unanswered: Option<Instant> = None;
    let mut beat = crate::keepalive::next_beat(Instant::now(), interval);
    loop {
        if unanswered.is_some_and(|sent| link.inner.last_received() >= sent) {
            unanswered = None;
        }
        let deadline = unanswered.map(|sent| link.inner.last_received().max(sent) + timeout);
        tokio::select! {
            _ = closed.wait_for(Option::is_some) => return,
            () = tokio::time::sleep_until(beat) => {
                if link.inner.carrier_is_down() {
                    // A reliable link's dropped carrier is not pinged.
                    unanswered = None;
                    beat = crate::keepalive::next_beat(beat, interval);
                    continue;
                }
                // The pinger waits one beat for its pong (the RTT it reports);
                // any frame, the pong too, counts as the answer above.
                let pinger = link.clone();
                tokio::spawn(async move {
                    let _ = tokio::time::timeout(interval, pinger.ping()).await;
                });
                unanswered.get_or_insert(beat);
                beat = crate::keepalive::next_beat(beat, interval);
            }
            () = tokio::time::sleep_until(deadline.unwrap_or(beat)), if deadline.is_some() => {
                if let Some(sent) = unanswered
                    && link.inner.last_received() < sent
                    && sent + timeout <= Instant::now()
                {
                    if link.inner.reliable.is_some() {
                        link.inner.lose_carrier("keepalive timed out");
                        unanswered = None;
                        continue;
                    }
                    link.inner.shut("keepalive timed out");
                    return;
                }
            }
        }
    }
}

async fn read_loop<R>(
    inner: Arc<Inner>,
    stream: usize,
    mut source: FramedRead<R, FrameCodec>,
    incoming: mpsc::Sender<IncomingChannel>,
    mut tag: CarrierTag,
) where
    R: AsyncRead + Send + Unpin,
{
    let reason = loop {
        let next = tokio::select! {
            // A carrier that is over reads no more.
            biased;
            () = superseded(&mut tag) => return,
            next = source.next() => next,
        };
        let frame = match next {
            Some(Ok(frame)) => frame,
            Some(Err(error)) => break format!("read failed: {error}"),
            None => break "peer closed the link".to_owned(),
        };
        inner.received();
        if !matches!(frame.kind, FrameType::Ping | FrameType::Pong) {
            inner.received_traffic();
        }
        if stream == INPUT {
            // The peer is heard on the lane: use it.
            inner.lane.send_if_modified(|state| {
                let changed = *state == LaneState::Pending;
                if changed {
                    *state = LaneState::Ready;
                }
                changed
            });
        }
        if let Some(reliable) = &inner.reliable {
            reliable.heard.store(true, Ordering::Release);
            if let Err(reason) = handle_reliable(&inner, stream, frame, &incoming).await {
                inner.shut(&reason);
                return;
            }
        } else {
            handle_frame(&inner, stream, frame, &incoming).await;
        }
    };
    inner.carrier_failed(&tag, &reason);
}

/// One inbound frame of a reliable link: a channel frame is delivered once,
/// in order, whatever carrier it came on. `Err`: the link ends.
async fn handle_reliable(
    inner: &Arc<Inner>,
    stream: usize,
    frame: Frame,
    incoming: &mpsc::Sender<IncomingChannel>,
) -> Result<(), String> {
    let reliable = inner.reliable.as_ref().expect("a reliable link");
    match frame.kind {
        FrameType::Seq => {
            let channel = frame.channel;
            let (sequence, kind, payload) =
                rel::open_seq(frame.payload).ok_or_else(|| format!("bad seq frame on channel {channel}"))?;
            let _turn = reliable.deliver.lock().await;
            let (verdict, flush) = {
                let mut state = reliable.lock();
                let peer_opens = kind == FrameType::Open && inner.role.peer_owns(channel);
                let new_stream = peer_opens && channel > state.max_peer_opened;
                let verdict = state.cursors.accept(channel, sequence, new_stream);
                let mut flush = false;
                match verdict {
                    Inbound::Deliver => {
                        if peer_opens {
                            state.max_peer_opened = state.max_peer_opened.max(channel);
                        }
                        if kind == FrameType::Close {
                            // The peer is done with the channel: what this side
                            // still holds or queues for it is moot.
                            state.cursors.close(channel);
                            state.log.forget(channel);
                            state.forgotten.insert(channel);
                        }
                        state.pending.insert(channel, sequence);
                        state.pending_bytes += payload.len() + 9;
                        flush = state.pending_bytes >= rel::ACK_BYTES;
                    }
                    Inbound::Duplicate => {
                        if let Some(cursor) = state.cursors.get(channel) {
                            state.pending.insert(channel, cursor);
                        }
                    }
                    Inbound::Unknown | Inbound::Gap { .. } => {}
                }
                (verdict, flush)
            };
            match verdict {
                Inbound::Deliver => {
                    if flush {
                        inner.flush_acks();
                    } else {
                        reliable.ack_wake.notify_one();
                    }
                    if kind == FrameType::Close {
                        for outbox in &inner.outboxes {
                            outbox.room.notify_waiters();
                        }
                    }
                    handle_frame(inner, stream, Frame { channel, kind, payload }, incoming).await;
                }
                Inbound::Duplicate => {
                    reliable.stats().duplicates_dropped += 1;
                    reliable.ack_wake.notify_one();
                }
                Inbound::Unknown => {}
                Inbound::Gap { expected } => {
                    return Err(format!("channel {channel} skipped from {expected} to {sequence}"));
                }
            }
        }
        FrameType::Ack => {
            let acks = rel::open_ack(frame.payload).ok_or("bad ack frame")?;
            let mut freed = 0;
            {
                let mut state = reliable.lock();
                for (channel, sequence) in acks {
                    freed += state.log.ack(channel, sequence);
                }
            }
            if freed > 0 {
                for outbox in &inner.outboxes {
                    outbox.room.notify_waiters();
                }
            }
        }
        FrameType::Bye => return Err("peer closed the link".into()),
        // A phone's opening hello (a Mac built with `Link::new`): nothing to do.
        FrameType::Hello => {}
        _ => handle_frame(inner, stream, frame, incoming).await,
    }
    Ok(())
}

/// One inbound frame, as every link handles it.
async fn handle_frame(
    inner: &Arc<Inner>,
    stream: usize,
    frame: Frame,
    incoming: &mpsc::Sender<IncomingChannel>,
) {
    match frame.kind {
        FrameType::Ping => {
            let _ = inner.push(stream, Class::Control, Frame::new(0, FrameType::Pong, frame.payload));
        }
        FrameType::Pong => {
            if let Ok(bytes) = <[u8; 8]>::try_from(&frame.payload[..]) {
                let nonce = u64::from_be_bytes(bytes);
                let waiter = inner.pings.lock().unwrap_or_else(PoisonError::into_inner).remove(&nonce);
                if let Some(waiter) = waiter {
                    let _ = waiter.send(Instant::now());
                }
            }
        }
        FrameType::Open => {
            if !inner.role.peer_owns(frame.channel) || inner.lock_channels().contains_key(&frame.channel) {
                refuse(inner, stream, frame.channel, "bad_channel", "channel id is not the peer's or in use");
                return;
            }
            let Ok(request) = serde_json::from_slice::<OpenRequest>(&frame.payload) else {
                refuse(inner, stream, frame.channel, "bad_request", "open payload is not JSON");
                return;
            };
            // Replies go back on the stream the open came on, at the
            // priority of the lane the peer asked for.
            let class = Class::from(request.lane);
            let (tx, rx) = mpsc::channel(CHANNEL_DEPTH);
            let closed = Arc::new(AtomicBool::new(false));
            let inbox = Inbox::new(tx, inner, stream, frame.channel);
            inner.lock_channels().insert(frame.channel, Route { inbox, closed: Arc::clone(&closed) });
            let channel = Channel::new(frame.channel, stream, class, Arc::clone(inner), rx, closed);
            let accepted =
                IncomingChannel { service: request.service, args: request.args, lane: request.lane, channel };
            if incoming.send(accepted).await.is_err() {
                // Nobody accepts; the channel's drop refuses it.
            }
        }
        FrameType::Data => {
            let inbox = inner.lock_channels().get(&frame.channel).map(|route| route.inbox.clone());
            if let Some(inbox) = inbox {
                // The reader never waits on one channel's owner (see
                // `Inbox`), only on a channel holding its whole buffer.
                // Past the stall budget that channel is closed `overflow`
                // on both sides and the link goes on.
                if inbox.owner_gone() {
                    inner.lock_channels().remove(&frame.channel);
                } else if !inbox.push(ChannelEvent::Data(frame.payload)).await
                    && inner.lock_channels().remove(&frame.channel).is_some()
                {
                    tracing::warn!(
                        channel = frame.channel,
                        "channel held {CHANNEL_BUFFER_BYTES} bytes for {CHANNEL_STALL:?}; closing it"
                    );
                    refuse(inner, stream, frame.channel, "overflow", "the channel was not read");
                }
            }
        }
        // Reliable-link frames outside a reliable link: ignored.
        FrameType::Seq | FrameType::Ack | FrameType::Hello | FrameType::Bye => {}
        FrameType::Close => {
            let info = serde_json::from_slice::<CloseInfo>(&frame.payload)
                .unwrap_or_else(|_| CloseInfo::new("closed", ""));
            let route = inner.lock_channels().remove(&frame.channel);
            if let Some(route) = route {
                // The peer is gone from this channel: our sends stop, a
                // send waiting for room included, and no close goes back.
                route.closed.store(true, Ordering::Release);
                for outbox in &inner.outboxes {
                    outbox.room.notify_waiters();
                }
                route.inbox.push_now(ChannelEvent::Closed(info));
            }
        }
    }
}

/// Refuse or end `channel` with a `close` frame on `stream`, ahead of data.
fn refuse(inner: &Inner, stream: usize, channel: u32, code: &str, reason: &str) {
    let payload = serde_json::to_vec(&CloseInfo::new(code, reason)).expect("close serializes");
    let _ = inner.push(stream, Class::Control, Frame::new(channel, FrameType::Close, payload));
}

/// Payload byte totals one or more channels add to: what their senders queued
/// for the peer and what their receivers handed to the owner. Opt-in
/// ([`ChannelSender::count_into`], [`ChannelReceiver::count_into`]); a channel
/// without one counts nothing. One relaxed atomic add per chunk, no lock and no
/// allocation, so a meter shared by every channel of a kind costs the same at
/// any rate.
#[derive(Debug, Default)]
pub struct ByteMeter {
    received: AtomicU64,
    sent: AtomicU64,
}

impl ByteMeter {
    /// Payload bytes received so far.
    pub fn received(&self) -> u64 {
        self.received.load(Ordering::Relaxed)
    }

    /// Payload bytes sent so far.
    pub fn sent(&self) -> u64 {
        self.sent.load(Ordering::Relaxed)
    }

    /// Adds `bytes` received (also for traffic that does not ride a channel).
    pub fn add_received(&self, bytes: usize) {
        self.received.fetch_add(bytes as u64, Ordering::Relaxed);
    }

    /// Adds `bytes` sent (also for traffic that does not ride a channel: a media lane's frames).
    pub fn add_sent(&self, bytes: usize) {
        self.sent.fetch_add(bytes as u64, Ordering::Relaxed);
    }
}

/// Sending half of a channel.
pub struct ChannelSender {
    id: u32,
    stream: usize,
    class: Class,
    inner: Arc<Inner>,
    /// Set by our close or drop, or by the peer's close (see [`Route`]).
    closed: Arc<AtomicBool>,
    /// Where queued payload bytes are counted, if anywhere.
    meter: Option<Arc<ByteMeter>>,
}

impl ChannelSender {
    pub fn id(&self) -> u32 {
        self.id
    }

    /// The lane this channel rides.
    pub fn lane(&self) -> Lane {
        if self.class == Class::Input { Lane::Input } else { Lane::Bulk }
    }

    /// Whether this channel's frames travel on the input lane's own stream
    /// (not the main stream).
    pub fn on_input_stream(&self) -> bool {
        self.stream == INPUT
    }

    /// Counts every payload byte this sender queues from now on into `meter`.
    pub fn count_into(&mut self, meter: Arc<ByteMeter>) {
        self.meter = Some(meter);
    }

    /// Send bytes; writes are split into [`DATA_CHUNK`] frames, and a
    /// channel with [`CHANNEL_QUEUE_BYTES`] already queued waits for room.
    pub async fn send(&self, data: Bytes) -> Result<(), LinkError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(LinkError::ChannelClosed);
        }
        let mut rest = data;
        while !rest.is_empty() {
            let chunk = rest.split_to(rest.len().min(DATA_CHUNK));
            if self.inner.closed_reason().is_some() {
                return Err(self.inner.closed_error());
            }
            let size = chunk.len();
            let frame = Frame::new(self.id, FrameType::Data, chunk);
            let budget =
                self.inner.reliable.as_ref().map_or(usize::MAX, |r| r.config.replay_bytes_per_channel);
            let logged = |channel| self.inner.logged_bytes(channel);
            match self.inner.outboxes[self.stream]
                .push_data(self.class, frame, &self.closed, &logged, budget)
                .await
            {
                Pushed::Queued => {
                    if let Some(meter) = &self.meter {
                        meter.add_sent(size);
                    }
                }
                Pushed::Shutdown => return Err(self.inner.closed_error()),
                Pushed::ChannelClosed => return Err(LinkError::ChannelClosed),
            }
        }
        Ok(())
    }

    /// Close the channel with `code` and `reason`. Idempotent. The close
    /// follows the channel's queued data.
    pub async fn close(&self, code: &str, reason: &str) {
        if self.closed.swap(true, Ordering::AcqRel) {
            return;
        }
        self.inner.lock_channels().remove(&self.id);
        let payload = serde_json::to_vec(&CloseInfo::new(code, reason)).expect("close serializes");
        let _ = self.inner.push(self.stream, self.class, Frame::new(self.id, FrameType::Close, payload));
        // A send of this channel waiting for room gives up now, not when the link moves again.
        self.inner.outboxes[self.stream].room.notify_waiters();
    }
}

impl Drop for ChannelSender {
    fn drop(&mut self) {
        if !self.closed.swap(true, Ordering::AcqRel) {
            self.inner.lock_channels().remove(&self.id);
            let payload = serde_json::to_vec(&CloseInfo::new("dropped", "")).expect("close serializes");
            let _ = self.inner.push(self.stream, self.class, Frame::new(self.id, FrameType::Close, payload));
        }
    }
}

/// Receiving half of a channel.
pub struct ChannelReceiver {
    rx: mpsc::Receiver<ChannelEvent>,
    done: bool,
    /// Where delivered payload bytes are counted, if anywhere.
    meter: Option<Arc<ByteMeter>>,
}

impl ChannelReceiver {
    /// Counts every payload byte this receiver delivers from now on into `meter`.
    pub fn count_into(&mut self, meter: Arc<ByteMeter>) {
        self.meter = Some(meter);
    }

    /// The next event; `None` after `Closed` was delivered.
    pub async fn recv(&mut self) -> Option<ChannelEvent> {
        if self.done {
            return None;
        }
        match self.rx.recv().await {
            Some(event) => {
                match &event {
                    ChannelEvent::Data(data) => {
                        if let Some(meter) = &self.meter {
                            meter.add_received(data.len());
                        }
                    }
                    ChannelEvent::Closed(_) => self.done = true,
                }
                Some(event)
            }
            None => {
                self.done = true;
                Some(ChannelEvent::Closed(CloseInfo::new("link_closed", "")))
            }
        }
    }
}

/// One multiplexed channel.
pub struct Channel {
    pub sender: ChannelSender,
    pub receiver: ChannelReceiver,
}

impl Channel {
    fn new(
        id: u32,
        stream: usize,
        class: Class,
        inner: Arc<Inner>,
        rx: mpsc::Receiver<ChannelEvent>,
        closed: Arc<AtomicBool>,
    ) -> Self {
        Self {
            sender: ChannelSender { id, stream, class, inner, closed, meter: None },
            receiver: ChannelReceiver { rx, done: false, meter: None },
        }
    }

    pub fn id(&self) -> u32 {
        self.sender.id
    }

    pub fn lane(&self) -> Lane {
        self.sender.lane()
    }

    pub fn split(self) -> (ChannelSender, ChannelReceiver) {
        (self.sender, self.receiver)
    }

    pub async fn send(&self, data: impl Into<Bytes>) -> Result<(), LinkError> {
        self.sender.send(data.into()).await
    }

    pub async fn recv(&mut self) -> Option<ChannelEvent> {
        self.receiver.recv().await
    }

    pub async fn close(&self, code: &str, reason: &str) {
        self.sender.close(code, reason).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pair() -> (Link, Link) {
        let (a, b) = tokio::io::duplex(64 * 1024);
        (
            Link::new(a, Role::Phone, LinkConfig::default(), None),
            Link::new(b, Role::Mac, LinkConfig::default(), None),
        )
    }

    /// A carrier the test can cut: two duplexes with a pump between; a cut
    /// loses whatever is in flight, as a dropped path does.
    fn cuttable() -> (tokio::io::DuplexStream, tokio::io::DuplexStream, Vec<JoinHandle<()>>) {
        let (a, pump_a) = tokio::io::duplex(64 * 1024);
        let (pump_b, b) = tokio::io::duplex(64 * 1024);
        let (ra, wa) = tokio::io::split(pump_a);
        let (rb, wb) = tokio::io::split(pump_b);
        let copy = |mut r: tokio::io::ReadHalf<tokio::io::DuplexStream>,
                    mut w: tokio::io::WriteHalf<tokio::io::DuplexStream>| {
            tokio::spawn(async move {
                use tokio::io::{AsyncReadExt, AsyncWriteExt};
                // About 16 MB/s with a chunk held in the path each
                // millisecond, so a cut always lands mid-stream and loses it.
                let mut buf = vec![0u8; 16 * 1024];
                while let Ok(n) = r.read(&mut buf).await {
                    tokio::time::sleep(Duration::from_millis(1)).await;
                    if n == 0 || w.write_all(&buf[..n]).await.is_err() {
                        return;
                    }
                }
            })
        };
        let pumps = vec![copy(ra, wb), copy(rb, wa)];
        (a, b, pumps)
    }

    /// The reliable link: a carrier cut mid-stream is resumed over a new one,
    /// and the channel sees every byte once, in order, both ways, without a
    /// reopen; only what the peer lacked is replayed.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn reliable_link_resumes_a_cut_carrier_without_loss_or_duplicates() {
        let registry = Arc::new(rel::ResumeRegistry::default());
        let config = LinkConfig {
            keepalive: None,
            reliable: Some(ReliableConfig {
                registry: Some(Arc::clone(&registry)),
                ..ReliableConfig::default()
            }),
            ..LinkConfig::default()
        };
        let (a, b, pumps) = cuttable();
        let phone = Link::new(a, Role::Phone, config.clone(), None);
        let mac_config = config.clone();
        let (carriers_tx, mut carriers) = mpsc::unbounded_channel::<tokio::io::DuplexStream>();
        let _ = carriers_tx.send(b);
        let server = tokio::spawn(async move {
            let mut served = Vec::new();
            while let Some(stream) = carriers.recv().await {
                match Link::accept_reliable(stream, mac_config.clone(), None).await.unwrap() {
                    Accepted::New(mac) => {
                        let mut incoming = mac.accept().await.expect("incoming");
                        served.push(tokio::spawn(async move {
                            // Echo every byte back.
                            while let Some(ChannelEvent::Data(bytes)) = incoming.channel.recv().await {
                                incoming.channel.send(bytes).await.unwrap();
                            }
                            mac
                        }));
                    }
                    Accepted::Resumed(_) => {}
                }
            }
        });
        let channel = phone.open("echo", serde_json::json!({})).await.unwrap();
        let (sender, mut receiver) = channel.split();
        let total = 4 * 1024 * 1024;
        let data: Vec<u8> = (0..total).map(|i| (i * 7 + i / 251) as u8).collect();
        let expected = data.clone();
        let writer = tokio::spawn(async move {
            for chunk in data.chunks(10_000) {
                sender.send(Bytes::copy_from_slice(chunk)).await.unwrap();
            }
            sender
        });
        let reader = tokio::spawn(async move {
            let mut got = Vec::with_capacity(total);
            while got.len() < total {
                match receiver.recv().await.unwrap() {
                    ChannelEvent::Data(bytes) => got.extend_from_slice(&bytes),
                    other => panic!("the channel saw {other:?}"),
                }
            }
            got
        });
        // Cut the carrier three times while bytes flow both ways.
        let mut pumps = pumps;
        for _ in 0..3 {
            tokio::time::sleep(Duration::from_millis(40)).await;
            for pump in pumps.drain(..) {
                pump.abort();
            }
            let (a, b, next) = cuttable();
            pumps = next;
            let _ = carriers_tx.send(b);
            let report = phone.resume(a, None).await.expect("resume");
            assert_eq!(report.round_trips, 1);
        }
        let got =
            tokio::time::timeout(Duration::from_secs(30), reader).await.expect("all bytes back").unwrap();
        assert!(got == expected, "every byte once, in order");
        let _sender = writer.await.unwrap();
        let stats = phone.reliable_stats().unwrap();
        assert_eq!(stats.resumes, 3);
        assert_eq!(
            stats.duplicates_dropped, 0,
            "only what the Mac lacked was replayed to the phone: {stats:?}"
        );
        assert!(stats.replayed_bytes <= stats.unacked_at_drop_bytes, "{stats:?}");
        assert!(stats.unacked_at_drop_bytes > 0, "the cuts came mid-stream: {stats:?}");
        assert!(
            stats.replayed_bytes > 0,
            "a cut lost bytes in flight and the resume replayed them: {stats:?}"
        );
        println!("phone {stats:?}");
        for (metric, value) in [
            ("dups", stats.duplicates_dropped as f64),
            ("holes", 0.0),
            ("reattaches", 0.0),
            ("resume_bytes", stats.replayed_bytes as f64),
            ("unacked_at_drop_bytes", stats.unacked_at_drop_bytes as f64),
            ("resume_round_trips", stats.resume_round_trips as f64),
        ] {
            println!(
                "after NETCOND {{\"surface\":\"terminal\",\"profile\":\"cut-40ms@1\",\"phase\":\"reconnect\",\"scale\":\"1x\",\"metric\":\"{metric}\",\"value\":{value},\"run\":0,\"seed\":0}}"
            );
        }
        assert!(!phone.is_closed());
        phone.close("done");
        drop(carriers_tx);
        server.await.unwrap();
    }

    /// BEFORE (today's link, `reliable: None`), the same cut: the link shuts,
    /// the channel closes mid-stream and the bytes in flight are gone, so the
    /// phone must redial, reopen and re-fetch.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn before_a_cut_carrier_closes_the_link_and_its_channels() {
        let config = LinkConfig { keepalive: None, ..LinkConfig::default() };
        let (a, b, pumps) = cuttable();
        let phone = Link::new(a, Role::Phone, config.clone(), None);
        let mac = Link::new(b, Role::Mac, config, None);
        let server = tokio::spawn(async move {
            let mut incoming = mac.accept().await.expect("incoming");
            while let Some(ChannelEvent::Data(bytes)) = incoming.channel.recv().await {
                if incoming.channel.send(bytes).await.is_err() {
                    break;
                }
            }
        });
        let channel = phone.open("echo", serde_json::json!({})).await.unwrap();
        let (sender, mut receiver) = channel.split();
        let total = 4 * 1024 * 1024;
        let writer = tokio::spawn(async move {
            let mut sent = 0usize;
            for chunk in vec![1u8; total].chunks(10_000) {
                if sender.send(Bytes::copy_from_slice(chunk)).await.is_err() {
                    break;
                }
                sent += chunk.len();
            }
            sent
        });
        tokio::time::sleep(Duration::from_millis(40)).await;
        for pump in pumps {
            pump.abort();
        }
        let mut got = 0usize;
        let closed = loop {
            match tokio::time::timeout(Duration::from_secs(10), receiver.recv()).await {
                Ok(Some(ChannelEvent::Data(bytes))) => got += bytes.len(),
                Ok(_) => break true,
                Err(_) => break false,
            }
        };
        assert!(closed, "today's channel ends with the carrier");
        let sent = writer.await.unwrap();
        tokio::time::timeout(Duration::from_secs(5), async {
            while !phone.is_closed() {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .expect("today's link shuts with its carrier");
        let lost = sent.saturating_sub(got);
        println!("before: sent {sent} echoed {got} lost {lost}");
        for (metric, value) in
            [("dups", 0.0), ("holes", lost as f64), ("reattaches", 1.0), ("resume_round_trips", f64::NAN)]
        {
            let value = if value.is_nan() { "null".to_string() } else { value.to_string() };
            println!(
                "before NETCOND {{\"surface\":\"terminal\",\"profile\":\"cut-40ms@1\",\"phase\":\"reconnect\",\"scale\":\"1x\",\"metric\":\"{metric}\",\"value\":{value},\"run\":0,\"seed\":0}}"
            );
        }
        assert!(lost > 0);
        server.abort();
    }

    fn reliable_config() -> LinkConfig {
        LinkConfig {
            keepalive: None,
            reliable: Some(ReliableConfig {
                registry: Some(Arc::new(rel::ResumeRegistry::default())),
                ..ReliableConfig::default()
            }),
            ..LinkConfig::default()
        }
    }

    /// A reliable link whose Mac no longer has it (the phone heard the Mac
    /// on it, then the Mac restarted): the resume is refused and the link
    /// closes as today.
    #[tokio::test]
    async fn a_resume_the_mac_does_not_know_is_refused() {
        let (a, b) = tokio::io::duplex(64 * 1024);
        let phone = Link::new(a, Role::Phone, reliable_config(), None);
        let Accepted::New(mac) = Link::accept_reliable(b, reliable_config(), None).await.unwrap() else {
            panic!("a new link");
        };
        let echo = tokio::spawn(async move {
            let mut incoming = mac.accept().await.expect("incoming");
            if let Some(ChannelEvent::Data(bytes)) = incoming.channel.recv().await {
                incoming.channel.send(bytes).await.unwrap();
            }
            mac
        });
        let mut channel = phone.open("echo", serde_json::json!({})).await.unwrap();
        channel.send(Bytes::from_static(b"hi")).await.unwrap();
        assert!(matches!(channel.recv().await, Some(ChannelEvent::Data(_))));
        drop(echo.await.unwrap());
        // A Mac with a new registry: it never had this link.
        let (a, b) = tokio::io::duplex(64 * 1024);
        let mac = tokio::spawn(Link::accept_reliable(b, reliable_config(), None));
        assert!(phone.resume(a, None).await.is_err());
        assert!(phone.is_closed());
        assert!(mac.await.unwrap().is_err());
    }

    /// The link's first carrier drops before the Mac reads its `New` (the
    /// phone queued it and a channel's data behind it): the phone, which
    /// never heard the Mac on the link, reopens it over the next carrier,
    /// the Mac opens it then, and every byte arrives once.
    #[tokio::test]
    async fn a_link_whose_first_carrier_dropped_before_its_hello_reopens() {
        let config = reliable_config();
        let (a, b) = tokio::io::duplex(64 * 1024);
        let phone = Link::new(a, Role::Phone, config.clone(), None);
        let mut channel = phone.open("echo", serde_json::json!({})).await.unwrap();
        channel.send(Bytes::from_static(b"before the cut")).await.unwrap();
        // The Mac never reads this carrier.
        drop(b);
        phone.drop_carrier("test cut");
        let (a, b) = tokio::io::duplex(64 * 1024);
        let mac = tokio::spawn(Link::accept_reliable(b, config.clone(), None));
        phone.resume(a, None).await.expect("reopen");
        let Accepted::New(mac) = mac.await.unwrap().expect("accept") else {
            panic!("the Mac never had the link: a new one");
        };
        let mut incoming = mac.accept().await.expect("incoming");
        assert_eq!(incoming.service, "echo");
        channel.send(Bytes::from_static(b" and after")).await.unwrap();
        let mut got = Vec::new();
        while got.len() < b"before the cut and after".len() {
            match incoming.channel.recv().await {
                Some(ChannelEvent::Data(bytes)) => got.extend_from_slice(&bytes),
                other => panic!("unexpected {other:?}"),
            }
        }
        assert_eq!(&got[..], b"before the cut and after");
        // A late `New` of the first carrier finds the link open: refused.
        let (a, b) = tokio::io::duplex(64 * 1024);
        let mut late = FramedWrite::new(a, FrameCodec);
        late.send(Frame::new(0, FrameType::Hello, phone.inner.hello(HelloKind::New).encode())).await.unwrap();
        assert!(Link::accept_reliable(b, config, None).await.is_err());
        assert!(!phone.is_closed() && !mac.is_closed());
    }

    #[tokio::test]
    async fn open_echo_close_and_ping() {
        let (phone, mac) = pair();
        let server = tokio::spawn(async move {
            let mut incoming = mac.accept().await.expect("incoming");
            assert_eq!(incoming.service, "echo");
            assert_eq!(incoming.args["x"], 1);
            assert_eq!(incoming.channel.id() % 2, 1);
            while let Some(ChannelEvent::Data(bytes)) = incoming.channel.recv().await {
                incoming.channel.send(bytes).await.unwrap();
            }
            mac
        });
        let mut channel = phone.open("echo", serde_json::json!({"x": 1})).await.unwrap();
        let big = Bytes::from(vec![7u8; crate::frame::MAX_PAYLOAD * 2 + 3]);
        channel.send(big.clone()).await.unwrap();
        let mut got = Vec::new();
        while got.len() < big.len() {
            match channel.recv().await.unwrap() {
                ChannelEvent::Data(bytes) => got.extend_from_slice(&bytes),
                other => panic!("unexpected {other:?}"),
            }
        }
        assert_eq!(&got[..], &big[..]);
        assert!(phone.ping().await.unwrap() < Duration::from_secs(1));
        channel.close("done", "").await;
        let mac = server.await.unwrap();
        phone.close("bye");
        assert_eq!(mac.closed().await, "peer closed the link");
    }

    /// Closing a channel wakes its own send that waits for queue room: a
    /// cancelled upload over a stalled link must not keep the phone's file open.
    #[tokio::test]
    async fn close_wakes_a_send_waiting_for_room() {
        // The peer never reads, so the channel's queue fills and the send waits.
        let (a, _stalled) = tokio::io::duplex(64 * 1024);
        let phone = Link::new(a, Role::Phone, LinkConfig::default(), None);
        let channel = phone.open("upload", serde_json::json!({})).await.unwrap();
        let sender = Arc::new(channel.sender);
        let sending = tokio::spawn({
            let sender = Arc::clone(&sender);
            async move { sender.send(Bytes::from(vec![0u8; CHANNEL_QUEUE_BYTES * 8])).await }
        });
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert!(!sending.is_finished(), "the send waits for room");

        sender.close("cancelled", "").await;
        let sent = tokio::time::timeout(Duration::from_secs(5), sending)
            .await
            .expect("the close wakes the waiting send")
            .unwrap();
        assert!(matches!(sent, Err(LinkError::ChannelClosed)), "{sent:?}");
        drop(phone);
    }

    /// The peer's close stops our sends: a Mac that refuses an upload before
    /// reading it must not have the phone stream the whole file anyway.
    #[tokio::test]
    async fn the_peers_close_stops_our_sends() {
        let (phone, mac) = pair();
        let server = tokio::spawn(async move {
            let incoming = mac.accept().await.expect("incoming");
            incoming.channel.send(Bytes::from_static(b"refused")).await.unwrap();
            incoming.channel.close("forbidden", "no").await;
            mac
        });
        let mut channel = phone.open("upload", serde_json::json!({})).await.unwrap();
        assert!(matches!(channel.recv().await, Some(ChannelEvent::Data(_))));
        assert!(matches!(channel.recv().await, Some(ChannelEvent::Closed(_))));
        let sent = channel.send(Bytes::from(vec![0u8; 16])).await;
        assert!(matches!(sent, Err(LinkError::ChannelClosed)), "{sent:?}");
        let _mac = server.await.unwrap();
    }

    /// A stream that accepts at most `chunk` bytes every `pause`, like a
    /// slow relay path.
    struct Throttled {
        inner: tokio::io::DuplexStream,
        chunk: usize,
        pause: Duration,
        sleep: Option<std::pin::Pin<Box<tokio::time::Sleep>>>,
    }

    impl AsyncRead for Throttled {
        fn poll_read(
            mut self: std::pin::Pin<&mut Self>,
            cx: &mut std::task::Context<'_>,
            buf: &mut tokio::io::ReadBuf<'_>,
        ) -> std::task::Poll<std::io::Result<()>> {
            std::pin::Pin::new(&mut self.inner).poll_read(cx, buf)
        }
    }

    impl AsyncWrite for Throttled {
        fn poll_write(
            mut self: std::pin::Pin<&mut Self>,
            cx: &mut std::task::Context<'_>,
            buf: &[u8],
        ) -> std::task::Poll<std::io::Result<usize>> {
            use std::task::Poll;
            if let Some(sleep) = self.sleep.as_mut() {
                if sleep.as_mut().poll(cx).is_pending() {
                    return Poll::Pending;
                }
                self.sleep = None;
            }
            let len = buf.len().min(self.chunk);
            let result = std::pin::Pin::new(&mut self.inner).poll_write(cx, &buf[..len]);
            if matches!(result, Poll::Ready(Ok(_))) {
                let pause = self.pause;
                self.sleep = Some(Box::pin(tokio::time::sleep(pause)));
            }
            result
        }

        fn poll_flush(
            mut self: std::pin::Pin<&mut Self>,
            cx: &mut std::task::Context<'_>,
        ) -> std::task::Poll<std::io::Result<()>> {
            std::pin::Pin::new(&mut self.inner).poll_flush(cx)
        }

        fn poll_shutdown(
            mut self: std::pin::Pin<&mut Self>,
            cx: &mut std::task::Context<'_>,
        ) -> std::task::Poll<std::io::Result<()>> {
            std::pin::Pin::new(&mut self.inner).poll_shutdown(cx)
        }
    }

    use std::future::Future;

    /// A ping must not queue behind bulk data: on a slow relay a 10 MiB
    /// echo held the keepalive ping for 20 s and closed the link.
    #[tokio::test]
    async fn ping_overtakes_queued_bulk_data() {
        let (a, b) = tokio::io::duplex(64 * 1024);
        // About 1.6 MB/s from the phone.
        let a = Throttled { inner: a, chunk: 16 * 1024, pause: Duration::from_millis(10), sleep: None };
        let config = LinkConfig { keepalive: None, ..LinkConfig::default() };
        let phone = Link::new(a, Role::Phone, config.clone(), None);
        let mac = Link::new(b, Role::Mac, config, None);
        let sink = tokio::spawn(async move {
            let mut incoming = mac.accept().await.expect("incoming");
            let mut total = 0;
            while let Some(ChannelEvent::Data(bytes)) = incoming.channel.recv().await {
                total += bytes.len();
            }
            (mac, total)
        });
        let channel = phone.open("sink", serde_json::json!({})).await.unwrap();
        // 4 MiB queued takes about 2.6 s to drain.
        for _ in 0..64 {
            channel.send(Bytes::from(vec![1u8; 64 * 1024])).await.unwrap();
        }
        let started = Instant::now();
        let rtt = phone.ping().await.unwrap();
        assert!(rtt < Duration::from_millis(1500), "ping waited {rtt:?} behind queued data");
        assert!(started.elapsed() < Duration::from_millis(1500));
        drop(channel);
        phone.close("done");
        let _ = sink.await;
    }

    /// A Mac that floods one channel through a slow stream and, meanwhile,
    /// answers on an input channel and a second bulk channel.
    async fn flood_then_measure(lane: bool) -> (Duration, Duration) {
        let (a, b) = tokio::io::duplex(64 * 1024);
        // About 1.6 MB/s from the Mac.
        let b = Throttled { inner: b, chunk: 16 * 1024, pause: Duration::from_millis(10), sleep: None };
        let config = LinkConfig { keepalive: None, ..LinkConfig::default() };
        let phone = Link::new(a, Role::Phone, config.clone(), None);
        let mac = Link::new(b, Role::Mac, config, None);
        if lane {
            let (la, lb) = tokio::io::duplex(64 * 1024);
            phone.attach_input_lane(la);
            mac.attach_input_lane(lb);
        }
        let mut flood = phone.open("flood", serde_json::json!({})).await.unwrap();
        let mut other = phone.open("other", serde_json::json!({})).await.unwrap();
        let mut input = phone.open_on("input", serde_json::json!({}), Lane::Input).await.unwrap();
        assert_eq!(input.sender.on_input_stream(), lane);
        let server = tokio::spawn(async move {
            let mut channels = HashMap::new();
            for _ in 0..3 {
                let incoming = mac.accept().await.expect("incoming");
                channels.insert(incoming.service.clone(), incoming);
            }
            let flood = channels.remove("flood").unwrap();
            let mut other = channels.remove("other").unwrap();
            let mut input = channels.remove("input").unwrap();
            assert_eq!(input.lane, Lane::Input);
            let flooder = tokio::spawn(async move {
                // 8 MiB: about 5 s through the throttle.
                for _ in 0..128 {
                    if flood.channel.send(Bytes::from(vec![b'y'; 64 * 1024])).await.is_err() {
                        return;
                    }
                }
            });
            // Echo input and the other channel.
            loop {
                tokio::select! {
                    Some(ChannelEvent::Data(bytes)) = input.channel.recv() => { let _ = input.channel.send(bytes).await; }
                    Some(ChannelEvent::Data(bytes)) = other.channel.recv() => { let _ = other.channel.send(bytes).await; }
                    else => break,
                }
            }
            flooder.abort();
            mac
        });
        // Let the flood fill the queues.
        let mut received = 0;
        while received < 512 * 1024 {
            if let Some(ChannelEvent::Data(bytes)) = flood.recv().await {
                received += bytes.len();
            }
        }
        let drain = tokio::spawn(async move { while flood.recv().await.is_some() {} });
        let started = Instant::now();
        input.send(Bytes::from_static(b"k")).await.unwrap();
        assert_eq!(input.recv().await, Some(ChannelEvent::Data(Bytes::from_static(b"k"))));
        let input_echo = started.elapsed();
        let started = Instant::now();
        other.send(Bytes::from_static(b"o")).await.unwrap();
        assert_eq!(other.recv().await, Some(ChannelEvent::Data(Bytes::from_static(b"o"))));
        let other_echo = started.elapsed();
        phone.close("done");
        drain.abort();
        server.abort();
        (input_echo, other_echo)
    }

    /// Head-of-line blocking: an input-lane reply overtakes a flood queued
    /// on the same stream, and another bulk channel waits for at most its
    /// round-robin turn, not for the flood's whole backlog.
    #[tokio::test]
    async fn input_and_other_channels_overtake_a_flood_on_one_stream() {
        let (input, other) = flood_then_measure(false).await;
        eprintln!("one stream: input {input:?}, other {other:?}");
        assert!(input < Duration::from_millis(400), "input echo took {input:?}");
        assert!(other < Duration::from_millis(800), "other channel echo took {other:?}");
    }

    /// With the input lane attached, input does not share the flooded
    /// stream at all.
    #[tokio::test]
    async fn input_lane_stream_bypasses_a_flood() {
        let (input, _) = flood_then_measure(true).await;
        assert!(input < Duration::from_millis(100), "input echo took {input:?}");
    }

    /// A lane only this side attached (the peer's wait ran out) is never
    /// used: input falls back to the main stream instead of vanishing.
    #[tokio::test]
    async fn a_lane_the_peer_never_attached_is_not_used() {
        let (phone, mac) = pair();
        let (la, _lb_unread) = tokio::io::duplex(64 * 1024);
        phone.expect_input_lane();
        phone.attach_input_lane(la);
        assert_eq!(phone.input_lane(), LaneState::Pending);
        let server = tokio::spawn(async move {
            let mut incoming = mac.accept().await.expect("incoming");
            assert_eq!(incoming.lane, Lane::Input);
            while let Some(ChannelEvent::Data(bytes)) = incoming.channel.recv().await {
                incoming.channel.send(bytes).await.unwrap();
            }
        });
        let mut channel = phone.open_on("input", serde_json::json!({}), Lane::Input).await.unwrap();
        assert!(!channel.sender.on_input_stream());
        channel.send(Bytes::from_static(b"k")).await.unwrap();
        assert_eq!(channel.recv().await, Some(ChannelEvent::Data(Bytes::from_static(b"k"))));
        phone.close("done");
        let _ = server.await;
    }

    /// Writes are split into DATA_CHUNK frames.
    #[tokio::test]
    async fn large_writes_are_chunked() {
        let (a, b) = tokio::io::duplex(1024 * 1024);
        let config = LinkConfig { keepalive: None, ..LinkConfig::default() };
        let phone = Link::new(a, Role::Phone, config.clone(), None);
        let mac = Link::new(b, Role::Mac, config, None);
        let channel = phone.open("sink", serde_json::json!({})).await.unwrap();
        channel.send(Bytes::from(vec![1u8; DATA_CHUNK * 3 + 1])).await.unwrap();
        let mut incoming = mac.accept().await.unwrap();
        let mut sizes = Vec::new();
        while sizes.iter().sum::<usize>() < DATA_CHUNK * 3 + 1 {
            if let Some(ChannelEvent::Data(bytes)) = incoming.channel.recv().await {
                sizes.push(bytes.len());
            }
        }
        assert_eq!(sizes, vec![DATA_CHUNK, DATA_CHUNK, DATA_CHUNK, 1]);
    }

    /// The `open` frame names the lane only for input; older peers ignore it.
    #[test]
    fn open_request_lane_on_the_wire() {
        let bulk = serde_json::to_value(OpenRequest {
            service: "echo".into(),
            args: serde_json::json!({}),
            lane: Lane::Bulk,
        })
        .unwrap();
        assert!(bulk.get("lane").is_none());
        let input = serde_json::to_value(OpenRequest {
            service: "daemon".into(),
            args: serde_json::json!({}),
            lane: Lane::Input,
        })
        .unwrap();
        assert_eq!(input["lane"], "input");
        let old: OpenRequest = serde_json::from_str(r#"{"service":"daemon"}"#).unwrap();
        assert_eq!(old.lane, Lane::Bulk);
    }

    #[tokio::test]
    async fn a_channel_read_slowly_does_not_delay_the_others() {
        // A god session's backlog applied 1 ms per delta: the owner reads, just
        // slowly. Another channel's reply and the link's pong must not wait
        // behind it (they used to: the reader sat on the full channel).
        let (phone, mac) = pair();
        const BACKLOG: usize = CHANNEL_DEPTH * 4;
        let server = tokio::spawn(async move {
            let backlog = mac.accept().await.expect("backlog");
            let mut echo = mac.accept().await.expect("echo");
            let flooder = tokio::spawn(async move {
                let channel = backlog.channel;
                for _ in 0..BACKLOG {
                    if channel.send(Bytes::from_static(&[7u8; 256])).await.is_err() {
                        break;
                    }
                }
                channel
            });
            while let Some(ChannelEvent::Data(bytes)) = echo.channel.recv().await {
                echo.channel.send(bytes).await.unwrap();
            }
            (mac, flooder.await.unwrap())
        });
        let mut backlog = phone.open("backlog", serde_json::json!({})).await.unwrap();
        let mut echo = phone.open("echo", serde_json::json!({})).await.unwrap();
        let reader = tokio::spawn(async move {
            let mut read = 0usize;
            while read < BACKLOG {
                match backlog.recv().await {
                    Some(ChannelEvent::Data(_)) => {
                        read += 1;
                        tokio::time::sleep(Duration::from_millis(1)).await;
                    }
                    _ => break,
                }
            }
            read
        });
        // Let the backlog fill the slow channel's queue first.
        tokio::time::sleep(Duration::from_millis(300)).await;
        let started = Instant::now();
        echo.send(Bytes::from_static(b"still here")).await.unwrap();
        let reply = tokio::time::timeout(Duration::from_secs(5), echo.recv()).await.expect("echo answered");
        assert!(matches!(reply, Some(ChannelEvent::Data(b)) if &b[..] == b"still here"));
        let echoed = started.elapsed();
        let pong = tokio::time::timeout(Duration::from_secs(5), phone.ping()).await.unwrap().unwrap();
        assert!(echoed < Duration::from_millis(500), "echo behind a slow channel took {echoed:?}");
        assert!(pong < Duration::from_millis(500), "pong behind a slow channel took {pong:?}");
        // Nothing lost or reordered on the slow channel, and it was not closed.
        assert_eq!(reader.await.unwrap(), BACKLOG);
        assert!(!phone.is_closed());
        drop(echo);
        phone.close("done");
        let _ = server.await.unwrap();
    }

    /// A channel its owner never reads (a terminal screen that never got
    /// attached) fills up; the link reader must not stall behind it, or
    /// pings and every other channel stop and the peer's keepalive closes a
    /// healthy link. The stuck channel is closed `overflow` instead.
    #[tokio::test]
    async fn an_unread_channel_does_not_stall_the_link() {
        let (phone, mac) = pair();
        let server = tokio::spawn(async move {
            // The first channel floods; the second echoes.
            let flood = mac.accept().await.expect("flood");
            let mut echo = mac.accept().await.expect("echo");
            let flooder = tokio::spawn(async move {
                let mut channel = flood.channel;
                let mut sent = 0usize;
                while channel.send(Bytes::from_static(&[9u8; 64])).await.is_ok() {
                    sent += 1;
                    if sent > CHANNEL_DEPTH * 4 {
                        break;
                    }
                }
                // The phone closed it once it stalled the reader.
                loop {
                    match channel.recv().await {
                        Some(ChannelEvent::Closed(info)) => return info.code,
                        Some(_) => {}
                        None => return "gone".to_owned(),
                    }
                }
            });
            while let Some(ChannelEvent::Data(bytes)) = echo.channel.recv().await {
                echo.channel.send(bytes).await.unwrap();
            }
            (mac, flooder.await.unwrap())
        });
        let _unread = phone.open("flood", serde_json::json!({})).await.unwrap();
        let mut echo = phone.open("echo", serde_json::json!({})).await.unwrap();
        tokio::time::sleep(CHANNEL_STALL + Duration::from_millis(500)).await;
        echo.send(Bytes::from_static(b"still here")).await.unwrap();
        let reply = tokio::time::timeout(Duration::from_secs(5), echo.recv()).await.expect("echo answered");
        assert!(matches!(reply, Some(ChannelEvent::Data(b)) if &b[..] == b"still here"));
        assert!(tokio::time::timeout(Duration::from_secs(2), phone.ping()).await.unwrap().is_ok());
        assert!(!phone.is_closed());
        drop(echo);
        phone.close("done");
        let (_mac, code) = server.await.unwrap();
        assert_eq!(code, "overflow");
    }

    /// Any inbound frame proves the peer is alive: a link receiving data
    /// stays up even when no pong comes back, and closes once it goes quiet.
    #[tokio::test]
    async fn keepalive_counts_any_inbound_frame() {
        let (a, b) = tokio::io::duplex(1024 * 1024);
        let config = LinkConfig {
            keepalive: Some(Duration::from_millis(50)),
            keepalive_timeout: Duration::from_millis(600),
            aligned: false,
            reliable: None,
        };
        let phone = Link::new(a, Role::Phone, config, None);
        // A peer that streams data frames and never answers pings.
        let (_read, write) = tokio::io::split(b);
        let mut peer = FramedWrite::new(write, FrameCodec);
        let started = Instant::now();
        while started.elapsed() < Duration::from_millis(1200) {
            peer.send(Frame::new(2, FrameType::Data, vec![0u8; 16])).await.unwrap();
            tokio::time::sleep(Duration::from_millis(40)).await;
        }
        assert!(
            !phone.is_closed(),
            "closed while data was arriving: {:?}",
            phone.closed_state().borrow().clone()
        );
        let reason =
            tokio::time::timeout(Duration::from_secs(2), phone.closed()).await.expect("closes once quiet");
        assert_eq!(reason, "keepalive timed out");
    }

    /// Records when the phone writes to its stream (each write is a tunnel
    /// datagram's worth of link bytes).
    struct WriteTap {
        inner: tokio::io::DuplexStream,
        writes: Arc<Mutex<Vec<Instant>>>,
    }

    impl AsyncRead for WriteTap {
        fn poll_read(
            mut self: std::pin::Pin<&mut Self>,
            cx: &mut std::task::Context<'_>,
            buf: &mut tokio::io::ReadBuf<'_>,
        ) -> std::task::Poll<std::io::Result<()>> {
            std::pin::Pin::new(&mut self.inner).poll_read(cx, buf)
        }
    }

    impl AsyncWrite for WriteTap {
        fn poll_write(
            mut self: std::pin::Pin<&mut Self>,
            cx: &mut std::task::Context<'_>,
            buf: &[u8],
        ) -> std::task::Poll<std::io::Result<usize>> {
            self.writes.lock().unwrap().push(Instant::now());
            std::pin::Pin::new(&mut self.inner).poll_write(cx, buf)
        }

        fn poll_flush(
            mut self: std::pin::Pin<&mut Self>,
            cx: &mut std::task::Context<'_>,
        ) -> std::task::Poll<std::io::Result<()>> {
            std::pin::Pin::new(&mut self.inner).poll_flush(cx)
        }

        fn poll_shutdown(
            mut self: std::pin::Pin<&mut Self>,
            cx: &mut std::task::Context<'_>,
        ) -> std::task::Poll<std::io::Result<()>> {
            std::pin::Pin::new(&mut self.inner).poll_shutdown(cx)
        }
    }

    /// The instants an idle phone link writes in one virtual minute.
    async fn idle_minute_writes(config: LinkConfig) -> Vec<Instant> {
        let (a, b) = tokio::io::duplex(1024 * 1024);
        let writes = Arc::new(Mutex::new(Vec::new()));
        let phone = Link::new(WriteTap { inner: a, writes: Arc::clone(&writes) }, Role::Phone, config, None);
        let mac = Link::new(b, Role::Mac, LinkConfig { keepalive: None, ..LinkConfig::default() }, None);
        tokio::time::sleep(Duration::from_secs(60)).await;
        assert!(!phone.is_closed(), "{:?}", phone.closed_state().borrow().clone());
        assert!(phone.traffic_ago() >= Duration::from_secs(60), "pings and pongs are not traffic");
        // Taken before closing: the close frame is not a keepalive.
        let mut taken = writes.lock().unwrap().clone();
        taken.dedup();
        phone.close("done");
        mac.close("done");
        taken
    }

    /// Off: a ping 15 s after the last pong, as before. On: a ping on every
    /// 10 s beat of the shared keepalive grid, and nothing in between.
    #[tokio::test(start_paused = true)]
    async fn an_aligned_keepalive_pings_on_every_beat_and_nowhere_else() {
        let today = idle_minute_writes(LinkConfig::default()).await;
        assert!((3..=4).contains(&today.len()), "15 s keepalive over 60 s: {}", today.len());
        let start = Instant::now();
        let aligned = idle_minute_writes(LinkConfig::aligned()).await;
        assert!(
            (5..=6).contains(&aligned.len()),
            "{:?}",
            aligned.iter().map(|at| at.duration_since(start)).collect::<Vec<_>>()
        );
        // On the beat, within the timer wheel's 1 ms resolution.
        for at in &aligned {
            let beat = crate::keepalive::next_beat(*at - Duration::from_millis(1), crate::keepalive::BEAT);
            assert!(
                beat <= *at && at.duration_since(beat) < Duration::from_millis(1),
                "{at:?} is not on {beat:?}"
            );
        }
    }

    /// Aligned, a peer that stops answering still closes the link 20 s
    /// after the first unanswered ping.
    #[tokio::test(start_paused = true)]
    async fn an_aligned_keepalive_still_closes_a_silent_link() {
        let (a, b) = tokio::io::duplex(1024 * 1024);
        let phone = Link::new(a, Role::Phone, LinkConfig::aligned(), None);
        // A peer that reads nothing and sends nothing.
        let _peer = b;
        let opened = Instant::now();
        let reason = tokio::time::timeout(Duration::from_secs(60), phone.closed()).await.expect("closes");
        assert_eq!(reason, "keepalive timed out");
        let after = opened.elapsed();
        assert!(after <= Duration::from_secs(30) + Duration::from_millis(1), "closed after {after:?}");
        assert!(after >= Duration::from_secs(20), "closed after {after:?}");
    }

    /// The app's probes (its 15 s heartbeat, a foreground, a presence change)
    /// ask whether the link is alive. A pong stuck behind a full transmit
    /// queue on a slow relay is not a dead link: any frame from the peer
    /// after the probe went out proves it alive, as for the link's own
    /// keepalive. Only silence fails it. (Live, 2026-10-23: the phone closed
    /// links whose tunnel was delivering, "peer closed the link" 22 to 24 s
    /// after link up, with no WireGuard handshake timeout on the Mac.)
    #[tokio::test]
    async fn a_probe_counts_any_inbound_frame_and_fails_only_on_silence() {
        let (a, b) = tokio::io::duplex(1024 * 1024);
        let config = LinkConfig { keepalive: None, ..LinkConfig::default() };
        let phone = Link::new(a, Role::Phone, config, None);
        // A peer that streams data and never answers pings.
        let (_read, write) = tokio::io::split(b);
        let mut peer = FramedWrite::new(write, FrameCodec);
        let streaming = tokio::spawn(async move {
            for _ in 0..20 {
                if peer.send(Frame::new(2, FrameType::Data, vec![0u8; 16])).await.is_err() {
                    return peer;
                }
                tokio::time::sleep(Duration::from_millis(40)).await;
            }
            peer
        });
        let alive = phone.probe(Duration::from_millis(400)).await;
        assert!(matches!(alive, Ok(None)), "data arrived, yet the probe said {alive:?}");
        let _peer = streaming.await.unwrap();
        // Now silent: the probe fails at its timeout.
        let silent = phone.probe(Duration::from_millis(300)).await;
        assert!(matches!(silent, Err(LinkError::Timeout)), "{silent:?}");
        // A peer that answers pings: the round trip.
        let (phone, _mac) = pair();
        assert!(matches!(phone.probe(Duration::from_secs(2)).await, Ok(Some(_))));
    }

    #[tokio::test]
    async fn bad_channel_parity_is_refused() {
        let (phone, mac) = pair();
        // The Mac opening an odd id is a protocol error: simulate by having
        // the phone side receive an Open for its own parity.
        let frame = Frame::new(3, FrameType::Open, br#"{"service":"echo"}"#.to_vec());
        mac.inner.push(MAIN, Class::Control, frame).unwrap();
        // The phone answers with close on channel 3; the Mac has no such
        // channel so it is ignored. The link stays up.
        assert!(phone.ping().await.is_ok());
        assert!(!mac.is_closed());
    }
}
