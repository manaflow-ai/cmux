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
//!   again every `max(1.5 * srtt, 30 ms)`.
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

/// The opt-in switch: `1` (or `true`) turns the datagram path on; anything else, or unset, is off.
pub const ENV: &str = "CMUX_MOBILE_VIEWPORT_SYNC";
/// The overlay UDP port (7420 link TCP, 7421 roam, 7422 media, 7423 failover relay).
pub const PORT: u16 = 7424;

/// Whether the datagram path is on in this process.
pub fn enabled() -> bool {
    enabled_from(std::env::var(ENV).ok().as_deref())
}

/// The gate's rule on a value of [`ENV`]: default off.
pub fn enabled_from(value: Option<&str>) -> bool {
    matches!(value.map(str::trim), Some("1" | "true"))
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
    /// The resend interval's floor (it is `max(1.5 * srtt, resend_floor)`).
    pub resend_floor: Duration,
    /// The resend interval before any round trip was measured.
    pub resend_unmeasured: Duration,
    /// How much the pacer may save up while idle, as time at its rate.
    pub burst: Duration,
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
    /// Datagrams when the round-trip loss is above this.
    pub loss_above: f64,
    /// Datagrams when the smoothed round trip is above this.
    pub srtt_above: Duration,
    /// Back to the stream only below both of these, for `hold` (the hysteresis).
    pub loss_below: f64,
    pub srtt_below: Duration,
    pub hold: Duration,
    /// Round trips measured before a long one switches.
    pub min_samples: u64,
    /// While nothing else goes, a small datagram every `probe` keeps the round trip and loss
    /// measured.
    pub probe: Duration,
}

impl Default for SelectorConfig {
    fn default() -> Self {
        Self {
            loss_above: 0.005,
            srtt_above: Duration::from_millis(20),
            loss_below: 0.0025,
            srtt_below: Duration::from_millis(15),
            hold: Duration::from_secs(2),
            min_samples: 3,
            probe: Duration::from_millis(100),
        }
    }
}

