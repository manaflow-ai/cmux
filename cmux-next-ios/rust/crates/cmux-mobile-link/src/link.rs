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

use crate::classes::{Delivery, ScreenState, Sequencer};
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
/// in priority order rather than one large batch. One data chunk: small
/// frames still go out together, and a transport that holds writes while
/// its unsent bytes are at a low-water mark (cmux-wg's streams) holds at
/// most one chunk the scheduler has already committed, so a frame queued
/// meanwhile still goes next by priority.
const FLUSH_BYTES: usize = DATA_CHUNK;
/// How long an attached lane may stay silent before it is given up.
const LANE_CONFIRM: Duration = Duration::from_secs(10);
/// How long opening an input-lane channel waits for a negotiated lane that
/// is still connecting before it falls back to the main stream.
const LANE_WAIT: Duration = Duration::from_secs(2);
/// How long a channel's owner may leave its full queue unread before that
/// channel is closed (`overflow`). A silence bound: each event waits afresh
/// for one free slot, so an owner that reads at all within it keeps the
/// channel however long its backlog takes.
const CHANNEL_STALL: Duration = Duration::from_secs(3);
/// Bytes one channel may hold between the link reader and its owner's queue
/// ([`Inbox`]) before the reader waits for it. Above the god sessions' bursts
/// (20,000 deltas after an outage is about 20 MB), so a channel read slowly
/// never holds the others; still a bound on what one channel can hold.
const CHANNEL_BUFFER_BYTES: usize = 64 * 1024 * 1024;

/// The service a phone opens to park the link before the OS suspends it
/// (PROTOCOL.md "Parked link"). A side that knows it answers `close` with
/// [`PARKED`]; an older one answers `unknown_service`.
pub const PARK_SERVICE: &str = "_link.park";
/// The `close` code that accepts a park.
pub const PARKED: &str = "parked";
/// Park argument advertising lossless, independently deflated data frames.
const PARK_ENCODING: &str = "deflate-v1";
/// The longest hold a side grants; a longer ask is cut to this.
pub const MAX_PARK_HOLD: Duration = Duration::from_secs(10 * 60);
/// The tunnel holds its connections this much past the park, so the link's
/// own expiry (a clean close) comes first.
const PARK_TRANSPORT_MARGIN: Duration = Duration::from_secs(30);

/// Applies a park to the transport under the link: `Some(hold)` holds the
/// tunnel's connections for a silent peer (`cmux_wg::WgNet::hold`), `None`
/// releases them. Calls arrive in order, one at a time.
pub type HoldHook =
    Arc<dyn Fn(Option<Duration>) -> futures_util::future::BoxFuture<'static, ()> + Send + Sync>;

/// Whether the link is parked (PROTOCOL.md "Parked link").
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Park {
    Off,
    /// Neither side expects the other until `until`: no keepalive, and the
    /// Mac sends only control frames. Past `until` the link closes.
    Parked {
        until: Instant,
        deflate: bool,
    },
    /// The phone is back ([`Link::resume`]); the first frame from the Mac
    /// ends the park on this side.
    Resuming,
}

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
/// A resumed parked link that has not answered after this many smoothed
/// round trips, plus [`RESUME_HEDGE_SLACK`], is presumed stale and a fresh
/// dial is started next to it (the old link keeps being probed; whichever
/// answers first is kept). A live resume answers in two round trips: the
/// tunnel's handshake on its new socket, then the ping's pong. The third
/// round trip and the slack absorb jitter and one lost datagram's pacing.
pub const RESUME_HEDGE_RTT_FACTOR: u32 = 3;
/// Fixed slack on top of [`RESUME_HEDGE_RTT_FACTOR`] round trips: wake-up
/// scheduling and the radio's promotion from idle.
pub const RESUME_HEDGE_SLACK: Duration = Duration::from_millis(100);
/// The hedge never fires sooner: under this, a healthy resume on a fast
/// path still races a needless dial.
pub const RESUME_HEDGE_FLOOR: Duration = Duration::from_millis(250);
/// Nor later than the parked-resume probe's own 1.5 s: past that the app
/// already gives up on the old link and redials.
pub const RESUME_HEDGE_CAP: Duration = Duration::from_millis(1500);
/// With no round trip measured on the link yet.
pub const RESUME_HEDGE_UNKNOWN: Duration = Duration::from_millis(500);

fn resume_hedge_after(srtt: Option<Duration>) -> Duration {
    srtt.map_or(RESUME_HEDGE_UNKNOWN, |srtt| {
        (srtt.saturating_mul(RESUME_HEDGE_RTT_FACTOR) + RESUME_HEDGE_SLACK)
            .clamp(RESUME_HEDGE_FLOOR, RESUME_HEDGE_CAP)
    })
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
/// How long a link stays quiet (nothing heard, no datagram ping sent)
/// before [`Link::prewake`] sends: a radio that heard or sent this recently
/// is still awake.
const PREWAKE_QUIET: Duration = Duration::from_secs(1);
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
    /// The peer listed [`crate::classes::CLASSES_LANE`]: input and state
    /// channels send their messages as datagrams too (`crate::classes`).
    pub classes: bool,
    /// The peer also listed [`crate::classes::SCREEN_LANE`]: a
    /// [`Delivery::Screen`] channel sends screen datagrams.
    pub screen: bool,
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
    /// The reliable link ([`crate::reliable`]): set only when both sides
    /// listed [`crate::reliable::RELIABLE_LANE`]. `None` (the default) sends
    /// exactly the frames of a link without it.
    pub reliable: Option<ReliableConfig>,
}

