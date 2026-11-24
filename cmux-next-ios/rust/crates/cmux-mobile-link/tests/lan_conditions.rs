//! The phone-to-Mac link on one Wi-Fi, headless: today's relayed dial beside the LAN direct
//! dial (`cmux_mobile_link::lan`), both through cmux-fault's seeded shapers playing one named
//! link profile (`cmux-tui/crates/cmux-fault/link-profiles.json`), so one harness gives the
//! before and the after.
//!
//! - `relayed` (before, today's path): the phone opens its signaling socket and dials the Mac
//!   over WireGuard through a TURN relay. Signaling rides the TCP shaper's internet path, and TURN
//!   rides the UDP shaper's internet path.
//! - `lan` (after): the phone dials the Mac's LAN mesh straight through the UDP shaper's own (LAN)
//!   path. It uses no signaling, token, ICE or relay.
//! - `race` (after, as the app runs it): `lan` and `relayed` at once; the first link up wins.
//! - `race-dead-lan` (after, off the Wi-Fi or with Local Network denied): the race, with the LAN
//!   address a black hole (a socket that never answers, the worst case: a denial that fails fast
//!   is quicker), so what it costs over `relayed` is the race's own cost.
//!
//! Per profile and run (seed = run + `NETCOND_SEED_BASE`), each path gives:
//! - `connect_ms`: from the dial's start to the link being up. For `relayed` this includes the
//!   signaling socket.
//! - `input_echo_ms`: one keystroke (1 byte) to its echo on an open channel, measured
//!   `NETCOND_ECHOES` times.
//! - `connected`: 1, or 0 when the dial failed within its bound.
//!
//! A profile whose disruption is `internet_down` cuts both internet paths before the dial.
//! `fallback` (profiles that do not cut the internet) has the phone up on its best link, then it
//! leaves the Wi-Fi: the Wi-Fi shapers go dark, and the redial (iOS `path_changed`) runs on an
//! `lte` shaper pair. `fallback_ms` is the time from leaving the Wi-Fi to the first echo on the
//! new link. With `lan` the redial races the direct dial against the relayed one, as `connect`
//! does on the phone.
//!
//! The output is one `NETCOND {json}` line per value (surface `link`, phase = path), and
//! `scripts/measure/ios-network-conditions-report.py` makes the table. The test is `#[ignore]`d,
//! so run it with `--ignored --nocapture`.
//!
//! Env:
//! - `NETCOND_PROFILES` (default `lan,internet-down-lan-up`)
//! - `NETCOND_PATHS` (default `relayed,lan,race,race-dead-lan`)
//! - `NETCOND_FALLBACK` (profiles that also run `fallback`; default `lan`)
//! - `NETCOND_RUNS` (default 5)
//! - `NETCOND_ECHOES` (default 20)
//! - `NETCOND_SEED_BASE` (default 0)
//! - `NETCOND_STREAM_KB` (default 0: off): while each path dials and echoes, a streaming session
//!   on its own relayed link through the same radio pushes this many KiB every 10 ms and drains
//!   the echo (a long live agent stream on the same Mac and Wi-Fi: the duress case).
//! - `NETCOND_STREAM_RADIO` (`shared` default, or `own`): `own` gives the stream its own radio
//!   (its own shaper and source address), as a second socket behind a real NAT gets its own
//!   mapping; the shaper is one mapping per radio (it answers "whichever spoke last").
//!   `stopped` brings the stream up on the shared radio, then stops it before the path dials
//!   (the second dial alone on a link a first session just used).

use std::future::Future;
use std::net::{Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use cmux_fault::Trace;
use cmux_fault::shaper::{Disruption, LinkProfile, ProfileFile, Shaper, UdpShaper};
use cmux_mobile_link::dial::{self, Connected, SessionEvents};
use cmux_mobile_link::lan::{self, LanEnrollRequest, LanHost, LanIdentity, LanMac};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling, TestTurn};
use cmux_mobile_link::{
    ChannelEvent, DialOptions, Link, LinkConfig, SignalingClient, Timeline, TransportKind,
};
use serde_json::json;
use tokio::time::{Instant, timeout};

