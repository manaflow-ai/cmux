//! Mac terminal scroll to iPhone terminal paint, split into legs, over the pair matrix's network
//! (Leo, 2026-11-22: "the scroll occurs or whatever on f***ing mac / then it delays on my actual
//! iphone display. thats the asinine part.").
//!
//! The path is the real one from the daemon socket to the phone's projection:
//!
//! - a stand-in cmux-tui session socket (`main.sock`) writes a scrolling full-screen terminal
//!   (40 rows of 100 columns, every redraw moves the text up a row, 60 redraws a second) as
//!   `output` lines, and records when it wrote each one (`t_daemon`);
//! - the real host `daemon` service splices it (`serve`, `splice`, `pseq` stamps: hostd's read
//!   `produced` and the link writer's flush `flushed`, `paint_latency::lookup`);
//! - the real Mac and phone `Link`s, dialed over cmux-wg (`dial::answer`, `dial::connect`), every
//!   datagram either tunnel receives through the pair matrix's hook (`shape_by_profile`), on the
//!   `direct` path (plain UDP on loopback) or the `relay` path (`relay_only` through a
//!   `TestTurn`);
//! - the phone: the line's JSON and base64 (`decoded`), then the phone's own Rust projection
//!   (`cmux_terminal_projection::Projection::feed(.., paint: true)`, `painted`).
//!
//! Legs per redraw, ms, on one clock (one process):
//! `daemon` (daemon write to hostd read), `mac` (hostd read to link flush: splice, policy, the
//! link's outbox and writer), `wire` (flush to the phone channel's event: WireGuard, smoltcp, the
//! shaped network, the phone's link reader), `decode` (JSON and base64), `paint` (projection
//! feed and paint), `total` (daemon write to painted). The phone's UIKit present (one display
//! frame at most, 16.7 ms, plus its draw, 6.4-12.7 ms p50 in the simulator, cmux#50617) is not in
//! `total`.
//!
//! Loads: `idle` (only the scroll), `duress` (the scroll while a second daemon channel on the
//! same link streams a long agent session's output, [`AGENT_CHUNK`] bytes every [`AGENT_EVERY`],
//! and [`BURNERS`] CPU burner threads at 50% duty, cmux-duress's preset).
//!
//! `cargo test --release -p cmux-mobile-host --test scroll_paint_legs -- --ignored --nocapture --test-threads 1`
//! env: `LEGS_TRIALS` (3), `LEGS_PROFILES` (`rtt-400,lossy-3`), `LEGS_PATHS` (`direct,relay`),
//! `LEGS_LOADS` (`idle,duress`). Prints one `LEGS-ROW` line per trial and one `LEGS-CELL {json}`
//! per cell (the median of its trials' p50 and p95 per leg).
//!
//! `shown` is the headline: daemon write of redraw `i` to the first phone paint whose screen shows
//! redraw `i` or a newer one, on any path. With `CMUX_MOBILE_VIEWPORT_SYNC=1` (cmux#50638, off by
//! default: hostd's gate and the phone's) the screen goes as newest-wins datagrams and only
//! `shown` (and `paint`) apply; the stream legs need the stream's own redraw lines.
//! `CMUX_MOBILE_VIEWPORT_SKIP_SUPERSEDED=1` (off by default) adds the switch's skip of the stream
//! batches still queued; `shown_late` is the second half's `shown`, past the switch.

use std::hint::black_box;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::Engine as _;
use bytes::Bytes;
use cmux_mobile_host::config::{AcpmuxTarget, ServiceConfig};
use cmux_mobile_host::paint_latency;
use cmux_mobile_host::pairing::LinkAuth;
use cmux_mobile_host::services::{Peer, serve};
use cmux_mobile_link::dial::{self, SessionEvents};
use cmux_mobile_link::frame::epoch_us;
use cmux_mobile_link::testing::{
    FakeOptions, FakeSignaling, LinkProfile, TestTurn, set_link_profile, shape_by_profile,
};
use cmux_mobile_link::{ChannelEvent, Connected, DialOptions, LinkConfig, SignalingClient, TransportKind};
use serde_json::json;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::time::Instant;

