//! The benches behind the unmeasured rows of the ultra-connectivity scoreboard (cmuxterm-hq
//! `docs/design/ultra-connectivity-scoreboard.md`), the dash rows that run first. Each prints
//! `SCOREROW {...}` lines (one per value; `scripts/measure/ultra-connectivity-scoreboard.py` makes the
//! "Today" cells from them) and `SCOREROW-NA {...}` for a row this process cannot measure.
//!
//!     SCOREROW {"condition":..,"pair":..,"metric":..,"value":..,"unit":..,"run":..,"host_os":..,"rig":..}
//!
//! `condition` and `pair` are the scoreboard row's words. The rig is the real phone `Link` and the real Mac
//! `Link` over a real cmux-wg tunnel on loopback, every datagram either tunnel receives going through a named
//! cmux-fault profile (`testing::shape_by_profile`, the `UdpShaper` model). Signaling is the in-process fake
//! on loopback, unshaped: a "link up" here is the WireGuard dial and one answered request across the shaped
//! path, not the Worker's signaling round trips.
//!
//! Env: `SCOREBOARD_N` (runs, 3), `SCOREBOARD_SEED_BASE` (0), `SCOREBOARD_IDLE_SECS` (idle window, 120),
//! `SCOREBOARD_IDLE_PROFILE` (lte). Run (release, one test at a time, the profile is process-wide):
//! `cargo test --release -p cmux-mobile-link --test scoreboard_rows -- --ignored --nocapture --test-threads 1`

use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

use bytes::Bytes;
use cmux_mobile_link::dial::{self, SessionEvents, wireguard};
use cmux_mobile_link::testing::{
    FakeOptions, FakeSignaling, LinkProfile, set_link_profile, shape_by_profile,
};
use cmux_mobile_link::{
    ChannelEvent, Connected, DialOptions, IncomingChannel, Lane, LinkConfig, SignalingClient, TransportKind,
};
use serde_json::{Value, json};
use tokio::time::Instant;

const FILE: &str = "scoreboard_rows.rs";
const FLOOD_BYTES: usize = 8 * 1024 * 1024;
const BULK_BYTES: usize = 4 * 1024 * 1024;
/// IPv4 header (20) plus UDP header (8): what a radio sends beyond the datagram's payload.
const IP_UDP_OVERHEAD: u64 = 28;