/// Every measured wait's bound.
const WAIT: Duration = Duration::from_secs(30);

fn env_list(name: &str, default: &str) -> Vec<String> {
    std::env::var(name)
        .unwrap_or_else(|_| default.to_owned())
        .split(',')
        .map(str::trim)
        .filter(|item| !item.is_empty())
        .map(str::to_owned)
        .collect()
}

fn env_u64(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|value| value.trim().parse().ok()).unwrap_or(default)
}

fn emit(profile: &LinkProfile, phase: &str, metric: &str, value: Option<f64>, run: u64, seed: u64) {
    let row = json!({"surface": "link", "profile": format!("{}@{}", profile.name, profile.version),
        "phase": phase, "scale": "1x", "metric": metric,
        "value": value.map(|v| (v * 10.0).round() / 10.0), "run": run, "seed": seed});
    println!("NETCOND {row}");
}

fn ms(since: Instant) -> f64 {
    since.elapsed().as_secs_f64() * 1000.0
}

/// Echo every channel's bytes back, for as long as the link lives.
fn serve_echo(connected: Connected) {
    tokio::spawn(async move {
        while let Some(mut incoming) = connected.link.accept().await {
            tokio::spawn(async move {
                while let Some(ChannelEvent::Data(bytes)) = incoming.channel.recv().await {
                    let _ = incoming.channel.send(bytes).await;
                }
            });
        }
    });
}

/// The Mac: a signaling client that answers every session, a TURN server, and the LAN mesh
/// with this run's phone enrolled. Every link it takes echoes.
struct Mac {
    signaling: FakeSignaling,
    mac_id: String,
    turn: TestTurn,
    lan: Arc<LanHost>,
    phone_lan: LanIdentity,
    lan_entry: LanMac,
}

impl Mac {
    async fn start() -> Self {
        Self::start_with(false).await
    }

    /// `with_turn`: the Mac takes its own TURN allocation too, so it offers a relayed address.
    async fn start_with(with_turn: bool) -> Self {
        let turn = TestTurn::start().await;
        let signaling = FakeSignaling::start(FakeOptions::default()).await;
        let mac_id = uuid::Uuid::new_v4().to_string();
        let mac = SignalingClient::connect(&signaling.base_url, "user:alice", "team", &mac_id)
            .await
            .expect("Mac signaling");
        let mac_ice = if with_turn { vec![turn.udp_only()] } else { Vec::new() };
        let mac_options = DialOptions {
            include_loopback: true,
            timeout: WAIT,
            ice_servers: mac_ice,
            ..DialOptions::default()
        };
        tokio::spawn(async move {
            while let Some(session) = mac.next_session().await {
                let events = SessionEvents {
                    backend: mac.events(),
                    session_id: session.first.session_id.clone(),
                    session: session.events,
                };
                let (mac, options) = (mac.clone(), mac_options.clone());
                tokio::spawn(async move {
                    if let Ok(connected) =
                        dial::answer(&mac, session.first, events, &options, LinkConfig::default()).await
                    {
                        serve_echo(connected);
                    }
                });
            }
        });
        let lan = Arc::new(LanHost::start(LanIdentity::generate(), 0, None, true).await.expect("LAN mesh"));
        let phone_lan = LanIdentity::generate();
        let reply = lan
            .enroll("phone", &LanEnrollRequest { phone_key: phone_lan.public_b64() })
            .await
            .expect("enroll");
        let lan_entry = LanMac::from_reply(&reply).expect("enrollment reply");
        let accepting = Arc::clone(&lan);
        tokio::spawn(async move {
            while let Some(accepted) = accepting.accept().await {
                let (_, connected) = lan::answer(accepted, LinkConfig::default());
                serve_echo(connected);
            }
        });
        Self { signaling, mac_id, turn, lan, phone_lan, lan_entry }
    }

