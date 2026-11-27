//! Viewport state sync, host side: the phone's screen as unordered, never retransmitted
//! datagrams, newest wins (opt-in, `CMUX_MOBILE_VIEWPORT_SYNC=1`; off by default).
//!
//! On the ordered stream a lost segment holds every redraw behind it (head-of-line blocking),
//! and on a slow link a queue of stale redraws builds. Here the host keeps the screen model (a
//! projection [`Terminal`] at the host grid, fed the PTY's bytes) and sends the diff from the
//! phone's last ACKED screen to the latest one ([`SyncSender`]); the phone applies it only if
//! it holds the base and acks the newest seq it applied. A lost datagram is covered by the next
//! one, never resent as it was. Rows leaving the viewport go on the reliable stream
//! ([`HistoryTracker`]), so the phone's scrollback stays exact.
//!
//! [`ViewportSync`] is the transport-agnostic driver: no I/O, the clock passed in.
//! - **Coalescing**: output only marks the screen dirty; the screen is captured when the pacer
//!   lets a diff out, so a slow link gets the newest state, not every state.
//! - **Pacer** ([`Pacer`]): a token bucket in bytes per second. Its rate follows the link's
//!   delay, never its loss: down to what the phone's acks say was delivered when the recent
//!   round trip's minimum rises above the floor by more than the jitter's spread (a queue
//!   building), up while the pacer was the limit and the round trip stays at its floor.
//! - **Stamps**: every datagram carries a stamp its ack echoes, so every ack (of a resend too)
//!   is a round trip, and a datagram whose ack never comes is a loss.
//! - **Resend**: while the latest state is unacked and nothing new is due, the latest diff goes
//!   again every `max(1.25 * srtt, 30 ms)`.
//! - **Path selector** ([`PathSelector`], [`ViewportSync::select_path`]): per link, today's
//!   stream until the measured loss is above 0.5% or the round trip above 20 ms, and back
//!   only after 2 s below 0.25% and 15 ms; a small probe datagram every 100 ms keeps it
//!   measured. [`run_selected`] hands the stream its batches while the stream path is on.
//!
//! [`run`] drives it over a [`DatagramIo`]: a tokio [`UdpSocket`] (the shaped-link harness) or
//! the WireGuard overlay's [`WgDatagramSocket`] on [`PORT`].

use std::collections::VecDeque;
use std::future::Future;
use std::io;
use std::net::SocketAddr;
use std::time::{Duration, Instant};

use cmux_terminal_projection::Terminal;
use cmux_terminal_projection::sync::{
    HistoryTracker, ScreenState, SyncSender, parse_ack_stamp, stamp_datagram,
};
use cmux_wg::{Priority, WgDatagramSocket, WgNet};
use tokio::net::UdpSocket;
use tokio::sync::mpsc;

/// The opt-in switch ([`enabled`]) and the overlay UDP port (7420 link TCP, 7421 roam, 7422
/// media, 7423 failover relay, 7424 this): one definition, the link crate's, for both sides.
pub use cmux_mobile_link::viewport::{ENV, PORT};

/// Whether the datagram path is on in this process.
pub fn enabled() -> bool {
    enabled_from(std::env::var(ENV).ok().as_deref())
}

/// The gate's rule on a value of [`ENV`]: default off.
pub fn enabled_from(value: Option<&str>) -> bool {
    matches!(value.map(str::trim), Some("1" | "true"))
}

/// Off by default: on a switch to the datagram path, the stream batches still queued for the
/// reliable stream are dropped (their scrolled-off rows go on as `viewport-history`), so the
/// `viewport-path` line no longer waits behind stale repaints on a slow or shared link.
pub const SKIP_SUPERSEDED_ENV: &str = "CMUX_MOBILE_VIEWPORT_SKIP_SUPERSEDED";

/// Whether [`SKIP_SUPERSEDED_ENV`] is on in this process.
pub fn skip_superseded() -> bool {
    enabled_from(std::env::var(SKIP_SUPERSEDED_ENV).ok().as_deref())
}

/// Binds [`PORT`] on a WireGuard session when the gate is on; `None` when it is off.
pub async fn bind_wg(net: &WgNet) -> io::Result<Option<WgDatagramSocket>> {
    if !enabled() {
        return Ok(None);
    }
    net.bind_datagram(PORT).await.map(Some).map_err(io::Error::other)
}

/// The driver's numbers.
#[derive(Clone, Debug)]
pub struct Config {
    /// The pacer's first rate, bytes per second.
    pub initial_rate: f64,
    pub min_rate: f64,
    pub max_rate: f64,
    /// The resend interval's floor (it is `max(1.25 * srtt, resend_floor)`).
    pub resend_floor: Duration,
    /// The resend interval before any round trip was measured.
    pub resend_unmeasured: Duration,
    /// How much the pacer may save up while idle, as time at its rate.
    pub burst: Duration,
    /// On a jittery link (the round trips' middle half spans a quarter of their median), each new
    /// diff goes this many more times, `copy_spacing` apart, each copy drawing its own delay:
    /// the phone holds it at the fastest copy's arrival, and a lost fragment has a stand-in.
    /// A copy goes only while the diff is the newest and unacked, and only on the pacer's
    /// spare budget (it never waits for one).
    pub copies: u8,
    pub copy_spacing: Duration,
    /// On a lossy link (round-trip loss at least this, measured) that is not jittery, a diff
    /// still the newest and unacked `loss_copy_after` after it went goes once more. A burst's
    /// last diff is the one no newer diff covers: lost alone it waits for the resend (more than
    /// a round trip); with its copy both must be lost. Redraws a frame apart supersede their
    /// diff before its copy is due, so mid-burst diffs go once.
    pub loss_copy_above: f64,
    pub loss_copy_after: Duration,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            // 1.5 Mbit/s: a 60 Hz redraw of a few KB passes on wifi and LTE unpaced; a slower
            // link's acks bring it down within a round trip or two.
            initial_rate: 192_000.0,
            min_rate: 8_000.0,
            max_rate: 8_000_000.0,
            resend_floor: Duration::from_millis(30),
            resend_unmeasured: Duration::from_millis(100),
            burst: Duration::from_millis(50),
            copies: 2,
            copy_spacing: Duration::from_millis(4),
            loss_copy_above: 0.02,
            loss_copy_after: Duration::from_millis(40),
        }
    }
}

/// A token bucket in bytes. A send goes when the bucket is above zero and may take it below
/// (a diff's fragments leave together); the debt is paid back at the rate before the next.
#[derive(Clone, Debug)]
pub struct Pacer {
    rate: f64,
    burst: Duration,
    tokens: f64,
    at: Instant,
}

impl Pacer {
    pub fn new(rate: f64, burst: Duration, now: Instant) -> Self {
        let mut pacer = Self { rate, burst, tokens: 0.0, at: now };
        pacer.tokens = pacer.cap();
        pacer
    }

    fn cap(&self) -> f64 {
        (self.rate * self.burst.as_secs_f64()).max(1.0)
    }

    fn refill(&mut self, now: Instant) {
        let elapsed = now.saturating_duration_since(self.at).as_secs_f64();
        self.tokens = (self.tokens + elapsed * self.rate).min(self.cap());
        self.at = self.at.max(now);
    }

    /// Whether a send may go now.
    pub fn ready(&mut self, now: Instant) -> bool {
        self.refill(now);
        self.tokens > 0.0
    }

    /// When a send may go (now, when it may already).
    /// Whether `bytes` fit in the budget saved up now, leaving it out of debt.
    pub fn affords(&mut self, bytes: usize, now: Instant) -> bool {
        self.refill(now);
        self.tokens >= bytes as f64
    }

    pub fn ready_at(&mut self, now: Instant) -> Instant {
        self.refill(now);
        if self.tokens > 0.0 {
            return now;
        }
        // Just past paying the debt, so the bucket is above zero then. The debt is counted from
        // the bucket's own clock, which a later refill may have moved past `now`.
        self.at + Duration::from_secs_f64(-self.tokens / self.rate) + Duration::from_micros(100)
    }