fn env_u64(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

fn ms(d: Duration) -> f64 {
    (d.as_secs_f64() * 10_000.0).round() / 10.0
}

#[allow(clippy::too_many_arguments)] // one SCOREROW line's columns
fn row(
    condition: &str,
    pair: &str,
    metric: &str,
    value: Option<f64>,
    unit: &str,
    run: u64,
    rig: &str,
    extra: Value,
) {
    let mut line = json!({
        "condition": condition, "pair": pair, "metric": metric, "value": value, "unit": unit, "run": run,
        "host_os": std::env::consts::OS, "rig": format!("{FILE}::{rig}"),
    });
    if let (Some(line), Some(extra)) = (line.as_object_mut(), extra.as_object()) {
        line.extend(extra.clone());
    }
    println!("SCOREROW {line}");
}

fn na(condition: &str, pair: &str, metric: &str, reason: &str) {
    println!(
        "SCOREROW-NA {}",
        json!({"condition": condition, "pair": pair, "metric": metric, "reason": reason,
               "host_os": std::env::consts::OS, "rig": format!("{FILE}::harness_missing_rows")})
    );
}

// ---------------------------------------------------------------------------------------------
// The rig

static PHONE_SENT: AtomicU64 = AtomicU64::new(0);
static PHONE_DATAGRAMS: AtomicU64 = AtomicU64::new(0);
static MAC_SENT: AtomicU64 = AtomicU64::new(0);
static MAC_DATAGRAMS: AtomicU64 = AtomicU64::new(0);
static SINK_BYTES: AtomicU64 = AtomicU64::new(0);

fn count_phone(_: &SocketAddr, len: usize) {
    PHONE_SENT.fetch_add(len as u64, Ordering::Relaxed);
    PHONE_DATAGRAMS.fetch_add(1, Ordering::Relaxed);
}

fn count_mac(_: &SocketAddr, len: usize) {
    MAC_SENT.fetch_add(len as u64, Ordering::Relaxed);
    MAC_DATAGRAMS.fetch_add(1, Ordering::Relaxed);
}

/// Bytes both ends handed the OS so far, IP and UDP headers included, and the datagram count.
fn wire_now() -> (u64, u64) {
    let datagrams = PHONE_DATAGRAMS.load(Ordering::Relaxed) + MAC_DATAGRAMS.load(Ordering::Relaxed);
    let payload = PHONE_SENT.load(Ordering::Relaxed) + MAC_SENT.load(Ordering::Relaxed);
    (payload + datagrams * IP_UDP_OVERHEAD, datagrams)
}

fn shaped_options(counted: bool) -> (DialOptions, DialOptions) {
    // A lost handshake message costs WireGuard a 5 s retry: room for a few, and for a 600 ms round trip.
    let base = DialOptions {
        include_loopback: true,
        impair_inbound: Some(shape_by_profile),
        timeout: Duration::from_secs(60),
        ..DialOptions::default()
    };
    if !counted {
        return (base.clone(), base);
    }
    (
        DialOptions { on_udp_sent: Some(count_phone), ..base.clone() },
        DialOptions { on_udp_sent: Some(count_mac), ..base },
    )
}

/// The Mac's end of the screen channel the phone opened (`screen`): `echo-screen` keys come back on it.
static SCREEN_OUT: std::sync::Mutex<Option<Arc<cmux_mobile_link::link::ChannelSender>>> =
    std::sync::Mutex::new(None);

/// What the Mac serves: `echo` (every byte back), `sink` (counts bytes) and `flood` (the first message is a
/// decimal byte count; the Mac then streams that many bytes in 16 KB sends, as a tool's output).
async fn serve(incoming: IncomingChannel) {
    let service = incoming.service.clone();
    let (sender, mut receiver) = incoming.channel.split();
    match service.as_str() {
        "echo" => {
            while let Some(ChannelEvent::Data(bytes)) = receiver.recv().await {
                if sender.send(bytes).await.is_err() {
                    return;
                }
            }
        }
        // The phone's screen channel (`Link::open_screen`): held for `echo-screen`, whose keys are answered on
        // it as a terminal's screen update is, over screen datagrams when both ends agreed them.
        "screen" => {
            *SCREEN_OUT.lock().unwrap() = Some(Arc::new(sender));
            while receiver.recv().await.is_some() {}
        }
        "echo-screen" => {
            while let Some(ChannelEvent::Data(bytes)) = receiver.recv().await {
                let out = SCREEN_OUT.lock().unwrap().clone();
                let Some(out) = out else { continue };
                if out.send_screen(None, &bytes).await.is_err() {
                    return;
                }
            }
        }
        "sink" => {
            while let Some(ChannelEvent::Data(bytes)) = receiver.recv().await {
                SINK_BYTES.fetch_add(bytes.len() as u64, Ordering::Relaxed);
            }
        }
        "flood" => {
            let Some(ChannelEvent::Data(ask)) = receiver.recv().await else { return };
            let total: usize = String::from_utf8_lossy(&ask).trim().parse().unwrap_or(0);
            let chunk = Bytes::from(vec![b'x'; 16 * 1024]);
            let mut sent = 0;
            while sent < total {
                let n = chunk.len().min(total - sent);
                if sender.send(chunk.slice(..n)).await.is_err() {
                    return;
                }
                sent += n;
            }
            while receiver.recv().await.is_some() {}
        }
        _ => {}
    }
}

/// A Mac that answers every dial with `options` and serves [`serve`]'s channels. Returns its id.
async fn start_mac(server: &FakeSignaling, options: DialOptions) -> String {
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id)
        .await
        .expect("mac signaling");
    tokio::spawn(async move {
        while let Some(session) = mac.next_session().await {
            let events = SessionEvents {
                backend: mac.events(),
                session_id: session.first.session_id.clone(),
                session: session.events,
            };
            let (mac, options) = (mac.clone(), options.clone());
            tokio::spawn(async move {
                let Ok(connected) =
                    dial::answer(&mac, session.first, events, &options, LinkConfig::default()).await
                else {
                    return;
                };
                while let Some(incoming) = connected.link.accept().await {
                    tokio::spawn(serve(incoming));
                }
            });
        }
    });
    mac_id
}

struct Phone {
    connected: Connected,
    dial_ms: f64,
    _signaling: SignalingClient,
    _server: FakeSignaling,
}