    fn signaling_addr(&self) -> SocketAddr {
        self.signaling.base_url.trim_start_matches("http://").parse().expect("signaling address")
    }

    fn turn_udp_addr(&self) -> SocketAddr {
        let url = &self.turn.udp_only().urls[0];
        let rest = url.trim_start_matches("turn:");
        rest.split('?').next().unwrap_or(rest).parse().expect("TURN address")
    }

    fn lan_addr(&self) -> SocketAddr {
        (Ipv4Addr::LOCALHOST, self.lan.port()).into()
    }
}

/// One Wi-Fi (or LTE) link: what the phone dials through.
struct Radio {
    tcp: Shaper,
    udp: UdpShaper,
    /// Signaling's base URL through the internet path.
    signaling_url: String,
    /// TURN through the internet path.
    turn: cmux_mobile_link::api::IceServer,
}

impl Radio {
    async fn start(mac: &Mac, profile: &LinkProfile, seed: u64, trace: &Trace) -> Self {
        let tcp =
            Shaper::start(mac.signaling_addr(), profile.clone(), seed, trace).await.expect("tcp shaper");
        let internet = tcp.open_internet_path(mac.signaling_addr()).await.expect("internet path");
        let udp = UdpShaper::start(mac.lan_addr(), profile.clone(), seed, trace).await.expect("udp shaper");
        let turn_path = udp.open_internet_path(mac.turn_udp_addr()).await.expect("TURN path");
        let mut turn = mac.turn.udp_only();
        turn.urls = vec![format!("turn:{turn_path}?transport=udp")];
        Self { tcp, udp, signaling_url: format!("http://{internet}"), turn }
    }

    fn internet_down(&self) {
        self.tcp.internet_down();
        self.udp.internet_down();
    }

    fn leave(&self) {
        self.tcp.blackout(Duration::from_secs(600));
        self.udp.blackout(Duration::from_secs(600));
    }
}

/// A link up and what keeps it up (the relayed dial's signaling socket).
struct Up {
    connected: Connected,
    _signaling: Option<SignalingClient>,
}

async fn dial_relayed(mac: &Mac, radio: &Radio) -> Option<Up> {
    dial_relayed_on(mac, radio, Timeline::default()).await
}

/// `dial_relayed`, marking `timeline` (`signaling_connected`, then the dial's own marks).
async fn dial_relayed_on(mac: &Mac, radio: &Radio, timeline: Timeline) -> Option<Up> {
    let options = DialOptions {
        include_loopback: true,
        relay_only: true,
        ice_servers: vec![radio.turn.clone()],
        timeout: WAIT,
        timeline: timeline.clone(),
        ..DialOptions::default()
    };
    let attempt = async {
        let phone_id = uuid::Uuid::new_v4().to_string();
        // The redial: TURN allocates beside the signaling reconnect (`signaling_connected`).
        let reconnect = SignalingClient::connect(&radio.signaling_url, "user:alice", "team", &phone_id);
        let (phone, connected) = dial::connect_after(
            reconnect,
            &mac.mac_id,
            TransportKind::WireGuard,
            &options,
            LinkConfig::default(),
        )
        .await
        .map_err(|error| eprintln!("COLDDIALERR {error:?}"))
        .ok()?;
        Some(Up { connected, _signaling: Some(phone) })
    };
    timeout(WAIT, attempt).await.ok().flatten()
}

/// MEASUREMENT ONLY. `relayed-seq`: the redial before #52992: reconnect signaling, then dial
/// (`dial::connect`), so TURN allocates after the reconnect.
async fn dial_relayed_seq_on(mac: &Mac, radio: &Radio, timeline: Timeline) -> Option<Up> {
    let options = DialOptions {
        include_loopback: true,
        relay_only: true,
        ice_servers: vec![radio.turn.clone()],
        timeout: WAIT,
        timeline: timeline.clone(),
        ..DialOptions::default()
    };
    let attempt = async {
        let phone_id = uuid::Uuid::new_v4().to_string();
        let phone =
            SignalingClient::connect(&radio.signaling_url, "user:alice", "team", &phone_id).await.ok()?;
        timeline.mark("signaling_connected");
        let connected =
            dial::connect(&phone, &mac.mac_id, TransportKind::WireGuard, &options, LinkConfig::default())
                .await
                .map_err(|error| eprintln!("SEQDIALERR {error:?}"))
                .ok()?;
        Some(Up { connected, _signaling: Some(phone) })
    };
    timeout(WAIT, attempt).await.ok().flatten()
}