const ROWS: usize = 40;
const COLS: usize = 100;
/// Redraws per trial (5 s at 60 Hz).
const REDRAWS: usize = 300;
const EVERY: Duration = Duration::from_micros(16_667);
/// Duress: the agent session's output, this many bytes this often (200 KB/s, a build log).
const AGENT_CHUNK: usize = 2048;
const AGENT_EVERY: Duration = Duration::from_millis(10);
/// Duress: cmux-duress's CPU preset, 2 burner threads at 50% duty.
const BURNERS: usize = 2;
const BOUND: Duration = Duration::from_secs(120);

fn b64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

// ---------------------------------------------------------------------------------------------
// The network: the pair matrix's hook

static WIRE_BYTES: AtomicU64 = AtomicU64::new(0);

fn impair(via_turn: bool, from: &SocketAddr, len: usize) -> Option<Duration> {
    WIRE_BYTES.fetch_add(len as u64, Ordering::Relaxed);
    shape_by_profile(via_turn, from, len)
}

/// The pair matrix's conditions (pair_matrix_ios_mac.rs `profile_for`): `rtt-400` is the `lte`
/// rate at 400 ms RTT with no loss; anything else a link-profiles.json row.
fn profile(name: &str) -> LinkProfile {
    match name {
        "rtt-400" => LinkProfile {
            name: "rtt-400".into(),
            up_kbit: 12_000,
            down_kbit: 12_000,
            rtt_ms: 400,
            jitter_ms: 0,
            loss_percent: 0.0,
        },
        other => LinkProfile::named(other),
    }
}

// ---------------------------------------------------------------------------------------------
// The stand-in daemon

/// The screen after `i` rows of scrolling: every row repainted, its text one row further on.
fn scrolled_screen(i: usize) -> Vec<u8> {
    let mut raw = Vec::with_capacity(ROWS * (COLS + 24));
    for r in 0..ROWS {
        let line = i + r;
        raw.extend_from_slice(format!("\x1b[{};1H\x1b[2K\x1b[38;5;{}m", r + 1, 16 + line % 216).as_bytes());
        let text =
            format!("{line:>6} | scrolling the transcript, one row per redraw, the way a pager repaints ");
        raw.extend(text.bytes().cycle().take(COLS - 8));
        raw.extend_from_slice(b"\x1b[0m");
    }
    raw
}

/// An agent's streamed output: prose and tool output lines, about `bytes`.
fn agent_chunk(n: u64) -> Vec<u8> {
    let mut out = Vec::with_capacity(AGENT_CHUNK + 128);
    let mut k = 0u64;
    while out.len() < AGENT_CHUNK {
        out.extend_from_slice(
            format!("\r\n   Compiling crate-{n}-{k} v0.1.0 (/src/crates/crate-{k}) warning: unused variable `x{k}`")
                .as_bytes(),
        );
        k += 1;
    }
    out
}

/// When the daemon wrote redraw `i` (epoch µs), for this trial.
struct Written(Vec<AtomicI64>);

fn fake_daemon(dir: &std::path::Path, written: Arc<Mutex<Arc<Written>>>) {
    let listener = tokio::net::UnixListener::bind(dir.join("main.sock")).unwrap();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            let written = Arc::clone(&written);
            tokio::spawn(async move {
                let (read, write) = stream.into_split();
                let write = Arc::new(tokio::sync::Mutex::new(write));
                let mut lines = BufReader::new(read).lines();
                // Every request answered `ok`; only `attach-surface` starts a stream. hostd's own
                // connections (the workspace cache's queries) get answers and nothing else.
                while let Ok(Some(line)) = lines.next_line().await {
                    let Ok(request) = serde_json::from_str::<serde_json::Value>(&line) else { continue };
                    let answer = json!({"id": request["id"], "ok": true, "data": {}});
                    if write.lock().await.write_all(format!("{answer}\n").as_bytes()).await.is_err() {
                        return;
                    }
                    if request["cmd"] != "attach-surface" {
                        continue;
                    }
                    let surface = request["surface"].clone();
                    let write = Arc::clone(&write);
                    if request["mode"] == "agent" {
                        tokio::spawn(async move {
                            let mut tick = tokio::time::interval(AGENT_EVERY);
                            for n in 0.. {
                                tick.tick().await;
                                let event = json!({"event": "output", "surface": surface, "data": b64(&agent_chunk(n))});
                                if write
                                    .lock()
                                    .await
                                    .write_all(format!("{event}\n").as_bytes())
                                    .await
                                    .is_err()
                                {
                                    return;
                                }
                            }
                        });
                        continue;
                    }
                    let written = Arc::clone(&written.lock().unwrap());
                    tokio::spawn(async move {
                        // The attach's state first (cmux-tui `vt-state`): a blank screen at the grid,
                        // what a viewport sync primes its model from.
                        let state = json!({"event": "vt-state", "surface": surface, "cols": COLS, "rows": ROWS,
                            "data": b64(b"\x1b[H\x1b[2J")});
                        if write.lock().await.write_all(format!("{state}\n").as_bytes()).await.is_err() {
                            return;
                        }
                        let mut tick = tokio::time::interval(EVERY);
                        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Burst);
                        for i in 0..REDRAWS {
                            tick.tick().await;
                            let event = json!({"event": "output", "surface": surface, "i": i, "data": b64(&scrolled_screen(i))});
                            let bytes = format!("{event}\n");
                            written.0[i].store(epoch_us(), Ordering::Relaxed);
                            if write.lock().await.write_all(bytes.as_bytes()).await.is_err() {
                                return;
                            }
                        }
                    });
                }
            });
        }
    });
}

