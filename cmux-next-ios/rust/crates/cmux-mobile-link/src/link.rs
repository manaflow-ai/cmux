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
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
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
/// How long one full channel may hold the link reader before that channel
/// is closed (`overflow`) so the rest of the link keeps flowing.
const CHANNEL_STALL: Duration = Duration::from_secs(3);

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
}

impl Default for LinkConfig {
    fn default() -> Self {
        Self { keepalive: Some(Duration::from_secs(15)), keepalive_timeout: Duration::from_secs(20) }
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
    tx: mpsc::Sender<ChannelEvent>,
    /// The channel's sender's closed flag: the peer's close sets it, so a send
    /// in progress stops instead of streaming into a channel the peer dropped.
    closed: Arc<AtomicBool>,
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
        let channels: Vec<_> = self.lock_channels().drain().map(|(_, route)| route.tx).collect();
        for tx in channels {
            let _ = tx.try_send(ChannelEvent::Closed(CloseInfo::new("link_closed", reason)));
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
            channels: Mutex::new(HashMap::new()),
            next_channel: AtomicU32::new(role.first_channel()),
            next_nonce: AtomicU64::new(1),
            pings: Mutex::new(HashMap::new()),
            rtt: watch::channel(None).0,
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
        if let Some(interval) = config.keepalive {
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
        self.inner.lock_channels().insert(id, Route { tx, closed: Arc::clone(&closed) });
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
        let mut pending = frame.payload.len();
        let mut result = sink.feed(frame).await;
        while result.is_ok() && pending < FLUSH_BYTES {
            match outbox.pop() {
                Some(Next::Frame(frame)) => {
                    pending += frame.payload.len();
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
                    let nonce = u64::from_be_bytes(bytes);
                    let waiter = inner.pings.lock().unwrap_or_else(PoisonError::into_inner).remove(&nonce);
                    if let Some(waiter) = waiter {
                        let _ = waiter.send(Instant::now());
                    }
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
                inner.lock_channels().insert(frame.channel, Route { tx, closed: Arc::clone(&closed) });
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
                let tx = inner.lock_channels().get(&frame.channel).map(|route| route.tx.clone());
                if let Some(tx) = tx {
                    // A full channel holds the reader only briefly: a channel
                    // nobody reads must not stall the whole link (pings and
                    // every other channel behind it, until the peer's
                    // keepalive gives up). Past the stall budget the channel
                    // is closed `overflow` on both sides and the link goes on.
                    match tokio::time::timeout(CHANNEL_STALL, tx.send(ChannelEvent::Data(frame.payload)))
                        .await
                    {
                        Ok(Ok(())) => {}
                        Ok(Err(_)) => {
                            inner.lock_channels().remove(&frame.channel);
                        }
                        Err(_) => {
                            tracing::warn!(
                                channel = frame.channel,
                                "channel not read for {CHANNEL_STALL:?}; closing it"
                            );
                            inner.lock_channels().remove(&frame.channel);
                            refuse(&inner, stream, frame.channel, "overflow", "the channel was not read");
                        }
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
                    let _ = route.tx.send(ChannelEvent::Closed(info)).await;
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

/// Sending half of a channel.
pub struct ChannelSender {
    id: u32,
    stream: usize,
    class: Class,
    inner: Arc<Inner>,
    /// Set by our close or drop, or by the peer's close (see [`Route`]).
    closed: Arc<AtomicBool>,
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
            let frame = Frame::new(self.id, FrameType::Data, chunk);
            match self.inner.outboxes[self.stream].push_data(self.class, frame, &self.closed).await {
                Pushed::Queued => {}
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
}

impl ChannelReceiver {
    /// The next event; `None` after `Closed` was delivered.
    pub async fn recv(&mut self) -> Option<ChannelEvent> {
        if self.done {
            return None;
        }
        match self.rx.recv().await {
            Some(event) => {
                if matches!(event, ChannelEvent::Closed(_)) {
                    self.done = true;
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
            sender: ChannelSender { id, stream, class, inner, closed },
            receiver: ChannelReceiver { rx, done: false },
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
