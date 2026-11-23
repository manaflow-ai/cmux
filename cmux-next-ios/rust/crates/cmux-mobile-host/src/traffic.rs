//! Bytes in and out of this host, per service kind: what `cmux device traffic`
//! prints (the link socket's `{"op":"traffic"}`, `link_socket.rs`).
//!
//! Each byte is counted once, where it crosses a link: a channel's payload in
//! the link's own send and receive (`cmux_mobile_link::link::ByteMeter`, set on
//! every channel `services::serve` serves and every channel `link_socket`
//! splices to another machine), and a video frame where it goes onto the
//! media lane (`browser::splice`). IN is what the peer sent this Mac, OUT what
//! this Mac sent it. Counted is the payload: framing, WireGuard, DTLS, RTP,
//! FEC and retransmits are not, so the OS's socket numbers run higher.
//!
//! Per byte this costs one relaxed atomic add. Rates come from a once a second
//! sample of the totals ([`run_sampler`]), never from the send path.

use std::collections::VecDeque;
use std::sync::{Arc, LazyLock, Mutex, PoisonError};
use std::time::{Duration, Instant};

use cmux_mobile_link::link::ByteMeter;
use serde_json::{Value, json};

/// What a channel or a lane carries.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// `daemon`: the cmux-tui session socket (terminal streams, workspace state).
    Terminal,
    /// `chief`, `acpmux`: agent chats.
    Chat,
    /// `cloud-acpmux`, `cloud-directory`: chats on the owner's Cloud machines.
    CloudChat,
    /// `browser`: a streamed Mac browser tab's channel (video too, without a media lane).
    Browser,
    /// A browser tab's video on the link's media lane.
    BrowserVideo,
    /// `surface`: a simulator surface's channel.
    Simulator,
    /// A simulator surface's video on the media lane.
    SimulatorVideo,
    /// `surface` for a Cloud desktop tab: a machine's screen.
    Desktop,
    /// A Cloud desktop's video on the media lane.
    DesktopVideo,
    /// `file`, `file-preview`, `upload`.
    File,
    /// `localhost`: a phone's browser tab reaching a port on this Mac.
    Localhost,
    /// `appearance`, `appearance-wallpaper`.
    Appearance,
    /// `tabs`: the tab overview's thumbnails and favicons.
    Tabs,
    /// This Mac's channels to another of the person's machines (`cmux machine`, `link_socket.rs`).
    Remote,
    /// `auth`, `echo`, `version`, `machine`, `needs-you`.
    Control,
    /// Anything else (refused names included).
    Other,
}

impl Kind {
    pub const ALL: [Kind; 16] = [
        Kind::Terminal,
        Kind::Chat,
        Kind::CloudChat,
        Kind::Browser,
        Kind::BrowserVideo,
        Kind::Simulator,
        Kind::SimulatorVideo,
        Kind::Desktop,
        Kind::DesktopVideo,
        Kind::File,
        Kind::Localhost,
        Kind::Appearance,
        Kind::Tabs,
        Kind::Remote,
        Kind::Control,
        Kind::Other,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Kind::Terminal => "terminal",
            Kind::Chat => "chat",
            Kind::CloudChat => "cloud_chat",
            Kind::Browser => "browser",
            Kind::BrowserVideo => "browser_video",
            Kind::Simulator => "simulator",
            Kind::SimulatorVideo => "simulator_video",
            Kind::Desktop => "desktop",
            Kind::DesktopVideo => "desktop_video",
            Kind::File => "file",
            Kind::Localhost => "localhost",
            Kind::Appearance => "appearance",
            Kind::Tabs => "tabs",
            Kind::Remote => "remote",
            Kind::Control => "control",
            Kind::Other => "other",
        }
    }

    /// Its place in [`Kind::ALL`] (declaration order).
    fn index(self) -> usize {
        self as usize
    }

    /// The kind of an incoming channel of `service` opened with `args`.
    pub fn of_service(service: &str, args: &Value) -> Self {
        match service {
            "daemon" => Kind::Terminal,
            "chief" | "acpmux" => Kind::Chat,
            "cloud-acpmux" | "cloud-directory" => Kind::CloudChat,
            "browser" => Kind::Browser,
            "surface" => {
                let tab = args.get("tab").and_then(Value::as_str).unwrap_or_default();
                if crate::surface::cloud_desktop_of(tab).is_some() { Kind::Desktop } else { Kind::Simulator }
            }
            "file" | "file-preview" | "upload" => Kind::File,
            "localhost" => Kind::Localhost,
            "appearance" | "appearance-wallpaper" => Kind::Appearance,
            "tabs" => Kind::Tabs,
            "auth" | "echo" | "version" | "machine" | "needs-you" | "phone-frames" => Kind::Control,
            _ => Kind::Other,
        }
    }

    /// The media-lane kind of a channel kind's video.
    pub fn video(self) -> Self {
        match self {
            Kind::Simulator => Kind::SimulatorVideo,
            Kind::Desktop => Kind::DesktopVideo,
            _ => Kind::BrowserVideo,
        }
    }
}