// ---------------------------------------------------------------------------------------------
// The rig: the Mac answering with the host's services, the phone dialing

#[derive(Clone, Copy, PartialEq, Eq)]
enum Path {
    Direct,
    Relay,
}

struct Rig {
    _dir: tempfile::TempDir,
    _signaling: FakeSignaling,
    _turns: Vec<TestTurn>,
    mac: tokio::task::JoinHandle<()>,
    phone: SignalingClient,
    mac_id: String,
    options: DialOptions,
    written: Arc<Mutex<Arc<Written>>>,
}

impl Drop for Rig {
    fn drop(&mut self) {
        self.mac.abort();
    }
}

fn base_options() -> DialOptions {
    DialOptions {
        include_loopback: true,
        impair_inbound: Some(impair),
        timeout: Duration::from_secs(40),
        ..DialOptions::default()
    }
}

impl Rig {
    async fn start(path: Path) -> Self {
        let dir = tempfile::tempdir().expect("tempdir");
        let written = Arc::new(Mutex::new(Arc::new(Written(Vec::new()))));
        fake_daemon(dir.path(), Arc::clone(&written));
        let mut turns = Vec::new();
        if path == Path::Relay {
            turns.push(TestTurn::start().await);
        }
        let ice: Vec<_> = turns.iter().map(TestTurn::udp_only).collect();
        let options =
            DialOptions { relay_only: path == Path::Relay, ice_servers: ice.clone(), ..base_options() };
        let mac_options = DialOptions { ice_servers: ice, ..base_options() };
        let config = Arc::new(ServiceConfig {
            tui_socket_dir: dir.path().to_owned(),
            default_session: "main".into(),
            default_socket: None,
            file_roots: vec![],
            acpmux: AcpmuxTarget::Fixed { url: "ws://127.0.0.1:9".into(), token: None },
            pairing: None,
            agent_tab_host: None,
            uploads_dir: dir.path().join("uploads"),
            chief_socket: None,
            browser: cmux_mobile_host::browser::BrowserConfig::new(None, 1),
            surface: cmux_mobile_host::surface::SurfaceConfig::new(None, 1),
            // The flag under test: viewport sync (cmux#50638), hostd's own gate.
            viewport_sync: cmux_mobile_host::viewport_sync::enabled()
                .then(cmux_mobile_host::viewport_sync::SelectorConfig::default),
        });
        let signaling = FakeSignaling::start(FakeOptions::default()).await;
        let mac_id = uuid::Uuid::new_v4().to_string();
        let mac_client = SignalingClient::connect(&signaling.base_url, "user:alice", "team", &mac_id)
            .await
            .expect("mac signaling");
        let mac = tokio::spawn(async move {
            let mut links = tokio::task::JoinSet::new();
            while let Some(session) = mac_client.next_session().await {
                let events = SessionEvents {
                    backend: mac_client.events(),
                    session_id: session.first.session_id.clone(),
                    session: session.events,
                };
                let (mac_client, options, config) =
                    (mac_client.clone(), mac_options.clone(), Arc::clone(&config));
                links.spawn(async move {
                    let Ok(connected) =
                        dial::answer(&mac_client, session.first, events, &options, LinkConfig::default())
                            .await
                    else {
                        return;
                    };
                    let mut services = tokio::task::JoinSet::new();
                    // As host.rs: the link's overlay datagram hub, when it rides WireGuard.
                    let hub = connected
                        .overlay
                        .clone()
                        .map(|overlay| Arc::new(cmux_mobile_host::viewport_link::LinkHub::new(overlay)));
                    while let Some(incoming) = connected.link.accept().await {
                        services.spawn(serve(
                            Arc::clone(&config),
                            Peer {
                                device_id: "scroll-legs-phone".into(),
                                session_id: connected.session_id.clone(),
                                video: None,
                                session_exposure: None,
                                route: None,
                                path: Some(connected.path.clone()),
                                viewport: hub.clone(),
                            },
                            Arc::new(LinkAuth::default()),
                            incoming,
                        ));
                    }
                    services.shutdown().await;
                });
            }
            links.shutdown().await;
        });
        let phone_id = uuid::Uuid::new_v4().to_string();
        let phone = SignalingClient::connect(&signaling.base_url, "user:alice", "team", &phone_id)
            .await
            .expect("phone signaling");
        Self { _dir: dir, _signaling: signaling, _turns: turns, mac, phone, mac_id, options, written }
    }

