//! What an idle link costs on the wire, sender by sender: every datagram
//! each side sends in an idle minute on a direct link, attributed to what
//! made it (the link's keepalive ping, the foreground probe, the app's
//! heartbeat probe, TCP keepalives and ACKs, WireGuard keepalives, `reach`
//! markers), with its bytes on the wire. The budget closes: what the
//! receiving tunnel attributed equals what the sending socket sent.
//!
//! Its own test binary: the receive tap (`cmux_wg::testing::set_receive_tap`)
//! is process-wide, and the scenarios run one after another.
//!
//! The table for a PR body:
//! `cargo test -p cmux-mobile-link --test idle_budget -- --nocapture`.

use std::collections::BTreeMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use cmux_mobile_link::dial::{self, SessionEvents, wireguard};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_mobile_link::{DialOptions, Link, LinkConfig, SignalingClient, TransportKind};
use cmux_wg::testing::Received;

/// The overlay addresses `dial::wireguard` gives each side.
const PHONE_OVERLAY: IpAddr = IpAddr::V4(Ipv4Addr::new(10, 77, 0, 2));
const MAC_OVERLAY: IpAddr = IpAddr::V4(Ipv4Addr::new(10, 77, 0, 1));
/// The app's foreground heartbeat (`LinkController.heartbeat`,
/// `probeTimeout`): a link quiet this long is probed.
const HEARTBEAT: Duration = Duration::from_millis(2500);
const HEARTBEAT_PROBE_TIMEOUT: Duration = Duration::from_secs(2);
const WINDOW: Duration = Duration::from_secs(60);
/// `dial::wireguard_roam::ROAM_PORT` (crate-private): `reach` and roam notes.
const ROAM_PORT: u16 = 7421;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Side {
    Phone,
    Mac,
}

#[derive(Default, Clone, Copy, Debug)]
struct Tally {
    datagrams: u64,
    bytes: u64,
}

impl Tally {
    fn add(&mut self, bytes: usize) {
        self.datagrams += 1;
        self.bytes += bytes as u64;
    }
}

static RECORDING: AtomicBool = AtomicBool::new(false);
/// What each side sent, by kind, as its peer's tunnel received it.
static BY_KIND: Mutex<BTreeMap<(Side, String), Tally>> = Mutex::new(BTreeMap::new());
/// What each side's socket sent.
static SENT: Mutex<BTreeMap<Side, Tally>> = Mutex::new(BTreeMap::new());

fn sent_phone(_target: &SocketAddr, bytes: usize) {
    if RECORDING.load(Ordering::Relaxed) {
        SENT.lock().unwrap().entry(Side::Phone).or_default().add(bytes);
    }
}

fn sent_mac(_target: &SocketAddr, bytes: usize) {
    if RECORDING.load(Ordering::Relaxed) {
        SENT.lock().unwrap().entry(Side::Mac).or_default().add(bytes);
    }
}

fn received(local: IpAddr, received: Received<'_>, wire_bytes: usize) {
    if !RECORDING.load(Ordering::Relaxed) {
        return;
    }
    // What a side receives, its peer sent.
    let sender = match local {
        MAC_OVERLAY => Side::Phone,
        PHONE_OVERLAY => Side::Mac,
        _ => return,
    };
    BY_KIND.lock().unwrap().entry((sender, kind(received))).or_default().add(wire_bytes);
}

/// The sender a datagram came from, by what it carried.
fn kind(received: Received<'_>) -> String {
    match received {
        Received::Handshake => "wg handshake".into(),
        Received::Cookie => "wg cookie".into(),
        Received::Keepalive => "wg keepalive".into(),
        Received::Refused => "wg duplicate (refused)".into(),
        Received::TunnelControl(what) => format!("wg {what}"),
        Received::Parity => "wg parity".into(),
        Received::Packet(packet) => packet_kind(packet),
    }
}