    pub fn spend(&mut self, bytes: usize, now: Instant) {
        self.refill(now);
        self.tokens -= bytes as f64;
    }

    pub fn rate(&self) -> f64 {
        self.rate
    }

    pub fn set_rate(&mut self, rate: f64, now: Instant) {
        self.refill(now);
        self.rate = rate;
        self.tokens = self.tokens.min(self.cap());
    }
}

/// One capture: how many output batches it covers, its seq, when, and what it cost the host
/// (the screen's capture, and the diff's encode into datagrams; zero unless recording).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Capture {
    pub batches: u64,
    pub seq: u64,
    pub at: Instant,
    pub capture: Duration,
    pub encode: Duration,
}

/// Which path carries the screen to the phone.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Path {
    /// Today's ordered stream: the PTY's bytes, as they came.
    Stream,
    /// Viewport state sync's datagrams.
    Datagram,
}

impl Path {
    pub fn name(self) -> &'static str {
        match self {
            Path::Stream => "stream",
            Path::Datagram => "datagram",
        }
    }
}

/// The path selector's numbers. The datagram path only wins where the stream stalls: a lost
/// segment's retransmit (loss) or a long round trip. On a clean LAN the stream's bytes arrive
/// as soon as the datagrams would, with nothing to capture or diff.
#[derive(Clone, Debug)]
pub struct SelectorConfig {
    /// Datagrams after this many sends lost (each one a retransmit the stream would wait on).
    pub losses: usize,
    /// Datagrams once `slow_samples` round trips in a row are longer than this. A send still
    /// unacked past it counts as one: on a long link the switch need not wait out a round trip.
    pub srtt_above: Duration,
    pub slow_samples: u64,
    /// Back to the stream only after `hold` with no send lost and the smoothed round trip below
    /// this (the hysteresis).
    pub srtt_below: Duration,
    pub hold: Duration,
    /// While nothing else goes, a small datagram every `probe` keeps the round trip and loss
    /// measured.
    pub probe: Duration,
}

impl Default for SelectorConfig {
    fn default() -> Self {
        Self {
            losses: 2,
            srtt_above: Duration::from_millis(20),
            slow_samples: 3,
            srtt_below: Duration::from_millis(15),
            hold: Duration::from_secs(5),
            probe: Duration::from_millis(100),
        }
    }
}

impl SelectorConfig {
    /// The datagram path from the first poll on, and never back (tests, and measuring the
    /// datagram path alone): a switch needs zero losses, the way back a hold that never ends.
    pub fn datagram_first() -> Self {
        Self { losses: 0, hold: Duration::MAX, ..Self::default() }
    }
}

/// What the selector judges a link by, at one moment.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Evidence {
    /// The smoothed round trip (None before the first ack).
    pub srtt: Option<Duration>,
    /// Round trips in a row longer than [`SelectorConfig::srtt_above`], each send still unacked
    /// past it included.
    pub slow: u64,
    /// Sends lost since the selector last switched.
    pub losses: usize,
    /// When the last send was found lost.
    pub last_loss: Option<Instant>,
    /// The round-trip loss over the last settled sends (for the log).
    pub loss: Option<f64>,
}

/// One path switch: when, to which path, and the measurements that made it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Switch {
    pub at: Instant,
    pub to: Path,
    pub evidence: Evidence,
}

/// Per link, the stream or the datagrams, from the round trip and loss the datagram side
/// measures. Starts on the stream.
#[derive(Clone, Debug)]
pub struct PathSelector {
    config: SelectorConfig,
    path: Path,
    /// Since when the link has been good enough for the stream (on the datagram path).
    good_since: Option<Instant>,
    switches: Vec<Switch>,
}

impl PathSelector {
    pub fn new(config: SelectorConfig) -> Self {
        Self { config, path: Path::Stream, good_since: None, switches: Vec::new() }
    }

    pub fn path(&self) -> Path {
        self.path
    }

    pub fn switches(&self) -> &[Switch] {
        &self.switches
    }

    pub fn config(&self) -> &SelectorConfig {
        &self.config
    }

    /// The link's numbers now. Returns the new path when it switches, and logs one line.
    pub fn observe(&mut self, evidence: Evidence, now: Instant) -> Option<Path> {
        let config = &self.config;
        let next = match self.path {
            Path::Stream => {
                let slow = evidence.slow >= config.slow_samples;
                let lossy = evidence.losses >= config.losses;
                (slow || lossy).then_some(Path::Datagram)
            }
            Path::Datagram => {
                let fast = evidence.srtt.is_some_and(|srtt| srtt < config.srtt_below);
                let clean =
                    evidence.last_loss.is_none_or(|at| now.saturating_duration_since(at) >= config.hold);
                if fast && clean {
                    let since = *self.good_since.get_or_insert(now);
                    (now.saturating_duration_since(since) >= config.hold).then_some(Path::Stream)
                } else {
                    self.good_since = None;
                    None
                }
            }
        }?;
        self.path = next;
        self.good_since = None;
        self.switches.push(Switch { at: now, to: next, evidence });
        tracing::info!(
            to = next.name(),
            srtt_ms = evidence.srtt.map_or(-1.0, |srtt| srtt.as_secs_f64() * 1000.0),
            slow = evidence.slow,
            losses = evidence.losses,
            loss = evidence.loss.map_or_else(|| "-".to_owned(), |loss| format!("{loss:.4}")),
            "viewport sync path switch"
        );
        Some(next)
    }
}

/// One datagram put on the wire: its stamp (the phone's ack echoes it), when, and the bytes
/// sent up to and with it.
#[derive(Clone, Copy, Debug)]
struct Flight {
    stamp: u32,
    at: Instant,
    cumulative: u64,
    acked: bool,
}

/// The transport-agnostic host driver.
pub struct ViewportSync {
    config: Config,
    term: Terminal,
    sender: SyncSender,
    history: HistoryTracker,
    pacer: Pacer,
    dirty: bool,
    batches: u64,
    /// The newest seq put on the wire.
    sent_seq: u64,
    last_send: Option<Instant>,
    bytes_sent: u64,
    /// The last stamp given (0 is never given: an unstamped datagram's).
    stamp: u32,
    /// Datagrams sent and not yet settled (acked, or past the loss timeout).
    flights: VecDeque<Flight>,
    /// The last settled sends: acked or lost, and how many of them were lost.
    outcomes: VecDeque<bool>,
    lost: usize,
    srtt: Option<Duration>,
    rttvar: Duration,
    /// Round trips in a row (one per send) longer than the selector's `srtt_above`, and the
    /// send time of the last one counted.
    slow_run: u64,
    slow_at: Option<Instant>,
    /// Sends lost since the selector last switched, and when the last one was.
    losses: usize,
    last_loss: Option<Instant>,
    /// The pacer's last look saw a queue (a cut needs two in a row).
    queued: bool,
    /// Round trip samples, for the floor (all of the last 10 s) and its recent value.
    samples: VecDeque<(Instant, Duration)>,
    /// (ack time, bytes sent up to the acked datagram): what reached the phone, over time.
    delivered: VecDeque<(Instant, u64)>,
    last_adjust: Option<Instant>,
    /// The pacer held a dirty screen back since the last rate change.
    limited: bool,
    selector: Option<PathSelector>,
    /// The smallest datagram of the last send: the probe, stamped anew each time.
    probe: Option<Vec<u8>>,
    switched: Option<Path>,
    captures: Option<Vec<Capture>>,
    feeds: Option<Vec<(Instant, Path)>>,
    /// The newest diff's copies still to go: its seq, its datagrams (unstamped), how many more,
    /// and when the next is due.
    copy: Option<Copies>,
    jitter: bool,
    copies_sent: u64,
    copy_bytes: u64,
}

