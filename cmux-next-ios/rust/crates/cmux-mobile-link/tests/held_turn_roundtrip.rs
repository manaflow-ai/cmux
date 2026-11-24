//! The Wi-Fi drop redial, headless, through cmux-fault's seeded shapers: the
//! phone is up on a Wi-Fi radio, the Wi-Fi goes dark, and the phone redials
//! the Mac over WireGuard through TURN on a cellular radio
//! (`lan_conditions.rs`'s `lan_roundtrip` `relayed` arm, without the LAN
//! mesh). Each run prints the redial's stage marks (`STAGES`, milliseconds
//! from the drop) and the time from the drop to the first echo on the new
//! link (`NETCOND`, metric `switch_ms`).
//!
//! - `relayed`: today's redial (`dial::connect_after`): the TURN allocation
//!   starts beside the signaling reconnect (`turn_early_allocated`).
//! - `relayed-held`: the redial takes a held allocation
//!   (`dial::connect_after_held`, the warm pool's `TurnHold`) made on the
//!   cellular radio before the drop (`turn_held`): no Allocate on its path.
//!   This is the redial that finds a spare on the network it redials on (the
//!   pool re-makes its spare on `network_changed`); an allocation made on the
//!   Wi-Fi is not handed out after the drop.
//!
//! Each (cellular profile, path) cell prints the 1-minute load average at its
//! start and end (`LOAD`). `#[ignore]`d: `--ignored --nocapture`.
//!
//! Env: `NETCOND_ROUNDTRIP_CELLS` (default `lte,lossy-3`),
//! `NETCOND_ROUNDTRIP_PATHS` (default `relayed,relayed-held`), `NETCOND_RUNS`
//! (default 20), `NETCOND_SEED_BASE` (default 0).

use std::net::SocketAddr;
use std::time::Duration;

use bytes::Bytes;
use cmux_fault::Trace;
use cmux_fault::shaper::{LinkProfile, ProfileFile, Shaper, UdpShaper};
use cmux_mobile_link::dial::{self, Connected, SessionEvents};
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

fn load_1m() -> f64 {
    std::fs::read_to_string("/proc/loadavg")
        .ok()
        .and_then(|text| text.split_whitespace().next().and_then(|value| value.parse().ok()))
        .unwrap_or(f64::NAN)
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

/// The Mac: a signaling client that answers every session, and a TURN
/// server. Every link it takes echoes.
struct Mac {
    signaling: FakeSignaling,
    mac_id: String,
    turn: TestTurn,
    /// The UDP shapers' direct-path target (no one answers on it).
    sink: std::net::UdpSocket,
}

impl Mac {
    async fn start() -> Self {
        let turn = TestTurn::start().await;
        let signaling = FakeSignaling::start(FakeOptions::default()).await;
        let mac_id = uuid::Uuid::new_v4().to_string();
        let mac = SignalingClient::connect(&signaling.base_url, "user:alice", "team", &mac_id)
            .await
            .expect("Mac signaling");
        let mac_options = DialOptions { include_loopback: true, timeout: WAIT, ..DialOptions::default() };
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
        let sink = std::net::UdpSocket::bind("127.0.0.1:0").expect("sink");
        Self { signaling, mac_id, turn, sink }
    }

    fn signaling_addr(&self) -> SocketAddr {
        self.signaling.base_url.trim_start_matches("http://").parse().expect("signaling address")
    }

    fn turn_udp_addr(&self) -> SocketAddr {
        let url = &self.turn.udp_only().urls[0];
        let rest = url.trim_start_matches("turn:");
        rest.split('?').next().unwrap_or(rest).parse().expect("TURN address")
    }
}

/// One Wi-Fi (or cellular) link: what the phone dials through.
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
        let sink = mac.sink.local_addr().expect("sink address");
        let udp = UdpShaper::start(sink, profile.clone(), seed, trace).await.expect("udp shaper");
        let turn_path = udp.open_internet_path(mac.turn_udp_addr()).await.expect("TURN path");
        let mut turn = mac.turn.udp_only();
        turn.urls = vec![format!("turn:{turn_path}?transport=udp")];
        Self { tcp, udp, signaling_url: format!("http://{internet}"), turn }
    }

    fn leave(&self) {
        self.tcp.blackout(Duration::from_secs(600));
        self.udp.blackout(Duration::from_secs(600));
    }

    fn options(&self, timeline: Timeline) -> DialOptions {
        DialOptions {
            include_loopback: true,
            relay_only: true,
            ice_servers: vec![self.turn.clone()],
            timeout: WAIT,
            timeline,
            ..DialOptions::default()
        }
    }
}

/// A link up and what keeps it up (its signaling socket).
struct Up {
    connected: Connected,
    _signaling: SignalingClient,
}

