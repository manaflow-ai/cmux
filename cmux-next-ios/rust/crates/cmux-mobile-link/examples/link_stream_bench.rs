//! The remote desktop workload over the iPhone mobile link, in one process:
//! the same workload as cmux-wg's `remote_stream_bench` (frames of 3.5 KB at
//! 60 fps from the Mac, an input from the phone every 20 ms, each frame
//! stamped with the input it answers), carried on a channel of a real
//! WireGuard link (fake signaling, a loopback TURN server, both tunnels'
//! underlays as they ship).
//!
//! The path set is shaped on receive (`DialOptions::impair_inbound`): each
//! direct datagram is delayed half the LAN round trip, each relayed one
//! (through a TURN server) half the relay round trip, and `--cut-at S` drops
//! every direct datagram from S seconds on, both ways (a cable pulled, a
//! Wi-Fi network left with the relay still up).
//!
//! ```text
//! cargo run --release -p cmux-mobile-link --example link_stream_bench -- \
//!     --row both --lan-rtt 2 --relay-rtt 40 --seconds 12 [--cut-at 4]
//! ```
//!
//! Rows: `lan-only` (no TURN server), `relay-only` (both sides relay only),
//! `both` (direct and TURN). Prints one JSON line. `longest_frame_gap_ms` is
//! the longest wait between two frames at the phone: a path that dropped
//! shows up there as a stall. `final_path` is the phone's path at the end.
//!
//! `--workload echo-flood [--flood-mbps N] [--loss PCT]` measures the
//! terminal's case instead: keystrokes on the input lane, their echo on the
//! main stream behind another channel's flood (N Mbit/s, 0 for as fast as
//! the link takes it). It prints the key-to-echo time and the flood's
//! goodput (`echo_ms`, `flood_goodput_mbit_s`).
//!
//! Both workloads open the screen (`bench`, `echo`) with `Link::open_latest`
//! and the keys on the input lane, so when both ends list the `classes`
//! lane those messages also travel as datagrams (`cmux_mobile_link::classes`).
//! `CMUX_LINK_CLASSES=off` measures today's streams only. `frame_delay_ms`
//! is a frame's send-to-receive time (one clock serves both ends); a frame
//! superseded by a newer one before it arrived is not counted.

use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use bytes::Bytes;
use cmux_mobile_link::dial::{self, SessionEvents};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling, TestTurn, is_test_relay};
use cmux_mobile_link::{ChannelEvent, DialOptions, Lane, LinkConfig, SignalingClient, TransportKind};
use tokio::time::{Instant, sleep_until};

const HEADER: usize = 21;
const FRAME_BYTES: usize = 3500;
const FPS: u32 = 60;
const INPUT_INTERVAL: Duration = Duration::from_millis(20);

static LAN_ONE_WAY_US: AtomicU64 = AtomicU64::new(1000);
static RELAY_ONE_WAY_US: AtomicU64 = AtomicU64::new(20_000);
static LAN_CUT: AtomicBool = AtomicBool::new(false);
/// `--loss`: the chance, in parts per million, that a received datagram is dropped.
static LOSS_PPM: AtomicU64 = AtomicU64::new(0);
static LOSS_STATE: AtomicU64 = AtomicU64::new(0x9e37_79b9_7f4a_7c15);

/// Whether to drop this datagram (`--loss`), from a fixed-seed xorshift so
/// runs see the same loss pattern.
fn lost() -> bool {
    let ppm = LOSS_PPM.load(Ordering::Relaxed);
    if ppm == 0 {
        return false;
    }
    let mut x = LOSS_STATE.load(Ordering::Relaxed);
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    LOSS_STATE.store(x, Ordering::Relaxed);
    x % 1_000_000 < ppm
}

/// Relayed: through this side's TURN allocation, or plain UDP from a TURN
/// relayed port (the peer's allocation).
fn impair(via_turn: bool, from: &SocketAddr, _len: usize) -> Option<Duration> {
    if lost() {
        return None;
    }
    let relayed = via_turn || is_test_relay(from);
    if relayed {
        return Some(Duration::from_micros(RELAY_ONE_WAY_US.load(Ordering::Relaxed)));
    }
    if LAN_CUT.load(Ordering::Relaxed) {
        return None;
    }
    Some(Duration::from_micros(LAN_ONE_WAY_US.load(Ordering::Relaxed)))
}