/// Below this much round-trip spread the copies would only spend bytes (good wifi's few ms).
const COPY_JITTER: Duration = Duration::from_millis(10);

struct Copies {
    seq: u64,
    datagrams: Vec<Vec<u8>>,
    left: u8,
    at: Instant,
}

const FLOOR_WINDOW: Duration = Duration::from_secs(10);
const MAX_SAMPLES: usize = 2048;
const MAX_FLIGHTS: usize = 4096;
/// Settled sends the loss is measured over, and the fewest it is reported from.
const LOSS_WINDOW: usize = 512;
const LOSS_MIN_SETTLED: usize = 100;
/// Round trips in the recent window before the pacer judges a queue (a few samples' minimum
/// under jitter is far above the floor).
const MIN_RECENT: usize = 16;

impl ViewportSync {
    pub fn new(cols: u16, rows: u16, max_datagram: usize, config: Config, now: Instant) -> Self {
        let pacer = Pacer::new(config.initial_rate, config.burst, now);
        Self {
            term: Terminal::new(
                usize::from(cols),
                usize::from(rows),
                cmux_terminal_projection::DEFAULT_HISTORY_LIMIT,
            ),
            sender: SyncSender::new(max_datagram),
            history: HistoryTracker::new(),
            pacer,
            config,
            dirty: true,
            batches: 0,
            sent_seq: 0,
            last_send: None,
            bytes_sent: 0,
            stamp: 0,
            flights: VecDeque::new(),
            outcomes: VecDeque::new(),
            lost: 0,
            srtt: None,
            rttvar: Duration::ZERO,
            slow_run: 0,
            slow_at: None,
            losses: 0,
            last_loss: None,
            queued: false,
            samples: VecDeque::new(),
            delivered: VecDeque::new(),
            last_adjust: None,
            limited: false,
            selector: None,
            probe: None,
            switched: None,
            captures: None,
            feeds: None,
            copy: None,
            jitter: false,
            copies_sent: 0,
            copy_bytes: 0,
        }
    }

    /// The same host model (screen, scrollback, parser state) under a new epoch: a fresh
    /// sender, pacer and round-trip state, no selector, the screen dirty. A phone that dropped
    /// the old epoch's state takes the new one's first diff as a keyframe.
    pub fn renewed(self, max_datagram: usize, now: Instant) -> ViewportSync {
        let mut next = ViewportSync::new(1, 1, max_datagram, self.config, now);
        next.term = self.term;
        next.history = self.history;
        next.batches = self.batches;
        next
    }

    /// The epoch every datagram of this driver carries (the phone's acks echo it).
    pub fn epoch(&self) -> u32 {
        self.sender.epoch()
    }

    /// Choose the path per link ([`PathSelector`]): the stream until the link's round trip or
    /// loss says the datagrams win. Without it the driver is always on the datagram path.
    pub fn select_path(&mut self, config: SelectorConfig) {
        self.selector = Some(PathSelector::new(config));
    }

    /// The path the screen goes by now.
    pub fn path(&self) -> Path {
        self.selector.as_ref().map_or(Path::Datagram, PathSelector::path)
    }

    pub fn switches(&self) -> &[Switch] {
        self.selector.as_ref().map_or(&[][..], PathSelector::switches)
    }

    /// The path, when it changed since the last call.
    pub fn take_switch(&mut self) -> Option<Path> {
        self.switched.take()
    }

    /// Keep every capture (batches covered, seq, time, cost) and every feed (time, path) for a
    /// measurement.
    pub fn record_captures(&mut self) {
        self.captures = Some(Vec::new());
        self.feeds = Some(Vec::new());
    }

    pub fn captures(&self) -> &[Capture] {
        self.captures.as_deref().unwrap_or_default()
    }

    /// Each batch's feed: when, and the path it went by.
    pub fn feeds(&self) -> &[(Instant, Path)] {
        self.feeds.as_deref().unwrap_or_default()
    }

    pub fn terminal(&self) -> &Terminal {
        &self.term
    }

    /// The host's screen now.
    pub fn capture(&self) -> ScreenState {
        ScreenState::capture(&self.term)
    }

    /// Output batches fed so far.
    pub fn batches(&self) -> u64 {
        self.batches
    }

    /// One batch of PTY output. Returns the rows it pushed out of the viewport, as VT bytes for
    /// the reliable stream (empty when none, and on the alternate screen).
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<u8> {
        for byte in bytes {
            self.term.advance(*byte);
        }
        self.batches += 1;
        self.dirty = true;
        let path = self.path();
        if let Some(feeds) = &mut self.feeds {
            feeds.push((Instant::now(), path));
        }
        self.history.take_new_rows(&self.term)
    }

    /// The host grid changed.
    pub fn resize(&mut self, cols: u16, rows: u16) {
        self.term.resize(usize::from(cols), usize::from(rows));
        self.dirty = true;
    }

    pub fn latest_seq(&self) -> u64 {
        self.sender.latest_seq()
    }

    pub fn acked_seq(&self) -> u64 {
        self.sender.acked_seq()
    }

    /// Nothing new since the last capture and the phone acked it.
    pub fn settled(&self) -> bool {
        !self.dirty && !self.sender.unacked()
    }

    pub fn rate(&self) -> f64 {
        self.pacer.rate()
    }

    pub fn srtt(&self) -> Option<Duration> {
        self.srtt
    }

    /// The round-trip loss over the last settled datagrams (a datagram or its ack lost), once
    /// enough settled.
    pub fn loss(&self) -> Option<f64> {
        (self.outcomes.len() >= LOSS_MIN_SETTLED).then(|| self.lost as f64 / self.outcomes.len() as f64)
    }

    pub fn bytes_sent(&self) -> u64 {
        self.bytes_sent
    }

    fn resend_interval(&self) -> Duration {
        match self.srtt {
            Some(srtt) => srtt.mul_f64(1.25).max(self.config.resend_floor),
            None => self.config.resend_unmeasured.max(self.config.resend_floor),
        }
    }

    fn resend_due(&self, now: Instant) -> bool {
        self.sender.unacked() && self.last_send.is_none_or(|last| now >= last + self.resend_interval())
    }

    /// Stamps each datagram (its ack echoes the stamp: a round trip per datagram, resent or
    /// not) and keeps it in flight.
    fn launch(&mut self, datagrams: &mut [Vec<u8>], now: Instant) {
        for datagram in datagrams.iter_mut() {
            self.stamp = self.stamp.wrapping_add(1).max(1);
            stamp_datagram(datagram, self.stamp);
            self.bytes_sent += datagram.len() as u64;
            self.flights.push_back(Flight {
                stamp: self.stamp,
                at: now,
                cumulative: self.bytes_sent,
                acked: false,
            });
        }
        let bytes: usize = datagrams.iter().map(Vec::len).sum();
        self.pacer.spend(bytes, now);
        self.last_send = Some(now);
        while self.flights.len() > MAX_FLIGHTS {
            if let Some(flight) = self.flights.pop_front() {
                self.settled_one(flight.acked, now);
            }
        }
    }

    fn settled_one(&mut self, acked: bool, now: Instant) {
        self.outcomes.push_back(acked);
        if !acked {
            self.lost += 1;
            self.losses += 1;
            self.last_loss = Some(now);
        }
        while self.outcomes.len() > LOSS_WINDOW {
            if self.outcomes.pop_front() == Some(false) {
                self.lost -= 1;
            }
        }
    }

    /// Flights acked, or unacked past the loss timeout, leave for the loss count.
    /// (No round trip measured yet: long enough for the slowest link's first ack.)
    fn settle(&mut self, now: Instant) {
        let timeout = match self.srtt {
            Some(srtt) => (srtt * 2).max(srtt + self.rttvar * 4),
            None => Duration::from_secs(3),
        } + Duration::from_millis(100);
        while let Some(front) = self.flights.front().copied() {
            if !front.acked && now < front.at + timeout {
                break;
            }
            self.flights.pop_front();
            self.settled_one(front.acked, now);
        }
    }

