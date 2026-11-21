//! Keystroke-to-echo latency over the direct path and the relay (TURN) path,
//! in one process, measured by one harness with one clock. The rig-free
//! counterpart of `cmux-mobile-lanebench --paths direct,relay`
//! (cmux-next-ios/verify/echo-latency-direct-vs-relay.md).
//!
//! Each path is a real WireGuard link (fake signaling, a loopback TURN
//! server, both tunnels' underlays as they ship), dialed fresh:
//!
//! - `direct`: no TURN server, so the link can only go direct;
//! - `relay`: both sides relay only (`DialOptions::relay_only`);
//! - `both`: direct and TURN offered, as the app dials.
//!
//! The workload mirrors the app and the Mac's daemon: the phone types one
//! byte at a time on an input-lane channel (`send`); the Mac answers the
//! request on that channel (`ack_ms`) and echoes the byte on the terminal's
//! attach channel, on the main stream (`echo_ms`). With `--flood-mbps M`
//! the Mac also streams M Mbit/s of terminal output on another attach
//! channel for the whole run, as a second terminal running `yes` would.
//!
//! The path set is shaped on receive (`DialOptions::impair_inbound`): each
//! direct datagram is delayed half the LAN round trip, each relayed one half
//! the relay round trip, plus up to `--jitter` ms of uniform jitter, and
//! dropped with probability `--loss` percent.
//!
//! ```text
//! cargo run --release -p cmux-mobile-link --example echo_latency_bench -- \
//!     --paths direct,relay --samples 300 --lan-rtt 2 --relay-rtt 40 \
//!     [--interval 50] [--jitter 0] [--loss 0] [--flood-mbps 0]
//! ```
//!
//! Prints one JSON line per path on stdout and a table on stderr.

use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use bytes::Bytes;
use cmux_mobile_link::dial::{self, SessionEvents};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling, TestTurn, is_test_relay};
use cmux_mobile_link::{ChannelEvent, DialOptions, Lane, LinkConfig, SignalingClient, TransportKind};
use serde_json::{Value, json};
use tokio::sync::{Notify, mpsc};
use tokio::time::Instant;

static LAN_ONE_WAY_US: AtomicU64 = AtomicU64::new(1000);
static RELAY_ONE_WAY_US: AtomicU64 = AtomicU64::new(20_000);
static JITTER_US: AtomicU64 = AtomicU64::new(0);
/// Loss per million datagrams.
static LOSS_PPM: AtomicU64 = AtomicU64::new(0);
static RNG: AtomicU64 = AtomicU64::new(0x9e37_79b9_7f4a_7c15);

/// splitmix64 on a shared counter: cheap, lock-free, good enough to shape.
fn random() -> u64 {
    let mut z = RNG.fetch_add(0x9e37_79b9_7f4a_7c15, Ordering::Relaxed);
    z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    z ^ (z >> 31)
}

/// Relayed: through this side's TURN allocation, or plain UDP from a TURN
/// relayed port (the peer's allocation).
fn impair(via_turn: bool, from: &SocketAddr) -> Option<Duration> {
    let loss = LOSS_PPM.load(Ordering::Relaxed);
    if loss > 0 && random() % 1_000_000 < loss {
        return None;
    }
    let base = if via_turn || is_test_relay(from) { &RELAY_ONE_WAY_US } else { &LAN_ONE_WAY_US };
    let jitter = JITTER_US.load(Ordering::Relaxed);
    let extra = if jitter > 0 { random() % (jitter + 1) } else { 0 };
    Some(Duration::from_micros(base.load(Ordering::Relaxed) + extra))
}

struct Args {
    paths: Vec<String>,
    samples: usize,
    interval_ms: u64,
    lan_rtt_ms: f64,
    relay_rtt_ms: f64,
    jitter_ms: f64,
    loss_pct: f64,
    flood_mbps: f64,
    warmup: usize,
}

