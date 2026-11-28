//! The phone's path report (PROTOCOL.md "Link stats"): which path its link to a Mac takes, how
//! long it took to come up, and its round trips and lost pings, sent as one small `link_stat`
//! text frame on the signaling socket. The service logs each one (with where the phone entered
//! Cloudflare and where its hub runs), so production can see path, RTT, loss and setup time.
//!
//! When: one stat once the link's first ping is answered (or [`FIRST_WAIT`] after it came up),
//! then one every [`PERIOD`] while it is up, one on a path change (at most one per
//! [`PATH_GAP`]; a change inside it is counted in `switches` and goes in the next stat), and one
//! when the link drops. Every stat is at most [`MAX_FRAME_BYTES`]: fixed fields, bounded
//! numbers, and only the dial marks of [`MARKS`]. It names no device, session or address.
//!
//! A Worker older than the frame refuses it once; the socket then sends no more
//! ([`crate::SignalingClient::sends_link_stats`]), and the refusal never fails a dial.

use std::collections::BTreeMap;
use std::time::{Duration, Instant};

use serde::Serialize;
use tokio::sync::watch;
use tokio::task::JoinHandle;

use crate::dial::{LinkPath, TransportKind};
use crate::hybrid::SignalingSource;
use crate::key_echo;
use crate::link::{Link, PingStats};
use crate::outbox_wait::{OutboxWait, OutboxWaitSummary};
use crate::timing::Timeline;

/// The `v` of the frame this side sends.
pub const VERSION: u8 = 1;
/// The most a stat serializes to.
pub const MAX_FRAME_BYTES: usize = 768;
/// How often a stat goes out while the link is up.
pub const PERIOD: Duration = Duration::from_secs(60);
/// The least time between a stat and a path change's stat.
pub const PATH_GAP: Duration = Duration::from_secs(10);
/// How long the first stat waits for the link's first pong.
pub const FIRST_WAIT: Duration = Duration::from_secs(5);
/// Every millisecond value is clamped to this (ten minutes).
pub const MAX_MS: u32 = 600_000;
/// The dial marks a first stat carries (each once, when the dial recorded it).
pub const MARKS: &[&str] = &[
    "signaling_open",
    "signaling_reused",
    "dial_start",
    "offer_sent",
    "answer_received",
    "wg_init_sent",
    "wg_resp_received",
    "endpoints_gathered",
    "ice_connected",
    "dtls_connected",
    "channel_open",
    "alive",
    "link_ready",
    "first_pong",
];

/// Why a stat went out.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Reason {
    First,
    Periodic,
    Path,
    End,
}

/// The round trips of one stat's window.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct RttSummary {
    pub n: u32,
    pub p50: u32,
    pub p95: u32,
    pub max: u32,
}

impl RttSummary {
    /// `None` for no samples. Nearest-rank percentiles, every value clamped to [`MAX_MS`].
    pub fn of(samples: &[u32]) -> Option<Self> {
        if samples.is_empty() {
            return None;
        }
        let mut sorted: Vec<u32> = samples.iter().map(|ms| (*ms).min(MAX_MS)).collect();
        sorted.sort_unstable();
        let rank =
            |p: usize| sorted[(sorted.len() * p).div_ceil(100).saturating_sub(1).min(sorted.len() - 1)];
        Some(Self {
            n: u32::try_from(sorted.len()).unwrap_or(u32::MAX),
            p50: rank(50),
            p95: rank(95),
            max: sorted[sorted.len() - 1],
        })
    }
}

/// Counters from the hop/1 leg, included only while the selected path is hop.
/// Values are bounded before they enter a link-stat frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HopStats {
    pub srtt_ms: u64,
    pub loss_permille: u16,
    pub resent: u64,
    pub repaired: u64,
}

impl HopStats {
    fn bounded(self) -> Self {
        Self {
            srtt_ms: self.srtt_ms.min(u64::from(MAX_MS)),
            loss_permille: self.loss_permille.min(1_000),
            resent: self.resent.min(100_000),
            repaired: self.repaired.min(100_000),
        }
    }
}