/// The redial on `radio`: signaling reconnect and the WireGuard dial, the
/// TURN allocation beside the reconnect (`dial::connect_after`).
async fn dial_relayed_on(mac: &Mac, radio: &Radio, timeline: Timeline) -> Option<Up> {
    let options = radio.options(timeline);
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
        .map_err(|error| eprintln!("DIALERR {error:?}"))
        .ok()?;
        Some(Up { connected, _signaling: phone })
    };
    timeout(WAIT, attempt).await.ok().flatten()
}

/// The redial on `radio` taking `held`'s allocation (`dial::connect_after_held`).
async fn dial_held_on(mac: &Mac, radio: &Radio, held: &dial::TurnHold, timeline: Timeline) -> Option<Up> {
    let options = radio.options(timeline);
    let attempt = async {
        let phone_id = uuid::Uuid::new_v4().to_string();
        let reconnect = SignalingClient::connect(&radio.signaling_url, "user:alice", "team", &phone_id);
        let (phone, connected) = dial::connect_after_held(
            reconnect,
            &mac.mac_id,
            TransportKind::WireGuard,
            &options,
            LinkConfig::default(),
            Some(held),
        )
        .await
        .map_err(|error| eprintln!("DIALERR {error:?}"))
        .ok()?;
        Some(Up { connected, _signaling: phone })
    };
    timeout(WAIT, attempt).await.ok().flatten()
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

/// Up on the Wi-Fi, the Wi-Fi drops, the phone redials on `cell`.
async fn roundtrip(wifi_profile: &LinkProfile, cell: &LinkProfile, path: &str, run: u64, seed: u64) {
    let trace = Trace::new();
    let mac = Mac::start().await;
    let wifi = Radio::start(&mac, wifi_profile, seed, &trace).await;
    let cellular = Radio::start(&mac, cell, seed, &trace).await;
    let tag = format!("{path}:{}:to_cell_relayed", cell.name);
    let Some(up) = dial_relayed_on(&mac, &wifi, Timeline::default()).await else {
        emit(cell, &format!("{path}:{}:wifi_up", cell.name), "switch_ms", None, run, seed);
        return;
    };
    if first_echo(&up.connected.link, Instant::now()).await.is_none() {
        emit(cell, &format!("{path}:{}:wifi_up", cell.name), "switch_ms", None, run, seed);
        return;
    }
    // `relayed-held`: the spare the pool holds, on the network the redial uses.
    let held = (path == "relayed-held").then(|| {
        let held = dial::TurnHold::default();
        held.arm(&cellular.options(Timeline::default()));
        held
    });
    if let Some(held) = &held {
        let deadline = Instant::now() + WAIT;
        while !held.is_ready() && Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }
    let count_before = mac.turn.allocation_count();
    let dropped = Instant::now();
    wifi.leave();
    let stages = Timeline::starting_at(dropped.into_std());
    let again = match &held {
        Some(held) => dial_held_on(&mac, &cellular, held, stages.clone()).await,
        None => dial_relayed_on(&mac, &cellular, stages.clone()).await,
    };
    let allocates = mac.turn.allocation_count().saturating_sub(count_before);
    let value = match &again {
        Some(again) => first_echo(&again.connected.link, dropped).await,
        None => None,
    };
    stages.mark("first_echo");
    let marks: Vec<_> = stages
        .marks()
        .into_iter()
        .map(|(name, at)| json!([name, (at.as_secs_f64() * 10000.0).round() / 10.0]))
        .collect();
    println!(
        "STAGES {}",
        json!({"phase": tag, "run": run, "ok": value.is_some(), "allocates": allocates, "marks": marks})
    );
    emit(cell, &tag, "switch_ms", value, run, seed);
    drop((up, again, held));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "a measurement: --ignored --nocapture"]
async fn held_turn_roundtrip() {
    let file = ProfileFile::builtin();
    let runs = env_u64("NETCOND_RUNS", 20);
    let seed_base = env_u64("NETCOND_SEED_BASE", 0);
    let wifi = file.get("lan").cloned().expect("lan profile");
    for cell in env_list("NETCOND_ROUNDTRIP_CELLS", "lte,lossy-3") {
        let cell = file.get(&cell).cloned().unwrap_or_else(|| panic!("no link profile {cell}"));
        for path in env_list("NETCOND_ROUNDTRIP_PATHS", "relayed,relayed-held") {
            println!(
                "LOAD {}",
                json!({"cell": cell.name, "path": path, "at": "start", "load_1m": load_1m()})
            );
            for run in 0..runs {
                roundtrip(&wifi, &cell, &path, run, run + seed_base).await;
            }
            println!("LOAD {}", json!({"cell": cell.name, "path": path, "at": "end", "load_1m": load_1m()}));
        }
    }
}