    async fn dial(&self) -> Connected {
        let dial = dial::connect(
            &self.phone,
            &self.mac_id,
            TransportKind::WireGuard,
            &self.options,
            LinkConfig::default(),
        );
        tokio::time::timeout(BOUND, dial).await.expect("dial in bound").expect("dial")
    }
}

// ---------------------------------------------------------------------------------------------
// Duress CPU

struct Burners {
    stop: Arc<AtomicBool>,
    threads: Vec<std::thread::JoinHandle<()>>,
}

impl Burners {
    fn start(n: usize) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let started = std::time::Instant::now();
        let threads = (0..n)
            .map(|_| {
                let stop = Arc::clone(&stop);
                std::thread::spawn(move || {
                    let mut x = 0x9e37_79b9_7f4a_7c15_u64;
                    while !stop.load(Ordering::Relaxed) && started.elapsed() < Duration::from_secs(600) {
                        // 50% duty: 5 ms busy, 5 ms asleep.
                        let busy = std::time::Instant::now();
                        while busy.elapsed() < Duration::from_millis(5) {
                            x = black_box(x.rotate_left(5) ^ x.wrapping_mul(0x2545_f491_4f6c_dd1d));
                        }
                        std::thread::sleep(Duration::from_millis(5));
                    }
                })
            })
            .collect();
        Self { stop, threads }
    }
}

impl Drop for Burners {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        for thread in self.threads.drain(..) {
            let _ = thread.join();
        }
    }
}

// ---------------------------------------------------------------------------------------------
// One trial

#[derive(Default)]
struct Legs {
    daemon: Vec<f64>,
    mac: Vec<f64>,
    wire: Vec<f64>,
    decode: Vec<f64>,
    paint: Vec<f64>,
    total: Vec<f64>,
    shown: Vec<f64>,
    /// `shown` for the second half of the redraws only: the steady state, past any path switch.
    shown_late: Vec<f64>,
}

const LEG_NAMES: [&str; 8] = ["daemon", "mac", "wire", "decode", "paint", "total", "shown", "shown_late"];

impl Legs {
    fn columns(&self) -> [&Vec<f64>; 8] {
        [
            &self.daemon,
            &self.mac,
            &self.wire,
            &self.decode,
            &self.paint,
            &self.total,
            &self.shown,
            &self.shown_late,
        ]
    }
}

/// The redraw the phone's screen shows: its top row's line number (`scrolled_screen`).
fn screen_redraw(projection: &cmux_terminal_projection::Projection) -> Option<usize> {
    let term = projection.terminal();
    let row = term.screen_rows().first()?;
    let text: String = row.cells.iter().take(8).map(|cell| term.cell_text(*cell)).collect();
    text.split('|').next()?.trim().parse().ok()
}

fn pct(values: &[f64], p: f64) -> f64 {
    if values.is_empty() {
        return f64::NAN;
    }
    let mut v = values.to_vec();
    v.sort_by(f64::total_cmp);
    let i = ((v.len() as f64 - 1.0) * p).round() as usize;
    (v[i] * 100.0).round() / 100.0
}