/// One `link_stat` frame.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LinkStat {
    #[serde(rename = "type")]
    pub kind: &'static str,
    pub v: u8,
    pub transport: &'static str,
    pub path: &'static str,
    pub reason: Reason,
    /// First stat only: ms from the app's `connect` to the first pong (else to `link_ready`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub setup_ms: Option<u32>,
    /// First stat only: the dial's marks of [`MARKS`], ms since `connect`.
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub marks: BTreeMap<&'static str, u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rtt: Option<RttSummary>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hop: Option<HopStats>,
    /// Pings sent since the last stat.
    pub pings: u32,
    /// Pings lost since the last stat (sent, never answered, no longer waiting).
    pub lost: u32,
    /// Path changes since the link came up.
    pub switches: u32,
    /// `cellular` or `other` (the app's last network report).
    pub net: &'static str,
    /// Seconds the link has been up.
    pub up_s: u32,
    /// `end` only: why the link closed (`app`, `keepalive`, `transport` or `other`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end: Option<&'static str>,
    /// The link library's version.
    pub lib: &'static str,
    /// `proxy` or `inspected` when this network's link connections leave
    /// through a proxy (one that inspects TLS); absent when direct.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub egress: Option<&'static str>,
    /// The Mac offered a NAT-mapped endpoint (PROTOCOL.md "Mapped
    /// endpoints"): which protocol mapped it and whether the route uses it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub portmap: Option<PortmapStat>,
    /// Keys typed since the last stat: tap to first echo ([`crate::key_echo`]).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub echo: Option<key_echo::Summary>,
    /// Keys typed since the last stat: tap to the Mac's answer to their `send`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ack: Option<key_echo::Summary>,
    /// Keys slower than [`key_echo::SPIKE_MS`] since the last stat (all, kept or not).
    #[serde(skip_serializing_if = "is_zero")]
    pub spike_count: u32,
    /// The slowest of them: `[seconds since the link came up, ack ms (-1: none yet), echo ms]`.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub spikes: Vec<[i64; 3]>,
    /// Frames written since the last stat: µs from entering the link's outbox to the flush that
    /// handed them to the transport ([`crate::outbox_wait`]). Slow with `rtt` fast is this side.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub outbox_us: Option<OutboxWaitSummary>,
}

fn is_zero(n: &u32) -> bool {
    *n == 0
}

/// `link_stat` `portmap`: `{"by":"pcp","used":true}`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct PortmapStat {
    /// `pcp`, `nat-pmp`, `upnp` or `unknown`.
    pub by: &'static str,
    /// The link's direct route goes to the mapped endpoint.
    pub used: bool,
}

impl From<crate::dial::portmap::PortmapUse> for PortmapStat {
    fn from(use_: crate::dial::portmap::PortmapUse) -> Self {
        Self { by: use_.protocol, used: use_.used }
    }
}

impl LinkStat {
    pub fn to_text(&self) -> String {
        serde_json::to_string(self).expect("link_stat serializes")
    }

    /// Carry the keys typed since the last stat, their spikes timed from `up_at`.
    #[must_use]
    pub fn with_keys(mut self, keys: &key_echo::Window, up_at: Instant) -> Self {
        self.echo = key_echo::Summary::of(&keys.echo);
        self.ack = key_echo::Summary::of(&keys.ack);
        self.spike_count = keys.spike_count.min(100_000);
        self.spikes = keys
            .spikes
            .iter()
            .map(|s| {
                let at = i64::try_from(s.at.saturating_duration_since(up_at).as_secs()).unwrap_or(i64::MAX);
                [at.min(30 * 86_400), s.ack_ms.map_or(-1, i64::from), i64::from(s.echo_ms)]
            })
            .collect();
        self
    }

    /// Carry the outbox waits since the last stat.
    #[must_use]
    pub fn with_outbox(mut self, wait: &OutboxWait) -> Self {
        self.outbox_us = wait.summary();
        self
    }
}

/// Why a link closed, as one of a few fixed words (its reason is free text).
pub fn end_kind(reason: &str) -> &'static str {
    let reason = reason.to_ascii_lowercase();
    if reason.contains("by the app") || reason.contains("handle dropped") {
        "app"
    } else if reason.contains("keepalive") {
        "keepalive"
    } else if reason.contains("transport") || reason.contains("tunnel") || reason.contains("channel") {
        "transport"
    } else {
        "other"
    }
}