/// How long rate samples are kept: the longest window and a second.
const KEEP: Duration = Duration::from_secs(61);
/// The rate windows `report` gives.
const WINDOWS: [(u64, &str); 2] = [(10, "10s"), (60, "60s")];

type Totals = [(u64, u64); Kind::ALL.len()];

/// The host's per-kind byte totals and their recent samples.
pub struct Traffic {
    meters: [Arc<ByteMeter>; Kind::ALL.len()],
    started: Instant,
    samples: Mutex<VecDeque<(Instant, Totals)>>,
}

impl Traffic {
    pub fn new(started: Instant) -> Self {
        let samples = VecDeque::from([(started, [(0, 0); Kind::ALL.len()])]);
        Self { meters: Default::default(), started, samples: Mutex::new(samples) }
    }

    /// The meter `kind`'s channels count into.
    pub fn meter(&self, kind: Kind) -> Arc<ByteMeter> {
        self.meters.get(kind.index()).map(Arc::clone).unwrap_or_default()
    }

    fn totals(&self) -> Totals {
        let mut totals = [(0, 0); Kind::ALL.len()];
        for (total, meter) in totals.iter_mut().zip(&self.meters) {
            *total = (meter.received(), meter.sent());
        }
        totals
    }

    /// Records the totals at `now` for the rates; drops samples past the longest window.
    pub fn sample(&self, now: Instant) {
        let totals = self.totals();
        let mut samples = self.samples.lock().unwrap_or_else(PoisonError::into_inner);
        samples.push_back((now, totals));
        while samples.len() > 1
            && samples.front().is_some_and(|(at, _)| now.saturating_duration_since(*at) > KEEP)
        {
            samples.pop_front();
        }
    }

    /// Totals since start and bytes per second over the last 10 s and 60 s
    /// (from the oldest sample inside each window, so a host up for 4 s
    /// rates its 4 s), per kind and summed.
    pub fn report(&self, now: Instant) -> Value {
        let totals = self.totals();
        let bases: Vec<(f64, Totals)> = {
            let samples = self.samples.lock().unwrap_or_else(PoisonError::into_inner);
            WINDOWS
                .iter()
                .map(|(seconds, _)| {
                    let from = now.checked_sub(Duration::from_secs(*seconds)).unwrap_or(self.started);
                    let (at, base) = samples
                        .iter()
                        .find(|(at, _)| *at >= from)
                        .or(samples.back())
                        .copied()
                        .unwrap_or((self.started, [(0, 0); Kind::ALL.len()]));
                    (now.saturating_duration_since(at).as_secs_f64(), base)
                })
                .collect()
        };
        let row = |name: &str, now: (u64, u64), bases: &[(f64, (u64, u64))]| {
            let mut row = serde_json::Map::new();
            row.insert("service".into(), json!(name));
            row.insert("in_bytes".into(), json!(now.0));
            row.insert("out_bytes".into(), json!(now.1));
            for ((_, label), (span, base)) in WINDOWS.iter().zip(bases) {
                let rate = |a: u64, b: u64| {
                    if *span > 0.0 { (a.saturating_sub(b) as f64 / span).round() as u64 } else { 0 }
                };
                row.insert(format!("in_per_s_{label}"), json!(rate(now.0, base.0)));
                row.insert(format!("out_per_s_{label}"), json!(rate(now.1, base.1)));
            }
            Value::Object(row)
        };
        let mut services = Vec::new();
        let mut sum = (0u64, 0u64);
        let mut sum_bases: Vec<(f64, (u64, u64))> = bases.iter().map(|(span, _)| (*span, (0, 0))).collect();
        for (index, kind) in Kind::ALL.iter().enumerate() {
            let now_kind = totals.get(index).copied().unwrap_or_default();
            let kind_bases: Vec<(f64, (u64, u64))> = bases
                .iter()
                .map(|(span, base)| (*span, base.get(index).copied().unwrap_or_default()))
                .collect();
            sum = (sum.0 + now_kind.0, sum.1 + now_kind.1);
            for (total, (_, base)) in sum_bases.iter_mut().zip(&kind_bases) {
                total.1 = (total.1.0 + base.0, total.1.1 + base.1);
            }
            services.push(row(kind.name(), now_kind, &kind_bases));
        }
        json!({
            "uptime_s": now.saturating_duration_since(self.started).as_secs(),
            "total": row("total", sum, &sum_bases),
            "services": services,
        })
    }
}

/// This process's traffic.
pub static TRAFFIC: LazyLock<Traffic> = LazyLock::new(|| Traffic::new(Instant::now()));

