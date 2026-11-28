//! Typing on a phone over a shaped link, one keystroke at a time, for as
//! long as a person types: the harness behind "lag spikes in intervals when
//! just typing on phone" (Leo, 2026-11-24, LTE to his Mac).
//!
//! In one process: fake signaling, a loopback TURN server, a phone and a Mac
//! dialing a real WireGuard link, every datagram either tunnel receives
//! shaped by a cmux-fault link profile (`testing::shape_by_profile`). The
//! phone types `--rate` keys per second on a `keys` channel on the input
//! lane, as the app does; the Mac echoes each key on an `echo` channel on
//! the main stream, as the terminal's output comes back. Each key's echo
//! time is written with its send time, so a periodic spike shows up as a
//! period in the CSV.
//!
//! ```text
//! RUST_LOG=cmux_mobile_link=debug,cmux_wg=debug \
//! cargo run --release -p cmux-mobile-link --features testing --example typing_echo -- \
//!     --profile lte --seconds 600 --rate 10 --row both --csv /tmp/lte.csv 2>/tmp/lte.log
//! ```
//!
//! Rows: `both` (direct and TURN, the default), `relay-only`, `lan-only`.
//! The loopback TURN server answers the client's requests after
//! `--turn-answer-ms` (default: the profile's RTT), as a server a round trip
//! away does.
//! The CSV has `seq,sent_ms,echo_ms` (sent_ms from the start of typing;
//! the tracing log's uptime timestamps share that origin to within a
//! millisecond, so a spike's time can be matched to what the link logged).
//! `--radio lte` plays the phone's LTE radio going idle after
//! `--radio-tail-ms` (default 11576) with nothing on the air
//! (`testing::RadioModel`); `--burst-every-s N --burst-keys K` types K keys
//! at `--rate` every N seconds instead of without a pause, and the JSON's
//! `first_key_ms` is the echo of each burst's first key;
//! `--foreground-probe on` starts the phone's link with its foreground
//! probe on, as the app does with a terminal on screen.
//! `--prewake-lead-ms L` calls `Link::prewake` L ms before each burst's
//! first key, as the app does when the keyboard takes focus or a finger
//! touches down (RFD 0142 T2).
//! `--duress-kbps N` has the Mac stream N KB/s of output on a `bulk` channel
//! on the main stream while the phone types (an agent printing as you type).
//! Prints one JSON line: echo percentiles and the keys whose echo took more
//! than the profile's RTT plus 50 ms, and `key_paint`: the phone's key-to-paint
//! histogram (`cmux_mobile_link::key_paint`, the one the app reads) fed each
//! key's paint (its echo, then the next 16.7 ms vsync, then one frame, as the
//! terminal draws), tagged by the profile's network and the link's path, with
//! the gaps between spikes and the period they share, if any.

use std::io::Write as _;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use bytes::Bytes;
use cmux_mobile_link::dial::{self, SessionEvents};
use cmux_mobile_link::key_paint;
use cmux_mobile_link::testing::{
    FakeOptions, FakeSignaling, LinkProfile, PeriodicLoss, RadioModel, TestTurn, radio_wakes,
    set_link_profile, set_periodic_loss, set_radio_model, set_turn_answer_delay, shape_downlink,
    shape_uplink, shaped_counts,
};
use cmux_mobile_link::{ChannelEvent, DialOptions, Lane, LinkConfig, SignalingClient, TransportKind};
use tokio::time::{Instant, sleep_until};

const FRAME_US: u64 = 16_667;

struct Args {
    profile: String,
    seconds: u64,
    rate: f64,
    row: String,
    csv: Option<String>,
    seed: u64,
    turn_answer_ms: Option<u64>,
    radio: bool,
    radio_tail_ms: u64,
    burst_every_s: Option<f64>,
    burst_keys: u64,
    foreground_probe: bool,
    idle_air_gap_ms: Option<u64>,
    air_floor_ms: Option<u64>,
    prewake_lead_ms: Option<u64>,
    periodic_loss: Option<PeriodicLoss>,
    duress_kbps: u64,
}