async fn trial(rig: &Rig, duress: bool) -> (Legs, u64) {
    let written = Arc::new(Written((0..REDRAWS).map(|_| AtomicI64::new(0)).collect()));
    *rig.written.lock().unwrap() = Arc::clone(&written);
    let connected = rig.dial().await;
    let link = &connected.link;
    let wire_before = WIRE_BYTES.load(Ordering::Relaxed);

    // Duress: the agent session's channel first, streaming before the scroll starts.
    let mut agent_task = None;
    if duress {
        let mut agent = link.open("daemon", json!({})).await.expect("open agent channel");
        agent
            .send(Bytes::from(format!(
                "{}\n",
                json!({"id": 1, "cmd": "attach-surface", "surface": 2, "mode": "agent"})
            )))
            .await
            .unwrap();
        agent_task = Some(tokio::spawn(async move {
            let mut bytes = 0u64;
            while let Some(event) = agent.recv().await {
                if let ChannelEvent::Data(data) = event {
                    bytes += data.len() as u64;
                }
            }
            bytes
        }));
        tokio::time::sleep(Duration::from_millis(500)).await;
    }

    // The phone's viewport sync, gated as in the app (`CMUX_MOBILE_VIEWPORT_SYNC`).
    let phone_viewport = cmux_mobile_link::viewport::PhoneViewport::new(
        connected.overlay.as_ref(),
        cmux_mobile_link::viewport::enabled(),
    );
    let mut args = json!({});
    phone_viewport.merge_daemon_args(&mut args);
    let (terminal_tx, terminal_rx) = link.open("daemon", args).await.expect("open terminal channel").split();
    let mut terminal = phone_viewport.wrap(terminal_rx);
    terminal_tx
        .send(Bytes::from(format!(
            "{}\n",
            json!({"id": 1, "cmd": "attach-surface", "surface": 1, "mode": "scroll"})
        )))
        .await
        .unwrap();
    let mut projection = cmux_terminal_projection::Projection::new(
        COLS,
        ROWS,
        cmux_terminal_projection::DEFAULT_HISTORY_LIMIT,
    );
    projection.set_viewport(COLS, ROWS);

    // (i, pseq, rx, decoded, painted), epoch ms: the stream's own redraws.
    let mut seen: Vec<(usize, u64, f64, f64, f64)> = Vec::with_capacity(REDRAWS);
    // When the phone's screen first showed redraw i or a newer one, epoch ms: any path (a
    // viewport sync sends the newest state, not every redraw).
    let mut shown: Vec<Option<f64>> = vec![None; REDRAWS];
    let mut pending = Vec::new();
    let deadline = Instant::now() + BOUND;
    while shown[REDRAWS - 1].is_none() {
        let event = tokio::time::timeout_at(deadline, terminal.recv()).await.expect("every redraw in bound");
        let Some(ChannelEvent::Data(bytes)) = event else {
            panic!("terminal channel closed after {}", seen.len())
        };
        let rx = epoch_us() as f64 / 1000.0;
        pending.extend_from_slice(&bytes);
        while let Some(end) = pending.iter().position(|b| *b == b'\n') {
            let line: Vec<u8> = pending.drain(..=end).collect();
            let value: serde_json::Value = serde_json::from_slice(&line).expect("a JSON line");
            if value["event"] != "output" || value["surface"] != 1 {
                continue;
            }
            let vt =
                base64::engine::general_purpose::STANDARD.decode(value["data"].as_str().unwrap()).unwrap();
            let decoded = epoch_us() as f64 / 1000.0;
            black_box(projection.feed(&vt, true));
            let painted = epoch_us() as f64 / 1000.0;
            if let Some(top) = screen_redraw(&projection) {
                for slot in shown.iter_mut().take((top + 1).min(REDRAWS)) {
                    slot.get_or_insert(painted);
                }
            }
            if let (Some(i), Some(seq)) = (value["i"].as_u64(), value["pseq"].as_u64()) {
                seen.push((i as usize, seq, rx, decoded, painted));
            }
        }
    }
    let wire_bytes = WIRE_BYTES.load(Ordering::Relaxed) - wire_before;

    let mut legs = Legs::default();
    for (i, seq, rx, decoded, painted) in seen {
        let daemon = written.0[i].load(Ordering::Relaxed) as f64 / 1000.0;
        let Some((produced, Some(flushed))) = paint_latency::lookup(seq) else { continue };
        let (produced, flushed) = (produced as f64 / 1000.0, flushed as f64 / 1000.0);
        legs.daemon.push(produced - daemon);
        legs.mac.push(flushed - produced);
        legs.wire.push(rx - flushed);
        legs.decode.push(decoded - rx);
        legs.paint.push(painted - decoded);
        legs.total.push(painted - daemon);
    }
    for (i, at) in shown.iter().enumerate() {
        let wrote = written.0[i].load(Ordering::Relaxed);
        if let Some(at) = at
            && wrote > 0
        {
            legs.shown.push(at - wrote as f64 / 1000.0);
            if i >= REDRAWS / 2 {
                legs.shown_late.push(at - wrote as f64 / 1000.0);
            }
        }
    }
    terminal_tx.close("done", "trial over").await;
    link.close("trial over");
    if let Some(task) = agent_task {
        task.abort();
    }
    (legs, wire_bytes)
}

