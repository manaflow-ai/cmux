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

/// How long a link may go without receiving anything after a keepalive
/// ping before it closes. Longer than a 30 s blackout (an elevator, a
/// tunnel, a cell dead zone) with room for the ping's phase: the network
/// comes back on the same link and channels, no redial. The app does not
/// wait for this to learn of a dead path: its own probes (every 2.5 s
/// while it watches) fail in seconds and it dials a new link beside this
/// one (make before break); this only bounds how long a link nobody
/// answers holds its resources on either end. It was 20 s.
pub const KEEPALIVE_TIMEOUT: Duration = Duration::from_secs(45);

/// How long a ping may go with nothing at all received after it before
/// the link is suspect ([`Link::suspect_state`]). Detection, not teardown:
/// a suspect link stays open (the network may come back, an elevator), it
/// is probed every [`SUSPECT_PROBE`], and any inbound frame clears it; only
/// [`KEEPALIVE_TIMEOUT`] closes it. Above a cellular round trip with a
/// radio waking from idle (a few hundred ms) and a pong queued behind a
/// burst; any inbound frame counts as the answer, so a busy link is never
/// suspect for a slow pong.
pub const SUSPECT_AFTER: Duration = Duration::from_secs(3);

/// A probe waits this many smoothed round trips for its pong ([`Link::probe_timeout`]):
/// room for one pong delayed by jitter and a loss repaired below.
pub const PROBE_RTT_FACTOR: u32 = 3;
/// The longest probe timeout an RTT can ask for.
pub const PROBE_TIMEOUT_CAP: Duration = Duration::from_secs(5);

fn probe_timeout(floor: Duration, srtt: Option<Duration>) -> Duration {
    let scaled = srtt.map_or(Duration::ZERO, |srtt| (srtt * PROBE_RTT_FACTOR).min(PROBE_TIMEOUT_CAP));
    floor.max(scaled)
}
/// While a link is suspect it pings this often, so the first ping after
/// the network comes back is answered within about this long, and so the
/// tunnel has a datagram to resume on. Only while suspect: an idle healthy
/// link sends no more than before.
pub const SUSPECT_PROBE: Duration = Duration::from_secs(1);
/// Data this side sent with nothing at all received for this long gets a
/// ping, so a link that dies under traffic is suspect in about this plus
/// [`SUSPECT_AFTER`] instead of waiting for the next keepalive. Only while
/// data is outstanding: a one-way stream with a live peer costs one ping
/// round trip per this long, an idle link none.
pub const OUTSTANDING_PROBE: Duration = Duration::from_secs(2);

/// The lane both sides list when their pings and pongs can travel as
/// datagrams beside the link's stream ([`LivenessDatagrams`]). A peer that
/// does not list it gets today's in-stream pings.
pub const LIVENESS_LANE: &str = "liveness";
/// A datagram ping nothing answered is sent again this often (the same
/// nonce, a new attempt number), up to [`DATAGRAM_PING_ATTEMPTS`] times in
/// all, so one lost datagram on a lossy link (lossy-3, lossy-10) never
/// costs a [`SUSPECT_AFTER`] false alarm: the stream's TCP would have
/// retransmitted it. Not while the link is suspect: its probes every
/// [`SUSPECT_PROBE`] are the retries then.
const DATAGRAM_PING_RESEND: Duration = Duration::from_millis(500);

/// While the phone app is in the foreground with a terminal or chat on
/// screen ([`Link::set_foreground_probe`]) and the link's pings travel as
/// liveness datagrams, it sends one this often, beside the keepalive, so a
/// dead path (an elevator) is suspect within seconds instead of a
/// keepalive later. Off (backgrounded, nothing on screen, no datagram
/// lane) the link sends only its keepalive, as before.
pub const FOREGROUND_PROBE: Duration = Duration::from_secs(3);
/// Foreground probes in a row with nothing at all received after them
/// before the link is suspect.
pub const FOREGROUND_PROBE_MISSES: u32 = 2;
/// A foreground probe nothing answered is sent once more after this many
/// smoothed round trips (at least [`DATAGRAM_PING_RESEND`], at most
/// [`FOREGROUND_RESEND_CAP`]), so one lost datagram on a lossy path is not
/// a miss.
const FOREGROUND_RESEND_RTTS: u32 = 2;
const FOREGROUND_RESEND_CAP: Duration = Duration::from_millis(1500);
const DATAGRAM_PING_ATTEMPTS: u8 = 5;
/// A liveness datagram: kind, the ping's nonce (8 bytes, big-endian), the
/// attempt number. A pong echoes the ping's nonce and attempt.
const DATAGRAM_PING: u8 = 1;
const DATAGRAM_PONG: u8 = 2;
const DATAGRAM_LEN: usize = 10;

/// Pings and pongs as unreliable datagrams beside the link's stream (on
/// WireGuard: overlay UDP on `dial::wireguard::LIVENESS_PORT`). A ping in
/// the stream waits behind every byte already in the transport's send
/// buffer (2000 rows a second fill it), so its pong, and the link's
/// liveness, trails the rows by seconds on a lossy path; a datagram goes
/// out in the tunnel's interactive class ahead of them. The link keeps
/// answering in-stream pings either way.
pub struct LivenessDatagrams {
    /// Datagrams to the peer. Best effort: a full queue drops one.
    pub outgoing: mpsc::Sender<Vec<u8>>,
    /// Datagrams from the peer; ends with the transport.
    pub incoming: mpsc::Receiver<Vec<u8>>,
    /// The peer has its end bound (it listed [`LIVENESS_LANE`] after
    /// binding): this side's pings go as datagrams at once. Otherwise they
    /// stay in the stream until the first datagram from the peer arrives.
    pub peer_listening: bool,
}

fn liveness_datagram(kind: u8, nonce: u64, attempt: u8) -> Vec<u8> {
    let mut datagram = Vec::with_capacity(DATAGRAM_LEN);
    datagram.push(kind);
    datagram.extend_from_slice(&nonce.to_be_bytes());
    datagram.push(attempt);
    datagram
}

/// Whether `datagram` answers a liveness ping (a pong): the transport
/// sends it expecting nothing back.
pub(crate) fn is_liveness_answer(datagram: &[u8]) -> bool {
    datagram.first() == Some(&DATAGRAM_PONG)
}

fn parse_liveness_datagram(datagram: &[u8]) -> Option<(u8, u64, u8)> {
    if datagram.len() != DATAGRAM_LEN || !matches!(datagram[0], DATAGRAM_PING | DATAGRAM_PONG) {
        return None;
    }
    let nonce = u64::from_be_bytes(datagram[1..9].try_into().ok()?);
    Some((datagram[0], nonce, datagram[9]))
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
    /// How long a ping may go unanswered (nothing at all received after
    /// it) before the link is suspect; `None` turns the suspect signal and
    /// its probes off. See [`SUSPECT_AFTER`].
    pub suspect_after: Option<Duration>,
    /// Whether the link starts with its foreground probe on
    /// ([`Link::set_foreground_probe`]). Off by default.
    pub foreground_probe: bool,
}