struct Args {
    row: String,
    lan_rtt_ms: u64,
    relay_rtt_ms: u64,
    seconds: u64,
    cut_at: Option<u64>,
    /// `--workload echo-flood`: keystroke echo under a flood (see [`echo_flood`]).
    workload: String,
    /// Flood rate in Mbit/s; 0 is as fast as the link takes it.
    flood_mbps: f64,
    loss_pct: f64,
    /// `echo-flood` only: `wireguard` (the default) or `webrtc` (no path
    /// shaping: the WebRTC dial has no impairment hook, so this is loopback).
    transport: String,
    profile: Option<String>,
}

fn args() -> Args {
    let mut parsed = Args {
        row: "both".into(),
        lan_rtt_ms: 2,
        relay_rtt_ms: 40,
        seconds: 12,
        cut_at: None,
        workload: "frames".into(),
        flood_mbps: 0.0,
        loss_pct: 0.0,
        transport: "wireguard".into(),
        profile: None,
    };
    let mut iter = std::env::args().skip(1);
    while let Some(flag) = iter.next() {
        let value = iter.next().unwrap_or_default();
        let number = || value.parse::<u64>().unwrap_or(0);
        match flag.as_str() {
            "--row" => parsed.row = value.clone(),
            "--lan-rtt" => parsed.lan_rtt_ms = number(),
            "--relay-rtt" => parsed.relay_rtt_ms = number(),
            "--seconds" => parsed.seconds = number(),
            "--cut-at" => parsed.cut_at = Some(number()),
            "--workload" => parsed.workload = value.clone(),
            "--flood-mbps" => parsed.flood_mbps = value.parse().unwrap_or(0.0),
            "--loss" => parsed.loss_pct = value.parse().unwrap_or(0.0),
            "--transport" => parsed.transport = value.clone(),
            "--profile" => parsed.profile = Some(value.clone()),
            other => eprintln!("ignoring unknown flag {other}"),
        }
    }
    parsed
}