fn ms(duration: Duration) -> u32 {
    u32::try_from(duration.as_millis()).unwrap_or(u32::MAX).min(MAX_MS)
}

/// What the report remembers between stats, and when the next one is due. Pure: the clock and
/// the link's numbers are passed in, so tests drive it.
#[derive(Debug)]
pub struct Reporter {
    transport: TransportKind,
    path: LinkPath,
    up_at: Instant,
    switches: u32,
    last_sent: Option<Instant>,
    /// Counts at the last stat.
    sent_before: u64,
    lost_reported: u64,
    ended: bool,
}

impl Reporter {
    pub fn new(transport: TransportKind, path: LinkPath, up_at: Instant) -> Self {
        Self {
            transport,
            path,
            up_at,
            switches: 0,
            last_sent: None,
            sent_before: 0,
            lost_reported: 0,
            ended: false,
        }
    }

    /// When the next periodic stat is due (the first one counts as a stat).
    pub fn next_periodic(&self) -> Instant {
        self.last_sent.unwrap_or(self.up_at) + PERIOD
    }

    /// The path changed; whether a stat is due for it now.
    pub fn path_changed(&mut self, path: LinkPath, now: Instant) -> bool {
        if path == self.path {
            return false;
        }
        self.path = path;
        self.switches = self.switches.saturating_add(1);
        !self.ended && self.last_sent.is_some_and(|at| now.saturating_duration_since(at) >= PATH_GAP)
    }

    /// Build the stat for `reason` from the link's ping numbers and the dial's timeline, and
    /// count it as sent at `now`. `None` after the end stat (at most one).
    pub fn build(
        &mut self,
        reason: Reason,
        now: Instant,
        pings: &PingStats,
        timeline: Option<&Timeline>,
        end: Option<&str>,
        cellular: bool,
    ) -> Option<LinkStat> {
        if self.ended {
            return None;
        }
        self.ended = reason == Reason::End;
        let first = self.last_sent.is_none();
        let (setup_ms, marks) = match (first, timeline) {
            (true, Some(timeline)) => {
                let marks: BTreeMap<&'static str, u32> =
                    MARKS.iter().filter_map(|name| timeline.get(name).map(|at| (*name, ms(at)))).collect();
                let setup = marks.get("first_pong").or_else(|| marks.get("link_ready")).copied();
                (setup, marks)
            }
            _ => (None, BTreeMap::new()),
        };
        // Lost: sent, not answered, and no longer waiting. A pong that comes after its ping was
        // counted lost cannot take the count back; that overcount is bounded by late pongs.
        let lost_now = pings.sent.saturating_sub(pings.answered).saturating_sub(pings.waiting);
        let lost = lost_now.saturating_sub(self.lost_reported);
        self.lost_reported = self.lost_reported.max(lost_now);
        let sent = pings.sent.saturating_sub(self.sent_before);
        self.sent_before = pings.sent;
        self.last_sent = Some(now);
        let clamp = |n: u64| u32::try_from(n).unwrap_or(u32::MAX).min(100_000);
        Some(LinkStat {
            kind: "link_stat",
            v: VERSION,
            transport: self.transport.as_str(),
            path: self.path.as_str(),
            reason,
            setup_ms,
            marks,
            rtt: RttSummary::of(&pings.samples),
            hop: None,
            pings: clamp(sent),
            lost: clamp(lost),
            switches: self.switches.min(10_000),
            net: if cellular { "cellular" } else { "other" },
            up_s: u32::try_from(now.saturating_duration_since(self.up_at).as_secs())
                .unwrap_or(u32::MAX)
                .min(30 * 86_400),
            end: end.map(end_kind),
            lib: env!("CARGO_PKG_VERSION"),
            egress: crate::egress::seen().map(crate::egress::PathKind::as_str),
            portmap: None,
            echo: None,
            ack: None,
            spike_count: 0,
            spikes: Vec::new(),
            outbox_us: None,
        })
    }
}