impl Default for LinkConfig {
    fn default() -> Self {
        Self {
            keepalive: Some(Duration::from_secs(15)),
            keepalive_timeout: KEEPALIVE_TIMEOUT,
            aligned: false,
            suspect_after: Some(SUSPECT_AFTER),
            foreground_probe: false,
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
    async fn push_data(&self, class: Class, frame: Frame, closed: &AtomicBool) -> Pushed {
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
                if used == 0 || used + frame.payload.len() <= CHANNEL_QUEUE_BYTES {
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

/// A link's pings for its path report: counts since the link opened, round trips since the
/// last [`Link::take_ping_stats`].
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PingStats {
    /// Pings sent since the link opened.
    pub sent: u64,
    /// Pongs to them received since the link opened (late ones too).
    pub answered: u64,
    /// Pings still waiting for their pong when taken.
    pub waiting: u64,
    /// Round trips (ms) since the last take, at most [`Self::MAX_SAMPLES`].
    pub samples: Vec<u32>,
}

impl PingStats {
    pub const MAX_SAMPLES: usize = 256;

    fn sample(&mut self, rtt: Duration) {
        if self.samples.len() < Self::MAX_SAMPLES {
            self.samples.push(u32::try_from(rtt.as_millis()).unwrap_or(u32::MAX));
        }
    }
}

struct Inner {
    role: Role,
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
    /// What this side sent that nothing has answered yet: the first frame
    /// (other than a ping or a pong) and the first ping written after the
    /// last inbound frame. Entries older than [`Inner::last_received`] are
    /// stale (answered).
    unanswered: Mutex<Unanswered>,
    /// Wakes the liveness watchdog when `unanswered` gains an entry.
    unanswered_changed: Notify,
    /// The link is suspect ([`Link::suspect_state`]).
    suspect: watch::Sender<bool>,
    /// Mirrors `suspect` for the reader's hot path.
    suspect_flag: AtomicBool,
    channels: Mutex<HashMap<u32, Route>>,
    next_channel: AtomicU32,
    next_nonce: AtomicU64,
    /// Waiters by nonce: each gets when the pong arrived and which attempt
    /// it answers (0 for a stream ping).
    pings: Mutex<HashMap<u64, oneshot::Sender<(Instant, u8)>>>,
    /// Where liveness datagrams go ([`Link::attach_liveness_datagrams`]);
    /// dropped when the link closes.
    datagrams: Mutex<Option<mpsc::Sender<Vec<u8>>>>,
    /// This side's pings go as datagrams: the peer is listening.
    datagram_pings: AtomicBool,
    /// The phone app is in the foreground with a surface on screen
    /// ([`Link::set_foreground_probe`]).
    foreground: watch::Sender<bool>,
    rtt: watch::Sender<Option<Duration>>,
    /// The smoothed round trip of answered pings ([`Link::probe_timeout`]).
    srtt: Mutex<Option<Duration>>,
    /// Ping counts and round trips for the link's path report ([`Link::take_ping_stats`]).
    ping_stats: Mutex<PingStats>,
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

    /// Send one liveness datagram; `false` when there is no datagram lane
    /// or its queue is full.
    fn send_datagram(&self, kind: u8, nonce: u64, attempt: u8) -> bool {
        let sender = self.datagrams.lock().unwrap_or_else(PoisonError::into_inner).clone();
        sender.is_some_and(|sender| sender.try_send(liveness_datagram(kind, nonce, attempt)).is_ok())
    }

    fn datagram_pings(&self) -> bool {
        self.datagram_pings.load(Ordering::Relaxed)
    }

    /// A pong to `nonce` arrived (in the stream or as a datagram).
    fn ponged(&self, nonce: u64, attempt: u8) {
        let waiter = self.pings.lock().unwrap_or_else(PoisonError::into_inner).remove(&nonce);
        // A pong to a ping of ours counts as answered even when its caller stopped
        // waiting (a probe that saw other traffic first): it was not lost.
        if waiter.is_some() || nonce < self.next_nonce.load(Ordering::Relaxed) {
            // A datagram ping's resends share its nonce: count one pong.
            if waiter.is_some() || attempt == 0 {
                self.ping_stats.lock().unwrap_or_else(PoisonError::into_inner).answered += 1;
            }
        }
        if let Some(waiter) = waiter {
            let _ = waiter.send((Instant::now(), attempt));
        }
    }

    fn received(&self) {
        *self.last_rx.lock().unwrap_or_else(PoisonError::into_inner) = Instant::now();
        // Anything from the peer clears a suspect link at once.
        if self.suspect_flag.load(Ordering::Relaxed) && self.suspect_flag.swap(false, Ordering::Relaxed) {
            self.suspect.send_replace(false);
            tracing::debug!("link alive again");
        }
    }

    /// The writer sent frames other than pings and pongs (data, open,
    /// close): note the first since the last inbound frame.
    fn sent_traffic(&self) {
        self.note_unanswered(|unanswered| &mut unanswered.traffic);
    }

    /// A ping went out: note the first since the last inbound frame.
    fn sent_ping(&self) {
        self.note_unanswered(|unanswered| &mut unanswered.ping);
    }

    fn note_unanswered(&self, field: impl FnOnce(&mut Unanswered) -> &mut Option<Instant>) {
        let last = self.last_received();
        let mut unanswered = self.unanswered.lock().unwrap_or_else(PoisonError::into_inner);
        let slot = field(&mut unanswered);
        if slot.is_none_or(|at| at <= last) {
            *slot = Some(Instant::now());
            drop(unanswered);
            self.unanswered_changed.notify_one();
        }
    }

    /// When the first unanswered frame and the first unanswered ping went
    /// out, if they are still unanswered.
    fn unanswered(&self) -> Unanswered {
        let last = self.last_received();
        let unanswered = *self.unanswered.lock().unwrap_or_else(PoisonError::into_inner);
        Unanswered {
            traffic: unanswered.traffic.filter(|at| *at > last),
            ping: unanswered.ping.filter(|at| *at > last),
        }
    }

    /// Mark the link suspect: nothing has answered a ping for
    /// `suspect_after`. Undone by the next inbound frame (`received`).
    fn raise_suspect(&self, since: Instant) {
        self.suspect_flag.store(true, Ordering::Relaxed);
        // A frame that arrived after the check clears it straight away.
        if self.last_received() > since && self.suspect_flag.swap(false, Ordering::Relaxed) {
            return;
        }
        self.suspect.send_replace(true);
        tracing::debug!(quiet_ms = self.last_received().elapsed().as_millis() as u64, "link suspect");
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
        let channels: Vec<_> = self.lock_channels().drain().map(|(_, route)| route.inbox).collect();
        for inbox in channels {
            inbox.push_now(ChannelEvent::Closed(CloseInfo::new("link_closed", reason)));
        }
        self.pings.lock().unwrap_or_else(PoisonError::into_inner).clear();
        self.datagrams.lock().unwrap_or_else(PoisonError::into_inner).take();
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
    pub fn new<S>(stream: S, role: Role, config: LinkConfig, transport: Option<Box<dyn Any + Send>>) -> Self
    where
        S: AsyncRead + AsyncWrite + Send + 'static,
    {
        let (incoming_tx, incoming_rx) = mpsc::channel(64);
        let inner = Arc::new(Inner {
            role,
            outboxes: [Outbox::default(), Outbox::default()],
            lane: watch::channel(LaneState::Unavailable).0,
            lane_attached: AtomicBool::new(false),
            last_rx: Mutex::new(Instant::now()),
            last_traffic: Mutex::new(Instant::now()),
            unanswered: Mutex::new(Unanswered::default()),
            unanswered_changed: Notify::new(),
            suspect: watch::channel(false).0,
            suspect_flag: AtomicBool::new(false),
            channels: Mutex::new(HashMap::new()),
            next_channel: AtomicU32::new(role.first_channel()),
            next_nonce: AtomicU64::new(1),
            pings: Mutex::new(HashMap::new()),
            datagrams: Mutex::new(None),
            datagram_pings: AtomicBool::new(false),
            foreground: watch::channel(config.foreground_probe).0,
            rtt: watch::channel(None).0,
            srtt: Mutex::new(None),
            ping_stats: Mutex::new(PingStats::default()),
            closed: watch::channel(None).0,
            incoming: tokio::sync::Mutex::new(incoming_rx),
            incoming_tx: Mutex::new(Some(incoming_tx.clone())),
            tasks: Mutex::new(Vec::new()),
            transport: Mutex::new(transport),
            media: Mutex::new(None),
        });
        let (read_half, write_half) = tokio::io::split(stream);
        let writer =
            tokio::spawn(write_loop(Arc::clone(&inner), MAIN, FramedWrite::new(write_half, FrameCodec)));
        let reader = tokio::spawn(read_loop(
            Arc::clone(&inner),
            MAIN,
            FramedRead::new(read_half, FrameCodec),
            incoming_tx,
        ));
        let mut tasks = vec![writer, reader];
        if let Some(after) = config.suspect_after {
            let link = Self { inner: Arc::clone(&inner) };
            tasks.push(tokio::spawn(watch_liveness(link, after)));
            let link = Self { inner: Arc::clone(&inner) };
            tasks.push(tokio::spawn(foreground_probe(link)));
        }
        if let Some(interval) = config.keepalive
            && config.aligned
        {
            let link = Self { inner: Arc::clone(&inner) };
            tasks.push(tokio::spawn(aligned_keepalive(link, interval, config.keepalive_timeout)));
        } else if let Some(interval) = config.keepalive {
            let link = Self { inner: Arc::clone(&inner) };
            tasks.push(tokio::spawn(async move {
                let mut closed = link.inner.closed.subscribe();
                loop {
                    tokio::select! {
                        () = tokio::time::sleep(interval) => {}
                        _ = closed.wait_for(Option::is_some) => return,
                    }
                    let sent = Instant::now();
                    let ping = link.ping();
                    tokio::pin!(ping);
                    loop {
                        // Wait for the pong, but count any inbound frame as
                        // life: a pong can trail a full transmit queue.
                        let deadline = link.inner.last_received().max(sent) + config.keepalive_timeout;
                        tokio::select! {
                            result = &mut ping => {
                                if result.is_err() {
                                    return;
                                }
                                break;
                            }
                            () = tokio::time::sleep_until(deadline) => {
                                let quiet_since = link.inner.last_received().max(sent);
                                if quiet_since + config.keepalive_timeout <= Instant::now() {
                                    link.inner.shut("keepalive timed out");
                                    return;
                                }
                            }
                        }
                    }
                }
            }));
        }
        *inner.tasks.lock().unwrap_or_else(PoisonError::into_inner) = tasks;
        Self { inner }
    }

    /// Attaches the media lane the dial negotiated.
    pub fn attach_media(&self, lane: crate::media::MediaLane) {
        *self.inner.media.lock().unwrap_or_else(PoisonError::into_inner) = Some(lane);
    }

    /// Carry this link's pings and pongs as datagrams too
    /// ([`LivenessDatagrams`]). Pings switch to datagrams at once when the
    /// peer is listening, else on the first datagram it sends; in-stream
    /// pings are still answered. A second attach is ignored.
    pub fn attach_liveness_datagrams(&self, lane: LivenessDatagrams) {
        let LivenessDatagrams { outgoing, incoming, peer_listening } = lane;
        {
            let mut datagrams = self.inner.datagrams.lock().unwrap_or_else(PoisonError::into_inner);
            if self.is_closed() || datagrams.is_some() {
                return;
            }
            *datagrams = Some(outgoing);
        }
        if peer_listening {
            self.inner.datagram_pings.store(true, Ordering::Relaxed);
        }
        let reader = tokio::spawn(read_datagrams(Arc::clone(&self.inner), incoming));
        self.inner.tasks.lock().unwrap_or_else(PoisonError::into_inner).push(reader);
        tracing::debug!(role = ?self.inner.role, peer_listening, "liveness datagrams attached");
    }

    /// The phone app is in the foreground with a terminal or chat on
    /// screen (`true`), or not. While it is and the pings travel as
    /// datagrams, the link probes every [`FOREGROUND_PROBE`] and is suspect
    /// after [`FOREGROUND_PROBE_MISSES`] unanswered probes. The keepalive
    /// keeps its own interval either way. Needs the suspect signal
    /// (`LinkConfig::suspect_after`); without it this does nothing.
    pub fn set_foreground_probe(&self, on: bool) {
        self.inner.foreground.send_if_modified(|state| std::mem::replace(state, on) != on);
    }

    /// Whether the foreground probe is on ([`Link::set_foreground_probe`]).
    pub fn foreground_probe(&self) -> bool {
        *self.inner.foreground.borrow()
    }

    /// Whether this link's pings travel as datagrams now.
    pub fn pings_as_datagrams(&self) -> bool {
        self.inner.datagram_pings()
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
        if !self.is_closed() {
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
        if self.is_closed() || self.inner.lane_attached.swap(true, Ordering::AcqRel) {
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
        ));
        let reader = tokio::spawn(read_loop(
            Arc::clone(&self.inner),
            INPUT,
            FramedRead::new(read_half, FrameCodec),
            incoming,
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
        // As a datagram when the peer listens (out ahead of the stream's
        // queued bytes), else, or when its queue is full, in the stream.
        let datagram = self.inner.datagram_pings() && {
            if self.inner.closed_reason().is_some() {
                return Err(self.inner.closed_error());
            }
            self.inner.send_datagram(DATAGRAM_PING, nonce, 0)
        };
        if !datagram {
            self.inner.send_control(Frame::new(0, FrameType::Ping, nonce.to_be_bytes().to_vec()))?;
        }
        self.inner.sent_ping();
        self.inner.ping_stats.lock().unwrap_or_else(PoisonError::into_inner).sent += 1;
        let mut sent_at = [None; DATAGRAM_PING_ATTEMPTS as usize];
        sent_at[0] = Some(started);
        // Tries so far, the first send (stream or datagram) as try 0.
        let mut tries = 1u8;
        // The ping is in the stream: sent there first, or after its
        // datagram tries ran out.
        let mut in_stream = !datagram;
        let has_lane = self.inner.datagrams.lock().unwrap_or_else(PoisonError::into_inner).is_some();
        tokio::pin!(rx);
        let (answered, answers) = loop {
            tokio::select! {
                answered = &mut rx => break answered.map_err(|_| {
                    LinkError::Closed(self.inner.closed_reason().unwrap_or_else(|| "closed".into()))
                })?,
                () = tokio::time::sleep(DATAGRAM_PING_RESEND),
                    if has_lane && (tries < DATAGRAM_PING_ATTEMPTS || !in_stream) =>
                {
                    if tries < DATAGRAM_PING_ATTEMPTS {
                        // A stream ping sent before the peer was heard on
                        // datagrams gets its tries once it is: behind a
                        // stream of rows its pong could take many seconds,
                        // and the keepalive pings no more until it comes.
                        if self.inner.datagram_pings() {
                            let attempt = tries;
                            tries += 1;
                            // While suspect the watchdog's probes are the resends.
                            if !self.inner.suspect_flag.load(Ordering::Relaxed)
                                && self.inner.send_datagram(DATAGRAM_PING, nonce, attempt)
                            {
                                sent_at[usize::from(attempt)] = Some(Instant::now());
                            }
                        }
                    } else {
                        // Every try lost (or the network dark): the same nonce
                        // in the stream, which delivers it once the path is
                        // back, so a ping nobody stopped waiting for (the
                        // keepalive's) is always answered on a live link.
                        in_stream = true;
                        self.inner
                            .send_control(Frame::new(0, FrameType::Ping, nonce.to_be_bytes().to_vec()))?;
                    }
                }
            }
        };
        let sent = sent_at.get(usize::from(answers)).copied().flatten().unwrap_or(started);
        let rtt = answered.saturating_duration_since(sent);
        self.inner.ping_stats.lock().unwrap_or_else(PoisonError::into_inner).sample(rtt);
        self.inner.rtt.send_replace(Some(rtt));
        let mut srtt = self.inner.srtt.lock().unwrap_or_else(PoisonError::into_inner);
        // RFC 6298's gain: one slow pong moves it an eighth of the way.
        *srtt = Some(srtt.map_or(rtt, |srtt| (srtt * 7 + rtt) / 8));
        Ok(rtt)
    }

    /// How long a probe of this link may wait for its pong: `floor`, or
    /// [`PROBE_RTT_FACTOR`] smoothed round trips when that is longer, at
    /// most [`PROBE_TIMEOUT_CAP`]. A fixed 1 s timeout never fits a 1 s round
    /// trip (lossy-10: every standby probe timed out and the standby was
    /// never kept).
    pub fn probe_timeout(&self, floor: Duration) -> Duration {
        let srtt = *self.inner.srtt.lock().unwrap_or_else(PoisonError::into_inner);
        probe_timeout(floor, srtt)
    }

    /// Whether the link is alive, within `timeout`: `Ok(Some(rtt))` on the
    /// pong, `Ok(None)` as soon as any other frame arrives after the ping went
    /// out (a pong can trail a full transmit queue on a slow relay; the link's
    /// own keepalive counts any inbound frame as life too), `Err(Timeout)`
    /// only when nothing at all came back, `Err(Closed)` once closed.
    ///
    /// Any frame proves only the peer-to-us direction: a link whose uplink
    /// alone broke still reads alive here until the peer's own keepalive
    /// closes it (15 s ping, [`KEEPALIVE_TIMEOUT`]), the bound the link
    /// already had.
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

    /// This link's pings since it opened (sent, answered, waiting) and the round trips measured
    /// since the last call (at most [`PingStats::MAX_SAMPLES`]), which it takes: one reader, the
    /// path report ([`crate::link_stat`]).
    pub fn take_ping_stats(&self) -> PingStats {
        let waiting = self.inner.pings.lock().unwrap_or_else(PoisonError::into_inner).len() as u64;
        let mut stats = self.inner.ping_stats.lock().unwrap_or_else(PoisonError::into_inner);
        PingStats {
            sent: stats.sent,
            answered: stats.answered,
            waiting,
            samples: std::mem::take(&mut stats.samples),
        }
    }

    /// The latest measured round-trip time.
    pub fn rtt(&self) -> watch::Receiver<Option<Duration>> {
        self.inner.rtt.subscribe()
    }

    /// `true` while the link is suspect: a ping went [`SUSPECT_AFTER`] with
    /// nothing at all received after it (a dead or silent peer, a dead
    /// network, a blackout). Detection, not teardown: the link stays open
    /// and pings every [`SUSPECT_PROBE`], the first inbound frame makes it
    /// `false` again, and it closes only after [`KEEPALIVE_TIMEOUT`]. The
    /// phone's app probes the link at once on it (its quick probe) and
    /// dials beside it while it stays dead.
    pub fn suspect_state(&self) -> watch::Receiver<bool> {
        self.inner.suspect.subscribe()
    }

    pub fn is_suspect(&self) -> bool {
        self.inner.suspect_flag.load(Ordering::Relaxed)
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
        self.inner.shut(reason);
    }
}

async fn write_loop<W>(inner: Arc<Inner>, stream: usize, mut sink: FramedWrite<W, FrameCodec>)
where
    W: AsyncWrite + Send + Unpin,
{
    let outbox = &inner.outboxes[stream];
    loop {
        // Highest priority first; feed what is queued, flushing every
        // FLUSH_BYTES so the transport sees frames in priority order.
        let frame = match outbox.next().await {
            Next::Frame(frame) => frame,
            Next::Shutdown => {
                let _ = sink.close().await;
                return;
            }
        };
        let mut frame = frame;
        let mut pending = frame.payload.len();
        // Frames whose sender asked when they reach the transport (send_marked).
        let mut marks: Vec<crate::frame::FlushMark> = Vec::new();
        marks.extend(frame.flushed.take());
        let mut traffic = !matches!(frame.kind, FrameType::Ping | FrameType::Pong);
        let mut result = sink.feed(frame).await;
        while result.is_ok() && pending < FLUSH_BYTES {
            match outbox.pop() {
                Some(Next::Frame(mut frame)) => {
                    pending += frame.payload.len();
                    marks.extend(frame.flushed.take());
                    traffic |= !matches!(frame.kind, FrameType::Ping | FrameType::Pong);
                    result = sink.feed(frame).await;
                }
                Some(Next::Shutdown) => {
                    let _ = sink.flush().await;
                    let _ = sink.close().await;
                    return;
                }
                None => break,
            }
        }
        if let Err(error) = result.and(sink.flush().await) {
            inner.shut(&format!("write failed: {error}"));
            return;
        }
        if !marks.is_empty() {
            let now = crate::frame::epoch_us();
            for mark in marks.drain(..) {
                mark.set(now);
            }
        }
        if traffic {
            inner.sent_traffic();
        }
    }
}

/// What this side sent since the last inbound frame (see
/// [`Inner::unanswered`]).
#[derive(Debug, Clone, Copy, Default)]
struct Unanswered {
    traffic: Option<Instant>,
    ping: Option<Instant>,
}

/// Detection, apart from teardown (the keepalive's [`KEEPALIVE_TIMEOUT`]):
/// data with nothing received for [`OUTSTANDING_PROBE`] gets a ping; a ping
/// with nothing received for `after` makes the link suspect; a suspect link
/// pings every [`SUSPECT_PROBE`] until anything arrives. Every ping counts
/// (the keepalive's, the app's probes, these), so an idle link is suspect
/// `after` past whichever ping comes first, and an idle healthy link sends
/// nothing more than its keepalive. Sleeps until the next deadline or until
/// something new goes unanswered.
async fn watch_liveness(link: Link, after: Duration) {
    let inner = &link.inner;
    let mut closed = inner.closed.subscribe();
    let probe = |link: &Link| {
        let pinger = link.clone();
        tokio::spawn(async move {
            let _ = tokio::time::timeout(after, pinger.ping()).await;
        });
    };
    let mut last_probe: Option<Instant> = None;
    loop {
        let now = Instant::now();
        let unanswered = inner.unanswered();
        let next = if inner.suspect_flag.load(Ordering::Relaxed) {
            let due = last_probe.map_or(now, |at| at + SUSPECT_PROBE);
            if now >= due {
                probe(&link);
                last_probe = Some(now);
                Some(now + SUSPECT_PROBE)
            } else {
                Some(due)
            }
        } else if let Some(ping) = unanswered.ping {
            if now >= ping + after {
                inner.raise_suspect(ping);
                if inner.suspect_flag.load(Ordering::Relaxed) {
                    probe(&link);
                    last_probe = Some(now);
                }
                continue;
            }
            Some(ping + after)
        } else if let Some(traffic) = unanswered.traffic {
            if now >= traffic + OUTSTANDING_PROBE {
                // Its ping wakes this loop (`unanswered_changed`) once out.
                probe(&link);
                Some(now + after)
            } else {
                Some(traffic + OUTSTANDING_PROBE)
            }
        } else {
            None
        };
        tokio::select! {
            _ = closed.wait_for(Option::is_some) => return,
            () = inner.unanswered_changed.notified() => {}
            () = tokio::time::sleep_until(next.unwrap_or(now)), if next.is_some() => {}
        }
    }
}

/// The foreground probe ([`Link::set_foreground_probe`]): while it is on
/// and the pings travel as datagrams, a datagram ping every
/// [`FOREGROUND_PROBE`], sent once more when nothing came back in a couple
/// of round trips. A probe with nothing at all received after it by the
/// next one is a miss; [`FOREGROUND_PROBE_MISSES`] in a row make the link
/// suspect, and the watchdog's [`SUSPECT_PROBE`] probes take over until
/// anything arrives. The probes take no waiter and do not count as the
/// watchdog's unanswered pings, so `SUSPECT_AFTER` does not shorten the
/// misses rule.
async fn foreground_probe(link: Link) {
    let inner = &link.inner;
    let mut closed = inner.closed.subscribe();
    let mut on = inner.foreground.subscribe();
    loop {
        while !*on.borrow_and_update() {
            tokio::select! {
                _ = closed.wait_for(Option::is_some) => return,
                changed = on.changed() => if changed.is_err() { return },
            }
        }
        // The last probe (when, its nonce) and whether it was resent.
        let mut last: Option<(Instant, u64)> = None;
        let mut resent = false;
        let mut misses = 0u32;
        let mut first_miss: Option<Instant> = None;
        let mut tick = Instant::now();
        loop {
            let resend_at = last.filter(|_| !resent).map(|(at, _)| {
                let srtt = *inner.srtt.lock().unwrap_or_else(PoisonError::into_inner);
                let wait = srtt.map_or(DATAGRAM_PING_RESEND, |srtt| srtt * FOREGROUND_RESEND_RTTS);
                at + wait.clamp(DATAGRAM_PING_RESEND, FOREGROUND_RESEND_CAP)
            });
            tokio::select! {
                _ = closed.wait_for(Option::is_some) => return,
                changed = on.changed() => {
                    if changed.is_err() {
                        return;
                    }
                    if !*on.borrow_and_update() {
                        break;
                    }
                    continue;
                }
                () = tokio::time::sleep_until(resend_at.unwrap_or(tick)), if resend_at.is_some() => {
                    resent = true;
                    if let Some((at, nonce)) = last
                        && inner.last_received() < at
                        && !inner.suspect_flag.load(Ordering::Relaxed)
                    {
                        inner.send_datagram(DATAGRAM_PING, nonce, 1);
                    }
                    continue;
                }
                () = tokio::time::sleep_until(tick) => {}
            }
            let now = Instant::now();
            tick = (tick + FOREGROUND_PROBE).max(now);
            if !inner.datagram_pings() || inner.suspect_flag.load(Ordering::Relaxed) {
                // No lane (pings in the stream: the keepalive's), or suspect
                // (the watchdog probes): start counting afresh.
                (last, misses, first_miss) = (None, 0, None);
                continue;
            }
            if let Some((at, _)) = last {
                if inner.last_received() < at {
                    misses += 1;
                    first_miss.get_or_insert(at);
                } else {
                    (misses, first_miss) = (0, None);
                }
            }
            if misses >= FOREGROUND_PROBE_MISSES
                && let Some(since) = first_miss
            {
                inner.raise_suspect(since);
                // The watchdog sleeps on an idle link: wake it to probe.
                inner.unanswered_changed.notify_one();
                (last, misses, first_miss) = (None, 0, None);
                continue;
            }
            let nonce = inner.next_nonce.fetch_add(1, Ordering::Relaxed);
            if inner.send_datagram(DATAGRAM_PING, nonce, 0) {
                inner.ping_stats.lock().unwrap_or_else(PoisonError::into_inner).sent += 1;
            }
            (last, resent) = (Some((now, nonce)), false);
        }
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
                    link.inner.shut("keepalive timed out");
                    return;
                }
            }
        }
    }
}

/// Liveness datagrams from the peer: answer its pings, hand pongs to their
/// waiters. Any of them proves the peer alive, as a frame does, and the
/// first one says the peer listens, so this side's pings switch over.
async fn read_datagrams(inner: Arc<Inner>, mut incoming: mpsc::Receiver<Vec<u8>>) {
    while let Some(datagram) = incoming.recv().await {
        let Some((kind, nonce, attempt)) = parse_liveness_datagram(&datagram) else { continue };
        if inner.closed_reason().is_some() {
            return;
        }
        inner.received();
        if !inner.datagram_pings.swap(true, Ordering::Relaxed) {
            tracing::debug!(role = ?inner.role, "peer heard on liveness datagrams: pings go as datagrams");
        }
        match kind {
            DATAGRAM_PING => {
                inner.send_datagram(DATAGRAM_PONG, nonce, attempt);
            }
            _ => inner.ponged(nonce, attempt),
        }
    }
}

async fn read_loop<R>(
    inner: Arc<Inner>,
    stream: usize,
    mut source: FramedRead<R, FrameCodec>,
    incoming: mpsc::Sender<IncomingChannel>,
) where
    R: AsyncRead + Send + Unpin,
{
    let reason = loop {
        let frame = match source.next().await {
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
        match frame.kind {
            FrameType::Ping => {
                let _ = inner.push(stream, Class::Control, Frame::new(0, FrameType::Pong, frame.payload));
            }
            FrameType::Pong => {
                if let Ok(bytes) = <[u8; 8]>::try_from(&frame.payload[..]) {
                    inner.ponged(u64::from_be_bytes(bytes), 0);
                }
            }
            FrameType::Open => {
                if !inner.role.peer_owns(frame.channel) || inner.lock_channels().contains_key(&frame.channel)
                {
                    refuse(
                        &inner,
                        stream,
                        frame.channel,
                        "bad_channel",
                        "channel id is not the peer's or in use",
                    );
                    continue;
                }
                let Ok(request) = serde_json::from_slice::<OpenRequest>(&frame.payload) else {
                    refuse(&inner, stream, frame.channel, "bad_request", "open payload is not JSON");
                    continue;
                };
                // Replies go back on the stream the open came on, at the
                // priority of the lane the peer asked for.
                let class = Class::from(request.lane);
                let (tx, rx) = mpsc::channel(CHANNEL_DEPTH);
                let closed = Arc::new(AtomicBool::new(false));
                let inbox = Inbox::new(tx, &inner, stream, frame.channel);
                inner.lock_channels().insert(frame.channel, Route { inbox, closed: Arc::clone(&closed) });
                let channel = Channel::new(frame.channel, stream, class, Arc::clone(&inner), rx, closed);
                let accepted = IncomingChannel {
                    service: request.service,
                    args: request.args,
                    lane: request.lane,
                    channel,
                };
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
                        refuse(&inner, stream, frame.channel, "overflow", "the channel was not read");
                    }
                }
            }
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
    };
    inner.shut(&reason);
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
        self.send_marked(data, None).await
    }

    /// [`send`](Self::send), and `mark` is set when the last byte of `data`
    /// was handed to the transport (the writer's flush after its frame).
    pub async fn send_marked(
        &self,
        data: Bytes,
        mark: Option<crate::frame::FlushMark>,
    ) -> Result<(), LinkError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(LinkError::ChannelClosed);
        }
        let mut rest = data;
        let mut mark = mark;
        while !rest.is_empty() {
            let chunk = rest.split_to(rest.len().min(DATA_CHUNK));
            if self.inner.closed_reason().is_some() {
                return Err(self.inner.closed_error());
            }
            let size = chunk.len();
            let mut frame = Frame::new(self.id, FrameType::Data, chunk);
            if rest.is_empty() {
                frame.flushed = mark.take();
            }
            match self.inner.outboxes[self.stream].push_data(self.class, frame, &self.closed).await {
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

    #[test]
    fn probe_timeout_scales_with_the_round_trip() {
        let floor = Duration::from_secs(1);
        assert_eq!(probe_timeout(floor, None), floor, "no pong yet: the floor");
        assert_eq!(probe_timeout(floor, Some(Duration::from_millis(80))), floor, "lte: the floor");
        assert_eq!(
            probe_timeout(floor, Some(Duration::from_secs(1))),
            Duration::from_secs(3),
            "lossy-10's 1 s round trip"
        );
        assert_eq!(probe_timeout(floor, Some(Duration::from_secs(4))), PROBE_TIMEOUT_CAP);
    }

    fn pair() -> (Link, Link) {
        let (a, b) = tokio::io::duplex(64 * 1024);
        (
            Link::new(a, Role::Phone, LinkConfig::default(), None),
            Link::new(b, Role::Mac, LinkConfig::default(), None),
        )
    }

    #[tokio::test]
    async fn a_marked_send_is_stamped_when_its_last_byte_is_flushed() {
        let (phone, mac) = pair();
        let server = tokio::spawn(async move {
            let incoming = mac.accept().await.expect("incoming");
            let (sender, _receiver) = incoming.channel.split();
            let mark = crate::frame::FlushMark::new();
            assert_eq!(mark.flushed_us(), None);
            let before = crate::frame::epoch_us();
            // Two chunks: the mark rides the last.
            sender.send_marked(Bytes::from(vec![1u8; DATA_CHUNK + 5]), Some(mark.clone())).await.unwrap();
            (mac, sender, mark, before)
        });
        let mut channel = phone.open("marked", serde_json::json!({})).await.unwrap();
        let mut got = 0;
        while got < DATA_CHUNK + 5 {
            match channel.recv().await.unwrap() {
                ChannelEvent::Data(bytes) => got += bytes.len(),
                other => panic!("unexpected {other:?}"),
            }
        }
        let (_mac, _sender, mark, before) = server.await.unwrap();
        let flushed = mark.flushed_us().expect("stamped once the phone has the bytes");
        assert!(flushed >= before);
        mark.set(flushed + 1_000_000);
        assert_eq!(mark.flushed_us(), Some(flushed), "the first flush wins");
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
            suspect_after: None,
            foreground_probe: false,
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

    /// Aligned, a peer that stops answering still closes the link
    /// [`KEEPALIVE_TIMEOUT`] after the first unanswered ping.
    #[tokio::test(start_paused = true)]
    async fn an_aligned_keepalive_still_closes_a_silent_link() {
        let (a, b) = tokio::io::duplex(1024 * 1024);
        let phone = Link::new(a, Role::Phone, LinkConfig::aligned(), None);
        // A peer that reads nothing and sends nothing.
        let _peer = b;
        let opened = Instant::now();
        let reason = tokio::time::timeout(Duration::from_secs(120), phone.closed()).await.expect("closes");
        assert_eq!(reason, "keepalive timed out");
        let after = opened.elapsed();
        let first_ping = crate::keepalive::BEAT;
        assert!(after <= first_ping + KEEPALIVE_TIMEOUT + Duration::from_millis(1), "closed after {after:?}");
        assert!(after >= KEEPALIVE_TIMEOUT, "closed after {after:?}");
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

    /// A phone and a Mac link joined by a network that can go dark: while
    /// `dark` is true nothing crosses either way (bytes wait, as TCP's do
    /// inside the tunnel), and they flow again once it is false.
    fn gated_pair(phone: LinkConfig, mac: LinkConfig) -> (Link, Link, watch::Sender<bool>) {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let (a, a_net) = tokio::io::duplex(1024 * 1024);
        let (b, b_net) = tokio::io::duplex(1024 * 1024);
        let dark = watch::channel(false).0;
        let pump = |mut from: tokio::io::ReadHalf<tokio::io::DuplexStream>,
                    mut to: tokio::io::WriteHalf<tokio::io::DuplexStream>,
                    mut dark: watch::Receiver<bool>| async move {
            let mut buffer = vec![0u8; 16 * 1024];
            loop {
                if dark.wait_for(|dark| !dark).await.is_err() {
                    return;
                }
                let n = match from.read(&mut buffer).await {
                    Ok(0) | Err(_) => return,
                    Ok(n) => n,
                };
                if dark.wait_for(|dark| !dark).await.is_err() || to.write_all(&buffer[..n]).await.is_err() {
                    return;
                }
            }
        };
        let (a_read, a_write) = tokio::io::split(a_net);
        let (b_read, b_write) = tokio::io::split(b_net);
        tokio::spawn(pump(a_read, b_write, dark.subscribe()));
        tokio::spawn(pump(b_read, a_write, dark.subscribe()));
        (Link::new(a, Role::Phone, phone, None), Link::new(b, Role::Mac, mac, None), dark)
    }

    /// Resolves when `link` turns suspect; how long after `since`.
    async fn suspect_after(link: &Link, since: Instant) -> Duration {
        let mut suspect = link.suspect_state();
        let _ = suspect.wait_for(|suspect| *suspect).await;
        since.elapsed()
    }

    /// Idle, the network goes dark: each end is suspect one ping plus
    /// `SUSPECT_AFTER` in (at most the 15 s keepalive plus 3 s, the bound
    /// with no app probe), long before the 45 s teardown. A 30 s blackout
    /// keeps the link: suspect clears on the first frame after it.
    #[tokio::test(start_paused = true)]
    async fn an_idle_dark_link_is_suspect_and_survives_30s() {
        let (phone, mac, dark) = gated_pair(LinkConfig::default(), LinkConfig::default());
        // Settle past the first keepalive round.
        tokio::time::sleep(Duration::from_secs(16)).await;
        assert!(!phone.is_suspect() && !mac.is_suspect());
        let began = Instant::now();
        dark.send_replace(true);
        let bound = Duration::from_secs(15) + SUSPECT_AFTER + Duration::from_millis(10);
        let (phone_at, mac_at) = tokio::time::timeout(bound, async {
            tokio::join!(suspect_after(&phone, began), suspect_after(&mac, began))
        })
        .await
        .expect("both ends suspect within one keepalive plus SUSPECT_AFTER");
        assert!(phone_at >= SUSPECT_AFTER && mac_at >= SUSPECT_AFTER, "{phone_at:?} {mac_at:?}");
        tokio::time::sleep_until(began + Duration::from_secs(30)).await;
        assert!(!phone.is_closed() && !mac.is_closed(), "closed inside a 30 s blackout");
        assert!(phone.is_suspect() && mac.is_suspect());
        let back = Instant::now();
        dark.send_replace(false);
        // The next suspect probe (every SUSPECT_PROBE) is answered.
        let mut state = phone.suspect_state();
        tokio::time::timeout(SUSPECT_PROBE + Duration::from_millis(100), state.wait_for(|suspect| !suspect))
            .await
            .expect("alive again within one suspect probe")
            .unwrap();
        assert!(back.elapsed() <= SUSPECT_PROBE + Duration::from_millis(100));
        assert!(phone.ping().await.is_ok());
        assert!(!mac.is_suspect());
        assert!(!phone.is_closed() && !mac.is_closed());
    }

    /// Past `KEEPALIVE_TIMEOUT` of darkness the link still closes: suspect
    /// first, teardown later.
    #[tokio::test(start_paused = true)]
    async fn a_dark_link_closes_only_at_the_keepalive_timeout() {
        let (phone, _mac, dark) = gated_pair(LinkConfig::default(), LinkConfig::default());
        tokio::time::sleep(Duration::from_secs(16)).await;
        let began = Instant::now();
        dark.send_replace(true);
        let suspect = suspect_after(&phone, began).await;
        let reason = phone.closed().await;
        let closed = began.elapsed();
        assert_eq!(reason, "keepalive timed out");
        assert!(suspect < Duration::from_secs(19), "{suspect:?}");
        assert!(closed >= KEEPALIVE_TIMEOUT, "{closed:?}");
        assert!(
            closed <= Duration::from_secs(15) + KEEPALIVE_TIMEOUT + Duration::from_millis(10),
            "{closed:?}"
        );
    }

    /// Busy (a frame each way every 100 ms), the network goes dark: the
    /// sender's unanswered data gets a ping after `OUTSTANDING_PROBE`, and
    /// the link is suspect `SUSPECT_AFTER` later, about 5 s, whatever the
    /// keepalive's phase.
    #[tokio::test(start_paused = true)]
    async fn a_busy_dark_link_is_suspect_in_about_5s() {
        let (phone, mac, dark) = gated_pair(LinkConfig::default(), LinkConfig::default());
        let echo = tokio::spawn(async move {
            let mut incoming = mac.accept().await.expect("echo");
            while let Some(ChannelEvent::Data(bytes)) = incoming.channel.recv().await {
                if incoming.channel.send(bytes).await.is_err() {
                    break;
                }
            }
            mac
        });
        let channel = phone.open("echo", serde_json::json!({})).await.unwrap();
        let (sender, mut receiver) = channel.split();
        tokio::spawn(async move { while receiver.recv().await.is_some() {} });
        tokio::spawn(async move {
            while sender.send(Bytes::from_static(b"frame")).await.is_ok() {
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        });
        // Mid keepalive interval: the keepalive is no help here.
        tokio::time::sleep(Duration::from_secs(7)).await;
        assert!(!phone.is_suspect());
        let began = Instant::now();
        dark.send_replace(true);
        let at = suspect_after(&phone, began).await;
        let bound = OUTSTANDING_PROBE + SUSPECT_AFTER + Duration::from_millis(200);
        assert!(at <= bound && at >= SUSPECT_AFTER, "suspect after {at:?}");
        dark.send_replace(false);
        let mut state = phone.suspect_state();
        tokio::time::timeout(Duration::from_secs(2), state.wait_for(|suspect| !suspect))
            .await
            .unwrap()
            .unwrap();
        assert!(!phone.is_closed());
        echo.abort();
    }

    /// A one-way stream with a live peer (terminal output to a phone that
    /// sends nothing) is never suspect: the Mac's unanswered data gets a
    /// ping every `OUTSTANDING_PROBE`, and the pong answers it.
    #[tokio::test(start_paused = true)]
    async fn a_one_way_stream_to_a_live_peer_is_never_suspect() {
        let (phone, mac, _dark) = gated_pair(LinkConfig::default(), LinkConfig::default());
        let flagged = Arc::new(AtomicBool::new(false));
        let watcher = {
            let mut suspect = mac.suspect_state();
            let flagged = Arc::clone(&flagged);
            tokio::spawn(async move {
                if suspect.wait_for(|suspect| *suspect).await.is_ok() {
                    flagged.store(true, Ordering::SeqCst);
                }
            })
        };
        let server = tokio::spawn(async move {
            let incoming = mac.accept().await.expect("feed");
            for _ in 0..600 {
                if incoming.channel.send(Bytes::from_static(&[7u8; 256])).await.is_err() {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            mac
        });
        let mut feed = phone.open("feed", serde_json::json!({})).await.unwrap();
        tokio::spawn(async move { while feed.recv().await.is_some() {} });
        let mac = server.await.unwrap();
        assert!(!flagged.load(Ordering::SeqCst), "a live one-way stream was suspect");
        assert!(!mac.is_suspect() && !phone.is_suspect());
        watcher.abort();
    }

    /// With the suspect signal off (`suspect_after: None`), nothing extra is
    /// sent and the link is never suspect: the old behavior.
    #[tokio::test(start_paused = true)]
    async fn the_suspect_signal_can_be_turned_off() {
        let off = LinkConfig { suspect_after: None, ..LinkConfig::default() };
        let (phone, _mac, dark) = gated_pair(off.clone(), off);
        tokio::time::sleep(Duration::from_secs(16)).await;
        dark.send_replace(true);
        tokio::time::sleep(Duration::from_secs(30)).await;
        assert!(!phone.is_suspect());
        assert!(!phone.is_closed());
    }

    /// Two linked datagram lanes; `drop_first` of the phone's datagrams are lost.
    fn datagram_pair(
        phone_listening: bool,
        mac_listening: bool,
        drop_first: usize,
    ) -> (LivenessDatagrams, LivenessDatagrams) {
        fn wire(drop_first: usize) -> (mpsc::Sender<Vec<u8>>, mpsc::Receiver<Vec<u8>>) {
            let (outgoing, mut sent) = mpsc::channel::<Vec<u8>>(64);
            let (delivered, incoming) = mpsc::channel(64);
            tokio::spawn(async move {
                let mut seen = 0;
                while let Some(datagram) = sent.recv().await {
                    seen += 1;
                    if seen > drop_first {
                        let _ = delivered.try_send(datagram);
                    }
                }
            });
            (outgoing, incoming)
        }
        let (phone_out, mac_in) = wire(drop_first);
        let (mac_out, phone_in) = wire(0);
        (
            LivenessDatagrams { outgoing: phone_out, incoming: phone_in, peer_listening: mac_listening },
            LivenessDatagrams { outgoing: mac_out, incoming: mac_in, peer_listening: phone_listening },
        )
    }

    /// The Mac's stream stalls after one byte (its writes never finish):
    /// an in-stream pong would never come back.
    fn stalled_pair() -> (Link, Link) {
        let (a, b) = tokio::io::duplex(64 * 1024);
        let b = Throttled { inner: b, chunk: 1, pause: Duration::from_secs(3600), sleep: None };
        let config = LinkConfig { keepalive: None, suspect_after: None, ..LinkConfig::default() };
        (Link::new(a, Role::Phone, config.clone(), None), Link::new(b, Role::Mac, config, None))
    }

    /// Pings as datagrams do not wait for the stream: a Mac whose stream is
    /// stuck still answers, and its own pings switch to datagrams once it
    /// hears the phone's.
    #[tokio::test]
    async fn datagram_pings_skip_a_stalled_stream() {
        let (phone, mac) = stalled_pair();
        let (phone_lane, mac_lane) = datagram_pair(true, true, 0);
        // The Mac listed the lane; the phone binds after its answer.
        let mac_lane = LivenessDatagrams { peer_listening: false, ..mac_lane };
        phone.attach_liveness_datagrams(phone_lane);
        mac.attach_liveness_datagrams(mac_lane);
        assert!(phone.pings_as_datagrams());
        assert!(!mac.pings_as_datagrams());
        let rtt =
            tokio::time::timeout(Duration::from_secs(2), phone.ping()).await.expect("datagram pong").unwrap();
        assert!(rtt < Duration::from_millis(500), "{rtt:?}");
        assert!(mac.pings_as_datagrams(), "the Mac heard the phone's datagram");
        tokio::time::timeout(Duration::from_secs(2), mac.ping()).await.expect("datagram pong").unwrap();
        let stats = phone.take_ping_stats();
        assert_eq!((stats.sent, stats.answered, stats.waiting), (1, 1, 0));
        phone.close("done");
        mac.close("done");
    }

    /// A lost datagram ping is sent again; the round trip is the resend's,
    /// not the time since the first.
    #[tokio::test]
    async fn a_lost_datagram_ping_is_resent() {
        let (phone, mac) = stalled_pair();
        let (phone_lane, mac_lane) = datagram_pair(true, true, 2);
        phone.attach_liveness_datagrams(phone_lane);
        mac.attach_liveness_datagrams(mac_lane);
        let started = Instant::now();
        let rtt = tokio::time::timeout(Duration::from_secs(3), phone.ping()).await.expect("resent").unwrap();
        let waited = started.elapsed();
        assert!(waited >= DATAGRAM_PING_RESEND * 2, "answered after {waited:?}");
        assert!(rtt < Duration::from_millis(300), "rtt {rtt:?} counts the lost tries");
        phone.close("done");
        mac.close("done");
    }

    /// A datagram ping whose every try is lost goes into the stream too, so
    /// it is still answered (the unaligned keepalive waits for its pong).
    #[tokio::test]
    async fn a_datagram_ping_falls_back_to_the_stream() {
        let (phone, mac) = pair();
        let (phone_lane, mac_lane) = datagram_pair(true, true, usize::MAX);
        phone.attach_liveness_datagrams(phone_lane);
        mac.attach_liveness_datagrams(mac_lane);
        let started = Instant::now();
        tokio::time::timeout(Duration::from_secs(5), phone.ping()).await.expect("stream pong").unwrap();
        let waited = started.elapsed();
        let tries = DATAGRAM_PING_RESEND * u32::from(DATAGRAM_PING_ATTEMPTS);
        assert!(waited >= tries, "answered after {waited:?}, before the stream fallback");
        phone.close("done");
        mac.close("done");
    }

    /// A stream ping sent before the peer was heard on datagrams (stuck
    /// behind a stalled stream here) is answered by datagram once it is.
    #[tokio::test]
    async fn a_stream_ping_gets_datagram_tries_once_the_peer_is_heard() {
        let (phone, mac) = stalled_pair();
        let (phone_lane, mac_lane) = datagram_pair(true, true, 0);
        let mac_lane = LivenessDatagrams { peer_listening: false, ..mac_lane };
        phone.attach_liveness_datagrams(phone_lane);
        mac.attach_liveness_datagrams(mac_lane);
        let waiting = tokio::spawn({
            let mac = mac.clone();
            async move { mac.ping().await }
        });
        tokio::time::sleep(Duration::from_millis(100)).await;
        // The phone's first ping makes the Mac switch.
        tokio::time::timeout(Duration::from_secs(2), phone.ping()).await.expect("phone pong").unwrap();
        let rtt =
            tokio::time::timeout(Duration::from_secs(2), waiting).await.expect("answered").unwrap().unwrap();
        assert!(rtt < Duration::from_millis(300), "rtt {rtt:?} is the datagram try's");
        phone.close("done");
        mac.close("done");
    }

    /// Until the peer is known to listen, pings stay in the stream: a phone
    /// whose Mac has no datagram lane pings as before.
    #[tokio::test]
    async fn pings_stay_in_the_stream_until_the_peer_listens() {
        let (phone, mac) = pair();
        let (phone_lane, _mac_lane) = datagram_pair(true, false, 0);
        phone.attach_liveness_datagrams(phone_lane);
        assert!(!phone.pings_as_datagrams());
        tokio::time::timeout(Duration::from_secs(2), phone.ping()).await.expect("stream pong").unwrap();
        assert!(!phone.pings_as_datagrams());
        phone.close("done");
        mac.close("done");
    }

    /// Liveness datagrams across `dark` (dropped while it is true, as a dead
    /// path drops them), counting what the phone sends.
    fn gated_datagrams(
        dark: &watch::Sender<bool>,
        phone_sent: Arc<AtomicU64>,
    ) -> (LivenessDatagrams, LivenessDatagrams) {
        fn wire(
            dark: watch::Receiver<bool>,
            sent: Option<Arc<AtomicU64>>,
        ) -> (mpsc::Sender<Vec<u8>>, mpsc::Receiver<Vec<u8>>) {
            let (outgoing, mut from) = mpsc::channel::<Vec<u8>>(64);
            let (delivered, incoming) = mpsc::channel(64);
            tokio::spawn(async move {
                while let Some(datagram) = from.recv().await {
                    if let Some(sent) = &sent {
                        sent.fetch_add(1, Ordering::Relaxed);
                    }
                    if !*dark.borrow() {
                        let _ = delivered.try_send(datagram);
                    }
                }
            });
            (outgoing, incoming)
        }
        let (phone_out, mac_in) = wire(dark.subscribe(), Some(phone_sent));
        let (mac_out, phone_in) = wire(dark.subscribe(), None);
        (
            LivenessDatagrams { outgoing: phone_out, incoming: phone_in, peer_listening: true },
            LivenessDatagrams { outgoing: mac_out, incoming: mac_in, peer_listening: true },
        )
    }

    /// In the foreground the phone probes every `FOREGROUND_PROBE` over the
    /// datagram lane and is suspect after `FOREGROUND_PROBE_MISSES` of them
    /// go unanswered: within 3 x 3 s of the network going dark, not the
    /// 15 s keepalive plus `SUSPECT_AFTER`. Backgrounded it is the keepalive
    /// alone again.
    #[tokio::test(start_paused = true)]
    async fn a_foreground_probe_finds_a_dark_link_in_two_misses() {
        let (phone, mac, dark) = gated_pair(LinkConfig::default(), LinkConfig::default());
        let sent = Arc::new(AtomicU64::new(0));
        let (phone_lane, mac_lane) = gated_datagrams(&dark, Arc::clone(&sent));
        phone.attach_liveness_datagrams(phone_lane);
        mac.attach_liveness_datagrams(mac_lane);
        assert!(!phone.foreground_probe());
        phone.set_foreground_probe(true);
        // Settle into the probe's beat, between two probes.
        tokio::time::sleep(Duration::from_millis(16_500)).await;
        assert!(!phone.is_suspect() && !mac.is_suspect(), "a false suspect on a live link");
        let began = Instant::now();
        dark.send_replace(true);
        let bound = FOREGROUND_PROBE * (FOREGROUND_PROBE_MISSES + 1) + Duration::from_millis(10);
        let at = tokio::time::timeout(bound, suspect_after(&phone, began))
            .await
            .expect("suspect within three foreground probes");
        assert!(at >= FOREGROUND_PROBE * FOREGROUND_PROBE_MISSES - FOREGROUND_PROBE, "suspect after {at:?}");
        dark.send_replace(false);
        let mut state = phone.suspect_state();
        tokio::time::timeout(SUSPECT_PROBE + Duration::from_millis(100), state.wait_for(|suspect| !suspect))
            .await
            .expect("alive again within one suspect probe")
            .unwrap();
        // Backgrounded: a quiet minute costs the keepalive's pings alone.
        phone.set_foreground_probe(false);
        tokio::time::sleep(Duration::from_secs(1)).await;
        let from = sent.load(Ordering::Relaxed);
        tokio::time::sleep(Duration::from_secs(60)).await;
        let background = sent.load(Ordering::Relaxed) - from;
        // Its keepalive pings and its pongs to the Mac's: 4 each.
        assert!(background <= 10, "{background} datagrams in a backgrounded minute");
        phone.set_foreground_probe(true);
        let from = sent.load(Ordering::Relaxed);
        tokio::time::sleep(Duration::from_secs(60)).await;
        let foreground = sent.load(Ordering::Relaxed) - from;
        // 20 probes besides.
        assert!((26..=32).contains(&foreground), "{foreground} datagrams in a foreground minute");
        assert!(!phone.is_closed() && !mac.is_closed());
        phone.close("done");
        mac.close("done");
    }

    /// With no datagram lane (WebRTC, loopback) the foreground probe stays
    /// off: the link pings only on its keepalive.
    #[tokio::test(start_paused = true)]
    async fn no_datagram_lane_no_foreground_probe() {
        let (phone, mac, _dark) = gated_pair(LinkConfig::default(), LinkConfig::default());
        phone.set_foreground_probe(true);
        tokio::time::sleep(Duration::from_secs(31)).await;
        assert_eq!(phone.take_ping_stats().sent, 2, "only the keepalive's pings");
        phone.close("done");
        mac.close("done");
    }
}