fn env_list(name: &str, default: &str) -> Vec<String> {
    std::env::var(name)
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| default.to_owned())
        .split(',')
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
        .collect()
}

fn median(mut v: Vec<f64>) -> f64 {
    v.sort_by(f64::total_cmp);
    v[v.len() / 2]
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "a measurement (a few minutes): --release --ignored --nocapture"]
async fn mac_scroll_to_phone_paint_legs() {
    let trials: usize = std::env::var("LEGS_TRIALS").ok().and_then(|v| v.parse().ok()).unwrap_or(3);
    let flag = format!(
        "{}+skip:{}",
        std::env::var(cmux_mobile_link::viewport::ENV).unwrap_or_default(),
        std::env::var(cmux_mobile_host::viewport_sync::SKIP_SUPERSEDED_ENV).unwrap_or_default()
    );
    for path_name in env_list("LEGS_PATHS", "direct,relay") {
        let path = if path_name == "relay" { Path::Relay } else { Path::Direct };
        for profile_name in env_list("LEGS_PROFILES", "rtt-400,lossy-3") {
            for load in env_list("LEGS_LOADS", "idle,duress") {
                let duress = load == "duress";
                let mut p50s: Vec<Vec<f64>> = vec![Vec::new(); LEG_NAMES.len()];
                let mut p95s: Vec<Vec<f64>> = vec![Vec::new(); LEG_NAMES.len()];
                for t in 0..trials {
                    set_link_profile(None, 0);
                    let rig = Rig::start(path).await;
                    // The dial itself unshaped (the matrix's dial numbers are its own); the
                    // stream shaped.
                    set_link_profile(Some(profile(&profile_name)), 0x5c01 + t as u64);
                    let burners = duress.then(|| Burners::start(BURNERS));
                    let (legs, wire_bytes) = trial(&rig, duress).await;
                    drop(burners);
                    set_link_profile(None, 0);
                    let cols = legs.columns();
                    let mut row = String::new();
                    for (k, name) in LEG_NAMES.iter().enumerate() {
                        let (p50, p95) = (pct(cols[k], 0.5), pct(cols[k], 0.95));
                        p50s[k].push(p50);
                        p95s[k].push(p95);
                        row.push_str(&format!(" {name} {p50}/{p95}"));
                    }
                    println!(
                        "LEGS-ROW {path_name} {profile_name} {load} trial {t} n {}:{row} | wire bytes {wire_bytes} | flag {flag:?}",
                        legs.shown.len()
                    );
                    assert!(legs.shown.len() >= REDRAWS * 9 / 10, "most redraws shown");
                }
                let mut cell = serde_json::Map::new();
                for (k, name) in LEG_NAMES.iter().enumerate() {
                    cell.insert(
                        (*name).into(),
                        json!({"p50_ms": median(p50s[k].clone()), "p95_ms": median(p95s[k].clone())}),
                    );
                }
                println!(
                    "LEGS-CELL {}",
                    json!({"path": path_name, "profile": profile_name, "load": load, "trials": trials,
                        "redraws": REDRAWS, "flag": flag, "legs": cell})
                );
            }
        }
    }
}