/// The warm-socket dial: signaling is already connected on this radio (the app's pool keeps it
/// for a returning user), so the dial starts at the offer, on the pool's `dial::connect`.
async fn dial_warm_on(mac: &Mac, radio: &Radio, warm: SignalingClient, timeline: Timeline) -> Option<Up> {
    let options = DialOptions {
        include_loopback: true,
        relay_only: true,
        ice_servers: vec![radio.turn.clone()],
        timeout: WAIT,
        timeline: timeline.clone(),
        ..DialOptions::default()
    };
    timeline.mark("signaling_connected");
    let attempt = async {
        let connected =
            dial::connect(&warm, &mac.mac_id, TransportKind::WireGuard, &options, LinkConfig::default())
                .await
                .map_err(|error| eprintln!("WARMDIALERR {error:?}"))
                .ok()?;
        Some(Up { connected, _signaling: Some(warm) })
    };
    timeout(WAIT, attempt).await.ok().flatten()
}

/// The `mac-relay-blocked` dial: not relay only, but every plain UDP datagram the phone's
/// WireGuard sends is lost (the Mac's relayed address and host are unreachable by plain UDP),
/// so the link runs through the phone's own TURN relay to the Mac's relayed address.
async fn dial_blocked_on(mac: &Mac, radio: &Radio, timeline: Timeline) -> Option<Up> {
    let options = DialOptions {
        include_loopback: true,
        drop_outbound_udp: true,
        ice_servers: vec![radio.turn.clone()],
        timeout: WAIT,
        timeline: timeline.clone(),
        ..DialOptions::default()
    };
    let attempt = async {
        let phone_id = uuid::Uuid::new_v4().to_string();
        let reconnect = SignalingClient::connect(&radio.signaling_url, "user:alice", "team", &phone_id);
        let (phone, connected) = dial::connect_after(
            reconnect,
            &mac.mac_id,
            TransportKind::WireGuard,
            &options,
            LinkConfig::default(),
        )
        .await
        .ok()?;
        Some(Up { connected, _signaling: Some(phone) })
    };
    timeout(WAIT, attempt).await.ok().flatten()
}

async fn dial_lan(mac: &Mac, address: SocketAddr) -> Option<Up> {
    let timeline = Timeline::default();
    let attempt =
        lan::connect(&mac.phone_lan, &mac.lan_entry, vec![address], LinkConfig::default(), &timeline);
    let (connected, _) = timeout(WAIT, attempt).await.ok()?.ok()?;
    Some(Up { connected, _signaling: None })
}

/// The first of two dials to come up (the phone's `connect` race).
async fn first_up(a: impl Future<Output = Option<Up>>, b: impl Future<Output = Option<Up>>) -> Option<Up> {
    tokio::pin!(a);
    tokio::pin!(b);
    tokio::select! {
        up = &mut a => match up { Some(up) => Some(up), None => b.await },
        up = &mut b => match up { Some(up) => Some(up), None => a.await },
    }
}

/// A streaming session beside the path under test: its own relayed link, flooding an echo
/// channel; dropped (tasks aborted, link closed) when the cold run ends.
struct Stream {
    _up: Up,
    tasks: Vec<tokio::task::JoinHandle<()>>,
}

impl Drop for Stream {
    fn drop(&mut self) {
        for task in &self.tasks {
            task.abort();
        }
    }
}