/// Send `stat` on the current signaling socket. `false` when that socket's Worker refused stats
/// (no more go out), or there is none.
async fn send(signaling: &SignalingSource, session_id: &str, mut stat: LinkStat) -> bool {
    if stat.path == LinkPath::Hop.as_str() {
        stat.hop = crate::dial::wireguard::hop_stats(session_id, true).map(HopStats::bounded);
    }
    let Some(client) = signaling().await else {
        return true;
    };
    if !client.sends_link_stats() {
        return false;
    }
    let text = stat.to_text();
    debug_assert!(text.len() <= MAX_FRAME_BYTES, "{text}");
    let _ = client.send_link_stat(text);
    true
}

/// Report `link`'s path until it closes (the phone's links: the FFI starts one per `connect`).
pub fn spawn(
    link: Link,
    transport: TransportKind,
    mut path: watch::Receiver<LinkPath>,
    timeline: Timeline,
    signaling: SignalingSource,
    session_id: String,
) -> JoinHandle<()> {
    // The Mac's mapped endpoint and whether the route uses it, read at each stat.
    let hop_session = session_id.clone();
    let portmap = move || crate::dial::wireguard::portmap_use(&session_id).map(PortmapStat::from);
    tokio::spawn(async move {
        let first_path = *path.borrow_and_update();
        crate::key_paint::set_route(first_path.as_str());
        let mut reporter = Reporter::new(transport, first_path, Instant::now());
        let mut closed = link.closed_state();
        let cellular = crate::dial::wireguard::cellular_path;
        // The first stat waits for the first pong (its setup time), at most FIRST_WAIT.
        let mut rtt = link.rtt();
        let first_closed = tokio::select! {
            _ = tokio::time::timeout(FIRST_WAIT, rtt.wait_for(Option::is_some)) => false,
            _ = closed.wait_for(Option::is_some) => true,
        };
        if !first_closed {
            let stat = reporter
                .build(
                    Reason::First,
                    Instant::now(),
                    &link.take_ping_stats(),
                    Some(&timeline),
                    None,
                    cellular(),
                )
                .map(|stat| {
                    stat.with_keys(&key_echo::take(), reporter.up_at).with_outbox(&link.take_outbox_wait())
                });
            if let Some(mut stat) = stat {
                stat.portmap = portmap();
                if !send(&signaling, &hop_session, stat).await {
                    return;
                }
            }
        }
        // The dialer's path watch can end before the link (then the link's close ends the report).
        let mut path_open = true;
        loop {
            let periodic = tokio::time::Instant::from_std(reporter.next_periodic());
            let reason = tokio::select! {
                () = tokio::time::sleep_until(periodic) => Reason::Periodic,
                changed = path.changed(), if path_open => {
                    if changed.is_err() {
                        path_open = false;
                        continue;
                    } else if reporter.path_changed(
                        crate::key_paint::route_changed(*path.borrow_and_update()),
                        Instant::now(),
                    ) {
                        Reason::Path
                    } else {
                        continue;
                    }
                }
                _ = closed.wait_for(Option::is_some) => Reason::End,
            };
            let end =
                (reason == Reason::End).then(|| link.closed_state().borrow().clone().unwrap_or_default());
            let first = reporter.last_sent.is_none();
            let stat = reporter.build(
                reason,
                Instant::now(),
                &link.take_ping_stats(),
                first.then_some(&timeline),
                end.as_deref(),
                cellular(),
            );
            let Some(stat) = stat else { return };
            let mut stat =
                stat.with_keys(&key_echo::take(), reporter.up_at).with_outbox(&link.take_outbox_wait());
            stat.portmap = portmap();
            if !send(&signaling, &hop_session, stat).await || reason == Reason::End {
                return;
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pings(sent: u64, answered: u64, waiting: u64, samples: &[u32]) -> PingStats {
        PingStats { sent, answered, waiting, samples: samples.to_vec() }
    }

    #[test]
    fn keys_ride_the_stat_with_their_spikes_and_stay_under_the_frame_cap() {
        let up = Instant::now();
        let mut reporter = Reporter::new(TransportKind::WireGuard, LinkPath::Turn, up);
        let stat = reporter
            .build(Reason::Periodic, up + PERIOD, &pings(6, 6, 0, &[40; 6]), None, None, true)
            .unwrap();
        let none = stat.clone().with_keys(&key_echo::Window::default(), up);
        let json: serde_json::Value = serde_json::from_str(&none.to_text()).unwrap();
        assert!(
            json.get("echo").is_none() && json.get("spikes").is_none() && json.get("spikeCount").is_none()
        );
        let mut keys = key_echo::Window::default();
        for i in 0..2000u32 {
            keys.ack(30 + i % 50);
            keys.echo(
                if i % 97 == 0 { 590_000 + i } else { 45 },
                (i % 2 == 0).then_some(599_999),
                up + Duration::from_secs(u64::from(i)),
            );
        }
        let text = stat.with_keys(&keys, up).to_text();
        assert!(text.len() <= MAX_FRAME_BYTES, "{} bytes: {text}", text.len());
        let json: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(json["echo"]["p50"], 45);
        assert_eq!(json["spikeCount"], 21);
        assert_eq!(json["spikes"].as_array().unwrap().len(), key_echo::MAX_SPIKES);
        assert_eq!(json["spikes"][0][0], 1940, "seconds since up of the slowest");
    }

    #[test]
    fn rtt_summary_is_nearest_rank_and_clamped() {
        assert_eq!(RttSummary::of(&[]), None);
        assert_eq!(RttSummary::of(&[40]), Some(RttSummary { n: 1, p50: 40, p95: 40, max: 40 }));
        let samples: Vec<u32> = (1..=100).collect();
        assert_eq!(RttSummary::of(&samples), Some(RttSummary { n: 100, p50: 50, p95: 95, max: 100 }));
        assert_eq!(RttSummary::of(&[30, 10, 20]).unwrap().p50, 20);
        assert_eq!(RttSummary::of(&[u32::MAX]).unwrap().max, MAX_MS);
    }

    #[test]
    fn the_first_stat_carries_setup_and_marks_and_the_shape_matches_the_contract() {
        let up = Instant::now();
        let timeline = Timeline::starting_at(up - Duration::from_millis(500));
        timeline.mark("signaling_open");
        timeline.mark("not_a_listed_mark");
        timeline.mark("first_pong");
        let mut reporter = Reporter::new(TransportKind::WireGuard, LinkPath::Direct, up);
        let stat = reporter
            .build(
                Reason::First,
                up + Duration::from_secs(1),
                &pings(1, 1, 0, &[42]),
                Some(&timeline),
                None,
                true,
            )
            .unwrap();
        let json: serde_json::Value = serde_json::from_str(&stat.to_text()).unwrap();
        assert_eq!(json["type"], "link_stat");
        assert_eq!(json["v"], 1);
        assert_eq!(json["transport"], "wireguard");
        assert_eq!(json["path"], "direct");
        assert_eq!(json["reason"], "first");
        assert_eq!(json["rtt"], serde_json::json!({"n":1,"p50":42,"p95":42,"max":42}));
        assert_eq!(json["pings"], 1);
        assert_eq!(json["lost"], 0);
        assert_eq!(json["net"], "cellular");
        assert_eq!(json["upS"], 1);
        assert!(json["setupMs"].as_u64().unwrap() >= 500);
        let marks = json["marks"].as_object().unwrap();
        assert!(marks.contains_key("signaling_open") && marks.contains_key("first_pong"));
        assert!(!marks.contains_key("not_a_listed_mark"));
        assert!(json.get("end").is_none());
        // Later stats carry neither setup nor marks.
        let next = reporter
            .build(Reason::Periodic, up + PERIOD, &pings(5, 4, 1, &[]), Some(&timeline), None, false)
            .unwrap();
        assert_eq!((next.setup_ms, next.marks.len(), next.rtt), (None, 0, None));
        assert_eq!((next.pings, next.lost), (4, 0));
    }

    #[test]
    fn loss_counts_pings_neither_answered_nor_waiting_once() {
        let up = Instant::now();
        let mut reporter = Reporter::new(TransportKind::WebRtc, LinkPath::Turn, up);
        let a = reporter.build(Reason::First, up, &pings(4, 2, 1, &[]), None, None, false).unwrap();
        assert_eq!((a.pings, a.lost), (4, 1));
        // The waiting one was lost too; nothing counted twice.
        let b =
            reporter.build(Reason::Periodic, up + PERIOD, &pings(6, 4, 0, &[]), None, None, false).unwrap();
        assert_eq!((b.pings, b.lost), (2, 1));
        // A late pong (answered grows past what was counted) never takes loss below zero.
        let c = reporter
            .build(Reason::Periodic, up + PERIOD * 2, &pings(6, 6, 0, &[]), None, None, false)
            .unwrap();
        assert_eq!((c.pings, c.lost), (0, 0));
    }

    #[test]
    fn every_stat_is_bounded_whatever_its_numbers() {
        let up = Instant::now();
        let timeline = Timeline::starting_at(up);
        for name in MARKS {
            timeline.mark(name);
        }
        let mut reporter = Reporter::new(TransportKind::WireGuard, LinkPath::TurnTls, up);
        for _ in 0..50 {
            reporter.path_changed(LinkPath::Direct, up);
            reporter.path_changed(LinkPath::TurnTls, up);
        }
        let huge = pings(u64::MAX, 0, 0, &vec![u32::MAX; PingStats::MAX_SAMPLES]);
        reporter.path_changed(LinkPath::Hop, up);
        let mut stat = reporter
            .build(
                Reason::End,
                up + Duration::from_secs(10 * 365 * 86_400),
                &huge,
                Some(&timeline),
                Some("keepalive timed out"),
                true,
            )
            .unwrap();
        stat.hop = Some(
            HopStats { srtt_ms: u64::MAX, loss_permille: u16::MAX, resent: u64::MAX, repaired: u64::MAX }
                .bounded(),
        );
        stat.portmap = Some(PortmapStat { by: "nat-pmp", used: false });
        let mut wait = OutboxWait::default();
        wait.record(u64::MAX);
        stat = stat.with_outbox(&wait);
        assert_eq!(stat.outbox_us.unwrap().max, crate::outbox_wait::MAX_US);
        let m = crate::outbox_wait::MAX_US;
        stat.outbox_us = Some(OutboxWaitSummary { n: 100_000_000, p50: m, p95: m, p99: m, max: m });
        let text = stat.to_text();
        assert!(text.len() <= MAX_FRAME_BYTES, "{} bytes: {text}", text.len());
        assert!(text.contains(r#""portmap":{"by":"nat-pmp","used":false}"#), "{text}");
        assert_eq!(stat.marks.len(), MARKS.len());
        assert_eq!(stat.end, Some("keepalive"));
        assert!(stat.lost <= stat.pings);
        // Nothing after the end stat.
        assert!(reporter.build(Reason::Periodic, up, &huge, None, None, false).is_none());
    }

    #[test]
    fn cadence_one_per_period_and_path_changes_at_most_one_per_gap() {
        let up = Instant::now();
        let mut reporter = Reporter::new(TransportKind::WireGuard, LinkPath::Direct, up);
        assert_eq!(reporter.next_periodic(), up + PERIOD);
        // Before the first stat a change is only counted.
        assert!(!reporter.path_changed(LinkPath::Turn, up + Duration::from_secs(1)));
        let first = up + Duration::from_secs(2);
        reporter.build(Reason::First, first, &PingStats::default(), None, None, false).unwrap();
        assert_eq!(reporter.next_periodic(), first + PERIOD);
        // The same path is no change; a change inside the gap is counted, not sent.
        assert!(!reporter.path_changed(LinkPath::Turn, first + Duration::from_secs(20)));
        assert!(!reporter.path_changed(LinkPath::Direct, first + PATH_GAP - Duration::from_millis(1)));
        assert!(reporter.path_changed(LinkPath::Turn, first + PATH_GAP));
        let stat =
            reporter.build(Reason::Path, first + PATH_GAP, &PingStats::default(), None, None, false).unwrap();
        assert_eq!((stat.path, stat.switches), ("turn", 3));
        assert_eq!(reporter.next_periodic(), first + PATH_GAP + PERIOD);
    }

    #[test]
    fn end_reasons_are_fixed_words() {
        assert_eq!(end_kind("closed by the app"), "app");
        assert_eq!(end_kind("keepalive timed out"), "keepalive");
        assert_eq!(end_kind("transport closed"), "transport");
        assert_eq!(end_kind("something 10.0.0.1 said"), "other");
    }
}