/// A fresh server, Mac and phone under `profile` (seeded), the phone dialed over WireGuard. `Err` is the
/// dial's error. `dial_ms` is `dial::connect`'s return.
async fn dial_phone(
    profile: Option<&str>,
    seed: u64,
    config: LinkConfig,
    counted: bool,
) -> Result<Phone, String> {
    set_link_profile(profile.map(LinkProfile::named), seed);
    let (phone_options, mac_options) = shaped_options(counted);
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = start_mac(&server, mac_options).await;
    let phone_id = uuid::Uuid::new_v4().to_string();
    let signaling = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id)
        .await
        .map_err(|e| format!("phone signaling: {e}"))?;
    let t0 = Instant::now();
    let connected = dial::connect(&signaling, &mac_id, TransportKind::WireGuard, &phone_options, config)
        .await
        .map_err(|e| format!("dial: {e}"))?;
    Ok(Phone { connected, dial_ms: ms(t0.elapsed()), _signaling: signaling, _server: server })
}

/// One byte out on `channel`, its echo back: the time in ms, or `None` past 30 s.
async fn echo_once(channel: &mut cmux_mobile_link::Channel, byte: u8) -> Option<f64> {
    let t = Instant::now();
    channel.send(Bytes::from(vec![byte])).await.ok()?;
    match tokio::time::timeout(Duration::from_secs(30), channel.recv()).await {
        Ok(Some(ChannelEvent::Data(_))) => Some(ms(t.elapsed())),
        _ => None,
    }
}