    fn select(&mut self, now: Instant) {
        let Some(selector) = &mut self.selector else { return };
        let above = selector.config().srtt_above;
        // Sends (one per launch time) still unacked past `above`: each a round trip longer than it.
        let mut pending = 0;
        let mut last_at = None;
        for flight in self.flights.iter().rev() {
            if flight.acked {
                // Acked after older unacked ones: those were lost or reordered, not slow.
                break;
            }
            if now.saturating_duration_since(flight.at) > above && last_at != Some(flight.at) {
                pending += 1;
                last_at = Some(flight.at);
            }
        }
        let evidence = Evidence {
            srtt: self.srtt,
            slow: self.slow_run + pending,
            losses: self.losses,
            last_loss: self.last_loss,
            loss: (self.outcomes.len() >= LOSS_MIN_SETTLED)
                .then(|| self.lost as f64 / self.outcomes.len() as f64),
        };
        if self.last_loss.is_some_and(|at| now.saturating_duration_since(at) >= selector.config().hold) {
            // Losses count toward a switch only while they keep coming.
            self.losses = 0;
        }
        let evidence = Evidence { losses: self.losses, ..evidence };
        if let Some(path) = selector.observe(evidence, now) {
            self.losses = 0;
            self.switched = Some(path);
            if path == Path::Datagram {
                // The phone's state is behind by everything the stream carried.
                self.dirty = true;
            }
        }
    }

    /// The datagrams to send now (empty when nothing is due or the pacer holds them back).
    pub fn poll(&mut self, now: Instant) -> Vec<Vec<u8>> {
        self.settle(now);
        self.select(now);
        if self.path() == Path::Datagram || self.probe.is_none() {
            let datagrams = self.poll_state(now);
            if !datagrams.is_empty() {
                return datagrams;
            }
            let copies = self.poll_copy(now);
            if !copies.is_empty() || self.path() == Path::Datagram && !self.settled() {
                return copies;
            }
        }
        self.poll_probe(now)
    }

    fn poll_state(&mut self, now: Instant) -> Vec<Vec<u8>> {
        if self.dirty {
            if !self.pacer.ready(now) {
                self.limited = true;
                return Vec::new();
            }
            let started = self.captures.is_some().then(Instant::now);
            let seq = self.sender.update(ScreenState::capture(&self.term));
            self.dirty = false;
            let batches = self.batches;
            if let (Some(captures), Some(started)) = (&mut self.captures, started) {
                captures.push(Capture {
                    batches,
                    seq,
                    at: now,
                    capture: started.elapsed(),
                    encode: Duration::ZERO,
                });
            }
        }
        let fresh = self.sender.latest_seq() > self.sent_seq;
        if !(fresh || self.resend_due(now)) || !self.pacer.ready(now) {
            return Vec::new();
        }
        let started = self.captures.is_some().then(Instant::now);
        let mut datagrams = self.sender.datagrams();
        if datagrams.is_empty() {
            return datagrams;
        }
        let seq = self.sender.latest_seq();
        if fresh
            && let (Some(captures), Some(started)) = (&mut self.captures, started)
            && let Some(last) = captures.last_mut()
            && last.seq == seq
        {
            last.encode = started.elapsed();
        }
        if self.selector.is_some() {
            self.probe = datagrams.iter().min_by_key(|datagram| datagram.len()).cloned();
        }
        if fresh {
            self.copy = if self.config.copies > 0 && self.jittery() {
                Some((self.config.copies, self.config.copy_spacing))
            } else if self.lossy() {
                Some((1, self.config.loss_copy_after))
            } else {
                None
            }
            .map(|(left, after)| Copies {
                seq,
                datagrams: datagrams.clone(),
                left,
                at: now + after,
            });
        }
        self.launch(&mut datagrams, now);
        self.sent_seq = seq;
        datagrams
    }

    /// Set by the pacer's look at the round trips (at least `2 * MIN_RECENT` of them): copies
    /// beat the jitter.
    fn jittery(&self) -> bool {
        self.jitter
    }

    /// The measured round-trip loss is at least `loss_copy_above`: a burst's last diff gets a copy.
    fn lossy(&self) -> bool {
        self.loss().is_some_and(|loss| loss >= self.config.loss_copy_above)
    }

    /// The copy due now, if its diff is still the newest unacked and the pacer has budget.
    fn poll_copy(&mut self, now: Instant) -> Vec<Vec<u8>> {
        let live = self.copy.as_ref().is_some_and(|copy| {
            copy.seq == self.sender.latest_seq() && self.sender.unacked() && copy.seq == self.sent_seq
        });
        if !live {
            self.copy = None;
            return Vec::new();
        }
        let Some(copy) = self.copy.as_mut() else { return Vec::new() };
        if now < copy.at {
            return Vec::new();
        }
        let mut datagrams = copy.datagrams.clone();
        copy.left -= 1;
        copy.at = now + self.config.copy_spacing;
        if copy.left == 0 {
            self.copy = None;
        }
        let bytes = datagrams.iter().map(Vec::len).sum::<usize>();
        if !self.pacer.affords(bytes, now) {
            // Only spare budget: a copy never puts the pacer in debt, so it never delays a
            // fresh diff. Without the budget it is skipped, not waited for.
            return Vec::new();
        }
        self.copies_sent += 1;
        self.copy_bytes += bytes as u64;
        self.launch(&mut datagrams, now);
        datagrams
    }

    /// Copies sent (each a whole diff again), and their bytes.
    pub fn copies_sent(&self) -> (u64, u64) {
        (self.copies_sent, self.copy_bytes)
    }

    fn probe_at(&self, now: Instant) -> Option<Instant> {
        let selector = self.selector.as_ref()?;
        self.probe.as_ref()?;
        Some(self.last_send.map_or(now, |last| last + selector.config().probe))
    }

    fn poll_probe(&mut self, now: Instant) -> Vec<Vec<u8>> {
        if self.probe_at(now).is_none_or(|at| now < at) || !self.pacer.ready(now) {
            return Vec::new();
        }
        let Some(probe) = self.probe.clone() else { return Vec::new() };
        let mut datagrams = vec![probe];
        self.launch(&mut datagrams, now);
        datagrams
    }

    /// When [`ViewportSync::poll`] next has something to send, or `None` when only new output
    /// or an ack can make it.
    pub fn next_wake(&mut self, now: Instant) -> Option<Instant> {
        let probe = self.probe_at(now).map(|at| at.max(self.pacer.ready_at(now)));
        if self.path() == Path::Stream && self.probe.is_some() {
            return probe;
        }
        let copy = self.copy.as_ref().map(|copy| copy.at);
        if self.dirty {
            let ready = self.pacer.ready_at(now);
            return Some(copy.map_or(ready, |copy| copy.min(ready)));
        }
        if let Some(copy) = copy
            && self.sender.unacked()
        {
            return Some(copy);
        }
        if !self.sender.unacked() {
            return probe;
        }
        let resend = self.last_send.map_or(now, |last| last + self.resend_interval());
        Some(resend.max(self.pacer.ready_at(now)))
    }

    /// A datagram from the phone (its ack).
    pub fn on_datagram(&mut self, datagram: &[u8], now: Instant) {
        self.sender.on_ack(datagram);
        if let Some(stamp) = parse_ack_stamp(datagram).filter(|stamp| *stamp != 0)
            && let Some(flight) = self.flights.iter_mut().rev().find(|flight| flight.stamp == stamp)
            && !flight.acked
        {
            flight.acked = true;
            let (at, cumulative) = (flight.at, flight.cumulative);
            let delivered = self.delivered.back().map_or(cumulative, |(_, bytes)| (*bytes).max(cumulative));
            self.delivered.push_back((now, delivered));
            while self.delivered.len() > MAX_SAMPLES {
                self.delivered.pop_front();
            }
            let rtt = now.saturating_duration_since(at);
            // One per send: a diff's fragments went together and say the same.
            if self.slow_at != Some(at) {
                let above =
                    self.selector.as_ref().map_or(Duration::MAX, |selector| selector.config().srtt_above);
                self.slow_run = if rtt > above { self.slow_run + 1 } else { 0 };
                self.slow_at = Some(at);
            }
            self.sample(rtt, now);
        }
        self.settle(now);
        self.select(now);
    }