fn args() -> Args {
    let mut parsed = Args {
        paths: vec!["direct".into(), "relay".into()],
        samples: 300,
        interval_ms: 50,
        lan_rtt_ms: 2.0,
        relay_rtt_ms: 40.0,
        jitter_ms: 0.0,
        loss_pct: 0.0,
        flood_mbps: 0.0,
        warmup: 10,
    };
    let mut iter = std::env::args().skip(1);
    while let Some(flag) = iter.next() {
        let value = iter.next().unwrap_or_default();
        let number = || {
            value.parse::<f64>().unwrap_or_else(|_| {
                eprintln!("{flag} needs a number, got {value:?}");
                std::process::exit(2);
            })
        };
        match flag.as_str() {
            "--paths" => parsed.paths = value.split(',').map(str::to_owned).collect(),
            "--samples" => parsed.samples = number() as usize,
            "--interval" => parsed.interval_ms = number() as u64,
            "--lan-rtt" => parsed.lan_rtt_ms = number(),
            "--relay-rtt" => parsed.relay_rtt_ms = number(),
            "--jitter" => parsed.jitter_ms = number(),
            "--loss" => parsed.loss_pct = number(),
            "--flood-mbps" => parsed.flood_mbps = number(),
            "--warmup" => parsed.warmup = number() as usize,
            other => {
                eprintln!("unknown flag {other}");
                std::process::exit(2);
            }
        }
    }
    parsed
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// n, min, p50, p90, p95, p99, max in ms (nearest rank).
fn summary(mut values: Vec<f64>) -> Value {
    if values.is_empty() {
        return Value::Null;
    }
    values.sort_by(f64::total_cmp);
    let at = |q: f64| {
        let v = values[((values.len() - 1) as f64 * q).round() as usize];
        (v * 100.0).round() / 100.0
    };
    json!({"n": values.len(), "min": at(0.0), "p50": at(0.5), "p90": at(0.9),
           "p95": at(0.95), "p99": at(0.99), "max": at(1.0)})
}

/// The Mac: answers the session and serves the three channels.
async fn mac(mac: SignalingClient, options: DialOptions, flood_mbps: f64, done: Arc<Notify>) {
    let Some(session) = mac.next_session().await else { return };
    let events = SessionEvents {
        backend: mac.events(),
        session_id: session.first.session_id.clone(),
        session: session.events,
    };
    let connected =
        dial::answer(&mac, session.first, events, &options, LinkConfig::default()).await.expect("answer");
    let link = connected.link.clone();
    // The terminal B's attach channel, where echoes go.
    let (echo_tx, mut echo_rx) = mpsc::unbounded_channel::<Bytes>();
    let mut echo_tx = Some(echo_tx);
    let finished = done.notified();
    tokio::pin!(finished);
    loop {
        let incoming = tokio::select! {
            incoming = link.accept() => incoming,
            () = &mut finished => break,
        };
        let Some(incoming) = incoming else { break };
        let (sender, mut receiver) = incoming.channel.split();
        match incoming.service.as_str() {
            "attach-b" => {
                tokio::spawn(async move {
                    while let Some(bytes) = echo_rx.recv().await {
                        if sender.send(bytes).await.is_err() {
                            break;
                        }
                    }
                    drop(receiver);
                });
                // Only one attach-b.
                echo_rx = mpsc::unbounded_channel().1;
            }
            "attach-a" => {
                // Terminal A's output: a paced flood, 16 KiB writes.
                tokio::spawn(async move {
                    if flood_mbps <= 0.0 {
                        let _ = receiver.recv().await;
                        return;
                    }
                    const CHUNK: usize = 16 * 1024;
                    let interval = Duration::from_secs_f64(CHUNK as f64 * 8.0 / (flood_mbps * 1e6));
                    let line = Bytes::from(vec![b'y'; CHUNK]);
                    let mut next = Instant::now();
                    loop {
                        if sender.send(line.clone()).await.is_err() {
                            break;
                        }
                        next += interval;
                        let now = Instant::now();
                        if next < now {
                            next = now;
                        }
                        tokio::time::sleep_until(next).await;
                    }
                    drop(receiver);
                });
            }
            "input" => {
                // `send` requests: reply on this channel, echo on B's.
                let echo = echo_tx.take().expect("one input channel");
                tokio::spawn(async move {
                    while let Some(ChannelEvent::Data(bytes)) = receiver.recv().await {
                        let _ = echo.send(bytes.clone());
                        if sender.send(bytes).await.is_err() {
                            break;
                        }
                    }
                });
            }
            other => eprintln!("mac: unknown service {other}"),
        }
    }
    link.close("done");
    drop(connected);
}

/// What the phone saw: per-key send time, ack and echo times, in one map
/// keyed by sequence number (two bytes per key).
#[derive(Default)]
struct Seen {
    sent: Vec<Option<Instant>>,
    ack: Vec<Option<Instant>>,
    echo: Vec<Option<Instant>>,
}

fn key(seq: usize) -> Bytes {
    Bytes::from(vec![(seq >> 8) as u8, seq as u8])
}

async fn run_path(path: &str, args: &Args, turn: &TestTurn) -> Value {
    let mut options = DialOptions {
        include_loopback: true,
        timeout: Duration::from_secs(20),
        turn_tls_roots: Some(turn.roots.clone()),
        impair_inbound: Some(impair),
        ..DialOptions::default()
    };
    match path {
        "direct" => {}
        "relay" => {
            options.ice_servers = vec![turn.udp_only()];
            options.relay_only = true;
        }
        "both" => options.ice_servers = vec![turn.udp_only()],
        other => {
            eprintln!("unknown path {other} (direct, relay, both)");
            std::process::exit(2);
        }
    }
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac_client =
        SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.expect("mac");
    let done = Arc::new(Notify::new());
    let mac_task = tokio::spawn(mac(mac_client, options.clone(), args.flood_mbps, done.clone()));
    let phone_id = uuid::Uuid::new_v4().to_string();
    let phone =
        SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.expect("phone");
    let connected = dial::connect(&phone, &mac_id, TransportKind::WireGuard, &options, LinkConfig::default())
        .await
        .expect("dial");
    let link = connected.link.clone();

    let attach_b = link.open("attach-b", json!({})).await.expect("open attach-b");
    let attach_a = link.open("attach-a", json!({})).await.expect("open attach-a");
    let input = link.open_on("input", json!({}), Lane::Input).await.expect("open input");
    let lane_state = format!("{:?}", link.input_lane());

    let total = args.warmup + args.samples;
    let seen = Arc::new(Mutex::new(Seen {
        sent: vec![None; total],
        ack: vec![None; total],
        echo: vec![None; total],
    }));
    let arrived = Arc::new(Notify::new());
    let (b_sender, b_receiver) = attach_b.split();
    let (a_sender, mut a_receiver) = attach_a.split();
    let (input_sender, input_receiver) = input.split();
    let flood_bytes = Arc::new(AtomicU64::new(0));
    let mut readers = Vec::new();
    {
        let flood_bytes = flood_bytes.clone();
        readers.push(tokio::spawn(async move {
            while let Some(ChannelEvent::Data(bytes)) = a_receiver.recv().await {
                flood_bytes.fetch_add(bytes.len() as u64, Ordering::Relaxed);
            }
        }));
    }
    for (is_echo, mut receiver) in [(true, b_receiver), (false, input_receiver)] {
        let (seen, arrived) = (seen.clone(), arrived.clone());
        readers.push(tokio::spawn(async move {
            let mut buffer = Vec::new();
            while let Some(ChannelEvent::Data(bytes)) = receiver.recv().await {
                let at = Instant::now();
                buffer.extend_from_slice(&bytes);
                let mut seen = lock(&seen);
                for pair in buffer.chunks_exact(2) {
                    let seq = (usize::from(pair[0]) << 8) | usize::from(pair[1]);
                    let slot = if is_echo { &mut seen.echo } else { &mut seen.ack };
                    if let Some(slot) = slot.get_mut(seq) {
                        slot.get_or_insert(at);
                    }
                }
                let whole = buffer.len() / 2 * 2;
                buffer.drain(..whole);
                drop(seen);
                arrived.notify_waiters();
            }
        }));
    }
    // Hold the senders so the channels stay open until the end.
    let _held = (b_sender, a_sender);

    // Let the flood fill every queue between the Mac and the phone.
    let flood_start = Instant::now();
    if args.flood_mbps > 0.0 {
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
    let mut missed = 0usize;
    let started = Instant::now();
    for seq in 0..total {
        let at = Instant::now();
        lock(&seen).sent[seq] = Some(at);
        if input_sender.send(key(seq)).await.is_err() {
            eprintln!("{path}: input channel closed at key {seq}");
            break;
        }
        // Wait for the echo (5 s at most), then the typing interval.
        let deadline = at + Duration::from_secs(5);
        loop {
            let notified = arrived.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if lock(&seen).echo[seq].is_some() {
                break;
            }
            if tokio::time::timeout_at(deadline, notified).await.is_err() {
                missed += 1;
                break;
            }
        }
        tokio::time::sleep(Duration::from_millis(args.interval_ms)).await;
    }
    let typing_seconds = started.elapsed().as_secs_f64();
    let flood_seconds = flood_start.elapsed().as_secs_f64();
    // Late acks.
    tokio::time::sleep(Duration::from_millis(200)).await;
    let final_path = format!("{:?}", *connected.path.borrow());
    let seen = lock(&seen);
    let ms = |list: &[Option<Instant>]| -> Vec<f64> {
        (args.warmup..total).filter_map(|i| Some((list[i]? - seen.sent[i]?).as_secs_f64() * 1000.0)).collect()
    };
    let report = json!({
        "path": path,
        "final_path": final_path,
        "lane_state": lane_state,
        "lan_rtt_ms": args.lan_rtt_ms,
        "relay_rtt_ms": args.relay_rtt_ms,
        "jitter_ms": args.jitter_ms,
        "loss_pct": args.loss_pct,
        "flood_mbps": args.flood_mbps,
        "flood_mbps_received":
            (flood_bytes.load(Ordering::Relaxed) as f64 * 8.0 / 1e6 / flood_seconds * 10.0).round() / 10.0,
        "samples": args.samples,
        "interval_ms": args.interval_ms,
        "typing_seconds": (typing_seconds * 10.0).round() / 10.0,
        "echo_ms": summary(ms(&seen.echo)),
        "ack_ms": summary(ms(&seen.ack)),
        "missed": missed,
    });
    drop(seen);
    done.notify_waiters();
    link.close("done");
    for reader in readers {
        reader.abort();
    }
    let _ = tokio::time::timeout(Duration::from_secs(2), mac_task).await;
    report
}

fn cell(report: &Value, metric: &str) -> String {
    let s = &report[metric];
    if s.is_null() {
        return "-".into();
    }
    format!("{} / {} / {} / {}", s["p50"], s["p95"], s["p99"], s["max"])
}

#[tokio::main(flavor = "multi_thread", worker_threads = 4)]
async fn main() {
    // RUST_LOG=cmux_mobile_link=debug shows the route changes, on stderr.
    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_writer(std::io::stderr)
        .try_init();
    let args = args();
    LAN_ONE_WAY_US.store((args.lan_rtt_ms * 500.0) as u64, Ordering::Relaxed);
    RELAY_ONE_WAY_US.store((args.relay_rtt_ms * 500.0) as u64, Ordering::Relaxed);
    JITTER_US.store((args.jitter_ms * 1000.0) as u64, Ordering::Relaxed);
    LOSS_PPM.store((args.loss_pct * 10_000.0) as u64, Ordering::Relaxed);
    if let Ok(nanos) = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
        RNG.store(nanos.as_nanos() as u64, Ordering::Relaxed);
    }
    let turn = TestTurn::start().await;
    let mut reports = Vec::new();
    for path in &args.paths {
        let report = run_path(path, &args, &turn).await;
        println!("{report}");
        reports.push(report);
    }
    eprintln!(
        "\nkeystroke-to-echo, ms (p50 / p95 / p99 / max); lan {} ms, relay {} ms, jitter {} ms, loss {}%, flood {} Mbit/s, {} keys every {} ms",
        args.lan_rtt_ms,
        args.relay_rtt_ms,
        args.jitter_ms,
        args.loss_pct,
        args.flood_mbps,
        args.samples,
        args.interval_ms
    );
    eprintln!("{:<8} {:<10} {:<32} {:<32} {}", "path", "final", "echo", "ack", "missed");
    for report in &reports {
        eprintln!(
            "{:<8} {:<10} {:<32} {:<32} {}",
            report["path"].as_str().unwrap_or_default(),
            report["final_path"].as_str().unwrap_or_default(),
            cell(report, "echo_ms"),
            cell(report, "ack_ms"),
            report["missed"]
        );
    }
    std::process::exit(0);
}