async fn stream_load(mac: &Mac, radio: &Radio, kib: u64) -> Option<Stream> {
    let up = dial_relayed(mac, radio).await?;
    let channel = timeout(WAIT, up.connected.link.open("echo", json!({}))).await.ok()?.ok()?;
    let (sender, mut receiver) = channel.split();
    let chunk = Bytes::from(vec![b's'; (kib * 1024) as usize]);
    let push = tokio::spawn(async move {
        while sender.send(chunk.clone()).await.is_ok() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    });
    let drain = tokio::spawn(async move { while receiver.recv().await.is_some() {} });
    Some(Stream { _up: up, tasks: vec![push, drain] })
}

/// `count` keystrokes, each timed to its echo; `None` for one that never came back.
async fn echoes(link: &Link, count: u64) -> Vec<Option<f64>> {
    let Ok(Ok(channel)) = timeout(WAIT, link.open("echo", json!({}))).await else {
        return vec![None; count as usize];
    };
    let (sender, mut receiver) = channel.split();
    let mut out = Vec::new();
    for _ in 0..count {
        let started = Instant::now();
        if sender.send(Bytes::from_static(b"k")).await.is_err() {
            out.push(None);
            continue;
        }
        match timeout(WAIT, receiver.recv()).await {
            Ok(Some(ChannelEvent::Data(_))) => out.push(Some(ms(started))),
            _ => out.push(None),
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    out
}

/// The first echo on `link`, from `since`.
async fn first_echo(link: &Link, since: Instant) -> Option<f64> {
    let channel = timeout(WAIT, link.open("echo", json!({}))).await.ok()?.ok()?;
    let (sender, mut receiver) = channel.split();
    sender.send(Bytes::from_static(b"k")).await.ok()?;
    match timeout(WAIT, receiver.recv()).await {
        Ok(Some(ChannelEvent::Data(_))) => Some(ms(since)),
        _ => None,
    }
}

async fn cold(profile: &LinkProfile, path: &str, run: u64, seed: u64, echo_count: u64, stream_kib: u64) {
    let trace = Trace::new();
    let mac = Mac::start().await;
    let radio = Radio::start(&mac, profile, seed, &trace).await;
    let stream_mode = std::env::var("NETCOND_STREAM_RADIO").unwrap_or_default();
    let own_radio = stream_mode == "own";
    let stream_radio = if stream_kib > 0 && own_radio {
        Some(Radio::start(&mac, profile, seed + 1_000, &trace).await)
    } else {
        None
    };
    let mut load = if stream_kib > 0 {
        stream_load(&mac, stream_radio.as_ref().unwrap_or(&radio), stream_kib).await
    } else {
        None
    };
    if stream_kib > 0 {
        emit(profile, path, "stream_up", Some(if load.is_some() { 1.0 } else { 0.0 }), run, seed);
    }
    if stream_mode == "stopped" {
        load = None;
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    if matches!(profile.disruption, Some(Disruption::InternetDown)) {
        radio.internet_down();
    }
    // A LAN address nothing answers (bound, never read): the Mac out of reach.
    let hole = std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).expect("black hole");
    let hole_addr = hole.local_addr().expect("black hole address");
    let started = Instant::now();
    let up = match path {
        "lan" => dial_lan(&mac, radio.udp.addr()).await,
        "race" => first_up(dial_lan(&mac, radio.udp.addr()), dial_relayed(&mac, &radio)).await,
        "race-dead-lan" => first_up(dial_lan(&mac, hole_addr), dial_relayed(&mac, &radio)).await,
        _ => dial_relayed(&mac, &radio).await,
    };
    drop(hole);
    let connect = up.as_ref().map(|_| ms(started));
    emit(profile, path, "connected", Some(if up.is_some() { 1.0 } else { 0.0 }), run, seed);
    emit(profile, path, "connect_ms", connect, run, seed);
    match up {
        Some(up) => {
            for value in echoes(&up.connected.link, echo_count).await {
                emit(profile, path, "input_echo_ms", value, run, seed);
            }
        }
        None => {
            for _ in 0..echo_count {
                emit(profile, path, "input_echo_ms", None, run, seed);
            }
        }
    }
    drop(load);
}

async fn fallback(profile: &LinkProfile, path: &str, run: u64, seed: u64) {
    let trace = Trace::new();
    let mac = Mac::start().await;
    let wifi = Radio::start(&mac, profile, seed, &trace).await;
    let lte_profile = ProfileFile::builtin().get("lte").cloned().expect("lte profile");
    let lte = Radio::start(&mac, &lte_profile, seed, &trace).await;
    let up = match path {
        "lan" => first_up(dial_lan(&mac, wifi.udp.addr()), dial_relayed(&mac, &wifi)).await,
        _ => dial_relayed(&mac, &wifi).await,
    };
    let Some(up) = up else {
        emit(profile, path, "fallback_ms", None, run, seed);
        return;
    };
    if first_echo(&up.connected.link, Instant::now()).await.is_none() {
        emit(profile, path, "fallback_ms", None, run, seed);
        return;
    }
    // The phone leaves the Wi-Fi: its Wi-Fi link goes dark (LAN and internet), and iOS reports
    // the path change, so the app redials on LTE. The Mac's addresses are unreachable from it.
    let left = Instant::now();
    wifi.leave();
    let again = match path {
        "lan" => first_up(dial_lan(&mac, wifi.udp.addr()), dial_relayed(&mac, &lte)).await,
        _ => dial_relayed(&mac, &lte).await,
    };
    let value = match again {
        Some(again) => first_echo(&again.connected.link, left).await,
        None => None,
    };
    emit(profile, path, "fallback_ms", value, run, seed);
    drop(up);
}

/// Which link a dial came up on: `lan` (direct) or `relayed`.
async fn first_up_named(
    a: impl Future<Output = Option<Up>>,
    b: impl Future<Output = Option<Up>>,
) -> Option<(Up, &'static str)> {
    let a = async { a.await.map(|up| (up, "lan")) };
    let b = async { b.await.map(|up| (up, "relayed")) };
    tokio::pin!(a);
    tokio::pin!(b);
    tokio::select! {
        up = &mut a => match up { Some(up) => Some(up), None => b.await },
        up = &mut b => match up { Some(up) => Some(up), None => a.await },
    }
}

/// The app's dial on `radio`: relayed alone, or raced against a direct dial to `lan_addr`.
async fn dial_named(mac: &Mac, radio: &Radio, lan_addr: Option<SocketAddr>) -> Option<(Up, &'static str)> {
    match lan_addr {
        Some(addr) => first_up_named(dial_lan(mac, addr), dial_relayed(mac, radio)).await,
        None => dial_relayed(mac, radio).await.map(|up| (up, "relayed")),
    }
}

/// The Wi-Fi round trip: up on the Wi-Fi, the Wi-Fi drops (the phone redials on cellular,
/// `cell`), then a fresh Wi-Fi comes back (the phone redials on it). Each leg's value is the
/// time from the path event to the first echo on the new link, the gap with no bytes flowing
/// when the old link is gone (the Wi-Fi drop) and the switch time when it is not (the return).
/// `path` `relayed` is today's app (relayed only); `lan` races the direct dial against it.
async fn roundtrip(profile: &LinkProfile, cell: &LinkProfile, path: &str, run: u64, seed: u64) {
    if path == "relayed-held" {
        return held_redial(profile, run, seed).await;
    }
    let trace = Trace::new();
    let mac = Mac::start_with(path == "mac-relay-blocked").await;
    let wifi = Radio::start(&mac, profile, seed, &trace).await;
    let cellular = Radio::start(&mac, cell, seed, &trace).await;
    let tag = |leg: &str| format!("{path}:{}:{leg}", cell.name);
    let lan_on = |radio: &Radio| (path == "lan").then(|| radio.udp.addr());
    // `relayed-warm`: the cellular radio's signaling socket is up before the Wi-Fi drops.
    let warm = if path == "relayed-warm" {
        let phone_id = uuid::Uuid::new_v4().to_string();
        match SignalingClient::connect(&cellular.signaling_url, "user:alice", "team", &phone_id).await {
            Ok(client) => Some(client),
            Err(_) => {
                emit(profile, &tag("warm_signaling"), "switch_ms", None, run, seed);
                return;
            }
        }
    } else {
        None
    };
    let Some((up, _)) = dial_named(&mac, &wifi, lan_on(&wifi)).await else {
        emit(profile, &tag("wifi_up"), "switch_ms", None, run, seed);
        return;
    };
    if first_echo(&up.connected.link, Instant::now()).await.is_none() {
        emit(profile, &tag("wifi_up"), "switch_ms", None, run, seed);
        return;
    }
    // Wi-Fi drops: everything on it goes dark; the phone redials on cellular. A direct dial
    // is still raced (the app does not know the LAN is gone), on the dead Wi-Fi address.
    let dropped = Instant::now();
    wifi.leave();
    // The relayed dial's stages, timed from the drop.
    let stages = Timeline::starting_at(dropped.into_std());
    let on_cell = match (lan_on(&wifi), warm) {
        (_, Some(warm)) => {
            dial_warm_on(&mac, &cellular, warm, stages.clone()).await.map(|up| (up, "relayed"))
        }
        (Some(addr), None) => {
            first_up_named(dial_lan(&mac, addr), dial_relayed_on(&mac, &cellular, stages.clone())).await
        }
        (None, None) if path == "relayed-seq" => {
            dial_relayed_seq_on(&mac, &cellular, stages.clone()).await.map(|up| (up, "relayed"))
        }
        (None, None) if path == "mac-relay-blocked" => {
            dial_blocked_on(&mac, &cellular, stages.clone()).await.map(|up| (up, "relayed"))
        }
        (None, None) => dial_relayed_on(&mac, &cellular, stages.clone()).await.map(|up| (up, "relayed")),
    };
    let (value, won) = match &on_cell {
        Some((again, won)) => (first_echo(&again.connected.link, dropped).await, *won),
        None => (None, "none"),
    };
    stages.mark("first_echo");
    let marks: Vec<_> = stages
        .marks()
        .into_iter()
        .map(|(name, at)| json!([name, (at.as_secs_f64() * 10000.0).round() / 10.0]))
        .collect();
    println!(
        "STAGES {}",
        json!({"phase": tag("to_cell"), "run": run, "ok": value.is_some(), "marks": marks})
    );
    emit(profile, &tag(&format!("to_cell_{won}")), "switch_ms", value, run, seed);
    drop(up);
    let Some((cell_up, _)) = on_cell else { return };
    // Wi-Fi comes back (a fresh shaper pair, the Mac's LAN still there); the cellular link
    // keeps flowing while the phone redials on the Wi-Fi.
    let back = Radio::start(&mac, profile, seed + 1_000, &trace).await;
    let returned = Instant::now();
    let (value, won) = match dial_named(&mac, &back, lan_on(&back)).await {
        Some((again, won)) => (first_echo(&again.connected.link, returned).await, won),
        None => (None, "none"),
    };
    emit(profile, &tag(&format!("to_wifi_{won}")), "switch_ms", value, run, seed);
    drop(cell_up);
}

/// Measurement-only same-network redial. The first WireGuard underlay returns
/// its TURN carrier to the lease, and the second dial takes that carrier.
async fn held_redial(profile: &LinkProfile, run: u64, seed: u64) {
    let trace = Trace::new();
    let mac = Mac::start().await;
    let radio = Radio::start(&mac, profile, seed, &trace).await;
    let first = dial_relayed(&mac, &radio).await;
    let Some(first) = first else {
        emit(profile, "relayed-held", "connected", Some(0.0), run, seed);
        emit(profile, "relayed-held", "allocate_delta", None, run, seed);
        return;
    };
    let lease = first.connected.turn_lease.clone().expect("WireGuard TURN lease");
    let before = mac.turn.allocation_count();
    first.connected.link.close("same-network redial");
    drop(first);
    let deadline = Instant::now() + WAIT;
    while !lease.has_carrier() {
        if Instant::now() >= deadline {
            emit(profile, "relayed-held", "connected", Some(0.0), run, seed);
            emit(profile, "relayed-held", "allocate_delta", None, run, seed);
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let started = Instant::now();
    let phone_id = uuid::Uuid::new_v4().to_string();
    let options = DialOptions {
        include_loopback: true,
        relay_only: true,
        ice_servers: vec![radio.turn.clone()],
        timeout: WAIT,
        ..DialOptions::default()
    };
    let reconnect = SignalingClient::connect(&radio.signaling_url, "user:alice", "team", &phone_id);
    let result = dial::connect_after_with_turn(
        reconnect,
        &mac.mac_id,
        TransportKind::WireGuard,
        &options,
        LinkConfig::default(),
        Some(lease),
    )
    .await;
    let (connected, _) = match result {
        Ok((signaling, connected)) => (connected, signaling),
        Err(error) => {
            eprintln!("HELDDIALERR {error:?}");
            emit(profile, "relayed-held", "connected", Some(0.0), run, seed);
            emit(profile, "relayed-held", "allocate_delta", None, run, seed);
            return;
        }
    };
    emit(profile, "relayed-held", "connected", Some(1.0), run, seed);
    emit(profile, "relayed-held", "connect_ms", Some(ms(started)), run, seed);
    emit(
        profile,
        "relayed-held",
        "allocate_delta",
        Some((mac.turn.allocation_count().saturating_sub(before)) as f64),
        run,
        seed,
    );
    let _ = first_echo(&connected.link, started).await;
    connected.link.close("measurement done");
}

/// `NETCOND_ROUNDTRIP_CELLS=lte,lossy-3 NETCOND_ROUNDTRIP_PATHS=relayed,lan NETCOND_RUNS=20`:
/// the Wi-Fi round trip ([`roundtrip`]) on the `lan` Wi-Fi profile, once per cellular profile.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "a measurement: --ignored --nocapture"]
async fn lan_roundtrip() {
    let file = ProfileFile::builtin();
    let runs = env_u64("NETCOND_RUNS", 5);
    let seed_base = env_u64("NETCOND_SEED_BASE", 0);
    let wifi = file.get("lan").cloned().expect("lan profile");
    for cell in env_list("NETCOND_ROUNDTRIP_CELLS", "lte,lossy-3") {
        let cell = file.get(&cell).cloned().unwrap_or_else(|| panic!("no link profile {cell}"));
        for run in 0..runs {
            for path in env_list("NETCOND_ROUNDTRIP_PATHS", "relayed,lan") {
                roundtrip(&wifi, &cell, &path, run, run + seed_base).await;
            }
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "a measurement: scripts/measure or --ignored --nocapture"]
async fn lan_conditions() {
    let file = ProfileFile::builtin();
    let runs = env_u64("NETCOND_RUNS", 5);
    let echo_count = env_u64("NETCOND_ECHOES", 20);
    let seed_base = env_u64("NETCOND_SEED_BASE", 0);
    let stream_kib = env_u64("NETCOND_STREAM_KB", 0);
    let paths = env_list("NETCOND_PATHS", "relayed,lan,race,race-dead-lan");
    let fallbacks = env_list("NETCOND_FALLBACK", "lan");
    for name in env_list("NETCOND_PROFILES", "lan,internet-down-lan-up") {
        let profile = file.get(&name).cloned().unwrap_or_else(|| panic!("no link profile {name}"));
        for run in 0..runs {
            let seed = run + seed_base;
            for path in &paths {
                cold(&profile, path, run, seed, echo_count, stream_kib).await;
                if fallbacks.contains(&name) && matches!(path.as_str(), "relayed" | "lan") {
                    fallback(&profile, path, run, seed).await;
                }
            }
        }
    }
}