/// What the phone and the Mac recorded, in microseconds.
#[derive(Default)]
struct Record {
    frames_sent: u64,
    inputs_sent: u64,
    frames_received: u64,
    /// The newest frame number received.
    newest_frame: Option<u32>,
    frame_delay_us: Vec<u64>,
    photon_us: Vec<u64>,
    last_frame_at_us: Option<u64>,
    longest_frame_gap_us: u64,
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

struct Clock(Instant);

impl Clock {
    fn us(&self) -> u64 {
        u64::try_from(self.0.elapsed().as_micros()).unwrap_or(u64::MAX).max(1)
    }
}

/// The tick after `next` that is not already past: a stalled sender skips
/// the frames it missed, as an encoder does.
fn next_tick(next: Instant, interval: Duration) -> Instant {
    let mut next = next + interval;
    let now = Instant::now();
    if next < now {
        let missed = (now - next).as_nanos() / interval.as_nanos().max(1);
        next += interval * u32::try_from(missed + 1).unwrap_or(u32::MAX);
    }
    next
}

fn message(seq: u32, sent_us: u64, echo_us: u64, size: usize) -> Bytes {
    let mut out = vec![0x5a; size.max(HEADER)];
    out[0] = 1;
    out[1..5].copy_from_slice(&seq.to_be_bytes());
    out[5..13].copy_from_slice(&sent_us.to_be_bytes());
    out[13..21].copy_from_slice(&echo_us.to_be_bytes());
    Bytes::from(out)
}

fn frame_seq(bytes: &[u8]) -> Option<u32> {
    Some(u32::from_be_bytes(bytes.get(1..5)?.try_into().ok()?))
}

fn stamps(bytes: &[u8]) -> Option<(u64, u64)> {
    let word = |at: usize| Some(u64::from_be_bytes(bytes.get(at..at + 8)?.try_into().ok()?));
    Some((word(5)?, word(13)?))
}

fn percentiles(values: &mut [u64]) -> String {
    if values.is_empty() {
        return "null".into();
    }
    values.sort_unstable();
    let at = |p: f64| values[((values.len() as f64 - 1.0) * p).round() as usize] as f64 / 1000.0;
    format!(
        "{{\"n\":{},\"p50\":{:.2},\"p95\":{:.2},\"p99\":{:.2},\"max\":{:.2}}}",
        values.len(),
        at(0.5),
        at(0.95),
        at(0.99),
        at(1.0)
    )
}

#[tokio::main(flavor = "multi_thread", worker_threads = 4)]
async fn main() {
    // RUST_LOG=cmux_mobile_link=debug shows the route changes, on stderr.
    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_writer(std::io::stderr)
        .try_init();
    let args = args();
    LAN_ONE_WAY_US.store(args.lan_rtt_ms * 500, Ordering::Relaxed);
    RELAY_ONE_WAY_US.store(args.relay_rtt_ms * 500, Ordering::Relaxed);
    let turn = TestTurn::start().await;
    let shaped = args.profile.is_some();
    if let Some(name) = &args.profile {
        cmux_mobile_link::testing::set_link_profile(
            Some(cmux_mobile_link::testing::LinkProfile::named(name)),
            42,
        );
    }
    let mut options = DialOptions {
        include_loopback: true,
        timeout: Duration::from_secs(20),
        turn_tls_roots: Some(turn.roots.clone()),
        impair_inbound: Some(if shaped { cmux_mobile_link::testing::shape_by_profile } else { impair }),
        ..DialOptions::default()
    };
    match args.row.as_str() {
        "lan-only" => {}
        "relay-only" => {
            options.ice_servers = vec![turn.udp_only()];
            options.relay_only = true;
        }
        "both" => options.ice_servers = vec![turn.udp_only()],
        other => {
            eprintln!("unknown row {other}");
            std::process::exit(2);
        }
    }
    if args.workload == "echo-flood" {
        echo_flood(&args, options).await;
        std::process::exit(0);
    }
    let clock = Arc::new(Clock(Instant::now()));
    let record = Arc::new(Mutex::new(Record::default()));
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.expect("mac");
    let end_slot: Arc<Mutex<Option<Instant>>> = Arc::default();
    {
        let (options, clock, record, end_slot) =
            (options.clone(), clock.clone(), record.clone(), end_slot.clone());
        tokio::spawn(async move {
            let Some(session) = mac.next_session().await else { return };
            let events = SessionEvents {
                backend: mac.events(),
                session_id: session.first.session_id.clone(),
                session: session.events,
            };
            let connected = dial::answer(&mac, session.first, events, &options, LinkConfig::default())
                .await
                .expect("answer");
            // `bench` carries the frames, `keys` the inputs.
            let pending = Arc::new(AtomicU64::new(0));
            let mut frames = None;
            let mut keys = None;
            while frames.is_none() || keys.is_none() {
                let Some(incoming) = connected.link.accept().await else { return };
                let (sender, mut receiver) = incoming.channel.split();
                if incoming.service == "keys" {
                    let pending = pending.clone();
                    tokio::spawn(async move {
                        while let Some(ChannelEvent::Data(bytes)) = receiver.recv().await {
                            if let Some((sent, _)) = stamps(&bytes) {
                                let _ =
                                    pending.compare_exchange(0, sent, Ordering::Relaxed, Ordering::Relaxed);
                            }
                        }
                    });
                    keys = Some(sender);
                } else {
                    frames = Some((sender, receiver));
                }
            }
            let (sender, _receiver) = frames.expect("bench opened");
            let _keys = keys;
            let end = loop {
                if let Some(end) = *lock(&end_slot) {
                    break end;
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            };
            let interval = Duration::from_secs(1) / FPS;
            let mut next = Instant::now();
            let mut seq = 0u32;
            while next < end {
                let echo = pending.swap(0, Ordering::Relaxed);
                if sender.send(message(seq, clock.us(), echo, FRAME_BYTES)).await.is_err() {
                    break;
                }
                lock(&record).frames_sent += 1;
                seq += 1;
                next = next_tick(next, interval);
                sleep_until(next).await;
            }
            // Hold the link until the phone is done reading.
            tokio::time::sleep(Duration::from_secs(30)).await;
            drop(connected);
        });
    }
    let phone_id = uuid::Uuid::new_v4().to_string();
    let phone =
        SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.expect("phone");
    let connected = dial::connect(&phone, &mac_id, TransportKind::WireGuard, &options, LinkConfig::default())
        .await
        .expect("dial");
    let channel = connected.link.open_latest("bench", serde_json::json!({})).await.expect("open");
    let (_frames_tx, mut receiver) = channel.split();
    let keys = connected.link.open_on("keys", serde_json::json!({}), Lane::Input).await.expect("keys");
    let (sender, _keys_rx) = keys.split();
    LOSS_PPM.store((args.loss_pct * 10_000.0) as u64, Ordering::Relaxed);
    let start = Instant::now();
    let end = start + Duration::from_secs(args.seconds);
    *lock(&end_slot) = Some(end);
    if let Some(at) = args.cut_at {
        tokio::spawn(async move {
            sleep_until(start + Duration::from_secs(at)).await;
            LAN_CUT.store(true, Ordering::Relaxed);
        });
    }
    {
        let (clock, record) = (clock.clone(), record.clone());
        tokio::spawn(async move {
            let mut seq = 0u32;
            let mut next = Instant::now() + INPUT_INTERVAL;
            while next < end {
                sleep_until(next).await;
                if sender.send(message(seq, clock.us(), 0, HEADER)).await.is_err() {
                    break;
                }
                lock(&record).inputs_sent += 1;
                seq += 1;
                next = next_tick(next, INPUT_INTERVAL);
            }
            // Keep the channel open while the last frames arrive.
            tokio::time::sleep(Duration::from_secs(30)).await;
            drop(sender);
        });
    }
    let reader = {
        let (clock, record) = (clock.clone(), record.clone());
        tokio::spawn(async move {
            while let Some(ChannelEvent::Data(bytes)) = receiver.recv().await {
                let now = clock.us();
                let mut record = lock(&record);
                if let Some(last) = record.last_frame_at_us {
                    record.longest_frame_gap_us = record.longest_frame_gap_us.max(now.saturating_sub(last));
                }
                record.last_frame_at_us = Some(now);
                record.frames_received += 1;
                record.newest_frame = frame_seq(&bytes).max(record.newest_frame);
                if let Some((sent, _)) = stamps(&bytes) {
                    record.frame_delay_us.push(now.saturating_sub(sent));
                }
                if let Some((_, echo)) = stamps(&bytes)
                    && echo != 0
                {
                    record.photon_us.push(now.saturating_sub(echo));
                }
            }
        })
    };
    // Every frame the Mac sent arrives, or the run gives up 20 s after its
    // end. The last frame can land before `end`, so this checks on a timer
    // rather than only when a frame arrives.
    let all_arrived = {
        let record = record.clone();
        async move {
            loop {
                {
                    let record = lock(&record);
                    // The newest frame arrived (older ones may be superseded).
                    let newest = record.newest_frame.map_or(0, |seq| u64::from(seq) + 1);
                    if Instant::now() >= end && record.frames_sent > 0 && newest >= record.frames_sent {
                        break;
                    }
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        }
    };
    let complete = tokio::time::timeout_at(end + Duration::from_secs(20), all_arrived).await.is_ok();
    reader.abort();
    let path = *connected.path.borrow();
    let mut record = lock(&record);
    if !complete && let Some(last) = record.last_frame_at_us {
        // Frames still missing at the deadline: the stall lasts at least
        // until now.
        let now = clock.us();
        record.longest_frame_gap_us = record.longest_frame_gap_us.max(now.saturating_sub(last));
    }
    let photon = percentiles(&mut record.photon_us);
    let frame_delay = percentiles(&mut record.frame_delay_us);
    println!(
        "{{\"classes\":{},\"loss_pct\":{},\"frame_delay_ms\":{},\"datagram_wins\":{},\"row\":\"{}\",\"lan_rtt_ms\":{},\"relay_rtt_ms\":{},\"seconds\":{},\"cut_at\":{},\
         \"frames_sent\":{},\"frames_received\":{},\"inputs_sent\":{},\"input_to_photon_ms\":{},\
         \"longest_frame_gap_ms\":{:.1},\"complete\":{},\"final_path\":\"{:?}\"}}",
        connected.link.class_datagrams(),
        args.loss_pct,
        frame_delay,
        connected.link.datagram_wins(),
        args.row,
        args.lan_rtt_ms,
        args.relay_rtt_ms,
        args.seconds,
        args.cut_at.map_or_else(|| "null".to_owned(), |at| at.to_string()),
        record.frames_sent,
        record.frames_received,
        record.inputs_sent,
        photon,
        record.longest_frame_gap_us as f64 / 1000.0,
        complete,
        path,
    );
    std::process::exit(0);
}

/// Bytes per flood write (the link splits it into 16 KiB frames).
const FLOOD_WRITE: usize = 64 * 1024;
/// Flood bytes and echoes before this are not counted (the window opening).
const WARMUP: Duration = Duration::from_secs(2);

/// `--workload echo-flood`: the terminal's case, a keystroke whose echo
/// queues behind other output on the link's main stream. The phone opens
/// three channels: `keys` on the input lane (keystrokes, as the app sends
/// them), and `echo` and `flood` on the main stream (two terminal surfaces'
/// output). The Mac floods `flood` at `--flood-mbps` (0: as fast as the link
/// takes it) and answers each key on `echo`. Prints the key-to-echo time and
/// the flood's goodput after the warm-up; `--loss` drops that share of the
/// received datagrams, both ways, once the link is up.
async fn echo_flood(args: &Args, options: DialOptions) {
    let clock = Arc::new(Clock(Instant::now()));
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.expect("mac");
    let flood_mbps = args.flood_mbps;
    {
        let options = options.clone();
        tokio::spawn(async move {
            let Some(session) = mac.next_session().await else { return };
            let events = SessionEvents {
                backend: mac.events(),
                session_id: session.first.session_id.clone(),
                session: session.events,
            };
            let connected = dial::answer(&mac, session.first, events, &options, LinkConfig::default())
                .await
                .expect("answer");
            let echo: Arc<tokio::sync::Mutex<Option<cmux_mobile_link::link::ChannelSender>>> = Arc::default();
            while let Some(incoming) = connected.link.accept().await {
                let (sender, mut receiver) = incoming.channel.split();
                match incoming.service.as_str() {
                    "echo" => *echo.lock().await = Some(sender),
                    "flood" => {
                        tokio::spawn(async move {
                            let chunk = Bytes::from(vec![0x5a; FLOOD_WRITE]);
                            if flood_mbps <= 0.0 {
                                while sender.send(chunk.clone()).await.is_ok() {}
                                return;
                            }
                            let tick = Duration::from_millis(5);
                            let per_tick = (flood_mbps * 1e6 / 8.0 * tick.as_secs_f64()) as usize;
                            let mut next = Instant::now();
                            loop {
                                let mut left = per_tick;
                                while left > 0 {
                                    let count = left.min(FLOOD_WRITE);
                                    if sender.send(chunk.slice(..count)).await.is_err() {
                                        return;
                                    }
                                    left -= count;
                                }
                                next = next_tick(next, tick);
                                sleep_until(next).await;
                            }
                        });
                    }
                    "keys" => {
                        let echo = echo.clone();
                        tokio::spawn(async move {
                            let _sender = sender;
                            while let Some(ChannelEvent::Data(bytes)) = receiver.recv().await {
                                if let Some(echo) = echo.lock().await.as_ref() {
                                    let _ = echo.send(bytes).await;
                                }
                            }
                        });
                    }
                    _ => {}
                }
            }
            drop(connected);
        });
    }
    let phone_id = uuid::Uuid::new_v4().to_string();
    let phone =
        SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.expect("phone");
    let kind = if args.transport == "webrtc" { TransportKind::WebRtc } else { TransportKind::WireGuard };
    let connected =
        dial::connect(&phone, &mac_id, kind, &options, LinkConfig::default()).await.expect("dial");
    let link = connected.link.clone();
    let (_echo_tx, mut echo_rx) =
        link.open_latest("echo", serde_json::json!({})).await.expect("echo").split();
    let (_flood_tx, mut flood_rx) = link.open("flood", serde_json::json!({})).await.expect("flood").split();
    let keys = link.open_on("keys", serde_json::json!({}), Lane::Input).await.expect("keys");
    let keys_on_lane = keys.lane() == Lane::Input;
    let (keys_tx, _keys_rx) = keys.split();
    let on_input_stream = keys_tx.on_input_stream();
    LOSS_PPM.store((args.loss_pct * 10_000.0) as u64, Ordering::Relaxed);
    let start = Instant::now();
    let counted_from = start + WARMUP;
    let end = start + Duration::from_secs(args.seconds.max(3));
    let flood_bytes = Arc::new(AtomicU64::new(0));
    {
        let flood_bytes = flood_bytes.clone();
        tokio::spawn(async move {
            while let Some(ChannelEvent::Data(bytes)) = flood_rx.recv().await {
                let now = Instant::now();
                if now >= counted_from && now < end {
                    flood_bytes.fetch_add(bytes.len() as u64, Ordering::Relaxed);
                }
            }
        });
    }
    // Key send times by number. An echo is the screen with every key up to
    // its own on it: with latest-wins delivery a newer echo can arrive in
    // place of an older one, and echoes the keys before it too.
    let key_sent_us: Arc<Mutex<Vec<u64>>> = Arc::default();
    let echoes: Arc<Mutex<Vec<u64>>> = Arc::default();
    {
        let (clock, echoes, key_sent_us) = (clock.clone(), echoes.clone(), key_sent_us.clone());
        tokio::spawn(async move {
            let mut echoed = 0usize;
            while let Some(ChannelEvent::Data(bytes)) = echo_rx.recv().await {
                let Some(seq) = frame_seq(&bytes) else { continue };
                let now = clock.us();
                let sent = lock(&key_sent_us).clone();
                let upto = (seq as usize + 1).min(sent.len());
                let mut echoes = lock(&echoes);
                while echoed < upto {
                    echoes.push(now.saturating_sub(sent[echoed]));
                    echoed += 1;
                }
            }
        });
    }
    let mut keys_sent = 0u64;
    sleep_until(counted_from).await;
    let mut next = Instant::now();
    let mut seq = 0u32;
    while next < end {
        let now = clock.us();
        lock(&key_sent_us).push(now);
        if keys_tx.send(message(seq, now, 0, HEADER)).await.is_err() {
            break;
        }
        keys_sent += 1;
        seq += 1;
        next = next_tick(next, INPUT_INTERVAL);
        sleep_until(next).await;
    }
    // The last echoes: give each up to 5 s.
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline && (lock(&echoes).len() as u64) < keys_sent {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let counted = (end - counted_from).as_secs_f64();
    let goodput = flood_bytes.load(Ordering::Relaxed) as f64 * 8.0 / counted / 1e6;
    let mut echoes = lock(&echoes).clone();
    let missing = keys_sent.saturating_sub(echoes.len() as u64);
    let path = *connected.path.borrow();
    println!(
        "{{\"classes\":{},\"datagram_wins\":{},\"workload\":\"echo-flood\",\"transport\":\"{}\",\"row\":\"{}\",\"lan_rtt_ms\":{},\"relay_rtt_ms\":{},\"seconds\":{},\
         \"flood_mbps\":{},\"loss_pct\":{},\"keys_on_input_lane\":{},\"keys_sent\":{},\"echo_missing\":{},\
         \"echo_ms\":{},\"flood_goodput_mbit_s\":{:.1},\"final_path\":\"{:?}\"}}",
        link.class_datagrams(),
        link.datagram_wins(),
        args.transport,
        args.row,
        args.lan_rtt_ms,
        args.relay_rtt_ms,
        args.seconds,
        args.flood_mbps,
        args.loss_pct,
        keys_on_lane && on_input_stream,
        keys_sent,
        missing,
        percentiles(&mut echoes),
        goodput,
        path,
    );
}