/// One path switch: when, to which path, and the measurements that made it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Switch {
    pub at: Instant,
    pub to: Path,
    pub srtt: Duration,
    pub loss: Option<f64>,
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

    /// The link's numbers now (`samples` round trips measured so far, `loss` once enough
    /// sends settled). Returns the new path when it switches, and logs one line.
    pub fn observe(&mut self, srtt: Duration, samples: u64, loss: Option<f64>, now: Instant) -> Option<Path> {
        let config = &self.config;
        let next = match self.path {
            Path::Stream => {
                let slow = samples >= config.min_samples && srtt > config.srtt_above;
                let lossy = loss.is_some_and(|loss| loss > config.loss_above);
                (slow || lossy).then_some(Path::Datagram)
            }
            Path::Datagram => {
                let good = srtt < config.srtt_below && loss.is_some_and(|loss| loss < config.loss_below);
                if good {
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
        self.switches.push(Switch { at: now, to: next, srtt, loss });
        tracing::info!(
            to = next.name(),
            srtt_ms = srtt.as_secs_f64() * 1000.0,
            loss = loss.map_or_else(|| "-".to_owned(), |loss| format!("{:.4}", loss)),
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
    rtt_samples: u64,
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
            rtt_samples: 0,
            samples: VecDeque::new(),
            delivered: VecDeque::new(),
            last_adjust: None,
            limited: false,
            selector: None,
            probe: None,
            switched: None,
            captures: None,
            feeds: None,
        }
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
            Some(srtt) => srtt.mul_f64(1.5).max(self.config.resend_floor),
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
                self.settled_one(flight.acked);
            }
        }
    }

    fn settled_one(&mut self, acked: bool) {
        self.outcomes.push_back(acked);
        if !acked {
            self.lost += 1;
        }
        while self.outcomes.len() > LOSS_WINDOW {
            if self.outcomes.pop_front() == Some(false) {
                self.lost -= 1;
            }
        }
    }

    /// Flights acked, or unacked past the loss timeout, leave for the loss count.
    fn settle(&mut self, now: Instant) {
        let timeout = match self.srtt {
            Some(srtt) => (srtt * 2).max(srtt + self.rttvar * 4),
            None => Duration::from_secs(1),
        } + Duration::from_millis(100);
        while let Some(front) = self.flights.front().copied() {
            if !front.acked && now < front.at + timeout {
                break;
            }
            self.flights.pop_front();
            self.settled_one(front.acked);
        }
    }

    fn select(&mut self, now: Instant) {
        let (Some(srtt), loss, samples) = (self.srtt, self.loss(), self.rtt_samples) else { return };
        let Some(selector) = &mut self.selector else { return };
        if let Some(path) = selector.observe(srtt, samples, loss, now) {
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
            if !datagrams.is_empty() || self.path() == Path::Datagram && !self.settled() {
                return datagrams;
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
        self.launch(&mut datagrams, now);
        self.sent_seq = seq;
        datagrams
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
        if self.dirty {
            return Some(self.pacer.ready_at(now));
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
            self.sample(now.saturating_duration_since(at), now);
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
        self.rtt_samples += 1;
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

    /// The rate follows the link's delay, never its loss, at most once a round trip: a recent
    /// round-trip minimum risen above the floor by more than the jitter's spread is a queue
    /// (down to under what was delivered); a held-back screen at the floor is headroom.
    fn adjust(&mut self, now: Instant) {
        let Some(srtt) = self.srtt else { return };
        let period = srtt.max(Duration::from_millis(50));
        if self.last_adjust.is_some_and(|last| now < last + period) {
            return;
        }
        let Some(floor) = self.samples.iter().map(|(_, rtt)| *rtt).min() else { return };
        let window = (srtt / 2).max(Duration::from_millis(500));
        let mut recent: Vec<Duration> = self
            .samples
            .iter()
            .filter(|(at, _)| now.saturating_duration_since(*at) <= window)
            .map(|(_, rtt)| *rtt)
            .collect();
        if recent.len() < MIN_RECENT {
            return;
        }
        recent.sort_unstable();
        let low = recent[0];
        let spread = recent[recent.len() / 2].saturating_sub(low);
        let threshold = Duration::from_millis(25).max(floor / 4).max(spread);
        let queue = low.saturating_sub(floor);
        let rate = self.pacer.rate();
        let next = if queue > threshold {
            let delivered = self.delivery_rate(now, srtt.max(Duration::from_millis(250)));
            delivered.map_or(rate * 0.7, |delivered| (delivered * 0.75).min(rate * 0.85))
        } else if self.limited && queue <= threshold / 2 {
            rate * 1.25
        } else {
            return;
        };
        self.pacer.set_rate(next.clamp(self.config.min_rate, self.config.max_rate), now);
        self.last_adjust = Some(now);
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
    Output { batch: u64, bytes: Vec<u8> },
    /// Rows that left the viewport while the datagrams carry the screen.
    History(Vec<u8>),
    /// The path changed; the batches after this go the new way.
    Switched(Path),
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
                    if let Sink::Selected(stream) = &sink
                        && path == Path::Stream
                    {
                        // Out before the model takes it: the stream path waits on nothing.
                        let batch = sync.batches() + 1;
                        let _ = stream.send(StreamOut::Output { batch, bytes: bytes.clone() }).await;
                    }
                    let rows = sync.feed(&bytes);
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
        // Unacked: the resend waits 1.5 * srtt.
        assert_eq!(sync.next_wake(acked_at), Some(acked_at + Duration::from_millis(300)));
        assert!(sync.poll(acked_at + Duration::from_millis(299)).is_empty());
        assert!(!sync.poll(acked_at + Duration::from_millis(300)).is_empty());
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
        assert!(switch.srtt > Duration::from_millis(20));
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
    fn viewport_sync_selector_switches_on_loss() {
        let start = Instant::now();
        let mut sync = driver(start);
        sync.select_path(SelectorConfig::default());
        // A fast link losing 2% each way.
        let mut link = FakeLink::new(Duration::from_millis(1), Duration::ZERO, 0.02);
        drive_fake(&mut sync, &mut link, start, 30);
        assert_eq!(sync.switches().first().map(|s| s.to), Some(Path::Datagram));
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