/// [`echo_once`], the echo read from `screen` when there is one (messages older than the key are skipped).
async fn echo_via(
    keys: &mut cmux_mobile_link::Channel,
    screen: Option<&mut cmux_mobile_link::Channel>,
    byte: u8,
) -> Option<f64> {
    let Some(screen) = screen else { return echo_once(keys, byte).await };
    let t = Instant::now();
    keys.send(Bytes::from(vec![byte])).await.ok()?;
    loop {
        match tokio::time::timeout(Duration::from_secs(30), screen.recv()).await {
            Ok(Some(ChannelEvent::Data(bytes))) => {
                // A screen message is `[seq][base][payload]`; plain (no screen class) is the payload.
                let payload = match cmux_mobile_link::classes::screen_message(&bytes) {
                    Some(message) if screen.screen_class() => message.payload,
                    _ => bytes,
                };
                if payload.first() == Some(&byte) {
                    return Some(ms(t.elapsed()));
                }
            }
            _ => return None,
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Satellite 600 ms and airplane Wi-Fi: link up, and a typed key's remote echo

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "scoreboard bench: run with --ignored --nocapture --test-threads 1"]
async fn link_up_satellite_and_airplane() {
    let runs = env_u64("SCOREBOARD_N", 3);
    let seed_base = env_u64("SCOREBOARD_SEED_BASE", 0);
    for (profile, condition) in [("satellite-600", "satellite 600 ms"), ("airplane-wifi", "airplane Wi-Fi")] {
        for run in 0..runs {
            let rig = "link_up_satellite_and_airplane";
            let extra = json!({"profile": format!("{profile}@1")});
            let started = Instant::now();
            let phone = match dial_phone(Some(profile), seed_base + run, LinkConfig::default(), false).await {
                Ok(phone) => phone,
                Err(error) => {
                    let extra = json!({"profile": format!("{profile}@1"), "error": error});
                    row(condition, "iOS→Mac", "link_up_ms", None, "ms", run, rig, extra);
                    continue;
                }
            };
            // Link up as netlab counts it: the dial and one answered request.
            let mut echo = phone.connected.link.open("echo", json!({})).await.expect("open echo");
            let first = echo_once(&mut echo, 0).await;
            let up = first.map(|_| ms(started.elapsed()));
            row(condition, "iOS→Mac", "dial_ms", Some(phone.dial_ms), "ms", run, rig, extra.clone());
            match up {
                Some(up) => row(condition, "iOS→Mac", "link_up_ms", Some(up), "ms", run, rig, extra.clone()),
                None => {
                    let extra = json!({"profile": format!("{profile}@1"), "error": "no echo in 30 s"});
                    row(condition, "iOS→Mac", "link_up_ms", None, "ms", run, rig, extra);
                }
            }
            if condition == "satellite 600 ms" {
                // The remote echo of ten typed keys on the input lane (what the phone shows when it does
                // not predict); the predicted echo is prediction_latency.rs's satellite test.
                let mut keys =
                    phone.connected.link.open_on("echo", json!({}), Lane::Input).await.expect("open keys");
                let mut samples = Vec::new();
                for i in 0..11u8 {
                    if let Some(sample) = echo_once(&mut keys, i).await
                        && i > 0
                    {
                        samples.push(sample); // the first key warms the lane
                    }
                }
                for sample in samples {
                    row(
                        condition,
                        "iOS→Mac",
                        "keystroke_echo_remote_ms",
                        Some(sample),
                        "ms",
                        run,
                        rig,
                        extra.clone(),
                    );
                }
            }
            phone.connected.link.close("done");
        }
    }
    set_link_profile(None, 0);
}

// ---------------------------------------------------------------------------------------------
// Keystroke echo p95 during 8 MB of tool output

/// Keys typed on the input lane while the Mac streams 8 MB on a bulk channel (a tool's output). Only keys
/// sent while the flood still runs count as `during`; the same keys on a quiet link are `idle`.
async fn keystroke_run(profile: &str, seed: u64, flood: bool) -> Result<Vec<f64>, String> {
    let phone = dial_phone(Some(profile), seed, LinkConfig::default(), false).await?;
    let link = &phone.connected.link;
    // SCOREBOARD_ECHO=screen: the echo comes back on a screen channel (the daemon channel's path), not
    // on the keys channel.
    let screen = std::env::var("SCOREBOARD_ECHO").is_ok_and(|value| value == "screen");
    let mut keys = if screen {
        link.open_on("echo-screen", json!({}), Lane::Input).await
    } else {
        link.open_on("echo", json!({}), Lane::Input).await
    }
    .map_err(|e| format!("open keys: {e}"))?;
    let mut screen_channel = if screen {
        let channel = link.open_screen("screen", json!({})).await.map_err(|e| format!("open screen: {e}"))?;
        // The open reaches the Mac before the first key does only on the same stream; wait for it.
        tokio::time::sleep(Duration::from_millis(500)).await;
        Some(channel)
    } else {
        None
    };
    for i in 0..3u8 {
        echo_via(&mut keys, screen_channel.as_mut(), i).await.ok_or("warm-up key not echoed")?;
    }
    let running = Arc::new(AtomicBool::new(false));
    let drain = if flood {
        let mut output =
            link.open_on("flood", json!({}), Lane::Bulk).await.map_err(|e| format!("open flood: {e}"))?;
        output.send(Bytes::from(FLOOD_BYTES.to_string())).await.map_err(|e| format!("ask flood: {e}"))?;
        running.store(true, Ordering::Relaxed);
        let running = Arc::clone(&running);
        Some(tokio::spawn(async move {
            let mut got = 0usize;
            while got < FLOOD_BYTES {
                match output.recv().await {
                    Some(ChannelEvent::Data(bytes)) => got += bytes.len(),
                    _ => break,
                }
            }
            running.store(false, Ordering::Relaxed);
            got
        }))
    } else {
        None
    };
    tokio::time::sleep(Duration::from_millis(200)).await;
    let mut samples = Vec::new();
    for i in 0..40u32 {
        let tick = Instant::now();
        if flood && !running.load(Ordering::Relaxed) {
            break;
        }
        if let Some(sample) = echo_via(&mut keys, screen_channel.as_mut(), i as u8).await
            && (!flood || running.load(Ordering::Relaxed))
        {
            samples.push(sample);
        }
        tokio::time::sleep(Duration::from_millis(100).saturating_sub(tick.elapsed())).await;
    }
    if let Some(drain) = drain {
        let got = tokio::time::timeout(Duration::from_secs(120), drain)
            .await
            .map_err(|_| "flood not delivered in 120 s")?;
        let got = got.map_err(|e| format!("drain: {e}"))?;
        if got != FLOOD_BYTES {
            return Err(format!("flood delivered {got} of {FLOOD_BYTES} bytes"));
        }
    }
    phone.connected.link.close("done");
    Ok(samples)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "scoreboard bench: run with --ignored --nocapture --test-threads 1"]
async fn keystroke_echo_during_8mb_output() {
    let runs = env_u64("SCOREBOARD_N", 3);
    let seed_base = env_u64("SCOREBOARD_SEED_BASE", 0);
    let profile = std::env::var("SCOREBOARD_KEY_PROFILE").unwrap_or_else(|_| "lte".into());
    let condition = "keystroke during 8 MB tool output";
    let rig = "keystroke_echo_during_8mb_output";
    let extra = json!({"profile": format!("{profile}@1"), "flood_bytes": FLOOD_BYTES});
    for run in 0..runs {
        for (flood, metric) in [(false, "keystroke_echo_idle_ms"), (true, "keystroke_echo_during_flood_ms")] {
            match keystroke_run(&profile, seed_base + run, flood).await {
                Ok(samples) if !samples.is_empty() => {
                    for sample in samples {
                        row(condition, "iOS→Mac", metric, Some(sample), "ms", run, rig, extra.clone());
                    }
                }
                Ok(_) => {
                    let extra = json!({"profile": format!("{profile}@1"), "error": "no key sent while the flood ran"});
                    row(condition, "iOS→Mac", metric, None, "ms", run, rig, extra);
                }
                Err(error) => {
                    let extra = json!({"profile": format!("{profile}@1"), "error": error});
                    row(condition, "iOS→Mac", metric, None, "ms", run, rig, extra);
                }
            }
        }
    }
    set_link_profile(None, 0);
}

// ---------------------------------------------------------------------------------------------
// Idle link bytes per hour, foreground

/// One idle window on one link: bytes (IP level, both ends, both ways) a `window` of nothing costs, scaled to
/// an hour. The tunnel's own timers are periodic (the link's 15 s ping, WireGuard's keepalive and its 120 s
/// rekey), so a window of one rekey period scaled by 3600/window is the hour's cost; it is not run for an hour.
async fn idle_run(
    profile: &str,
    seed: u64,
    foreground: bool,
    window: Duration,
) -> Result<(f64, u64, u64), String> {
    let config = LinkConfig { foreground_probe: foreground, ..LinkConfig::default() };
    let phone = dial_phone(Some(profile), seed, config, true).await?;
    tokio::time::sleep(Duration::from_secs(10)).await; // past the handshake and the first exchanges
    let (from, from_datagrams) = wire_now();
    tokio::time::sleep(window).await;
    let (to, to_datagrams) = wire_now();
    if phone.connected.link.is_closed() {
        return Err("the link closed during the idle window".into());
    }
    phone.connected.link.close("done");
    let bytes = to - from;
    Ok((bytes as f64 * 3600.0 / window.as_secs_f64(), bytes, to_datagrams - from_datagrams))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "scoreboard bench: about 2.5 minutes a run; --ignored --nocapture --test-threads 1"]
async fn idle_link_bytes_per_hour() {
    let runs = env_u64("SCOREBOARD_N", 3);
    let seed_base = env_u64("SCOREBOARD_SEED_BASE", 0);
    let window = Duration::from_secs(env_u64("SCOREBOARD_IDLE_SECS", 120));
    let profile = std::env::var("SCOREBOARD_IDLE_PROFILE").unwrap_or_else(|_| "lte".into());
    let rig = "idle_link_bytes_per_hour";
    for (foreground, count) in [(true, runs), (false, 1)] {
        for run in 0..count {
            let extra = json!({"profile": format!("{profile}@1"), "foreground_probe": foreground,
                               "window_s": window.as_secs(), "scaling": "bytes in window x 3600 / window_s, IP+UDP headers included"});
            match idle_run(&profile, seed_base + run, foreground, window).await {
                Ok((per_hour, bytes, datagrams)) => {
                    let mut extra = extra;
                    extra["window_bytes"] = json!(bytes);
                    extra["window_datagrams"] = json!(datagrams);
                    let metric =
                        if foreground { "idle_bytes_per_hour" } else { "idle_bytes_per_hour_probe_off" };
                    row(
                        "idle link, foreground",
                        "iOS→Mac",
                        metric,
                        Some(per_hour.round()),
                        "B/h",
                        run,
                        rig,
                        extra,
                    );
                }
                Err(error) => {
                    let mut extra = extra;
                    extra["error"] = json!(error);
                    row(
                        "idle link, foreground",
                        "iOS→Mac",
                        "idle_bytes_per_hour",
                        None,
                        "B/h",
                        run,
                        rig,
                        extra,
                    );
                }
            }
        }
    }
    set_link_profile(None, 0);
}

// ---------------------------------------------------------------------------------------------
// Metered cell: bulk bytes sent with the cellular flag set

/// The app says the path is cellular (`NetworkPathMonitor.swift:58` -> `set_cellular_path`), then sends 4 MB
/// on a bulk channel. The only thing that flag gates is the tunnel's repair data (`wireguard.rs`
/// `ultra_for_dial`, `cmux-wg/src/ultra.rs` `set_metered`); a bulk send has no gate, so all of it goes.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "scoreboard bench: run with --ignored --nocapture --test-threads 1"]
async fn metered_cell_bulk_bytes() {
    let runs = env_u64("SCOREBOARD_N", 3);
    let rig = "metered_cell_bulk_bytes";
    for run in 0..runs {
        wireguard::set_cellular_path(true);
        let outcome = async {
            let phone = dial_phone(None, run, LinkConfig::default(), true).await?;
            let sink = phone
                .connected
                .link
                .open_on("sink", json!({}), Lane::Bulk)
                .await
                .map_err(|e| e.to_string())?;
            let (sender, _receiver) = sink.split();
            SINK_BYTES.store(0, Ordering::Relaxed);
            let (before, _) = wire_now();
            let chunk = Bytes::from(vec![7u8; 16 * 1024]);
            let mut sent = 0;
            while sent < BULK_BYTES {
                sender.send(chunk.clone()).await.map_err(|e| e.to_string())?;
                sent += chunk.len();
            }
            let deadline = Instant::now() + Duration::from_secs(60);
            while SINK_BYTES.load(Ordering::Relaxed) < BULK_BYTES as u64 && Instant::now() < deadline {
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
            let (after, _) = wire_now();
            let arrived = SINK_BYTES.load(Ordering::Relaxed);
            phone.connected.link.close("done");
            Ok::<_, String>((after - before, arrived))
        }
        .await;
        wireguard::set_cellular_path(false);
        match outcome {
            Ok((wire, arrived)) => row(
                "metered cell",
                "iOS→Mac",
                "bulk_bytes_sent_on_cellular",
                Some(arrived as f64),
                "B",
                run,
                rig,
                json!({"attempted": BULK_BYTES, "wire_bytes_both_ways": wire, "cellular_path": true, "consent_asked": false,
                       "gate": "none on bulk; the flag only caps repair data (wireguard.rs ultra_for_dial, ultra.rs set_metered)"}),
            ),
            Err(error) => row(
                "metered cell",
                "iOS→Mac",
                "bulk_bytes_sent_on_cellular",
                None,
                "B",
                run,
                rig,
                json!({"error": error}),
            ),
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Rows no harness here can measure

/// The scoreboard's other dash rows, each with what it needs. Printed (not skipped) so the table says why.
#[test]
#[ignore = "scoreboard bench: run with --ignored --nocapture"]
fn harness_missing_rows() {
    na(
        "captive portal",
        "all",
        "time to \"sign in\" notice; cell stays live",
        "harness missing: captive-portal node (HTTP 302 until signed in) in netlab; the app has no 204 probe or sign-in notice to time (grep generate_204 and captive in cmux-next-ios/CmuxMobileKit: none)",
    );
    na(
        "explicit proxy, 443 only",
        "iOS→Mac, Mac→Cloud",
        "link up",
        "harness missing: explicit-proxy node with CONNECT-only egress in netlab (topologies have NAT sites only); the phone link also has no proxy code to measure (cmux-mobile-link/src has no proxy handling)",
    );
    na(
        "TLS-inspecting proxy",
        "iOS→Mac, Mac→Cloud",
        "link up",
        "harness missing: re-signing proxy node (mitmproxy with the lab CA; netlab services/gen-certs.sh makes the CA, no node uses it); no proxy code in cmux-mobile-link either",
    );
    na(
        "IPv6-only, NAT64",
        "iOS→Mac",
        "link up",
        "harness missing: IPv6-only site with DNS64/NAT64 (Jool or Tayga) in netlab (its address plan is IPv4 198.18.0.0/15 only)",
    );
    na(
        "peer nearby, no internet",
        "iOS→Mac, Mac→Mac",
        "link up",
        "harness missing: offline-LAN topology (no route to the inet node) in netlab; the dial needs signaling, so it fails by construction until local discovery exists (hq ultra-connectivity.md section 3, P7)",
    );
    na(
        "idle link, background",
        "iOS→Mac",
        "energy per hour (Instruments)",
        "harness missing: device Instruments (Energy Log on a real iPhone, background, an hour); no simulator or Linux runner reports energy",
    );
}