/// Samples [`TRAFFIC`] once a second, and logs the busy kinds once a minute.
pub async fn run_sampler() {
    let mut tick = tokio::time::interval(Duration::from_secs(1));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut seconds = 0u64;
    loop {
        tick.tick().await;
        let now = Instant::now();
        TRAFFIC.sample(now);
        seconds += 1;
        if seconds.is_multiple_of(60) {
            let report = TRAFFIC.report(now);
            let number = |row: &Value, key: &str| row.get(key).and_then(Value::as_u64).unwrap_or(0);
            let busy: Vec<String> = report
                .get("services")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter(|row| number(row, "in_per_s_60s") + number(row, "out_per_s_60s") > 0)
                .map(|row| {
                    format!(
                        "{} in {}B/s out {}B/s",
                        row.get("service").and_then(Value::as_str).unwrap_or_default(),
                        number(row, "in_per_s_60s"),
                        number(row, "out_per_s_60s")
                    )
                })
                .collect();
            if !busy.is_empty() {
                tracing::info!(busy = busy.join(", "), "traffic over the last 60 s");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::Bytes;
    use cmux_mobile_link::{ChannelEvent, Link, LinkConfig, Role};

    fn row<'a>(report: &'a Value, name: &str) -> &'a Value {
        report["services"].as_array().unwrap().iter().find(|r| r["service"] == name).unwrap()
    }

    /// Known bytes through two services' channels on a real link: each kind
    /// counts its own, both ways, and the 10 s rate is those bytes over 10 s.
    #[tokio::test]
    async fn two_services_count_their_own_bytes_and_rate() {
        let (a, b) = tokio::io::duplex(1 << 20);
        let phone = Link::new(a, Role::Phone, LinkConfig::default(), None);
        let mac = Link::new(b, Role::Mac, LinkConfig::default(), None);
        let start = Instant::now();
        let traffic = Traffic::new(start);
        let mut channels = Vec::new();
        for (service, up, down) in [("daemon", 3_000usize, 50_000usize), ("browser", 700, 200_000)] {
            let mut phone_side = phone.open(service, json!({})).await.unwrap();
            let incoming = mac.accept().await.unwrap();
            let kind = Kind::of_service(&incoming.service, &incoming.args);
            let (mut sender, mut receiver) = incoming.channel.split();
            sender.count_into(traffic.meter(kind));
            receiver.count_into(traffic.meter(kind));
            phone_side.send(Bytes::from(vec![1u8; up])).await.unwrap();
            let mut got = 0;
            while got < up {
                match receiver.recv().await {
                    Some(ChannelEvent::Data(data)) => got += data.len(),
                    other => panic!("{other:?}"),
                }
            }
            sender.send(Bytes::from(vec![2u8; down])).await.unwrap();
            let mut got = 0;
            while got < down {
                match phone_side.recv().await {
                    Some(ChannelEvent::Data(data)) => got += data.len(),
                    other => panic!("{other:?}"),
                }
            }
            channels.push((phone_side, sender, receiver));
        }
        let report = traffic.report(start + Duration::from_secs(10));
        eprintln!("traffic report: {report}");
        let terminal = row(&report, "terminal");
        assert_eq!(
            (terminal["in_bytes"].as_u64(), terminal["out_bytes"].as_u64()),
            (Some(3_000), Some(50_000))
        );
        let browser = row(&report, "browser");
        assert_eq!((browser["in_bytes"].as_u64(), browser["out_bytes"].as_u64()), (Some(700), Some(200_000)));
        assert_eq!(row(&report, "chat")["in_bytes"], 0);
        assert_eq!(terminal["out_per_s_10s"], 5_000);
        assert_eq!(browser["out_per_s_10s"], 20_000);
        assert_eq!(report["total"]["in_bytes"], 3_700);
        assert_eq!(report["total"]["out_per_s_10s"], 25_000);
        // A minute later with no new bytes, the 10 s rate is zero; the totals stay.
        traffic.sample(start + Duration::from_secs(60));
        let later = traffic.report(start + Duration::from_secs(65));
        assert_eq!(row(&later, "browser")["out_per_s_10s"], 0);
        assert_eq!(row(&later, "browser")["out_bytes"], 200_000);
    }

    #[test]
    fn surface_tabs_split_simulator_from_desktop() {
        assert_eq!(Kind::of_service("surface", &json!({"tab": "s12"})), Kind::Simulator);
        assert_eq!(Kind::of_service("surface", &json!({"tab": "c~m1~t1"})), Kind::Desktop);
        assert_eq!(Kind::of_service("surface", &json!({"tab": "c~m1~t1"})).video(), Kind::DesktopVideo);
        for (index, kind) in Kind::ALL.iter().enumerate() {
            assert_eq!(kind.index(), index);
        }
        assert_eq!(Kind::of_service("daemon", &json!({})), Kind::Terminal);
        assert_eq!(Kind::Simulator.video(), Kind::SimulatorVideo);
        assert_eq!(Kind::Browser.video(), Kind::BrowserVideo);
    }
}