fn args() -> Args {
    let mut parsed = Args {
        profile: "lte".into(),
        seconds: 600,
        rate: 10.0,
        row: "both".into(),
        csv: None,
        seed: 0x7e57_2024,
        turn_answer_ms: None,
        radio: false,
        radio_tail_ms: 11_576,
        burst_every_s: None,
        burst_keys: 5,
        foreground_probe: false,
        idle_air_gap_ms: None,
        air_floor_ms: None,
        prewake_lead_ms: None,
        periodic_loss: None,
        duress_kbps: 0,
    };
    let mut iter = std::env::args().skip(1);
    while let Some(flag) = iter.next() {
        let value = iter.next().unwrap_or_default();
        match flag.as_str() {
            "--profile" => parsed.profile = value,
            "--seconds" => parsed.seconds = value.parse().unwrap_or(600),
            "--rate" => parsed.rate = value.parse().unwrap_or(10.0),
            "--row" => parsed.row = value,
            "--csv" => parsed.csv = Some(value),
            "--seed" => parsed.seed = value.parse().unwrap_or(parsed.seed),
            "--turn-answer-ms" => parsed.turn_answer_ms = value.parse().ok(),
            "--radio" => parsed.radio = value == "lte",
            "--radio-tail-ms" => parsed.radio_tail_ms = value.parse().unwrap_or(parsed.radio_tail_ms),
            "--burst-every-s" => parsed.burst_every_s = value.parse().ok(),
            "--burst-keys" => parsed.burst_keys = value.parse().unwrap_or(5),
            "--foreground-probe" => parsed.foreground_probe = value == "on",
            "--idle-air-gap-ms" => parsed.idle_air_gap_ms = value.parse().ok(),
            "--air-floor-ms" => parsed.air_floor_ms = value.parse().ok(),
            "--prewake-lead-ms" => parsed.prewake_lead_ms = value.parse().ok(),
            // PERIOD_MS:BURST_MS:PERCENT, e.g. 15000:300:40 for a Starlink-like
            // reconfiguration every 15 s (RFD 0142 O5).
            "--periodic-loss" => parsed.periodic_loss = PeriodicLoss::parse(&value),
            "--duress-kbps" => parsed.duress_kbps = value.parse().unwrap_or(0),
            other => eprintln!("ignoring unknown flag {other}"),
        }
    }
    parsed
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// A key: its sequence number and when it was sent, in microseconds from
/// the start (16 bytes, about what a keystroke frame carries).
fn key(seq: u64, sent_us: u64) -> Bytes {
    let mut out = Vec::with_capacity(16);
    out.extend_from_slice(&seq.to_be_bytes());
    out.extend_from_slice(&sent_us.to_be_bytes());
    Bytes::from(out)
}

fn parse(bytes: &[u8]) -> Option<(u64, u64)> {
    let word = |at: usize| Some(u64::from_be_bytes(bytes.get(at..at + 8)?.try_into().ok()?));
    Some((word(0)?, word(8)?))
}

fn percentile(sorted: &[u64], p: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    sorted[((sorted.len() as f64 - 1.0) * p).round() as usize] as f64 / 1000.0
}

#[tokio::main(flavor = "multi_thread", worker_threads = 4)]
async fn main() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_timer(tracing_subscriber::fmt::time::uptime())
        .with_writer(std::io::stderr)
        .try_init();
    // The tracing uptime clock and this one start together.
    let origin = Instant::now();
    let us = move || u64::try_from(origin.elapsed().as_micros()).unwrap_or(u64::MAX);
    let args = args();
    let profile = LinkProfile::named(&args.profile);
    let threshold_us = (profile.rtt_ms + 50) * 1000;
    set_link_profile(Some(profile.clone()), args.seed);
    if args.radio {
        set_radio_model(Some(RadioModel {
            tail: Duration::from_millis(args.radio_tail_ms),
            ..RadioModel::lte()
        }));
    }
    set_periodic_loss(args.periodic_loss);
    // The TURN server is a round trip away, as a real one is: its answers to
    // the client's Allocate, Refresh, CreatePermission and ChannelBind wait
    // that long (the profile's RTT unless --turn-answer-ms says otherwise).
    let turn_answer_ms = args.turn_answer_ms.unwrap_or(profile.rtt_ms);
    set_turn_answer_delay(Duration::from_millis(turn_answer_ms));
    let turn = TestTurn::start().await;
    let mut options = DialOptions {
        include_loopback: true,
        timeout: Duration::from_secs(40),
        turn_tls_roots: Some(turn.roots.clone()),
        impair_inbound: Some(shape_uplink),
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
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.expect("mac");
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
                    // `--duress-kbps`: the Mac's output stream, 16 KiB at a time.
                    "bulk" => {
                        let kbps = incoming.args.get("kbps").and_then(serde_json::Value::as_u64).unwrap_or(0);
                        tokio::spawn(async move {
                            let _receiver = receiver;
                            let chunk = Bytes::from(vec![b'x'; 16 * 1024]);
                            let every = Duration::from_secs_f64(16.0 / kbps.max(1) as f64);
                            let mut at = Instant::now();
                            while kbps > 0 && sender.send(chunk.clone()).await.is_ok() {
                                at += every;
                                sleep_until(at.max(Instant::now())).await;
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
    options.impair_inbound = Some(shape_downlink);
    // `--air-floor-ms 0` turns the phone's floor off.
    if let Some(ms) = args.idle_air_gap_ms {
        options.idle_air_gap = (ms > 0).then(|| Duration::from_millis(ms));
    }
    if let Some(ms) = args.air_floor_ms {
        options.air_floor = (ms > 0).then(|| Duration::from_millis(ms));
    }
    let phone_config = LinkConfig { foreground_probe: args.foreground_probe, ..LinkConfig::default() };
    let phone_id = uuid::Uuid::new_v4().to_string();
    let phone =
        SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.expect("phone");
    let dial_start = us();
    let connected =
        dial::connect(&phone, &mac_id, TransportKind::WireGuard, &options, phone_config).await.expect("dial");
    let link = connected.link.clone();
    let (_echo_tx, mut echo_rx) = link.open("echo", serde_json::json!({})).await.expect("echo").split();
    let keys = link.open_on("keys", serde_json::json!({}), Lane::Input).await.expect("keys");
    let (keys_tx, _keys_rx) = keys.split();
    let on_input_stream = keys_tx.on_input_stream();
    let dialed_ms = (us() - dial_start) as f64 / 1000.0;
    if args.duress_kbps > 0 {
        let (_bulk_tx, mut bulk_rx) =
            link.open("bulk", serde_json::json!({ "kbps": args.duress_kbps })).await.expect("bulk").split();
        tokio::spawn(async move {
            let _bulk_tx = _bulk_tx;
            while let Some(ChannelEvent::Data(_)) = bulk_rx.recv().await {}
        });
    }
    // The phone's key-to-paint meter, as the app's: the profile's network, the path now.
    let net = if args.profile.contains("wifi") { "wifi" } else { "lte" };
    let meter: Arc<Mutex<key_paint::Meter>> = Arc::default();
    // (seq, sent_us, echo_us) per echoed key.
    let echoes: Arc<Mutex<Vec<(u64, u64, u64)>>> = Arc::default();
    {
        let echoes = echoes.clone();
        let meter = meter.clone();
        let path = connected.path.clone();
        tokio::spawn(async move {
            while let Some(ChannelEvent::Data(bytes)) = echo_rx.recv().await {
                if let Some((seq, sent)) = parse(&bytes) {
                    let now = us();
                    lock(&echoes).push((seq, sent, now.saturating_sub(sent)));
                    // Painted at the vsync after the echo is parsed, shown one frame later.
                    let painted = now.div_ceil(FRAME_US) * FRAME_US + FRAME_US;
                    let ms = u32::try_from(painted.saturating_sub(sent) / 1000).unwrap_or(u32::MAX);
                    let at = Duration::from_micros(now);
                    lock(&meter).record(ms, net, path.borrow().as_str(), at);
                }
            }
        });
    }
    let interval = Duration::from_secs_f64(1.0 / args.rate.max(0.1));
    let typing_from_us = us();
    let end = Instant::now() + Duration::from_secs(args.seconds);
    let mut next = Instant::now();
    let mut seq = 0u64;
    // The first key of each burst.
    let mut firsts = std::collections::HashSet::new();
    let mut burst_at = next;
    let mut in_burst = 0u64;
    // When the next pre-wake is due, and how many were sent.
    let mut prewake_at: Option<Instant> = None;
    let mut prewakes = 0u64;
    // A fixed rate, never catching up: a stalled send shows as a gap in
    // sent_ms, not as a burst.
    while next < end {
        if in_burst == 0 {
            firsts.insert(seq);
        }
        if keys_tx.send(key(seq, us())).await.is_err() {
            break;
        }
        seq += 1;
        next += interval;
        if let Some(every) = args.burst_every_s {
            in_burst += 1;
            if in_burst >= args.burst_keys {
                in_burst = 0;
                burst_at += Duration::from_secs_f64(every);
                next = next.max(burst_at);
                // None for a burst past the end: the loop sends none of its keys.
                prewake_at = args
                    .prewake_lead_ms
                    .filter(|_| burst_at < end)
                    .map(|lead| burst_at - Duration::from_millis(lead));
            }
        }
        let now = Instant::now();
        while next < now {
            next += interval;
        }
        if let Some(at) = prewake_at.take()
            && at > now
        {
            sleep_until(at).await;
            prewakes += u64::from(link.prewake());
        }
        sleep_until(next).await;
    }
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline && (lock(&echoes).len() as u64) < seq {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let rows = lock(&echoes).clone();
    if let Some(path) = &args.csv {
        let mut file = std::io::BufWriter::new(std::fs::File::create(path).expect("csv"));
        let _ = writeln!(file, "seq,sent_ms,echo_ms");
        for (seq, sent, echo) in &rows {
            let _ = writeln!(file, "{seq},{:.3},{:.3}", *sent as f64 / 1000.0, *echo as f64 / 1000.0);
        }
    }
    let mut sorted: Vec<u64> = rows.iter().map(|row| row.2).collect();
    sorted.sort_unstable();
    let spikes: Vec<String> = rows
        .iter()
        .filter(|row| row.2 > threshold_us)
        .map(|row| format!("[{:.0},{:.0}]", row.1 as f64 / 1000.0, row.2 as f64 / 1000.0))
        .collect();
    let (delivered, dropped) = shaped_counts();
    let mut first_sorted: Vec<u64> = rows
        .iter()
        .filter(|row| args.burst_every_s.is_some() && firsts.contains(&row.0))
        .map(|row| row.2)
        .collect();
    first_sorted.sort_unstable();
    let first_key = format!(
        "{{\"n\":{},\"p50\":{:.1},\"p90\":{:.1},\"max\":{:.1}}}",
        first_sorted.len(),
        percentile(&first_sorted, 0.5),
        percentile(&first_sorted, 0.9),
        percentile(&first_sorted, 1.0)
    );
    let wakes = radio_wakes();
    let path = *connected.path.borrow();
    println!(
        "{{\"workload\":\"typing\",\"profile\":\"{}\",\"row\":\"{}\",\"seconds\":{},\"rate\":{},\
         \"dial_ms\":{dialed_ms:.0},\"typing_from_ms\":{:.0},\"keys_on_input_lane\":{on_input_stream},\
         \"keys_sent\":{seq},\"echoed\":{},\"echo_ms\":{{\"p50\":{:.1},\"p95\":{:.1},\"p99\":{:.1},\"max\":{:.1}}},\
         \"turn_answer_ms\":{turn_answer_ms},\"threshold_ms\":{},\"over_threshold\":{},\"datagrams\":[{delivered},{dropped}],\
         \"final_path\":\"{path:?}\",\"radio\":{},\"radio_tail_ms\":{},\"foreground_probe\":{},\"idle_air_gap_ms\":{},\"air_floor_ms\":{},\"periodic_loss\":{},\"prewake_lead_ms\":{},\"prewakes\":{prewakes},\"radio_wakes\":{wakes},\"first_key_ms\":{first_key},\"duress_kbps\":{},\"key_paint\":{},\"spikes\":[{}]}}",
        args.profile,
        args.row,
        args.seconds,
        args.rate,
        typing_from_us as f64 / 1000.0,
        rows.len(),
        percentile(&sorted, 0.5),
        percentile(&sorted, 0.95),
        percentile(&sorted, 0.99),
        percentile(&sorted, 1.0),
        threshold_us / 1000,
        spikes.len(),
        args.radio,
        args.radio_tail_ms,
        args.foreground_probe,
        args.idle_air_gap_ms.map_or("null".to_string(), |ms| ms.to_string()),
        args.air_floor_ms.map_or("null".to_string(), |ms| ms.to_string()),
        args.periodic_loss.map_or("null".to_string(), |loss| format!(
            "\"{}:{}:{}\"",
            loss.period.as_millis(),
            loss.burst.as_millis(),
            loss.loss_percent
        )),
        args.prewake_lead_ms.map_or("null".to_string(), |ms| ms.to_string()),
        args.duress_kbps,
        serde_json::to_string(&lock(&meter).snapshot()).unwrap_or_default(),
        spikes.join(","),
    );
    std::process::exit(0);
}