fn packet_kind(packet: &[u8]) -> String {
    if packet.len() < 20 || packet[0] >> 4 != 4 {
        return "ip other".into();
    }
    let header = usize::from(packet[0] & 0x0f) * 4;
    let total = usize::from(u16::from_be_bytes([packet[2], packet[3]])).min(packet.len());
    let Some(transport) = packet.get(header..total) else { return "ip other".into() };
    match packet[9] {
        17 if transport.len() >= 8 => {
            let port = u16::from_be_bytes([transport[2], transport[3]]);
            let payload = &transport[8..];
            match port {
                wireguard::LIVENESS_PORT => match payload.first() {
                    Some(1) => "link ping (datagram)".into(),
                    Some(2) => "link pong (datagram)".into(),
                    _ => "liveness other".into(),
                },
                ROAM_PORT => {
                    let text = String::from_utf8_lossy(payload);
                    let tag = text.split("\"t\":\"").nth(1).and_then(|rest| rest.split('"').next());
                    format!("roam {}", tag.unwrap_or("?"))
                }
                port => format!("udp port {port}"),
            }
        }
        6 if transport.len() >= 20 => {
            let offset = usize::from(transport[12] >> 4) * 4;
            let flags = transport[13];
            let payload = transport.get(offset..).unwrap_or_default();
            if flags & 0x07 != 0 {
                return "tcp syn/fin/rst".into();
            }
            match payload.len() {
                0 => "tcp pure ack".into(),
                1 => "tcp keepalive probe".into(),
                _ => match payload.get(8) {
                    Some(3) => "link ping (in stream)".into(),
                    Some(4) => "link pong (in stream)".into(),
                    _ => "tcp data".into(),
                },
            }
        }
        protocol => format!("ip protocol {protocol}"),
    }
}

/// What the phone does while the minute runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Phone {
    /// Nothing: backgrounded or nothing on screen (`LinkConfig::default`).
    Idle,
    /// The Rust foreground probe on (`Link::set_foreground_probe`).
    RustProbe,
    /// The app's heartbeat alone (`LinkController.startHeartbeat`).
    Heartbeat,
    /// In front with a terminal on screen, as the app runs today: the
    /// Rust foreground probe and the heartbeat.
    Foreground,
}

/// `LinkController`'s foreground heartbeat: probe a link quiet for a whole
/// beat, then look again one beat after its last frame.
async fn heartbeat(link: Link) {
    let mut wait = HEARTBEAT;
    loop {
        tokio::time::sleep(wait).await;
        if link.is_closed() {
            return;
        }
        let quiet = link.received_ago();
        if quiet < HEARTBEAT {
            wait = HEARTBEAT - quiet;
            continue;
        }
        wait = HEARTBEAT;
        let _ = tokio::time::timeout(HEARTBEAT_PROBE_TIMEOUT, link.probe(HEARTBEAT_PROBE_TIMEOUT)).await;
    }
}

/// One idle minute on a direct link, both ends on `config`; per-kind
/// tallies (by sender) and what each socket sent.
async fn idle_minute(
    config: LinkConfig,
    phone: Phone,
) -> (BTreeMap<(Side, String), Tally>, BTreeMap<Side, Tally>) {
    let base =
        DialOptions { include_loopback: true, timeout: Duration::from_secs(20), ..DialOptions::default() };
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    {
        let (config, base) = (config.clone(), base.clone());
        tokio::spawn(async move {
            while let Some(session) = mac.next_session().await {
                let events = SessionEvents {
                    backend: mac.events(),
                    session_id: session.first.session_id.clone(),
                    session: session.events,
                };
                let (mac, config, base) = (mac.clone(), config.clone(), base.clone());
                tokio::spawn(async move {
                    let options = DialOptions { on_udp_sent: Some(sent_mac), ..base };
                    let connected =
                        dial::answer(&mac, session.first, events, &options, config).await.unwrap();
                    while connected.link.accept().await.is_some() {}
                });
            }
        });
    }
    let phone_id = uuid::Uuid::new_v4().to_string();
    let client = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    let options = DialOptions { on_udp_sent: Some(sent_phone), ..base };
    let connected =
        dial::connect(&client, &mac_id, TransportKind::WireGuard, &options, config).await.expect("dial");
    let link = connected.link.clone();
    if matches!(phone, Phone::RustProbe | Phone::Foreground) {
        link.set_foreground_probe(true);
    }
    let beat =
        matches!(phone, Phone::Heartbeat | Phone::Foreground).then(|| tokio::spawn(heartbeat(link.clone())));
    // Past the dial's own traffic (route settling, the first `reach`es).
    tokio::time::sleep(Duration::from_secs(5)).await;
    BY_KIND.lock().unwrap().clear();
    SENT.lock().unwrap().clear();
    RECORDING.store(true, Ordering::SeqCst);
    tokio::time::sleep(WINDOW).await;
    RECORDING.store(false, Ordering::SeqCst);
    assert!(!link.is_closed());
    if let Some(beat) = beat {
        beat.abort();
    }
    link.close("done");
    // Datagrams still in flight at the window's end land in a few ms.
    tokio::time::sleep(Duration::from_millis(200)).await;
    let by_kind = std::mem::take(&mut *BY_KIND.lock().unwrap());
    let sent = std::mem::take(&mut *SENT.lock().unwrap());
    (by_kind, sent)
}