    fn sample(&mut self, rtt: Duration, now: Instant) {
        match self.srtt {
            None => {
                self.srtt = Some(rtt);
                self.rttvar = rtt / 2;
            }
            Some(srtt) => {
                let deviation = srtt.abs_diff(rtt);
                self.rttvar = self.rttvar.mul_f64(0.75) + deviation.mul_f64(0.25);
                self.srtt = Some(srtt.mul_f64(0.875) + rtt.mul_f64(0.125));
            }
        }
        self.samples.push_back((now, rtt));
        while self.samples.len() > MAX_SAMPLES
            || self.samples.front().is_some_and(|(at, _)| now.saturating_duration_since(*at) > FLOOR_WINDOW)
        {
            self.samples.pop_front();
        }
        self.adjust(now);
    }

    /// What reached the phone per second, over about a round trip.
    fn delivery_rate(&self, now: Instant, window: Duration) -> Option<f64> {
        let (last_at, last_bytes) = *self.delivered.back()?;
        let (first_at, first_bytes) =
            self.delivered.iter().find(|(at, _)| now.saturating_duration_since(*at) <= window).copied()?;
        let elapsed = last_at.saturating_duration_since(first_at);
        if elapsed < Duration::from_millis(50) {
            return None;
        }
        Some(last_bytes.saturating_sub(first_bytes) as f64 / elapsed.as_secs_f64())
    }

    /// The rate follows the link's delay, never its loss, at most once a round trip. A queue
    /// lifts every round trip: the recent minimum above the 10 s floor and the recent median
    /// above the 10 s median, both by more than the jitter's spread (jitter alone strays one of
    /// them now and then, not both twice running). Two looks in a row with a queue cut the rate
    /// (to under what was delivered, at most by half); a held-back screen with none is headroom.
    fn adjust(&mut self, now: Instant) {
        let Some(srtt) = self.srtt else { return };
        let period = srtt.max(Duration::from_millis(50));
        if self.last_adjust.is_some_and(|last| now < last + period) {
            return;
        }
        if self.samples.len() < 2 * MIN_RECENT {
            return;
        }
        let mut long: Vec<Duration> = self.samples.iter().map(|(_, rtt)| *rtt).collect();
        let window = (srtt / 2).max(Duration::from_millis(500));
        let mut recent: Vec<Duration> = self
            .samples
            .iter()
            .filter(|(at, _)| now.saturating_duration_since(*at) <= window)
            .map(|(_, rtt)| *rtt)
            .collect();
        if recent.len() < MIN_RECENT {
            // A slow sender: its last few round trips, however long they took to come.
            recent = self.samples.iter().rev().take(MIN_RECENT).map(|(_, rtt)| *rtt).collect();
        }
        long.sort_unstable();
        recent.sort_unstable();
        let floor = long[0];
        let spread = long[long.len() * 3 / 4].saturating_sub(long[long.len() / 4]);
        // Jitter dominates when the round trips' middle half spans a quarter of their median:
        // lossy-3 (about 180 of 370 ms), not lossy-10 (about 180 of 1300) or lte (none).
        self.jitter = spread >= COPY_JITTER && spread * 4 >= long[long.len() / 2];
        let threshold = Duration::from_millis(25).max(floor / 4).max(spread / 2);
        let lifted = recent[0]
            .saturating_sub(floor)
            .min(recent[recent.len() / 2].saturating_sub(long[long.len() / 2]));
        let queued = lifted > threshold;
        let again = queued && self.queued;
        self.queued = queued;
        self.last_adjust = Some(now);
        let rate = self.pacer.rate();
        let next = if again {
            let delivered = self.delivery_rate(now, srtt.max(Duration::from_millis(250)));
            delivered.map_or(rate * 0.7, |delivered| (delivered * 0.75).min(rate * 0.85)).max(rate * 0.5)
        } else if !queued && self.limited && lifted <= threshold / 2 {
            rate * 1.25
        } else {
            return;
        };
        self.pacer.set_rate(next.clamp(self.config.min_rate, self.config.max_rate), now);
        self.limited = false;
    }
}

/// A datagram socket the driver sends through and hears acks on.
pub trait DatagramIo: Send {
    /// The largest payload a send takes.
    fn max_datagram(&self) -> usize;
    fn send_to(&self, payload: &[u8], peer: SocketAddr) -> impl Future<Output = io::Result<()>> + Send;
    /// The next datagram and who sent it. Cancel-safe.
    fn recv_from(&mut self) -> impl Future<Output = io::Result<(Vec<u8>, SocketAddr)>> + Send;
}

/// A UDP socket's payload under a 1280-byte IPv6 minimum MTU path, with room for headers.
pub const UDP_MAX_DATAGRAM: usize = 1200;

impl DatagramIo for UdpSocket {
    fn max_datagram(&self) -> usize {
        UDP_MAX_DATAGRAM
    }

    async fn send_to(&self, payload: &[u8], peer: SocketAddr) -> io::Result<()> {
        UdpSocket::send_to(self, payload, peer).await.map(|_| ())
    }

    async fn recv_from(&mut self) -> io::Result<(Vec<u8>, SocketAddr)> {
        let mut buffer = vec![0_u8; 8 * 1024];
        let (n, from) = UdpSocket::recv_from(self, &mut buffer).await?;
        buffer.truncate(n);
        Ok((buffer, from))
    }
}

impl DatagramIo for WgDatagramSocket {
    fn max_datagram(&self) -> usize {
        WgDatagramSocket::max_datagram(self)
    }

    async fn send_to(&self, payload: &[u8], peer: SocketAddr) -> io::Result<()> {
        WgDatagramSocket::send_to(self, payload, peer, Priority::Interactive).await.map_err(io::Error::other)
    }

    async fn recv_from(&mut self) -> io::Result<(Vec<u8>, SocketAddr)> {
        WgDatagramSocket::recv_from(self)
            .await
            .ok_or_else(|| io::Error::new(io::ErrorKind::BrokenPipe, "the WireGuard session ended"))
    }
}

/// What [`run_selected`] hands the reliable stream.
#[derive(Debug, PartialEq, Eq)]
pub enum StreamOut {
    /// A PTY batch for the stream, as it came (the stream path is on); `batch` counts from 1.
    /// `rows`: the rows it pushed out of the viewport, when [`skip_superseded`] is on (the
    /// stream may then drop the batch for them once a switch to the datagrams follows it).
    Output { batch: u64, bytes: Vec<u8>, rows: Option<Vec<u8>> },
    /// Rows that left the viewport while the datagrams carry the screen.
    History(Vec<u8>),
    /// The path changed; the batches after this go the new way.
    Switched(Path),
    /// Right after a switch to the stream: the host's screen now, for the phone to repaint in
    /// full before the stream's batches resume (the datagrams may have left it behind).
    Repaint(ScreenState),
}

enum Sink {
    History(Option<mpsc::Sender<Vec<u8>>>),
    Selected(mpsc::Sender<StreamOut>),
}

/// Drives `sync` over `io`: output batches from `output` (PTY bytes), the rows they push out
/// of the viewport to `history` (the reliable stream), datagrams to `peer` (learned from the
/// phone's datagrams when `None`). When `output` closes it keeps resending until the phone
/// acks the last state or `drain` passes, then returns the driver.
pub async fn run<I: DatagramIo>(
    sync: ViewportSync,
    io: I,
    peer: Option<SocketAddr>,
    output: mpsc::Receiver<Vec<u8>>,
    history: Option<mpsc::Sender<Vec<u8>>>,
    drain: Duration,
) -> io::Result<ViewportSync> {
    drive(sync, io, peer, output, Sink::History(history), drain).await
}