impl Default for LinkConfig {
    fn default() -> Self {
        Self {
            keepalive: Some(Duration::from_secs(15)),
            keepalive_timeout: KEEPALIVE_TIMEOUT,
            aligned: false,
            suspect_after: Some(SUSPECT_AFTER),
            foreground_probe: false,
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
    /// The channel's messages also travel as datagrams, delivered this way
    /// (`crate::classes`). Only sent to a peer that listed
    /// [`crate::classes::CLASSES_LANE`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub delivery: Option<Delivery>,
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
                *queues.bytes.entry(frame.channel).or_default() += frame.queue_bytes();
                queues.input.push_back(frame);
            }
            Class::Bulk => {
                let channel = frame.channel;
                *queues.bytes.entry(channel).or_default() += frame.queue_bytes();
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
                let size = frame.queue_bytes();
                if (used == 0 || used + size <= CHANNEL_QUEUE_BYTES)
                    && (held == 0 || held.saturating_add(size) <= budget)
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

    /// Puts back a frame [`Outbox::pop`] gave a writer whose carrier is
    /// over: it goes out first on the next carrier, ahead of the rest of
    /// its channel.
    fn unpop(&self, frame: Frame) {
        self.lock().control.push_front(frame);
        self.ready.notify_one();
    }

    /// The next frame by priority, without waiting. `held`: only control
    /// frames go (a parked Mac's writer; channel data waits in its queue).
    fn pop(&self, held: bool) -> Option<Next> {
        let mut queues = self.lock();
        if let Some(frame) = queues.control.pop_front() {
            return Some(Next::Frame(frame));
        }
        if held && !queues.shutdown {
            return None;
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
            *used = used.saturating_sub(frame.queue_bytes());
            if *used == 0 {
                queues.bytes.remove(&frame.channel);
            }
            drop(queues);
            self.room.notify_waiters();
        }
        Some(Next::Frame(frame))
    }

    async fn next(&self, held: &AtomicBool) -> Next {
        loop {
            let ready = self.ready.notified();
            tokio::pin!(ready);
            ready.as_mut().enable();
            if let Some(next) = self.pop(held.load(Ordering::Acquire)) {
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
    /// Puts numbered messages (stream chunks and datagrams) back in order
    /// for a channel opened with a [`Delivery`].
    sequencer: Option<Arc<tokio::sync::Mutex<Sequencer>>>,
    /// A [`Delivery::Screen`] channel's acknowledgement and copy state,
    /// shared with its sender.
    screen: Option<Arc<ScreenState>>,
}

impl Route {
    fn new(inbox: Inbox, closed: &Arc<AtomicBool>, delivery: Option<Delivery>) -> Self {
        let sequencer = delivery.map(|delivery| Arc::new(tokio::sync::Mutex::new(Sequencer::new(delivery))));
        let screen = (delivery == Some(Delivery::Screen)).then(|| Arc::new(ScreenState::new()));
        Self { inbox, closed: Arc::clone(closed), sequencer, screen }
    }
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

/// What [`Inner::seal`] made of a frame a writer took.
enum Sealed {
    /// Write it (sequenced on a reliable link).
    Send(Frame),
    /// Its channel is done; drop it.
    Skip,
    /// The writer's carrier is over: put it back, unlogged.
    Superseded(Frame),
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
    /// When the link last made progress ([`Link::progress_ago`]): a frame or
    /// datagram heard from the peer, or a write other than a keepalive taken
    /// by the transport.
    last_progress: Mutex<Instant>,
    /// How many times the link made progress ([`Link::progress_count`]).
    progress: AtomicU64,
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
    /// The peer takes class datagrams (`crate::classes`).
    classes: AtomicBool,
    /// The peer takes screen datagrams and acknowledges them.
    screen: AtomicBool,
    /// Messages delivered from a class datagram ahead of their stream copy.
    datagram_wins: AtomicU64,
    /// The phone app is in the foreground with a surface on screen
    /// ([`Link::set_foreground_probe`]).
    foreground: watch::Sender<bool>,
    rtt: watch::Sender<Option<Duration>>,
    /// The smoothed round trip of answered pings ([`Link::probe_timeout`]).
    srtt: Mutex<Option<Duration>>,
    /// When a round trip (the app's heartbeat, the keepalive) last sent its
    /// first ping as a datagram: the foreground probe takes it for its own.
    last_datagram_ping: Mutex<Option<Instant>>,
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
    park: watch::Sender<Park>,
    /// A parked Mac sends only control frames (the writers read this).
    writes_held: AtomicBool,
    /// The next explicit probe must wake the Mac on the ordered stream.
    resume_probe: AtomicBool,
    /// What the transport should hold ([`HoldHook`]); one task applies it.
    transport_hold: watch::Sender<Option<Duration>>,
    /// The task running the transport's [`HoldHook`]; a reliable link's
    /// next carrier brings its own and replaces it.
    hold_hook: Mutex<Option<JoinHandle<()>>>,
    /// Tests: while `true`, a keepalive beat's pinger waits here before it
    /// pings, as a pinger the scheduler runs late does.
    #[cfg(test)]
    pinger_gate: watch::Sender<bool>,
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
    /// for replay ([`Sealed`]). Runs as the writer of carrier `carrier` (its
    /// generation; `None` off a reliable link) takes the frame, so sequences
    /// follow wire order.
    fn seal(&self, frame: Frame, carrier: Option<u64>) -> Sealed {
        let Some(reliable) = &self.reliable else { return Sealed::Send(frame) };
        if frame.channel == 0
            || !matches!(
                frame.kind,
                FrameType::Open
                    | FrameType::Data
                    | FrameType::DeflatedData
                    | FrameType::Sequenced
                    | FrameType::Close
            )
        {
            return Sealed::Send(frame);
        }
        let channel = frame.channel;
        let last = frame.kind == FrameType::Close;
        let (sequence, over) = {
            let mut state = reliable.lock();
            // A writer whose carrier is over logs nothing more: the next
            // carrier's replay may already have read the log, so a frame
            // logged now would reach the peer on no carrier (a hole).
            // Checked under the log's lock, which the replay takes after
            // the generation moved.
            if let Some(mine) = carrier
                && *reliable.generation.borrow() != mine
            {
                return Sealed::Superseded(frame);
            }
            if state.forgotten.contains(channel) {
                return Sealed::Skip;
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
            return Sealed::Skip;
        }
        let mut sealed =
            Frame::new(channel, FrameType::Seq, rel::seq_payload(sequence, frame.kind, &frame.payload));
        sealed.flushed = frame.flushed;
        Sealed::Send(sealed)
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
        // The liveness datagrams rode that carrier's tunnel: pings go in the
        // stream until the next carrier attaches its own.
        *self.datagrams.lock().unwrap_or_else(PoisonError::into_inner) = None;
        self.datagram_pings.store(false, Ordering::Relaxed);
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

    /// Run `send` (queue a keepalive ping, as a datagram or in the stream)
    /// unless the link is parked: `Ok(false)` when parked. The check and
    /// the send hold the park's lock, as [`Self::set_parked`] does, so a
    /// beat that fired before a park either queues its ping ahead of the
    /// park's open or sends nothing; a ping after the park would end the
    /// Mac's park while the phone sleeps.
    fn send_keepalive(&self, send: impl FnOnce() -> Result<(), LinkError>) -> Result<bool, LinkError> {
        let mut sent = Ok(false);
        self.park.send_if_modified(|park| {
            if !matches!(park, Park::Parked { .. }) {
                sent = send().map(|()| true);
            }
            false
        });
        sent
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

    fn classes(&self) -> bool {
        self.classes.load(Ordering::Relaxed)
            && self.datagrams.lock().unwrap_or_else(PoisonError::into_inner).is_some()
    }

    fn screen(&self) -> bool {
        self.screen.load(Ordering::Relaxed) && self.classes()
    }

    /// Queue class datagrams to the peer, best effort: a full queue drops them.
    fn send_class_datagrams(&self, datagrams: Vec<Vec<u8>>) {
        self.send_datagram_copies(datagrams, crate::classes::COPIES);
    }

    fn send_datagram_copies(&self, datagrams: Vec<Vec<u8>>, copies: usize) {
        let Some(sender) = self.datagrams.lock().unwrap_or_else(PoisonError::into_inner).clone() else {
            return;
        };
        for _ in 0..copies {
            for datagram in &datagrams {
                let _ = sender.try_send(datagram.clone());
            }
        }
    }

    /// Tell the peer the newest screen message delivered on `channel`.
    fn acknowledge_screen(&self, channel: u32, delivered: &[Bytes]) {
        let seq = delivered.last().and_then(|message| message.get(..8)).and_then(|seq| seq.try_into().ok());
        if let Some(seq) = seq {
            let ack = crate::classes::screen_ack(channel, u64::from_be_bytes(seq));
            self.send_datagram_copies(vec![ack], crate::classes::COPIES);
        }
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
        let now = Instant::now();
        *self.last_rx.lock().unwrap_or_else(PoisonError::into_inner) = now;
        self.progressed(now);
        // Anything from the peer clears a suspect link at once.
        if self.suspect_flag.load(Ordering::Relaxed) && self.suspect_flag.swap(false, Ordering::Relaxed) {
            self.suspect.send_replace(false);
            tracing::debug!("link alive again");
        }
    }

    /// The writer sent frames other than pings and pongs (data, open,
    /// close): note the first since the last inbound frame.
    fn sent_traffic(&self) {
        self.progressed(Instant::now());
        self.note_unanswered(|unanswered| &mut unanswered.traffic);
    }

    /// The link moved: something was heard, or a write was taken.
    fn progressed(&self, now: Instant) {
        *self.last_progress.lock().unwrap_or_else(PoisonError::into_inner) = now;
        self.progress.fetch_add(1, Ordering::Relaxed);
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

    /// Park for `hold`: no keepalive on either side, the transport held, and
    /// on the Mac only control frames written, until the peer is heard again
    /// or `hold` passes (then the link closes).
    fn set_parked(&self, hold: Duration, deflate: bool) {
        let hold = hold.min(MAX_PARK_HOLD);
        if self.role == Role::Mac {
            self.writes_held.store(true, Ordering::Release);
        }
        self.park.send_replace(Park::Parked { until: Instant::now() + hold, deflate });
        self.transport_hold.send_replace(Some(hold + PARK_TRANSPORT_MARGIN));
        tracing::debug!(role = ?self.role, ?hold, "link parked");
    }

    /// End a park: the keepalive, the transport's own timeouts and every
    /// queued write resume. Called only once the peer was heard (a frame
    /// just arrived), so the transport's restored timeouts start fresh.
    fn unpark(&self) {
        let was = self.park.send_replace(Park::Off);
        if was == Park::Off {
            return;
        }
        self.writes_held.store(false, Ordering::Release);
        for outbox in &self.outboxes {
            outbox.ready.notify_one();
        }
        self.transport_hold.send_replace(None);
        tracing::debug!(role = ?self.role, "link unparked");
    }

    /// The park's deadline, while parked.
    fn parked_until(&self) -> Option<Instant> {
        match *self.park.borrow() {
            Park::Parked { until, .. } => Some(until),
            Park::Off | Park::Resuming => None,
        }
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

/// What [`Link::accept_reliable`] made of a carrier.
pub enum Accepted {
    /// A new link: serve it. Also a phone's `Reopen` of a link whose first
    /// carrier dropped before this Mac read its hello.
    New(Link),
    /// The carrier resumed this (already served) link.
    Resumed(Link),
}

/// What one [`Link::resume_carrier`] did.
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
            last_progress: Mutex::new(Instant::now()),
            progress: AtomicU64::new(0),
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
            classes: AtomicBool::new(false),
            screen: AtomicBool::new(false),
            datagram_wins: AtomicU64::new(0),
            foreground: watch::channel(config.foreground_probe).0,
            rtt: watch::channel(None).0,
            srtt: Mutex::new(None),
            last_datagram_ping: Mutex::new(None),
            ping_stats: Mutex::new(PingStats::default()),
            closed: watch::channel(None).0,
            incoming: tokio::sync::Mutex::new(incoming_rx),
            incoming_tx: Mutex::new(Some(incoming_tx)),
            tasks: Mutex::new(Vec::new()),
            transport: Mutex::new(transport),
            media: Mutex::new(None),
            park: watch::channel(Park::Off).0,
            writes_held: AtomicBool::new(false),
            resume_probe: AtomicBool::new(false),
            transport_hold: watch::channel(None).0,
            hold_hook: Mutex::new(None),
            #[cfg(test)]
            pinger_gate: watch::channel(false).0,
        })
    }

    /// The link's own tasks beside its carrier: the liveness watchdog, the
    /// keepalive and, on a reliable link, the ack timer.
    fn start(inner: Arc<Inner>, config: &LinkConfig) -> Self {
        let mut tasks = Vec::new();
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
            // The phone pings every interval, busy or not: its pongs are
            // the link's round-trip samples. The Mac pings only after
            // `interval` and a quarter with nothing heard: any frame, a
            // pong or the phone's own ping, proves the phone as a pong of
            // its own would. On an idle link the phone's pings arrive first
            // and the Mac only answers: one ping and one pong per interval,
            // not two of each. Its timeout counts from that quarter earlier, so it
            // still closes `interval + keepalive_timeout` after the last
            // frame at the latest, as before; and it is suspect when its own
            // ping would have made it (`suspect_after` past the interval),
            // since the phone's ping is due before then.
            let extra = if link.inner.role == Role::Mac { interval / 4 } else { Duration::ZERO };
            let suspect_after = config.suspect_after.filter(|after| !extra.is_zero() && *after < extra);
            // `config` is borrowed: the task takes its own copy of the timeout.
            let timeout = config.keepalive_timeout;
            tasks.push(tokio::spawn(async move {
                let mut closed = link.inner.closed.subscribe();
                let mut last_ping = Instant::now();
                'beat: loop {
                    loop {
                        let base = if extra.is_zero() {
                            last_ping
                        } else {
                            link.inner.last_received().max(last_ping)
                        };
                        let due = base + interval + extra;
                        let now = Instant::now();
                        if due <= now {
                            break;
                        }
                        let suspect_at = suspect_after
                            .map(|after| base + interval + after)
                            .filter(|_| !link.inner.suspect_flag.load(Ordering::Relaxed));
                        if let Some(at) = suspect_at
                            && at <= now
                            && link.inner.parked_until().is_none()
                        {
                            link.inner.raise_suspect(base + interval);
                            // The watchdog sleeps on an idle link: wake it to probe.
                            link.inner.unanswered_changed.notify_one();
                        }
                        let wake = suspect_at.filter(|at| *at > now).map_or(due, |at| at.min(due));
                        tokio::select! {
                            () = tokio::time::sleep_until(wake) => {}
                            _ = closed.wait_for(Option::is_some) => return,
                        }
                    }
                    // Neither a parked link nor a reliable link's dropped
                    // carrier is pinged.
                    if !wait_until_pingable(&link).await {
                        return;
                    }
                    let sent = Instant::now();
                    last_ping = sent;
                    let credited = sent.checked_sub(extra).unwrap_or(sent);
                    // Not sent if a park came since the check above.
                    let ping = link.round_trip(true);
                    tokio::pin!(ping);
                    loop {
                        // Wait for the pong, but count any inbound frame as
                        // life: a pong can trail a full transmit queue.
                        let deadline = link.inner.last_received().max(credited) + timeout;
                        tokio::select! {
                            result = &mut ping => {
                                if result.is_err() {
                                    return;
                                }
                                break;
                            }
                            () = tokio::time::sleep_until(deadline) => {
                                // Parked since the ping: its pong may never come.
                                if link.inner.parked_until().is_some() {
                                    break;
                                }
                                let quiet_since = link.inner.last_received().max(credited);
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
    pub async fn resume_carrier<S>(
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
    /// dropped carrier waits for [`Link::resume_carrier`] (phone) or
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

    /// Carry this link's pings and pongs as datagrams too
    /// ([`LivenessDatagrams`]). Pings switch to datagrams at once when the
    /// peer is listening, else on the first datagram it sends; in-stream
    /// pings are still answered. A second attach is ignored.
    pub fn attach_liveness_datagrams(&self, lane: LivenessDatagrams) {
        let LivenessDatagrams { outgoing, incoming, peer_listening, classes, screen } = lane;
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
        self.inner.classes.store(classes, Ordering::Relaxed);
        self.inner.screen.store(screen && classes, Ordering::Relaxed);
        let reader = tokio::spawn(read_datagrams(Arc::clone(&self.inner), incoming));
        self.inner.tasks.lock().unwrap_or_else(PoisonError::into_inner).push(reader);
        tracing::debug!(role = ?self.inner.role, peer_listening, classes, "liveness datagrams attached");
    }

    /// Whether input and state channels send their messages as datagrams
    /// too (the peer listed [`crate::classes::CLASSES_LANE`]).
    pub fn class_datagrams(&self) -> bool {
        self.inner.classes()
    }

    /// Whether [`Delivery::Screen`] channels send screen datagrams (the peer
    /// listed [`crate::classes::SCREEN_LANE`] as well). When not, the app
    /// sends its screen updates as plain stream messages.
    pub fn screen_datagrams(&self) -> bool {
        self.inner.screen()
    }

    /// Messages this side took from a class datagram ahead of their stream
    /// copy, since the link opened.
    pub fn datagram_wins(&self) -> u64 {
        self.inner.datagram_wins.load(Ordering::Relaxed)
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

    /// Wake the radio before a keystroke: one datagram ping, unanswered by
    /// any waiter, when the link has heard nothing for [`PREWAKE_QUIET`] and
    /// sent no datagram ping as long. A cellular radio sleeps (DRX, then RRC
    /// idle) after a short silence and a wake costs 50-300 ms (RFD 0142
    /// hypothesis 2); a ping sent as the keyboard takes focus or a finger
    /// touches down pays that while the person is still reaching for the key.
    /// The peer's pong wakes the downlink too. `true` when sent; `false` on a
    /// link with no datagram pings, parked, closed or not quiet (no cost).
    pub fn prewake(&self) -> bool {
        let inner = &self.inner;
        if !inner.datagram_pings() || inner.closed_reason().is_some() || inner.parked_until().is_some() {
            return false;
        }
        let now = Instant::now();
        if now.saturating_duration_since(inner.last_received()) < PREWAKE_QUIET {
            return false;
        }
        let mut last = inner.last_datagram_ping.lock().unwrap_or_else(PoisonError::into_inner);
        if last.is_some_and(|at| now.saturating_duration_since(at) < PREWAKE_QUIET) {
            return false;
        }
        let nonce = inner.next_nonce.fetch_add(1, Ordering::Relaxed);
        if !inner.send_datagram(DATAGRAM_PING, nonce, 0) {
            return false;
        }
        // The foreground probe takes it for its own round trip.
        *last = Some(now);
        drop(last);
        inner.ping_stats.lock().unwrap_or_else(PoisonError::into_inner).sent += 1;
        true
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
    ///
    /// When the peer takes class datagrams, an input-lane channel's messages
    /// also travel as datagrams, delivered in order ([`Delivery::Ordered`]).
    pub async fn open_on(
        &self,
        service: &str,
        args: serde_json::Value,
        lane: Lane,
    ) -> Result<Channel, LinkError> {
        let delivery = (lane == Lane::Input).then_some(Delivery::Ordered);
        self.open_with(service, args, lane, delivery).await
    }

    /// Open a channel for terminal screen state: each message is a whole
    /// state, and when the peer takes class datagrams they also travel as
    /// datagrams and only the newest reaches the reader
    /// ([`Delivery::Latest`]). Otherwise a main-stream channel.
    pub async fn open_latest(&self, service: &str, args: serde_json::Value) -> Result<Channel, LinkError> {
        self.open_with(service, args, Lane::Bulk, Some(Delivery::Latest)).await
    }

    /// A main-stream channel for terminal screen updates: when both peers
    /// listed [`crate::classes::SCREEN_LANE`], its messages go as screen
    /// datagrams (the screen class, acknowledged, see
    /// [`ChannelSender::send_screen`]) and come out as [`Delivery::Screen`]
    /// messages ([`crate::classes::screen_message`]). Otherwise it is a plain
    /// stream channel ([`Channel::screen_class`] is false): the app sends and
    /// reads its updates as before.
    pub async fn open_screen(&self, service: &str, args: serde_json::Value) -> Result<Channel, LinkError> {
        self.open_with(service, args, Lane::Bulk, Some(Delivery::Screen)).await
    }

    /// [`Link::open_on`] with its messages also sent as datagrams and
    /// delivered as `delivery` says, when the peer takes class datagrams.
    pub async fn open_with(
        &self,
        service: &str,
        args: serde_json::Value,
        lane: Lane,
        delivery: Option<Delivery>,
    ) -> Result<Channel, LinkError> {
        let delivery = delivery.filter(|delivery| match delivery {
            Delivery::Screen => self.inner.screen(),
            _ => self.inner.classes(),
        });
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
        let route = Route::new(inbox, &closed, delivery);
        let screen = route.screen.clone();
        self.inner.lock_channels().insert(id, route);
        let payload = serde_json::to_vec(&OpenRequest { service: service.to_owned(), args, lane, delivery })
            .expect("open request serializes");
        if let Err(error) = self.inner.push(stream, class, Frame::new(id, FrameType::Open, payload)) {
            self.inner.lock_channels().remove(&id);
            return Err(error);
        }
        Ok(Channel::new(id, stream, class, Arc::clone(&self.inner), rx, closed, delivery, screen))
    }

    /// The next channel the peer opened, or `None` once the link is closed.
    pub async fn accept(&self) -> Option<IncomingChannel> {
        self.inner.incoming.lock().await.recv().await
    }

    /// Round-trip one ping.
    pub async fn ping(&self) -> Result<Duration, LinkError> {
        // Not a keepalive: always sent, so always a round trip.
        self.round_trip(false).await.map(Option::unwrap_or_default)
    }

    /// Round-trip one ping; a `keepalive` ping is not sent while parked
    /// (`Ok(None)`).
    async fn round_trip(&self, keepalive: bool) -> Result<Option<Duration>, LinkError> {
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
        // A keepalive ping is not sent at all while parked.
        let mut datagram = false;
        let mut first = || {
            // An ordinary datagram can arrive after a later park. Only the
            // ordered stream proves this wake follows the request to park.
            let wake = !keepalive && self.inner.resume_probe.swap(false, Ordering::AcqRel);
            datagram = !wake && self.inner.datagram_pings() && {
                if self.inner.closed_reason().is_some() {
                    return Err(self.inner.closed_error());
                }
                self.inner.send_datagram(DATAGRAM_PING, nonce, 0)
            };
            if datagram {
                *self.inner.last_datagram_ping.lock().unwrap_or_else(PoisonError::into_inner) =
                    Some(Instant::now());
            } else {
                self.inner.send_control(Frame::new(0, FrameType::Ping, nonce.to_be_bytes().to_vec()))?;
            }
            Ok(())
        };
        if keepalive {
            if !self.inner.send_keepalive(first)? {
                return Ok(None);
            }
        } else {
            first()?;
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
                    // Parked since the first send: no resend wakes the Mac.
                    let park = self.inner.park.borrow();
                    if matches!(*park, Park::Parked { .. }) {
                        if keepalive {
                            return Ok(None);
                        }
                        continue;
                    }
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
        Ok(Some(rtt))
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

    /// How long a resumed parked link may stay silent before a fresh dial
    /// is raced against it: [`RESUME_HEDGE_RTT_FACTOR`] smoothed round trips
    /// plus [`RESUME_HEDGE_SLACK`], within [`RESUME_HEDGE_FLOOR`] and
    /// [`RESUME_HEDGE_CAP`]. A remembered endpoint that died during the park
    /// then costs this plus the dial instead of the full 1.5 s probe plus it.
    pub fn resume_hedge_after(&self) -> Duration {
        resume_hedge_after(*self.inner.srtt.lock().unwrap_or_else(PoisonError::into_inner))
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

    /// How long ago the link last made progress: anything heard from the
    /// peer (a frame or a liveness datagram, keepalives included), or a write
    /// other than a ping or a pong taken by the transport. It starts at the
    /// link's creation.
    ///
    /// This is the one progress clock a sender's hold reads: a prompt queued
    /// on this link is stalled only once this has stayed quiet for the hold,
    /// however long ago it was tapped (Leo: "10s timeout for messages being
    /// sendsble is a shame. if it's making good progress, it shiukd be allowed
    /// to keep going?"). The phone's `PromptOutbox::progressed` is its adapter.
    pub fn progress_ago(&self) -> Duration {
        self.inner.last_progress.lock().unwrap_or_else(PoisonError::into_inner).elapsed()
    }

    /// How many times the link made progress (see [`progress_ago`](Self::progress_ago)).
    /// Monotonic: a reader that saw it change since its last look knows the
    /// link moved in between, without comparing clocks.
    pub fn progress_count(&self) -> u64 {
        self.inner.progress.load(Ordering::Relaxed)
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

    /// Phone, before the OS suspends the app: ask the Mac to hold this link
    /// for up to `hold` (at most [`MAX_PARK_HOLD`]) while the phone is
    /// silent, waiting at most `timeout` for the answer. On `Ok(true)` both
    /// sides are parked: no keepalives, the transport held, and the Mac
    /// writes only control frames until [`Link::resume`] and a ping. `Ok(false)`:
    /// the Mac predates parking or did not answer in time; nothing changed,
    /// and the link closes on silence as before.
    pub async fn park(&self, hold: Duration, timeout: Duration) -> Result<bool, LinkError> {
        let hold = hold.min(MAX_PARK_HOLD);
        let millis = u64::try_from(hold.as_millis()).unwrap_or(u64::MAX);
        // Parked before the ask: this side's keepalive must not ping in the
        // round trip, since a ping ends the Mac's park as soon as it starts.
        self.inner.set_parked(hold, false);
        let parked = match self
            .open(PARK_SERVICE, serde_json::json!({ "hold_ms": millis, "encoding": PARK_ENCODING }))
            .await
        {
            Ok(mut channel) => Ok(matches!(
                tokio::time::timeout(timeout, channel.recv()).await,
                Ok(Some(ChannelEvent::Closed(info))) if info.code == PARKED
            )),
            Err(error) => Err(error),
        };
        if parked != Ok(true) {
            // Not held over there: back to the keepalive. The transport keeps
            // its long timeout through the release grace.
            self.inner.unpark();
        }
        parked
    }

    /// Phone, back from the background: this side expects the Mac again.
    /// The keepalive restarts from now, and the park ends here at the first
    /// frame from the Mac; send a ping (a probe) so the Mac ends its own.
    /// `false` when the link was not parked (or its park already expired).
    pub fn resume(&self) -> bool {
        if self.inner.parked_until().is_none_or(|until| until <= Instant::now()) {
            return false;
        }
        self.inner.received();
        self.inner.resume_probe.store(true, Ordering::Release);
        self.inner.park.send_replace(Park::Resuming);
        true
    }

    /// Whether the link is parked (resuming counts as parked until the peer
    /// is heard).
    pub fn is_parked(&self) -> bool {
        *self.inner.park.borrow() != Park::Off
    }

    /// Run `hook` whenever the park changes what the transport should hold,
    /// in order, one call at a time (the WireGuard dialer's `WgNet::hold`).
    /// A reliable link's resumed carrier brings its own transport: its hook
    /// replaces the last one and gets a hold already in force.
    pub fn set_hold_hook(&self, hook: HoldHook) {
        let mut hold = self.inner.transport_hold.subscribe();
        if hold.borrow().is_some() {
            hold.mark_changed();
        }
        let mut closed = self.inner.closed.subscribe();
        let task = tokio::spawn(async move {
            loop {
                tokio::select! {
                    changed = hold.changed() => {
                        if changed.is_err() {
                            return;
                        }
                    }
                    _ = closed.wait_for(Option::is_some) => return,
                }
                let wanted = *hold.borrow_and_update();
                hook(wanted).await;
            }
        });
        let previous = self.inner.hold_hook.lock().unwrap_or_else(PoisonError::into_inner).replace(task);
        if let Some(previous) = previous {
            previous.abort();
        }
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
        // A parked Mac's writer takes only control frames, so held channel
        // data is not sealed either until the park ends.
        let next = tokio::select! {
            next = outbox.next(&inner.writes_held) => next,
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
        // Frames whose sender asked when they reach the transport (send_marked),
        // and whether the batch carries anything the peer answers.
        let mut marks: Vec<crate::frame::FlushMark> = Vec::new();
        let mut traffic = false;
        // A frame this carrier may no longer send goes back to the front of
        // the outbox for the next carrier's writer, and this one stops.
        let carrier = tag.as_ref().map(|(_, generation)| *generation);
        let mut take = |frame: Frame| match inner.seal(frame, carrier) {
            Sealed::Send(mut frame) => {
                marks.extend(frame.flushed.take());
                traffic |= expects_answer(frame.kind);
                Ok(Some(frame))
            }
            Sealed::Skip => Ok(None),
            Sealed::Superseded(frame) => {
                outbox.unpop(frame);
                Err(())
            }
        };
        let frame = match take(frame) {
            Ok(Some(frame)) => frame,
            Ok(None) => continue,
            Err(()) => return,
        };
        let batch = async {
            let mut pending = frame.payload.len();
            let mut pong = frame.kind == FrameType::Pong;
            let mut result = sink.feed(frame).await;
            let mut shutdown = false;
            // Hand a pong to the transport before feeding more queued output.
            while result.is_ok() && !pong && pending < FLUSH_BYTES {
                match outbox.pop(inner.writes_held.load(Ordering::Acquire)) {
                    Some(Next::Frame(frame)) => {
                        let frame = match take(frame) {
                            Ok(Some(frame)) => frame,
                            Ok(None) => continue,
                            Err(()) => return None,
                        };
                        pending += frame.payload.len();
                        pong = frame.kind == FrameType::Pong;
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

/// Whether the peer answers a frame of this kind with something: pings,
/// pongs and a reliable link's own acks, hellos and byes are not traffic
/// the liveness watchdog waits on.
fn expects_answer(kind: FrameType) -> bool {
    !matches!(kind, FrameType::Ping | FrameType::Pong | FrameType::Ack | FrameType::Hello | FrameType::Bye)
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
            let _ = tokio::time::timeout(after, pinger.round_trip(true)).await;
        });
    };
    let mut last_probe: Option<Instant> = None;
    loop {
        // The Mac's park reply is deliberately the last unanswered frame.
        // Silence only indicates a dead path while we expect the peer to answer.
        if inner.parked_until().is_some() {
            if !wait_out_park(&link).await {
                return;
            }
            last_probe = None;
        }
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
        if inner.parked_until().is_some() {
            if !wait_out_park(&link).await {
                return;
            }
            continue;
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
            let retry = tokio::select! {
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
                () = tokio::time::sleep_until(resend_at.unwrap_or(tick)), if resend_at.is_some() => true,
                () = tokio::time::sleep_until(tick) => false,
            };
            // Serialize each send with set_parked, including a retry already due.
            let park = inner.park.borrow();
            if matches!(*park, Park::Parked { .. }) {
                break;
            }
            if retry {
                resent = true;
                if let Some((at, nonce)) = last
                    && inner.last_received() < at
                    && !inner.suspect_flag.load(Ordering::Relaxed)
                {
                    inner.send_datagram(DATAGRAM_PING, nonce, 1);
                }
                continue;
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
            // A datagram ping another round trip (the app's heartbeat, the
            // keepalive) sent within the last beat, after the ping judged
            // above, proves the link as one of ours would: judge it a beat
            // after it left, which is no later than ours would be, instead
            // of sending another. Its resends are its own round trip's.
            let other = *inner.last_datagram_ping.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some(other) = other
                && now.checked_sub(FOREGROUND_PROBE).is_none_or(|beat_ago| other > beat_ago)
                && last.is_none_or(|(at, _)| other > at)
            {
                (last, resent) = (Some((other, 0)), true);
                tick = (other + FOREGROUND_PROBE).max(now);
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

/// While the link is parked, wait for the park to end. `false` when the link
/// ended instead: it closed, or the park expired and it is closed here.
async fn wait_out_park(link: &Link) -> bool {
    let mut park = link.inner.park.subscribe();
    let mut closed = link.inner.closed.subscribe();
    loop {
        let Some(until) = link.inner.parked_until() else {
            return !link.is_closed();
        };
        tokio::select! {
            _ = closed.wait_for(Option::is_some) => return false,
            changed = park.changed() => {
                if changed.is_err() {
                    return false;
                }
            }
            () = tokio::time::sleep_until(until) => {
                if link.inner.parked_until().is_some_and(|until| until <= Instant::now()) {
                    link.inner.shut("park expired");
                    return false;
                }
            }
        }
    }
}

/// Until the keepalive may ping: the link is not parked and, on a reliable
/// link, its carrier is up. `false` when the link ended instead.
async fn wait_until_pingable(link: &Link) -> bool {
    loop {
        link.inner.carrier_up().await;
        if !wait_out_park(link).await {
            return false;
        }
        if !link.inner.carrier_is_down() {
            return true;
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
        if link.inner.parked_until().is_some() {
            if !wait_out_park(&link).await {
                return;
            }
            unanswered = None;
            beat = crate::keepalive::next_beat(Instant::now(), interval);
        }
        if unanswered.is_some_and(|sent| link.inner.last_received() >= sent) {
            unanswered = None;
        }
        let deadline = unanswered.map(|sent| link.inner.last_received().max(sent) + timeout);
        tokio::select! {
            _ = closed.wait_for(Option::is_some) => return,
            () = tokio::time::sleep_until(beat) => {
                if link.inner.parked_until().is_some() {
                    continue;
                }
                if link.inner.carrier_is_down() {
                    // A reliable link's dropped carrier is not pinged.
                    unanswered = None;
                    beat = crate::keepalive::next_beat(beat, interval);
                    continue;
                }
                // The pinger waits one beat for its pong (the RTT it reports);
                // any frame, the pong too, counts as the answer above. It runs
                // later than this check, maybe after a park: it sends nothing
                // then.
                let pinger = link.clone();
                tokio::spawn(async move {
                    #[cfg(test)]
                    let _ = pinger.inner.pinger_gate.subscribe().wait_for(|held| !*held).await;
                    let _ = tokio::time::timeout(interval, pinger.round_trip(true)).await;
                });
                unanswered.get_or_insert(beat);
                beat = crate::keepalive::next_beat(beat, interval);
            }
            () = tokio::time::sleep_until(deadline.unwrap_or(beat)), if deadline.is_some() => {
                if let Some(sent) = unanswered
                    && link.inner.parked_until().is_none()
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

/// Liveness datagrams from the peer: answer its pings, hand pongs to their
/// waiters. Any of them proves the peer alive, as a frame does, and the
/// first one says the peer listens, so this side's pings switch over.
async fn read_datagrams(inner: Arc<Inner>, mut incoming: mpsc::Receiver<Vec<u8>>) {
    while let Some(datagram) = incoming.recv().await {
        if let Some((channel, seq)) = crate::classes::parse_screen_ack(&datagram) {
            if inner.closed_reason().is_some() {
                return;
            }
            inner.received();
            let screen = inner.lock_channels().get(&channel).and_then(|route| route.screen.clone());
            if let Some(screen) = screen {
                screen.acknowledge(seq);
            }
            continue;
        }
        if let Some(fragment) = crate::classes::parse_datagram(&datagram) {
            if inner.closed_reason().is_some() {
                return;
            }
            inner.received();
            inner.received_traffic();
            let channel = fragment.channel;
            let route = inner.lock_channels().get(&channel).and_then(|route| {
                route
                    .sequencer
                    .clone()
                    .map(|sequencer| (route.inbox.clone(), sequencer, route.screen.is_some()))
            });
            let Some((inbox, sequencer, screen)) = route else { continue };
            let mut sequencer = sequencer.lock().await;
            let delivered = sequencer.fragment(fragment);
            if !delivered.is_empty() {
                inner.datagram_wins.fetch_add(1, Ordering::Relaxed);
                if screen {
                    inner.acknowledge_screen(channel, &delivered);
                }
                // Errors (an overflow close) go on the main stream.
                deliver(&inner, MAIN, channel, &inbox, delivered).await;
            }
            continue;
        }
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
        // A park ends when the peer is back: on the Mac its first ping or
        // app request (channel data or a new channel, in `handle_frame`, so
        // a reliable link's sequenced data counts too: a phone running a
        // notification action in the background is awake and waits for the
        // answer), on a resuming phone the first frame from the Mac.
        if *inner.park.borrow() == Park::Resuming {
            inner.unpark();
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
        } else if let Err(reason) = handle_frame(&inner, stream, frame, &incoming).await {
            break reason;
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
                    handle_frame(inner, stream, Frame::new(channel, kind, payload), incoming).await?;
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
        _ => handle_frame(inner, stream, frame, incoming).await?,
    }
    Ok(())
}

/// One inbound frame, as every link handles it. `Err`: the carrier fails.
async fn handle_frame(
    inner: &Arc<Inner>,
    stream: usize,
    frame: Frame,
    incoming: &mpsc::Sender<IncomingChannel>,
) -> Result<(), String> {
    let mac_parked = inner.role == Role::Mac && matches!(*inner.park.borrow(), Park::Parked { .. });
    match frame.kind {
        FrameType::Ping => {
            let _ = inner.push(stream, Class::Control, Frame::new(0, FrameType::Pong, frame.payload));
            if mac_parked {
                // Queue the answer before waking either backlog writer.
                inner.unpark();
            }
        }
        FrameType::Pong => {
            if let Ok(bytes) = <[u8; 8]>::try_from(&frame.payload[..]) {
                inner.ponged(u64::from_be_bytes(bytes), 0);
            }
        }
        FrameType::Open => {
            if !inner.role.peer_owns(frame.channel) || inner.lock_channels().contains_key(&frame.channel) {
                refuse(inner, stream, frame.channel, "bad_channel", "channel id is not the peer's or in use");
                return Ok(());
            }
            let Ok(request) = serde_json::from_slice::<OpenRequest>(&frame.payload) else {
                refuse(inner, stream, frame.channel, "bad_request", "open payload is not JSON");
                return Ok(());
            };
            // The peer is about to be suspended: hold the link for it.
            // The answer is a control frame, so it goes out while parked.
            if request.service == PARK_SERVICE {
                match request.args.get("hold_ms").and_then(serde_json::Value::as_u64) {
                    Some(millis) if millis > 0 => {
                        let deflate = request.args.get("encoding").and_then(serde_json::Value::as_str)
                            == Some(PARK_ENCODING);
                        inner.set_parked(Duration::from_millis(millis), deflate);
                        refuse(inner, stream, frame.channel, PARKED, "");
                    }
                    _ => refuse(inner, stream, frame.channel, "bad_request", "hold_ms must be positive"),
                }
                return Ok(());
            }
            // Any other new channel is an app request: the phone is awake.
            if inner.role == Role::Mac {
                inner.unpark();
            }
            // Replies go back on the stream the open came on, at the
            // priority of the lane the peer asked for.
            let class = Class::from(request.lane);
            let (tx, rx) = mpsc::channel(CHANNEL_DEPTH);
            let closed = Arc::new(AtomicBool::new(false));
            let inbox = Inbox::new(tx, inner, stream, frame.channel);
            // Replies are sent as datagrams too only when this side
            // also has the peer's word that it takes them.
            let delivery = request.delivery;
            // A screen delivery from a peer this side did not agree it with
            // gets the stream path only.
            let delivery = delivery.filter(|delivery| *delivery != Delivery::Screen || inner.screen());
            let route = Route::new(inbox, &closed, delivery);
            let screen = route.screen.clone();
            inner.lock_channels().insert(frame.channel, route);
            let mirror = delivery.filter(|_| inner.classes());
            let channel =
                Channel::new(frame.channel, stream, class, Arc::clone(inner), rx, closed, mirror, screen);
            let accepted =
                IncomingChannel { service: request.service, args: request.args, lane: request.lane, channel };
            if incoming.send(accepted).await.is_err() {
                // Nobody accepts; the channel's drop refuses it.
            }
        }
        FrameType::Data | FrameType::DeflatedData => {
            if mac_parked && frame.kind == FrameType::Data {
                // Channel data from a parked phone: it is awake.
                inner.unpark();
            }
            let channel = frame.channel;
            let inbox = inner.lock_channels().get(&channel).map(|route| route.inbox.clone());
            if let Some(inbox) = inbox {
                // The reader never waits on one channel's owner (see
                // `Inbox`), only on a channel holding its whole buffer.
                // Past the stall budget that channel is closed `overflow`
                // on both sides and the link goes on.
                if inbox.owner_gone() {
                    inner.lock_channels().remove(&channel);
                } else {
                    let payload = frame.into_data().map_err(|error| format!("read failed: {error}"))?;
                    if !inbox.push(ChannelEvent::Data(payload)).await
                        && inner.lock_channels().remove(&channel).is_some()
                    {
                        tracing::warn!(
                            channel,
                            "channel held {CHANNEL_BUFFER_BYTES} bytes for {CHANNEL_STALL:?}; closing it"
                        );
                        refuse(inner, stream, channel, "overflow", "the channel was not read");
                    }
                }
            }
        }
        FrameType::Sequenced => {
            let channel = frame.channel;
            let route = inner
                .lock_channels()
                .get(&channel)
                .map(|route| (route.inbox.clone(), route.sequencer.clone(), route.screen.is_some()));
            let Some((inbox, sequencer, screen)) = route else { return Ok(()) };
            let Some((seq, last, chunk)) = crate::classes::parse_sequenced(frame.payload) else {
                return Err("read failed: short sequenced frame".to_owned());
            };
            match &sequencer {
                Some(sequencer) => {
                    let mut sequencer = sequencer.lock().await;
                    let delivered = sequencer.stream_chunk(seq, last, chunk);
                    if screen {
                        inner.acknowledge_screen(channel, &delivered);
                    }
                    deliver(inner, stream, channel, &inbox, delivered).await;
                }
                // A channel opened without a delivery: take the chunks as they come.
                None => {
                    deliver(inner, stream, channel, &inbox, vec![chunk]).await;
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
    Ok(())
}

/// Hand `messages` to `channel`'s inbox in order; `false` once the channel is
/// gone (its owner left, or it held its whole buffer too long and was closed).
async fn deliver(inner: &Inner, stream: usize, channel: u32, inbox: &Inbox, messages: Vec<Bytes>) -> bool {
    for message in messages {
        if inbox.owner_gone() {
            inner.lock_channels().remove(&channel);
            return false;
        }
        if !inbox.push(ChannelEvent::Data(message)).await {
            if inner.lock_channels().remove(&channel).is_some() {
                tracing::warn!(
                    channel,
                    "channel held {CHANNEL_BUFFER_BYTES} bytes for {CHANNEL_STALL:?}; closing it"
                );
                refuse(inner, stream, channel, "overflow", "the channel was not read");
            }
            return false;
        }
    }
    true
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
    /// Each send is a numbered message, sent as datagrams too
    /// (`crate::classes`).
    mirror: Option<Delivery>,
    next_seq: AtomicU64,
    /// Present on a [`Delivery::Screen`] channel.
    screen: Option<Arc<ScreenState>>,
    /// Payload bytes queued for the transport so far ([`sent_bytes`](Self::sent_bytes)).
    sent: AtomicU64,
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

    /// Payload bytes this channel has queued for the transport so far. A channel's queue holds
    /// at most [`CHANNEL_QUEUE_BYTES`], so each chunk of a long write gets in only once the
    /// writer took the ones before it: while a write waits, this moves exactly as the link
    /// drains it. A caller's deadline for a request reads it as progress (iOS `DaemonClient`:
    /// a send that is still moving is never cut by a wall clock).
    pub fn sent_bytes(&self) -> u64 {
        self.sent.load(Ordering::Relaxed)
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
        self.send_numbered(data, mark).await.map(|_| ())
    }

    /// Whether this channel sends screen datagrams ([`Delivery::Screen`] and
    /// the peer agreed [`crate::classes::SCREEN_LANE`]).
    pub fn screen_class(&self) -> bool {
        self.screen.is_some() && self.mirror.is_some()
    }

    /// The newest message number the peer acknowledged: a screen message
    /// may be built as a diff against it. `None` until one is acknowledged.
    pub fn screen_base(&self) -> Option<u64> {
        self.screen.as_ref().and_then(|screen| screen.base())
    }

    /// Say whether this channel's surface is on screen and being read (the
    /// `visible` and `attending` flags): an attended surface sends each
    /// screen datagram twice, a visible one once, a hidden one none (its
    /// updates reach the peer on the stream).
    pub fn set_surface_state(&self, visible: bool, attending: bool) {
        if let Some(screen) = &self.screen {
            screen.set_surface(visible, attending);
        }
    }

    /// Send screen message `payload`, built against message `base` (from
    /// [`screen_base`](Self::screen_base); `None` for a whole state). Returns
    /// the message's number. On a channel without screen datagrams this is
    /// a plain stream send with number 0.
    pub async fn send_screen(&self, base: Option<u64>, payload: &[u8]) -> Result<u64, LinkError> {
        if !self.screen_class() {
            self.send(Bytes::copy_from_slice(payload)).await?;
            return Ok(0);
        }
        let message = crate::classes::screen_wire(base.unwrap_or(crate::classes::NO_BASE), payload);
        Ok(self.send_numbered(message, None).await?.unwrap_or(0))
    }

    async fn send_numbered(
        &self,
        data: Bytes,
        mark: Option<crate::frame::FlushMark>,
    ) -> Result<Option<u64>, LinkError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(LinkError::ChannelClosed);
        }
        let seq = self.mirror.map(|_| self.next_seq.fetch_add(1, Ordering::Relaxed));
        if let (Some(delivery), Some(seq)) = (self.mirror, seq)
            && data.len() <= crate::classes::MIRROR_MAX
            && !self.inner.writes_held.load(Ordering::Acquire)
        {
            // Ahead of the stream copy, which may wait for room.
            match &self.screen {
                Some(screen) => {
                    let copies = screen.copies();
                    self.inner
                        .send_datagram_copies(crate::classes::screen_datagrams(self.id, seq, &data), copies);
                }
                None => {
                    self.inner.send_class_datagrams(crate::classes::datagrams(self.id, seq, &data, delivery));
                }
            }
        }
        let mut rest = data;
        let mut mark = mark;
        while !rest.is_empty() {
            let chunk = rest.split_to(rest.len().min(DATA_CHUNK));
            if self.inner.closed_reason().is_some() {
                return Err(self.inner.closed_error());
            }
            let size = chunk.len();
            let mut frame = match seq {
                Some(seq) => Frame::new(
                    self.id,
                    FrameType::Sequenced,
                    crate::classes::sequenced_payload(seq, rest.is_empty(), &chunk),
                ),
                None => Frame::new(self.id, FrameType::Data, chunk),
            };
            if frame.kind == FrameType::Data
                && self.inner.writes_held.load(Ordering::Acquire)
                && matches!(*self.inner.park.borrow(), Park::Parked { deflate: true, .. })
            {
                frame.deflate_if_smaller();
            }
            if rest.is_empty() {
                frame.flushed = mark.take();
            }
            let budget =
                self.inner.reliable.as_ref().map_or(usize::MAX, |r| r.config.replay_bytes_per_channel);
            let logged = |channel| self.inner.logged_bytes(channel);
            match self.inner.outboxes[self.stream]
                .push_data(self.class, frame, &self.closed, &logged, budget)
                .await
            {
                Pushed::Queued => {
                    self.sent.fetch_add(size as u64, Ordering::Relaxed);
                    if let Some(meter) = &self.meter {
                        meter.add_sent(size);
                    }
                }
                Pushed::Shutdown => return Err(self.inner.closed_error()),
                Pushed::ChannelClosed => return Err(LinkError::ChannelClosed),
            }
        }
        Ok(seq)
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
    #[allow(clippy::too_many_arguments)] // one call site per side: the open and the accept
    fn new(
        id: u32,
        stream: usize,
        class: Class,
        inner: Arc<Inner>,
        rx: mpsc::Receiver<ChannelEvent>,
        closed: Arc<AtomicBool>,
        mirror: Option<Delivery>,
        screen: Option<Arc<ScreenState>>,
    ) -> Self {
        Self {
            sender: ChannelSender {
                id,
                stream,
                class,
                inner,
                closed,
                meter: None,
                mirror,
                next_seq: AtomicU64::new(0),
                screen,
                sent: AtomicU64::new(0),
            },
            receiver: ChannelReceiver { rx, done: false, meter: None },
        }
    }

    pub fn id(&self) -> u32 {
        self.sender.id
    }

    /// Whether this channel sends screen datagrams ([`ChannelSender::screen_class`]).
    pub fn screen_class(&self) -> bool {
        self.sender.screen_class()
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

    #[test]
    fn resume_hedge_scales_with_the_round_trip_within_bounds() {
        let ms = Duration::from_millis;
        assert_eq!(resume_hedge_after(None), RESUME_HEDGE_UNKNOWN);
        assert_eq!(resume_hedge_after(Some(ms(2))), RESUME_HEDGE_FLOOR);
        assert_eq!(resume_hedge_after(Some(ms(20))), RESUME_HEDGE_FLOOR);
        assert_eq!(resume_hedge_after(Some(ms(70))), ms(310));
        assert_eq!(resume_hedge_after(Some(ms(300))), ms(1000));
        assert_eq!(resume_hedge_after(Some(Duration::from_secs(2))), RESUME_HEDGE_CAP);
    }

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
            let report = phone.resume_carrier(a, None).await.expect("resume");
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

    /// A reliable link takes the parked Mac's deflated data (wire type 5) as
    /// a link without the reliable mode does: bare (as base sends it) or
    /// sequenced (as a reliable Mac does), the channel gets the plain bytes.
    #[tokio::test]
    async fn a_reliable_link_reads_deflated_data_bare_or_sequenced() {
        let (a, b) = tokio::io::duplex(1024 * 1024);
        let phone = Link::new(a, Role::Phone, reliable_config(), None);
        let (read, write) = tokio::io::split(b);
        let mut from_phone = FramedRead::new(read, FrameCodec);
        let mut to_phone = FramedWrite::new(write, FrameCodec);
        let mut channel = phone.open("echo", serde_json::json!({})).await.unwrap();
        let mut kinds = Vec::new();
        while kinds.len() < 2 {
            let frame = tokio::time::timeout(Duration::from_secs(5), from_phone.next())
                .await
                .expect("the phone's opening frames")
                .expect("open stream")
                .unwrap();
            kinds.push(frame.kind);
        }
        assert_eq!(kinds, [FrameType::Hello, FrameType::Seq], "a reliable phone's hello and sequenced open");

        let plain = Bytes::from("a terminal row / another chat delta\n".repeat(200));
        let mut deflated = Frame::new(channel.id(), FrameType::Data, plain.clone());
        deflated.deflate_if_smaller();
        assert_eq!(deflated.kind, FrameType::DeflatedData);
        to_phone
            .send(Frame::new(channel.id(), FrameType::DeflatedData, deflated.payload.clone()))
            .await
            .unwrap();
        let sequenced = rel::seq_payload(1, FrameType::DeflatedData, &deflated.payload);
        to_phone.send(Frame::new(channel.id(), FrameType::Seq, sequenced)).await.unwrap();
        for how in ["bare", "sequenced"] {
            match tokio::time::timeout(Duration::from_secs(5), channel.recv()).await.expect(how) {
                Some(ChannelEvent::Data(bytes)) => assert_eq!(bytes, plain, "{how} deflated data"),
                other => panic!("{how}: unexpected {other:?}"),
            }
        }
        assert!(!phone.is_closed(), "{:?}", phone.closed_state().borrow().clone());
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
        assert!(phone.resume_carrier(a, None).await.is_err());
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
        let channel = phone.open("echo", serde_json::json!({})).await.unwrap();
        channel.send(Bytes::from_static(b"before the cut")).await.unwrap();
        // The Mac never reads this carrier.
        drop(b);
        phone.drop_carrier("test cut");
        let (a, b) = tokio::io::duplex(64 * 1024);
        let mac = tokio::spawn(Link::accept_reliable(b, config.clone(), None));
        phone.resume_carrier(a, None).await.expect("reopen");
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

    /// A writer whose carrier dropped can still be holding a frame it took
    /// from the outbox. It must not log it: the next carrier's replay may
    /// already have read the log, and the frame would reach the peer on no
    /// carrier (seen as "channel 3 skipped from 7271 to 7282" in the host
    /// matrix). It is handed back unlogged, first in line for the next one.
    #[tokio::test]
    async fn a_dropped_carriers_writer_logs_nothing_more() {
        let (a, _b) = tokio::io::duplex(64 * 1024);
        let phone = Link::new(a, Role::Phone, reliable_config(), None);
        let reliable = phone.inner.reliable.as_ref().unwrap();
        let old = *reliable.generation.borrow();
        let frame = Frame::new(1, FrameType::Data, Bytes::from_static(b"late"));
        assert!(matches!(phone.inner.seal(frame.clone(), Some(old)), Sealed::Send(_)));
        let logged = phone.inner.logged_bytes(1);
        assert!(logged > 0);
        phone.drop_carrier("test cut");
        let Sealed::Superseded(back) = phone.inner.seal(frame.clone(), Some(old)) else {
            panic!("the old carrier's writer sealed a frame after the drop");
        };
        assert_eq!(back, frame);
        assert_eq!(phone.inner.logged_bytes(1), logged, "nothing more was logged");
        phone.inner.outboxes[MAIN].unpop(back);
        assert!(matches!(phone.inner.outboxes[MAIN].pop(false), Some(Next::Frame(first)) if first == frame));
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

    /// `sent_bytes` is a write's progress: it stops where a stalled link stops taking bytes and
    /// reaches the whole write on a link that drains (iOS `DaemonClient` bounds a send by it).
    #[tokio::test]
    async fn sent_bytes_moves_only_while_the_link_takes_the_write() {
        let (a, _stalled) = tokio::io::duplex(64 * 1024);
        let phone = Link::new(a, Role::Phone, LinkConfig::default(), None);
        let channel = phone.open("daemon", serde_json::json!({})).await.unwrap();
        let sender = Arc::new(channel.sender);
        let total = CHANNEL_QUEUE_BYTES * 8;
        let sending = tokio::spawn({
            let sender = Arc::clone(&sender);
            async move { sender.send(Bytes::from(vec![0u8; total])).await }
        });
        tokio::time::sleep(Duration::from_millis(200)).await;
        let stuck = sender.sent_bytes();
        assert!(stuck > 0 && stuck < total as u64, "part of the write got in: {stuck}");
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert_eq!(sender.sent_bytes(), stuck, "a stalled link makes no progress");
        sender.close("cancelled", "").await;
        let _ = sending.await;

        let (phone, mac) = pair();
        let server = tokio::spawn(async move {
            let mut incoming = mac.accept().await.expect("incoming");
            let mut got = 0;
            while got < total {
                match incoming.channel.recv().await {
                    Some(ChannelEvent::Data(bytes)) => got += bytes.len(),
                    other => panic!("unexpected {other:?}"),
                }
            }
            mac
        });
        let channel = phone.open("daemon", serde_json::json!({})).await.unwrap();
        channel.send(Bytes::from(vec![1u8; total])).await.unwrap();
        assert_eq!(channel.sender.sent_bytes(), total as u64);
        let _mac = server.await.unwrap();
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

    /// The progress clock moves on every write taken and everything heard,
    /// so a link that keeps moving never looks stalled however long it runs,
    /// and a link that goes silent does, one quiet stretch after its last move.
    #[tokio::test(start_paused = true)]
    async fn the_progress_clock_follows_the_last_move_not_the_first() {
        let (a, b) = tokio::io::duplex(1024 * 1024);
        let config = LinkConfig { keepalive: None, ..LinkConfig::default() };
        let phone = Link::new(a, Role::Phone, config.clone(), None);
        let mac = Link::new(b, Role::Mac, config, None);
        let sink = async {
            let mut incoming = mac.accept().await.expect("incoming");
            while let Some(ChannelEvent::Data(_)) = incoming.channel.recv().await {}
        };
        let moves = async {
            let channel = phone.open("sink", serde_json::json!({})).await.unwrap();
            // A minute of a write every 5 s: far past a 10 s hold from the
            // first write, never 10 s quiet.
            for _ in 0..12 {
                let before = phone.progress_count();
                channel.send(Bytes::from_static(b"chunk")).await.unwrap();
                tokio::time::sleep(Duration::from_millis(10)).await;
                assert!(phone.progress_count() > before, "a write taken is progress");
                assert!(mac.progress_ago() < Duration::from_millis(100), "a frame heard is progress");
                tokio::time::sleep(Duration::from_secs(5)).await;
                assert!(phone.progress_ago() < Duration::from_secs(6), "{:?}", phone.progress_ago());
            }
            // Then silence: the clock runs from the last move.
            let count = phone.progress_count();
            tokio::time::sleep(Duration::from_secs(30)).await;
            assert_eq!(phone.progress_count(), count, "a silent link does not move");
            assert!(phone.progress_ago() >= Duration::from_secs(30), "{:?}", phone.progress_ago());
            drop(channel);
            phone.close("done");
        };
        tokio::join!(sink, moves);
        mac.close("done");
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
            delivery: None,
        })
        .unwrap();
        assert!(bulk.get("lane").is_none());
        assert!(bulk.get("delivery").is_none());
        let input = serde_json::to_value(OpenRequest {
            service: "daemon".into(),
            args: serde_json::json!({}),
            lane: Lane::Input,
            delivery: Some(Delivery::Ordered),
        })
        .unwrap();
        assert_eq!(input["lane"], "input");
        assert_eq!(input["delivery"], "ordered");
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

    /// [`CHANNEL_STALL`] is a silence bound on the channel's owner, not a
    /// total: each event waits for one free slot in the owner's queue, so an
    /// owner that drains a backlog slowly (one event every 2 s for 2 minutes,
    /// far past 3 s from the first full queue) keeps its channel, and one that
    /// stops reading is closed `overflow` one bound after its last read.
    #[tokio::test(start_paused = true)]
    async fn a_slowly_draining_channel_is_kept_and_a_stopped_one_closed() {
        let (a, b) = tokio::io::duplex(1024 * 1024);
        let config = LinkConfig { keepalive: None, ..LinkConfig::default() };
        let phone = Link::new(a, Role::Phone, config.clone(), None);
        let mac = Link::new(b, Role::Mac, config, None);
        let flood = async {
            let mut incoming = mac.accept().await.expect("incoming");
            for _ in 0..CHANNEL_DEPTH + 100 {
                incoming.channel.send(Bytes::from_static(&[7u8; 64])).await.unwrap();
            }
            loop {
                match incoming.channel.recv().await {
                    Some(ChannelEvent::Closed(info)) => return (info.code, tokio::time::Instant::now()),
                    Some(_) => {}
                    None => return ("gone".to_owned(), tokio::time::Instant::now()),
                }
            }
        };
        let drain = async {
            let mut channel = phone.open("flood", serde_json::json!({})).await.unwrap();
            for read in 0..60 {
                tokio::time::sleep(Duration::from_secs(2)).await;
                let event = channel.recv().await;
                assert!(matches!(event, Some(ChannelEvent::Data(_))), "read {read}: {event:?}");
            }
            let stopped = tokio::time::Instant::now();
            tokio::time::sleep(CHANNEL_STALL * 3).await;
            (channel, stopped)
        };
        let ((code, closed_at), (_channel, stopped)) = tokio::join!(flood, drain);
        assert_eq!(code, "overflow");
        assert!(closed_at >= stopped + CHANNEL_STALL - Duration::from_secs(2), "closed while still read");
        assert!(closed_at <= stopped + CHANNEL_STALL + Duration::from_secs(1), "closed late");
        phone.close("done");
        mac.close("done");
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

    /// Link keepalive tight enough to close a silent peer within a second.
    fn quick_keepalive() -> LinkConfig {
        LinkConfig {
            keepalive: Some(Duration::from_millis(50)),
            keepalive_timeout: Duration::from_millis(600),
            ..LinkConfig::default()
        }
    }

    /// The next frame from the Mac that is not one of its keepalive pings.
    async fn next_from_mac(
        frames: &mut FramedRead<tokio::io::ReadHalf<tokio::io::DuplexStream>, FrameCodec>,
    ) -> Option<Frame> {
        loop {
            let frame = tokio::time::timeout(Duration::from_secs(5), frames.next()).await.ok()??.ok()?;
            if frame.kind != FrameType::Ping {
                return Some(frame);
            }
        }
    }

    /// The partial link (PROTOCOL.md "Parked link"): a Mac whose phone parked
    /// the link before the OS suspended it outlives its keepalive timeout,
    /// sends the silent phone nothing (no ping, no held channel data), and on
    /// the phone's first ping answers and sends what it held. The phone side
    /// is raw frames, as a suspended phone sends nothing at all.
    #[tokio::test(start_paused = true)]
    async fn a_parked_mac_link_waits_silently_for_the_phone() {
        let (a, b) = tokio::io::duplex(1024 * 1024);
        let mac = Link::new(a, Role::Mac, quick_keepalive(), None);
        let (read, write) = tokio::io::split(b);
        let mut from_mac = FramedRead::new(read, FrameCodec);
        let mut to_mac = FramedWrite::new(write, FrameCodec);
        to_mac.send(Frame::new(1, FrameType::Open, br#"{"service":"echo"}"#.to_vec())).await.unwrap();
        let served = mac.accept().await.expect("the echo channel").channel;
        to_mac
            .send(Frame::new(
                3,
                FrameType::Open,
                br#"{"service":"_link.park","args":{"hold_ms":5000}}"#.to_vec(),
            ))
            .await
            .unwrap();
        let answer = next_from_mac(&mut from_mac).await.expect("the Mac answers the park");
        assert_eq!((answer.channel, answer.kind), (3, FrameType::Close));
        let info: CloseInfo = serde_json::from_slice(&answer.payload).unwrap();
        assert_eq!(info.code, "parked");

        // Output for the suspended phone waits on the Mac.
        served.send(Bytes::from_static(b"held")).await.unwrap();
        let quiet = tokio::time::timeout(Duration::from_secs(4), from_mac.next()).await;
        assert!(quiet.is_err(), "a parked Mac sent its silent phone {quiet:?}");
        assert!(!mac.is_closed(), "closed while parked: {:?}", mac.closed_state().borrow().clone());

        // The phone is back: its ping ends the park.
        to_mac.send(Frame::new(0, FrameType::Ping, 7u64.to_be_bytes().to_vec())).await.unwrap();
        // The pong and the held data; the Mac's own keepalive pings, back on,
        // may come between them.
        let pong = (0, FrameType::Pong, Bytes::from(7u64.to_be_bytes().to_vec()));
        let held = (1, FrameType::Data, Bytes::from_static(b"held"));
        let mut got = Vec::new();
        while !(got.contains(&pong) && got.contains(&held)) {
            let frame = next_from_mac(&mut from_mac).await.expect("the Mac answers the returning phone");
            got.push((frame.channel, frame.kind, frame.payload));
            assert!(got.len() <= 4, "unexpected frames from the Mac: {got:?}");
        }
        assert!(!mac.is_closed());
    }

    /// A parked phone that runs a request in the background (a notification
    /// action's permission lookup on a channel it has, or a new channel) is
    /// awake: the Mac answers it with no ping first, and stays unparked.
    #[tokio::test(start_paused = true)]
    async fn a_parked_mac_answers_an_app_request_without_a_ping() {
        let (a, b) = tokio::io::duplex(1024 * 1024);
        let mac = Link::new(a, Role::Mac, quick_keepalive(), None);
        let (read, write) = tokio::io::split(b);
        let mut from_mac = FramedRead::new(read, FrameCodec);
        let mut to_mac = FramedWrite::new(write, FrameCodec);
        to_mac.send(Frame::new(1, FrameType::Open, br#"{"service":"acpmux"}"#.to_vec())).await.unwrap();
        let mut served = mac.accept().await.expect("the acpmux channel").channel;
        to_mac
            .send(Frame::new(
                3,
                FrameType::Open,
                br#"{"service":"_link.park","args":{"hold_ms":600000}}"#.to_vec(),
            ))
            .await
            .unwrap();
        let answer = next_from_mac(&mut from_mac).await.expect("the Mac answers the park");
        assert_eq!((answer.channel, answer.kind), (3, FrameType::Close));
        assert!(mac.is_parked());

        // The request on the channel the phone has: the Mac's answer comes back.
        to_mac.send(Frame::new(1, FrameType::Data, b"info?".to_vec())).await.unwrap();
        assert_eq!(served.recv().await, Some(ChannelEvent::Data(Bytes::from_static(b"info?"))));
        served.send(Bytes::from_static(b"info")).await.unwrap();
        let reply = next_from_mac(&mut from_mac).await.expect("the parked Mac answers the request");
        assert_eq!(
            (reply.channel, reply.kind, reply.payload),
            (1, FrameType::Data, Bytes::from_static(b"info"))
        );
        assert!(!mac.is_parked(), "the Mac still holds a link its phone is using");

        // A new channel on a parked link is answered the same way.
        to_mac
            .send(Frame::new(
                5,
                FrameType::Open,
                br#"{"service":"_link.park","args":{"hold_ms":600000}}"#.to_vec(),
            ))
            .await
            .unwrap();
        let answer = next_from_mac(&mut from_mac).await.expect("the Mac answers the second park");
        assert_eq!((answer.channel, answer.kind), (5, FrameType::Close));
        to_mac.send(Frame::new(7, FrameType::Open, br#"{"service":"echo"}"#.to_vec())).await.unwrap();
        let lookup = mac.accept().await.expect("the new channel").channel;
        lookup.send(Bytes::from_static(b"answer")).await.unwrap();
        let reply = next_from_mac(&mut from_mac).await.expect("the parked Mac answers on a new channel");
        assert_eq!(
            (reply.channel, reply.kind, reply.payload),
            (7, FrameType::Data, Bytes::from_static(b"answer"))
        );
        assert!(!mac.is_parked());
        assert!(!mac.is_closed());
    }

    /// A park is bounded: once its hold passes with nothing heard, the Mac
    /// closes the link as a dead one closes.
    #[tokio::test(start_paused = true)]
    async fn a_parked_link_closes_when_its_hold_passes() {
        let (a, b) = tokio::io::duplex(1024 * 1024);
        let mac = Link::new(a, Role::Mac, quick_keepalive(), None);
        let (read, write) = tokio::io::split(b);
        let mut from_mac = FramedRead::new(read, FrameCodec);
        let mut to_mac = FramedWrite::new(write, FrameCodec);
        to_mac
            .send(Frame::new(
                1,
                FrameType::Open,
                br#"{"service":"_link.park","args":{"hold_ms":2000}}"#.to_vec(),
            ))
            .await
            .unwrap();
        let answer = next_from_mac(&mut from_mac).await.expect("the Mac answers the park");
        assert_eq!(answer.kind, FrameType::Close);
        let started = Instant::now();
        let reason = tokio::time::timeout(Duration::from_secs(5), mac.closed()).await.expect("closes");
        assert_eq!(reason, "park expired");
        assert!(started.elapsed() >= Duration::from_millis(1900), "closed after {:?}", started.elapsed());
    }

    /// Both ends: the phone parks, both outlive their keepalives while
    /// silent, and resume plus one probe brings the link back with no redial.
    #[tokio::test(start_paused = true)]
    async fn park_then_resume_keeps_the_link() {
        let (a, b) = tokio::io::duplex(1024 * 1024);
        let phone = Link::new(a, Role::Phone, quick_keepalive(), None);
        let mac = Link::new(b, Role::Mac, quick_keepalive(), None);
        assert!(phone.park(Duration::from_secs(5), Duration::from_secs(1)).await.unwrap());
        assert!(phone.is_parked() && mac.is_parked());
        tokio::time::sleep(Duration::from_secs(3)).await;
        assert!(!phone.is_closed() && !mac.is_closed(), "a parked link closed");
        assert!(phone.resume());
        assert!(phone.probe(Duration::from_secs(1)).await.is_ok());
        assert!(!phone.is_parked() && !mac.is_parked(), "the park did not end");
        // Unparked, the keepalives run again and the link stays up.
        tokio::time::sleep(Duration::from_secs(2)).await;
        assert!(!phone.is_closed() && !mac.is_closed());
    }

    #[tokio::test(start_paused = true)]
    async fn resume_probe_releases_ordered_output_with_liveness_datagrams() {
        let (a, b) = tokio::io::duplex(1024);
        let config = LinkConfig { keepalive: None, ..LinkConfig::default() };
        let phone = Link::new(a, Role::Phone, config.clone(), None);
        let mac = Link::new(b, Role::Mac, config, None);
        let (phone_lane, mac_lane) = datagram_pair(true, true, 0);
        phone.attach_liveness_datagrams(phone_lane);
        mac.attach_liveness_datagrams(mac_lane);
        let mut channel = phone.open("echo", serde_json::json!({})).await.unwrap();
        let served = mac.accept().await.unwrap().channel;
        assert!(phone.park(Duration::from_secs(10), Duration::from_secs(1)).await.unwrap());
        let writes: Vec<_> = (0..20u8).map(|n| Bytes::from(vec![n; 512])).collect();
        for bytes in &writes {
            served.send(bytes.clone()).await.unwrap();
        }
        assert!(phone.resume());
        phone.probe(Duration::from_secs(1)).await.unwrap();
        assert!(!mac.is_parked());
        served.close("done", "").await;
        for bytes in writes {
            assert!(matches!(channel.recv().await, Some(ChannelEvent::Data(got)) if got == bytes));
        }
        assert!(matches!(channel.recv().await, Some(ChannelEvent::Closed(info)) if info.code == "done"));
    }

    #[tokio::test(start_paused = true)]
    async fn foreground_probes_wait_out_a_park() {
        let (phone, mac, dark) = gated_pair(LinkConfig::default(), LinkConfig::default());
        let sent = Arc::new(AtomicU64::new(0));
        let (phone_lane, mac_lane) = gated_datagrams(&dark, Arc::clone(&sent));
        phone.attach_liveness_datagrams(phone_lane);
        mac.attach_liveness_datagrams(mac_lane);
        phone.set_foreground_probe(true);
        tokio::time::sleep(FOREGROUND_PROBE).await;
        assert!(phone.park(Duration::from_secs(60), Duration::from_secs(1)).await.unwrap());
        dark.send_replace(true);
        let before = sent.load(Ordering::Relaxed);
        tokio::time::sleep(Duration::from_secs(36)).await;
        assert_eq!(sent.load(Ordering::Relaxed), before);
        assert!(!mac.is_suspect() && !phone.is_suspect());

        dark.send_replace(false);
        assert!(phone.resume());
        phone.probe(Duration::from_secs(1)).await.unwrap();
        let resumed = sent.load(Ordering::Relaxed);
        tokio::time::sleep(FOREGROUND_PROBE * 2).await;
        assert!(sent.load(Ordering::Relaxed) > resumed);
    }

    /// A keepalive beat that fired just before the phone parked must not put
    /// its ping on the wire after the park: the Mac takes any ping from a
    /// parked phone as the phone back, and would unpark while the phone
    /// sleeps. The beat's pinger is held at the test gate (as a pinger the
    /// scheduler runs late is) until the park was accepted.
    #[tokio::test(start_paused = true)]
    async fn a_keepalive_ping_deferred_past_a_park_stays_unsent() {
        let (a, b) = tokio::io::duplex(1024 * 1024);
        let beat = Duration::from_millis(200);
        let config = LinkConfig {
            keepalive: Some(beat),
            keepalive_timeout: Duration::from_secs(30),
            aligned: true,
            ..LinkConfig::default()
        };
        let phone = Link::new(a, Role::Phone, config, None);
        let mac = Link::new(b, Role::Mac, LinkConfig { keepalive: None, ..LinkConfig::default() }, None);

        // The next beat's pinger waits at the gate.
        phone.inner.pinger_gate.send_replace(true);
        tokio::time::timeout(Duration::from_secs(5), async {
            while phone.inner.pinger_gate.receiver_count() == 0 {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .expect("a keepalive beat fired");

        // The park is sent and accepted while that pinger waits; then it runs.
        assert!(phone.park(Duration::from_secs(5), Duration::from_secs(1)).await.unwrap());
        assert!(mac.is_parked());
        phone.inner.pinger_gate.send_replace(false);

        tokio::time::sleep(beat * 3).await;
        assert!(phone.is_parked(), "the phone left its park");
        assert!(mac.is_parked(), "a keepalive ping queued after the park unparked the Mac");
    }

    /// A Mac that predates parking refuses the service: the phone is told,
    /// and nothing on its side is parked.
    #[tokio::test]
    async fn an_older_mac_refuses_the_park() {
        let (a, b) = tokio::io::duplex(64 * 1024);
        let phone = Link::new(a, Role::Phone, LinkConfig::default(), None);
        let (read, write) = tokio::io::split(b);
        let mut from_phone = FramedRead::new(read, FrameCodec);
        let mut to_phone = FramedWrite::new(write, FrameCodec);
        let older_mac = tokio::spawn(async move {
            while let Some(Ok(frame)) = from_phone.next().await {
                if frame.kind == FrameType::Open {
                    let refusal = br#"{"code":"unknown_service","reason":"no service _link.park"}"#.to_vec();
                    to_phone.send(Frame::new(frame.channel, FrameType::Close, refusal)).await.unwrap();
                }
            }
        });
        assert!(!phone.park(Duration::from_secs(60), Duration::from_secs(1)).await.unwrap());
        assert!(!phone.is_parked());
        assert!(!phone.resume());
        older_mac.abort();
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
            LivenessDatagrams {
                outgoing: phone_out,
                incoming: phone_in,
                peer_listening: mac_listening,
                classes: false,
                screen: false,
            },
            LivenessDatagrams {
                outgoing: mac_out,
                incoming: mac_in,
                peer_listening: phone_listening,
                classes: false,
                screen: false,
            },
        )
    }

    /// With class datagrams agreed, an input-lane channel's messages cross
    /// while the streams are dark, in order and once each, and a
    /// latest-wins channel shows the newest; the stream copies that follow
    /// when the network is back are dropped as duplicates.
    #[tokio::test(start_paused = true)]
    async fn class_datagrams_cross_a_dark_stream_once_each() {
        let (phone, mac, dark) = gated_pair(LinkConfig::default(), LinkConfig::default());
        let (phone_lane, mac_lane) = datagram_pair(true, true, 0);
        phone.attach_liveness_datagrams(LivenessDatagrams { classes: true, ..phone_lane });
        mac.attach_liveness_datagrams(LivenessDatagrams { classes: true, ..mac_lane });
        assert!(phone.class_datagrams() && mac.class_datagrams());
        let server = tokio::spawn({
            let mac = mac.clone();
            async move {
                let keys = mac.accept().await.expect("keys");
                let screen = mac.accept().await.expect("screen");
                (keys.channel, screen.channel)
            }
        });
        let keys = phone.open_on("keys", serde_json::json!({}), Lane::Input).await.unwrap();
        let mut screen = phone.open_latest("screen", serde_json::json!({})).await.unwrap();
        let (mut mac_keys, mac_screen) = server.await.unwrap();
        dark.send_replace(true);
        for key in 0u8..5 {
            keys.send(Bytes::from(vec![key; 3])).await.unwrap();
        }
        for key in 0u8..5 {
            match tokio::time::timeout(Duration::from_millis(100), mac_keys.recv()).await {
                Ok(Some(ChannelEvent::Data(bytes))) => assert_eq!(&bytes[..], &[key; 3]),
                other => panic!("key {key}: {other:?}"),
            }
        }
        let (screen_tx, _screen_rx) = mac_screen.split();
        for state in 0u8..3 {
            screen_tx.send(Bytes::from(vec![state; 2000])).await.unwrap();
        }
        let mut newest = None;
        while let Ok(Some(ChannelEvent::Data(bytes))) =
            tokio::time::timeout(Duration::from_millis(100), screen.recv()).await
        {
            assert!(newest.is_none_or(|seen| bytes[0] > seen), "older state after a newer one");
            newest = Some(bytes[0]);
        }
        assert_eq!(newest, Some(2), "the newest state arrived while dark");
        dark.send_replace(false);
        assert!(phone.ping().await.is_ok());
        assert!(
            tokio::time::timeout(Duration::from_millis(200), mac_keys.recv()).await.is_err(),
            "a stream copy was delivered twice"
        );
        assert!(tokio::time::timeout(Duration::from_millis(200), screen.recv()).await.is_err());
        assert!(mac.datagram_wins() >= 5 && phone.datagram_wins() >= 1);
    }

    /// Screen messages cross a dark stream as screen datagrams, newest wins,
    /// the receiver's acknowledgements give the sender its base, and the
    /// stream copies that follow are dropped as duplicates.
    #[tokio::test(start_paused = true)]
    async fn screen_datagrams_cross_a_dark_stream_and_are_acknowledged() {
        let (phone, mac, dark) = gated_pair(LinkConfig::default(), LinkConfig::default());
        let (phone_lane, mac_lane) = datagram_pair(true, true, 0);
        phone.attach_liveness_datagrams(LivenessDatagrams { classes: true, screen: true, ..phone_lane });
        mac.attach_liveness_datagrams(LivenessDatagrams { classes: true, screen: true, ..mac_lane });
        assert!(phone.screen_datagrams() && mac.screen_datagrams());
        let server = tokio::spawn({
            let mac = mac.clone();
            async move { mac.accept().await.expect("screen").channel }
        });
        let mut screen = phone.open_screen("screen", serde_json::json!({})).await.unwrap();
        assert!(screen.screen_class());
        let mac_screen = server.await.unwrap();
        let (mac_tx, _mac_rx) = mac_screen.split();
        assert!(mac_tx.screen_class());
        assert_eq!(mac_tx.screen_base(), None);
        dark.send_replace(true);
        let mut last = 0;
        for state in 0u8..3 {
            last = mac_tx.send_screen(mac_tx.screen_base(), &vec![state; 2000]).await.unwrap();
        }
        let mut newest = None;
        while let Ok(Some(ChannelEvent::Data(bytes))) =
            tokio::time::timeout(Duration::from_millis(100), screen.recv()).await
        {
            let message = crate::classes::screen_message(&bytes).expect("a screen message");
            assert_eq!(message.base, None, "nothing was acknowledged yet");
            assert!(newest.is_none_or(|seen| message.seq > seen), "older state after a newer one");
            newest = Some(message.seq);
            assert_eq!(message.payload.len(), 2000);
        }
        assert_eq!(newest, Some(last), "the newest state arrived while dark");
        // The phone's acknowledgement crossed back as a datagram.
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(mac_tx.screen_base(), Some(last));
        // The next message is a diff against it.
        mac_tx.send_screen(mac_tx.screen_base(), b"diff").await.unwrap();
        let Ok(Some(ChannelEvent::Data(bytes))) =
            tokio::time::timeout(Duration::from_millis(100), screen.recv()).await
        else {
            panic!("no diff arrived")
        };
        let message = crate::classes::screen_message(&bytes).unwrap();
        assert_eq!((message.base, &message.payload[..]), (Some(last), &b"diff"[..]));
        dark.send_replace(false);
        assert!(phone.ping().await.is_ok());
        assert!(tokio::time::timeout(Duration::from_millis(200), screen.recv()).await.is_err());
        // A hidden surface sends no datagrams: its update waits for the stream.
        mac_tx.set_surface_state(false, false);
        dark.send_replace(true);
        mac_tx.send_screen(None, b"hidden").await.unwrap();
        assert!(tokio::time::timeout(Duration::from_millis(100), screen.recv()).await.is_err());
        dark.send_replace(false);
        assert!(matches!(
            tokio::time::timeout(Duration::from_millis(500), screen.recv()).await,
            Ok(Some(ChannelEvent::Data(_)))
        ));
    }

    /// Each side's flags are what negotiation agreed (both listed the lane),
    /// so an older peer (no `classes-screen-v1`, or no classes at all) leaves
    /// both false. It never sees the `screen` delivery: the channel is a plain stream channel on
    /// both sides and screen sends go as ordinary stream messages.
    #[tokio::test]
    async fn open_screen_negotiates_down_to_the_stream_path() {
        for (phone_classes, phone_screen, mac_classes, mac_screen) in
            [(true, false, true, false), (false, false, false, false)]
        {
            let (phone, mac) = pair();
            let (phone_lane, mac_lane) = datagram_pair(true, true, 0);
            phone.attach_liveness_datagrams(LivenessDatagrams {
                classes: phone_classes,
                screen: phone_screen,
                ..phone_lane
            });
            mac.attach_liveness_datagrams(LivenessDatagrams {
                classes: mac_classes,
                screen: mac_screen,
                ..mac_lane
            });
            let server = tokio::spawn({
                let mac = mac.clone();
                async move { mac.accept().await.expect("screen") }
            });
            let mut screen = phone.open_screen("screen", serde_json::json!({})).await.unwrap();
            let accepted = server.await.unwrap();
            assert!(!screen.screen_class());
            assert!(!accepted.channel.screen_class());
            let (tx, _rx) = accepted.channel.split();
            assert_eq!(tx.send_screen(None, b"plain").await.unwrap(), 0);
            match screen.recv().await {
                Some(ChannelEvent::Data(bytes)) => assert_eq!(&bytes[..], b"plain"),
                other => panic!("{other:?}"),
            }
        }
    }

    /// `screen` datagrams do not parse as class messages of another kind,
    /// and acknowledgements round trip.
    #[test]
    fn screen_ack_and_kind_round_trip() {
        let ack = crate::classes::screen_ack(7, 99);
        assert_eq!(crate::classes::parse_screen_ack(&ack), Some((7, 99)));
        assert!(crate::classes::parse_datagram(&ack).is_none());
        let datagrams = crate::classes::screen_datagrams(3, 1, &[9; 10]);
        assert_eq!(
            crate::classes::parse_datagram(&datagrams[0]).unwrap().kind,
            crate::classes::DATAGRAM_SCREEN
        );
        assert!(crate::classes::parse_screen_ack(&datagrams[0]).is_none());
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

    /// A pre-wake sends one datagram ping on a quiet link, its pong is
    /// counted, and a second call inside the quiet bound sends nothing.
    #[tokio::test]
    async fn prewake_sends_one_ping_on_a_quiet_link() {
        let (phone, mac) = stalled_pair();
        let (phone_lane, mac_lane) = datagram_pair(true, true, 0);
        phone.attach_liveness_datagrams(phone_lane);
        mac.attach_liveness_datagrams(mac_lane);
        // Fresh link: heard just now, so not quiet.
        assert!(!phone.prewake(), "a link that just heard its peer is awake");
        tokio::time::sleep(PREWAKE_QUIET + Duration::from_millis(50)).await;
        assert!(phone.prewake());
        assert!(!phone.prewake(), "a second pre-wake inside the bound is dropped");
        let started = Instant::now();
        loop {
            let stats = phone.take_ping_stats();
            if stats.answered == 1 {
                assert_eq!(stats.sent, 1);
                break;
            }
            assert!(started.elapsed() < Duration::from_secs(2), "pre-wake pong never came");
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        phone.close("done");
        assert!(!phone.prewake(), "a closed link sends nothing");
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
            LivenessDatagrams {
                outgoing: phone_out,
                incoming: phone_in,
                peer_listening: true,
                classes: false,
                screen: false,
            },
            LivenessDatagrams {
                outgoing: mac_out,
                incoming: mac_in,
                peer_listening: true,
                classes: false,
                screen: false,
            },
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
        // Its keepalive pings: the Mac only answers them.
        assert!(background <= 5, "{background} datagrams in a backgrounded minute");
        phone.set_foreground_probe(true);
        let from = sent.load(Ordering::Relaxed);
        tokio::time::sleep(Duration::from_secs(60)).await;
        let foreground = sent.load(Ordering::Relaxed) - from;
        // A probe every beat; the keepalive's pings stand in for four of them.
        assert!((18..=22).contains(&foreground), "{foreground} datagrams in a foreground minute");
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