fn per_hour(tally: Tally) -> f64 {
    tally.bytes as f64 * (3600.0 / WINDOW.as_secs_f64()) / 1_000_000.0
}

/// Print the minute's table; returns each side's attributed total.
fn report(name: &str, by_kind: &BTreeMap<(Side, String), Tally>, sent: &BTreeMap<Side, Tally>) -> [Tally; 2] {
    let mut totals = [Tally::default(); 2];
    eprintln!("IDLE BUDGET {name}: datagrams/min, wire bytes/min, MB/h");
    for ((side, kind), tally) in by_kind {
        eprintln!(
            "  {side:?} {kind:<28} {:>4} {:>7} {:>6.3}",
            tally.datagrams,
            tally.bytes,
            per_hour(*tally)
        );
        let total = &mut totals[*side as usize];
        total.datagrams += tally.datagrams;
        total.bytes += tally.bytes;
    }
    for side in [Side::Phone, Side::Mac] {
        let attributed = totals[side as usize];
        let socket = sent.get(&side).copied().unwrap_or_default();
        eprintln!(
            "  {side:?} total {:>4} {:>7} {:>6.3} (socket sent {} {})",
            attributed.datagrams,
            attributed.bytes,
            per_hour(attributed),
            socket.datagrams,
            socket.bytes
        );
    }
    totals
}

/// The budget closes: every datagram a socket sent is one the peer's
/// tunnel attributed, give or take the one in flight at each edge.
fn assert_closed(
    by_kind: &BTreeMap<(Side, String), Tally>,
    sent: &BTreeMap<Side, Tally>,
    totals: [Tally; 2],
) {
    for side in [Side::Phone, Side::Mac] {
        let socket = sent.get(&side).copied().unwrap_or_default();
        let attributed = totals[side as usize];
        assert!(
            socket.datagrams.abs_diff(attributed.datagrams) <= 2,
            "{side:?}: socket sent {socket:?}, attributed {attributed:?}: {by_kind:?}"
        );
    }
}

/// The idle and foreground budgets, each sender counted. A gate on the
/// budget closing (nothing unattributed) and on today's totals.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn idle_minute_budget() {
    assert!(cmux_wg::testing::set_receive_tap(received));
    let mut results = Vec::new();
    for phone in [Phone::Idle, Phone::Foreground] {
        let (by_kind, sent) = idle_minute(LinkConfig::default(), phone).await;
        let totals = report(&format!("{phone:?}"), &by_kind, &sent);
        assert_closed(&by_kind, &sent, totals);
        results.push((phone, totals));
    }
    for (phone, [phone_total, mac_total]) in results {
        eprintln!(
            "IDLE BUDGET {phone:?}: phone {:.3} MB/h ({} datagrams/min), Mac {:.3} MB/h ({} datagrams/min)",
            per_hour(phone_total),
            phone_total.datagrams,
            per_hour(mac_total),
            mac_total.datagrams
        );
    }
}

/// Each probe clock alone, for the PR body:
/// `cargo test -p cmux-mobile-link --test idle_budget probe_clocks -- --ignored --nocapture`.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "measurement: two idle minutes; run on its own"]
async fn probe_clocks_alone() {
    assert!(cmux_wg::testing::set_receive_tap(received));
    for phone in [Phone::RustProbe, Phone::Heartbeat] {
        let (by_kind, sent) = idle_minute(LinkConfig::default(), phone).await;
        let totals = report(&format!("{phone:?}"), &by_kind, &sent);
        assert_closed(&by_kind, &sent, totals);
    }
}