/// [`run`] with the path chosen per link ([`ViewportSync::select_path`], the default
/// [`SelectorConfig`] when not set): on the stream path each batch goes to `stream` as it
/// came; on the datagram path only the rows leaving the viewport do. Each switch goes to
/// `stream` too. When `output` closes on the stream path it returns at once.
pub async fn run_selected<I: DatagramIo>(
    mut sync: ViewportSync,
    io: I,
    peer: Option<SocketAddr>,
    output: mpsc::Receiver<Vec<u8>>,
    stream: mpsc::Sender<StreamOut>,
    drain: Duration,
) -> io::Result<ViewportSync> {
    if sync.selector.is_none() {
        sync.select_path(SelectorConfig::default());
    }
    drive(sync, io, peer, output, Sink::Selected(stream), drain).await
}

async fn drive<I: DatagramIo>(
    mut sync: ViewportSync,
    mut io: I,
    mut peer: Option<SocketAddr>,
    mut output: mpsc::Receiver<Vec<u8>>,
    sink: Sink,
    drain: Duration,
) -> io::Result<ViewportSync> {
    let mut closed_at: Option<Instant> = None;
    let skip = skip_superseded();
    loop {
        let now = Instant::now();
        if let Some(peer) = peer {
            for datagram in sync.poll(now) {
                // A refused send is a lost datagram: the next state or the resend covers it.
                let _ = io.send_to(&datagram, peer).await;
            }
        }
        if let (Some(path), Sink::Selected(stream)) = (sync.take_switch(), &sink) {
            let _ = stream.send(StreamOut::Switched(path)).await;
            if path == Path::Stream {
                // Before any batch the stream path forwards: those follow this screen.
                let _ = stream.send(StreamOut::Repaint(sync.capture())).await;
            }
        }
        let done = sync.settled() || matches!(sink, Sink::Selected(_)) && sync.path() == Path::Stream;
        if let Some(closed) = closed_at
            && (done || now >= closed + drain)
        {
            return Ok(sync);
        }
        let mut wake = if peer.is_some() { sync.next_wake(now) } else { None };
        if let Some(closed) = closed_at {
            let end = closed + drain;
            wake = Some(wake.map_or(end, |at| at.min(end)));
        }
        let sleep = async {
            match wake {
                Some(at) => tokio::time::sleep_until(tokio::time::Instant::from_std(at)).await,
                None => std::future::pending().await,
            }
        };
        tokio::select! {
            received = io.recv_from() => {
                let (datagram, from) = received?;
                peer = Some(from);
                sync.on_datagram(&datagram, Instant::now());
            }
            batch = output.recv(), if closed_at.is_none() => match batch {
                Some(bytes) => {
                    let path = sync.path();
                    let rows = if let Sink::Selected(stream) = &sink
                        && path == Path::Stream
                    {
                        let batch = sync.batches() + 1;
                        if skip {
                            // The model first: the batch carries its scrolled-off rows.
                            let rows = sync.feed(&bytes);
                            let out = StreamOut::Output { batch, bytes, rows: Some(rows.clone()) };
                            let _ = stream.send(out).await;
                            rows
                        } else {
                            // Out before the model takes it: the stream path waits on nothing.
                            let _ = stream.send(StreamOut::Output { batch, bytes: bytes.clone(), rows: None }).await;
                            sync.feed(&bytes)
                        }
                    } else {
                        sync.feed(&bytes)
                    };
                    match &sink {
                        Sink::History(Some(history)) if !rows.is_empty() => {
                            let _ = history.send(rows).await;
                        }
                        Sink::Selected(stream) if path == Path::Datagram && !rows.is_empty() => {
                            let _ = stream.send(StreamOut::History(rows)).await;
                        }
                        _ => {}
                    }
                }
                None => closed_at = Some(Instant::now()),
            },
            () = sleep => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_terminal_projection::sync::SyncReceiver;

    fn driver(now: Instant) -> ViewportSync {
        ViewportSync::new(80, 24, UDP_MAX_DATAGRAM, Config::default(), now)
    }

    #[test]
    fn viewport_sync_is_off_unless_asked() {
        assert!(!enabled_from(None));
        assert!(!enabled_from(Some("")));
        assert!(!enabled_from(Some("0")));
        assert!(!enabled_from(Some("off")));
        assert!(enabled_from(Some("1")));
        assert!(enabled_from(Some("true")));
        assert_eq!(PORT, 7424);
    }

    #[test]
    fn viewport_sync_pacer_holds_a_send_until_its_debt_is_paid() {
        let start = Instant::now();
        let mut pacer = Pacer::new(10_000.0, Duration::from_millis(50), start);
        assert!(pacer.ready(start));
        // 500 bytes of burst; a 2500-byte diff goes whole and leaves 2000 bytes of debt.
        pacer.spend(2_500, start);
        assert!(!pacer.ready(start));
        let at = pacer.ready_at(start);
        let wait = at - start;
        assert!(wait >= Duration::from_millis(200) && wait < Duration::from_millis(202), "{wait:?}");
        assert!(!pacer.ready(start + Duration::from_millis(150)));
        assert!(pacer.ready(at));
        // Idle time saves up only the burst.
        let later = at + Duration::from_secs(10);
        pacer.ready(later);
        pacer.spend(501, later);
        assert!(!pacer.ready(later));
    }

    #[test]
    fn viewport_sync_pacer_coalesces_to_the_newest_screen() {
        let start = Instant::now();
        let config = Config { initial_rate: 1_000.0, burst: Duration::from_millis(1), ..Config::default() };
        let mut sync = ViewportSync::new(80, 24, UDP_MAX_DATAGRAM, config, start);
        sync.record_captures();
        sync.feed(b"first");
        let first = sync.poll(start);
        assert!(!first.is_empty());
        // Ten redraws while the pacer is in debt: none goes, none is captured.
        for i in 0..10 {
            sync.feed(format!("\r\x1b[2Kredraw {i}").as_bytes());
            let now = start + Duration::from_millis(i);
            assert!(sync.poll(now).is_empty());
        }
        let at = sync.next_wake(start).expect("a dirty screen wakes the driver");
        let next = sync.poll(at);
        assert!(!next.is_empty());
        let captures = sync.captures();
        assert_eq!(captures.len(), 2, "one capture per send: {captures:?}");
        assert_eq!(captures[1].batches, 11, "the second covers every redraw");
        assert_eq!(captures[1].seq, 2);
    }

    #[test]
    fn viewport_sync_resends_the_latest_until_acked() {
        let start = Instant::now();
        let mut sync = driver(start);
        let mut phone = SyncReceiver::new();
        sync.feed(b"hello");
        let first = sync.poll(start);
        assert!(!first.is_empty());
        // Lost. Nothing goes before the resend interval (100 ms unmeasured).
        assert!(sync.poll(start + Duration::from_millis(50)).is_empty());
        let wake = sync.next_wake(start + Duration::from_millis(50)).unwrap();
        assert_eq!(wake, start + Duration::from_millis(100));
        let again = sync.poll(wake);
        assert!(!again.is_empty(), "the latest diff again");
        let mut ack = None;
        for datagram in &again {
            ack = phone.on_datagram(datagram).or(ack);
        }
        assert_eq!(phone.seq(), sync.latest_seq());
        sync.on_datagram(&ack.expect("an ack"), wake + Duration::from_millis(5));
        assert!(sync.settled());
        assert!(sync.poll(wake + Duration::from_secs(5)).is_empty());
        assert_eq!(sync.next_wake(wake + Duration::from_secs(5)), None);
        assert_eq!(phone.screen(), Some(&sync.capture()));
    }

    #[test]
    fn viewport_sync_resend_interval_follows_the_round_trip() {
        let start = Instant::now();
        let mut sync = driver(start);
        let mut phone = SyncReceiver::new();
        sync.feed(b"one");
        let mut ack = None;
        for datagram in sync.poll(start) {
            ack = phone.on_datagram(&datagram).or(ack);
        }
        // A 200 ms round trip.
        let acked_at = start + Duration::from_millis(200);
        sync.on_datagram(&ack.unwrap(), acked_at);
        assert_eq!(sync.srtt(), Some(Duration::from_millis(200)));
        sync.feed(b" two");
        assert!(!sync.poll(acked_at).is_empty());
        // Unacked: the resend waits 1.25 * srtt.
        assert_eq!(sync.next_wake(acked_at), Some(acked_at + Duration::from_millis(250)));
        assert!(sync.poll(acked_at + Duration::from_millis(249)).is_empty());
        assert!(!sync.poll(acked_at + Duration::from_millis(250)).is_empty());
    }

    #[test]
    fn viewport_sync_rate_comes_down_when_the_round_trip_floor_rises() {
        let start = Instant::now();
        let mut sync = driver(start);
        let mut phone = SyncReceiver::new();
        let mut now = start;
        // A link whose queue grows: each redraw's round trip is 10 ms longer than the last.
        let mut in_flight: VecDeque<(Instant, Vec<Vec<u8>>)> = VecDeque::new();
        let initial = sync.rate();
        for i in 0..200_u64 {
            now += Duration::from_millis(16);
            sync.feed(format!("\x1b[H\x1b[2Kline {i}").as_bytes());
            let datagrams = sync.poll(now);
            if !datagrams.is_empty() {
                in_flight.push_back((now + Duration::from_millis(20 + 10 * i), datagrams));
            }
            while let Some((due, _)) = in_flight.front()
                && *due <= now
            {
                let (_, datagrams) = in_flight.pop_front().unwrap();
                for datagram in datagrams {
                    if let Some(ack) = phone.on_datagram(&datagram) {
                        sync.on_datagram(&ack, now);
                    }
                }
            }
        }
        assert!(sync.rate() < initial, "{} >= {initial}", sync.rate());
    }

    /// A link for the driver's unit tests: each datagram (and its ack) delayed by `delay` plus
    /// up to `jitter`, each way lost with probability `loss`, the jitter and loss from a seed.
    struct FakeLink {
        delay: Duration,
        jitter: Duration,
        loss: f64,
        seed: u64,
        to_phone: Vec<(Instant, Vec<u8>)>,
        to_host: Vec<(Instant, Vec<u8>)>,
    }

    impl FakeLink {
        fn new(delay: Duration, jitter: Duration, loss: f64) -> Self {
            Self {
                delay,
                jitter,
                loss,
                seed: 0x9e37_79b9_7f4a_7c15,
                to_phone: Vec::new(),
                to_host: Vec::new(),
            }
        }

        fn random(&mut self) -> f64 {
            self.seed ^= self.seed << 13;
            self.seed ^= self.seed >> 7;
            self.seed ^= self.seed << 17;
            (self.seed >> 11) as f64 / (1_u64 << 53) as f64
        }

        fn arrival(&mut self, now: Instant) -> Option<Instant> {
            if self.random() < self.loss {
                return None;
            }
            Some(now + self.delay + self.jitter.mul_f64(self.random()))
        }

        /// Moves the clock to `now`: datagrams reach the phone, acks reach the host.
        fn step(
            &mut self,
            sync: &mut ViewportSync,
            phone: &mut SyncReceiver,
            sent: Vec<Vec<u8>>,
            now: Instant,
        ) {
            for datagram in sent {
                if let Some(at) = self.arrival(now) {
                    self.to_phone.push((at, datagram));
                }
            }
            let (due, later): (Vec<_>, Vec<_>) = self.to_phone.drain(..).partition(|(at, _)| *at <= now);
            self.to_phone = later;
            for (_, datagram) in due {
                if let Some(ack) = phone.on_datagram(&datagram)
                    && let Some(at) = self.arrival(now)
                {
                    self.to_host.push((at, ack));
                }
            }
            let (due, later): (Vec<_>, Vec<_>) = self.to_host.drain(..).partition(|(at, _)| *at <= now);
            self.to_host = later;
            for (_, ack) in due {
                sync.on_datagram(&ack, now);
            }
        }
    }

    /// Redraws every 16 ms for `seconds` over `link`, polled every millisecond.
    fn drive_fake(sync: &mut ViewportSync, link: &mut FakeLink, start: Instant, seconds: u64) -> Instant {
        let mut phone = SyncReceiver::new();
        let mut now = start;
        for ms in 0..seconds * 1000 {
            now = start + Duration::from_millis(ms);
            if ms % 16 == 0 {
                sync.feed(format!("\x1b[H\x1b[2Kline {ms}\r\n").as_bytes());
            }
            let sent = sync.poll(now);
            link.step(sync, &mut phone, sent, now);
        }
        now
    }

    #[test]
    fn viewport_sync_pacer_does_not_back_off_on_loss_alone() {
        // lossy-3: 35 ms each way, 300 ms of jitter, 3% loss each way, no queue at all.
        let start = Instant::now();
        let mut sync = driver(start);
        let initial = sync.rate();
        let mut link = FakeLink::new(Duration::from_millis(35), Duration::from_millis(300), 0.03);
        drive_fake(&mut sync, &mut link, start, 20);
        assert!(sync.rate() >= initial, "{} < {initial}: loss and jitter are not a queue", sync.rate());
        let loss = sync.loss().expect("enough settled");
        assert!((0.03..0.10).contains(&loss), "round-trip loss {loss}");
    }

    #[test]
    fn viewport_sync_copies_the_newest_diff_only_on_a_jittery_link() {
        // lossy-3's jitter: each diff goes up to twice more, on spare budget.
        let start = Instant::now();
        let mut sync = driver(start);
        let mut link = FakeLink::new(Duration::from_millis(35), Duration::from_millis(300), 0.03);
        drive_fake(&mut sync, &mut link, start, 10);
        let (copies, bytes) = sync.copies_sent();
        assert!(copies > 100, "{copies} copies on a jittery link");
        assert!(bytes > 0);
        // A steady 70 ms round trip: no copies.
        let mut sync = driver(start);
        let mut link = FakeLink::new(Duration::from_millis(35), Duration::ZERO, 0.0);
        drive_fake(&mut sync, &mut link, start, 10);
        assert_eq!(sync.copies_sent().0, 0);
    }

    #[test]
    fn viewport_sync_a_copy_never_outlives_its_diff() {
        let start = Instant::now();
        let mut sync = driver(start);
        sync.jitter = true;
        sync.feed(b"one");
        assert!(!sync.poll(start).is_empty());
        let at = sync.next_wake(start).expect("a copy is due");
        assert_eq!(at, start + Duration::from_millis(4));
        assert!(!sync.poll(at).is_empty(), "the first copy");
        // A newer diff replaces the rest of the old one's copies.
        sync.feed(b" two");
        let now = at + Duration::from_millis(4);
        assert!(!sync.poll(now).is_empty());
        assert_eq!(sync.copy.as_ref().map(|copy| copy.seq), Some(2));
        assert_eq!(sync.copies_sent().0, 1);
    }

    #[test]
    fn viewport_sync_selector_keeps_the_stream_on_a_fast_clean_link() {
        let start = Instant::now();
        let mut sync = driver(start);
        sync.select_path(SelectorConfig::default());
        assert_eq!(sync.path(), Path::Stream);
        let mut link = FakeLink::new(Duration::from_millis(1), Duration::ZERO, 0.0);
        drive_fake(&mut sync, &mut link, start, 15);
        assert_eq!(sync.path(), Path::Stream);
        assert!(sync.switches().is_empty());
        assert_eq!(sync.loss(), Some(0.0), "the probes measured it");
        // The probes are all it sent after the first state: no screen went by datagram.
        assert_eq!(sync.latest_seq(), 1);
    }

    #[test]
    fn viewport_sync_selector_switches_on_a_long_round_trip_and_back_with_hysteresis() {
        let start = Instant::now();
        let mut sync = driver(start);
        sync.select_path(SelectorConfig::default());
        let mut link = FakeLink::new(Duration::from_millis(35), Duration::ZERO, 0.0);
        let now = drive_fake(&mut sync, &mut link, start, 2);
        assert_eq!(sync.path(), Path::Datagram);
        assert_eq!(sync.take_switch(), Some(Path::Datagram));
        let switch = sync.switches()[0];
        assert!(switch.at < start + Duration::from_millis(600), "{:?}", switch.at - start);
        assert!(switch.evidence.slow >= 3, "{:?}", switch.evidence);
        // The link gets fast: back to the stream only after the hold, once.
        link.delay = Duration::from_millis(1);
        let mut phone_link = link;
        let later = drive_fake(&mut sync, &mut phone_link, now + Duration::from_millis(1), 20);
        assert_eq!(sync.path(), Path::Stream);
        let switches = sync.switches();
        assert_eq!(switches.len(), 2, "{switches:?}");
        assert!(switches[1].at >= now + SelectorConfig::default().hold);
        assert!(later > switches[1].at);
    }

    #[test]
    fn viewport_sync_selector_switches_within_a_second_on_lossy_10() {
        let start = Instant::now();
        let mut sync = driver(start);
        sync.select_path(SelectorConfig::default());
        // lossy-10: 500 ms each way, 300 ms of jitter, 10% loss each way. No ack comes back for
        // a second; the sends still unacked past 20 ms say the round trip is long.
        let mut link = FakeLink::new(Duration::from_millis(500), Duration::from_millis(300), 0.10);
        drive_fake(&mut sync, &mut link, start, 2);
        let switch = sync.switches().first().copied().expect("a switch");
        assert_eq!(switch.to, Path::Datagram);
        assert!(switch.at - start <= Duration::from_secs(1), "{:?}", switch.at - start);
    }

    #[test]
    fn viewport_sync_selector_switches_on_loss() {
        let start = Instant::now();
        let mut sync = driver(start);
        sync.select_path(SelectorConfig::default());
        // A fast link losing 2% each way.
        let mut link = FakeLink::new(Duration::from_millis(1), Duration::ZERO, 0.02);
        drive_fake(&mut sync, &mut link, start, 30);
        assert_eq!(sync.switches().first().map(|s| s.to), Some(Path::Datagram));
    }

    /// RFD 0140 §4: on a 200 ms round trip with 5% loss each way (and jitter that reorders), the
    /// phone's screen matches the host's within one round trip after a burst of output ends. A
    /// burst's last diff lost on the way comes back with its copy (`loss_copy_after` later) or,
    /// both lost, the resend at 1.25 * srtt: the 95th percentile within one round trip, the worst
    /// within three.
    /// (ms from each burst's end to a match, bytes sent, bytes of copies)
    fn lossy_link_bursts(seed: u64, bursts: usize) -> (Vec<u64>, u64, u64) {
        let start = Instant::now();
        let mut sync = driver(start);
        let mut link = FakeLink::new(Duration::from_millis(90), Duration::from_millis(20), 0.05);
        link.seed ^= seed.wrapping_mul(0x2545_f491_4f6c_dd1d);
        let mut phone = SyncReceiver::new();
        let mut ms = 0_u64;
        let mut line = 0_u64;
        let mut took_ms = Vec::with_capacity(bursts);
        let tick = |sync: &mut ViewportSync, phone: &mut SyncReceiver, link: &mut FakeLink, ms: u64| {
            let now = start + Duration::from_millis(ms);
            let sent = sync.poll(now);
            link.step(sync, phone, sent, now);
        };
        for _ in 0..bursts {
            // 1 to 40 lines over up to 300 ms: test output, a progress line, typing.
            let ticks = 1 + (link.random() * 20.0) as u64;
            for _ in 0..ticks {
                for _ in 0..(link.random() * 3.0) as u64 {
                    line += 1;
                    let text = match line % 4 {
                        0 => format!("\x1b[32mok\x1b[0m test_{line} ... passed\r\n"),
                        1 => format!("\r\x1b[Kbuilding {}%", line % 100),
                        2 => "x".to_string(),
                        _ => format!("\x1b[1;31merror\x1b[0m[E{line:04}]: at src/lib.rs:{line}\r\n"),
                    };
                    sync.feed(text.as_bytes());
                }
                for _ in 0..16 {
                    tick(&mut sync, &mut phone, &mut link, ms);
                    ms += 1;
                }
            }
            let end = ms;
            let target = sync.capture();
            while phone.screen() != Some(&target) {
                tick(&mut sync, &mut phone, &mut link, ms);
                ms += 1;
                assert!(ms - end < 10_000, "seed {seed}: no match 10 s after a burst");
            }
            took_ms.push(ms - end);
            // Idle between commands.
            for _ in 0..(200 + (link.random() * 400.0) as u64) {
                tick(&mut sync, &mut phone, &mut link, ms);
                ms += 1;
            }
        }
        (took_ms, sync.bytes_sent(), sync.copies_sent().1)
    }

    #[test]
    fn viewport_sync_matches_within_one_round_trip_after_a_burst_on_a_lossy_link() {
        // 90 ms each way plus up to 20 ms of jitter each way: a 200 ms round trip at most.
        const RTT: u64 = 200;
        let mut all = Vec::new();
        for seed in 1..=10 {
            let (mut took, bytes, copy_bytes) = lossy_link_bursts(seed, 50);
            all.extend_from_slice(&took);
            took.sort_unstable();
            let within = took.iter().filter(|&&ms| ms <= RTT).count();
            let worst = took.last().copied().unwrap_or(0);
            println!(
                "seed {seed}: {within}/{} within {RTT} ms, worst {worst} ms, {bytes} B sent, {copy_bytes} B of copies",
                took.len()
            );
        }
        all.sort_unstable();
        let p95 = all[(all.len() * 95).div_ceil(100) - 1];
        let p50 = all[all.len() / 2];
        let worst = all.last().copied().unwrap_or(0);
        let within = all.iter().filter(|&&ms| ms <= RTT).count();
        println!(
            "all: {within}/{} within one round trip, p50 {p50} ms, p95 {p95} ms, worst {worst} ms",
            all.len()
        );
        assert!(p95 <= RTT, "p95 {p95} ms > one round trip ({RTT} ms)");
        assert!(worst <= 3 * RTT, "worst {worst} ms > three round trips");
    }

    #[tokio::test]
    async fn viewport_sync_runs_over_udp_and_the_phone_converges() {
        let host = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let phone = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        phone.connect(host.local_addr().unwrap()).await.unwrap();
        let (output, batches) = mpsc::channel(64);
        let sync = ViewportSync::new(80, 24, UDP_MAX_DATAGRAM, Config::default(), Instant::now());
        let peer = Some(phone.local_addr().unwrap());
        let host_task = tokio::spawn(run(sync, host, peer, batches, None, Duration::from_secs(5)));
        let phone_task = tokio::spawn(async move {
            let mut receiver = SyncReceiver::new();
            let mut buffer = vec![0_u8; 64 * 1024];
            loop {
                let Ok(Ok(n)) =
                    tokio::time::timeout(Duration::from_millis(500), phone.recv(&mut buffer)).await
                else {
                    return receiver;
                };
                if let Some(ack) = receiver.on_datagram(&buffer[..n]) {
                    phone.send(&ack).await.unwrap();
                }
            }
        });
        for i in 0..50 {
            output.send(format!("line {i}\r\n").into_bytes()).await.unwrap();
        }
        drop(output);
        let sync = host_task.await.unwrap().unwrap();
        assert!(sync.settled());
        let receiver = phone_task.await.unwrap();
        assert_eq!(receiver.screen(), Some(&sync.capture()));
    }
}
