//! Measurement, not a check (ignored by default): resume to the first frame for a parked link
//! (PROTOCOL.md "Parked link") against a full redial, at a 20 ms and a 300 ms round trip.
//!
//! Both ends' tunnel datagrams are held for half the round trip on receive
//! (`DialOptions::impair_inbound`). The signaling legs to the in-process fake are not delayed, so
//! the redial figure is a lower bound: a real redial also pays the token, the signaling Worker and
//! the internet round trips of offer and answer.
//!
//! - parked: the phone parks, stays silent, then `resume` (the tunnel roams onto a fresh socket),
//!   one probe, and the first frame back on the channel it had before the park.
//! - redial: what the app does without a park: a new `dial::connect` on the same signaling
//!   client, a new channel, and its first frame back.
//!
//! `cargo test -p cmux-mobile-link --test park_resume_rtt -- --ignored --nocapture --test-threads 4`
//! prints one `PARK_RESUME_RTT {json}` line per case.

use std::net::SocketAddr;
use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_mobile_link::dial::{self, SessionEvents};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_mobile_link::{
    Channel, ChannelEvent, DialOptions, Link, LinkConfig, SignalingClient, TransportKind,
};
use serde_json::json;

/// Every tunnel datagram arrives `ONE_WAY_MS` late: a round trip of twice that.
fn impair<const ONE_WAY_MS: u64>(_via_turn: bool, _from: &SocketAddr) -> Option<Duration> {
    Some(Duration::from_millis(ONE_WAY_MS))
}

fn options(impair: fn(bool, &SocketAddr) -> Option<Duration>) -> DialOptions {
    DialOptions { include_loopback: true, impair_inbound: Some(impair), ..DialOptions::default() }
}

fn ms(duration: Duration) -> f64 {
    (duration.as_secs_f64() * 10_000.0).round() / 10.0
}

struct Bench {
    _server: FakeSignaling,
    phone: SignalingClient,
    mac_id: String,
    options: DialOptions,
}

impl Bench {
    async fn start(impair: fn(bool, &SocketAddr) -> Option<Duration>) -> Bench {
        let server = FakeSignaling::start(FakeOptions::default()).await;
        let mac_id = uuid::Uuid::new_v4().to_string();
        let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
        let mac_options = options(impair);
        tokio::spawn(async move {
            while let Some(session) = mac.next_session().await {
                let events = SessionEvents {
                    backend: mac.events(),
                    session_id: session.first.session_id.clone(),
                    session: session.events,
                };
                let (mac, options) = (mac.clone(), mac_options.clone());
                tokio::spawn(async move {
                    let Ok(connected) =
                        dial::answer(&mac, session.first, events, &options, LinkConfig::default()).await
                    else {
                        return;
                    };
                    while let Some(mut incoming) = connected.link.accept().await {
                        tokio::spawn(async move {
                            while let Some(ChannelEvent::Data(bytes)) = incoming.channel.recv().await {
                                let _ = incoming.channel.send(bytes).await;
                            }
                        });
                    }
                });
            }
        });
        let phone_id = uuid::Uuid::new_v4().to_string();
        let phone =
            SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
        Bench { _server: server, phone, mac_id, options: options(impair) }
    }

    /// A link with an echo channel that carried one frame.
    async fn link_up(&self) -> (Link, String, Channel) {
        let connected = dial::connect(
            &self.phone,
            &self.mac_id,
            TransportKind::WireGuard,
            &self.options,
            LinkConfig::default(),
        )
        .await
        .expect("the phone links up");
        let mut channel = connected.link.open("echo", json!({})).await.expect("channel");
        echo(&mut channel, b"before").await;
        (connected.link, connected.session_id, channel)
    }
}

async fn echo(channel: &mut Channel, frame: &'static [u8]) {
    channel.send(Bytes::from_static(frame)).await.unwrap();
    let back = tokio::time::timeout(Duration::from_secs(10), channel.recv()).await.expect("the first frame");
    assert!(matches!(back, Some(ChannelEvent::Data(ref bytes)) if bytes.as_ref() == frame), "{back:?}");
}

/// Resume to the first frame of a parked link, after `silent`.
async fn parked(bench: &Bench, silent: Duration) -> (f64, f64) {
    let (link, session_id, mut channel) = bench.link_up().await;
    assert!(link.park(Duration::from_secs(600), Duration::from_secs(5)).await.unwrap(), "parked");
    tokio::time::sleep(silent).await;
    let start = Instant::now();
    assert!(link.resume(), "the park had already ended");
    dial::wireguard::resume_session(&session_id);
    link.probe(Duration::from_millis(1_500)).await.expect("the resumed link answers its probe");
    let probed = ms(start.elapsed());
    echo(&mut channel, b"after").await;
    let first_frame = ms(start.elapsed());
    assert!(!link.is_parked());
    link.close("done");
    (probed, first_frame)
}

/// A full redial to the first frame: the old link closed, a new dial, a new channel.
async fn redial(bench: &Bench) -> f64 {
    let (link, _, _channel) = bench.link_up().await;
    link.close("background");
    let start = Instant::now();
    let (link, _, _channel) = bench.link_up().await;
    let first_frame = ms(start.elapsed());
    link.close("done");
    first_frame
}

fn median(mut values: Vec<f64>) -> f64 {
    values.sort_by(f64::total_cmp);
    values[values.len() / 2]
}

const SAMPLES: usize = 5;

async fn measure(rtt_ms: u64, impair: fn(bool, &SocketAddr) -> Option<Duration>, silent: Duration) {
    let bench = Bench::start(impair).await;
    let mut probe = Vec::new();
    let mut first = Vec::new();
    let mut redials = Vec::new();
    for _ in 0..SAMPLES {
        let (probed, first_frame) = parked(&bench, silent).await;
        probe.push(probed);
        first.push(first_frame);
        redials.push(redial(&bench).await);
    }
    let rtt = rtt_ms as f64;
    let round_trips = |ms: f64| (ms / rtt * 10.0).round() / 10.0;
    let (parked_ms, redial_ms) = (median(first.clone()), median(redials.clone()));
    println!(
        "PARK_RESUME_RTT {}",
        json!({"rtt_ms": rtt_ms, "silent_s": silent.as_secs(), "samples": SAMPLES,
               "parked": {"probe_ms": median(probe.clone()), "first_frame_ms": parked_ms,
                          "round_trips": round_trips(parked_ms), "all_first_frame_ms": first},
               "redial": {"first_frame_ms": redial_ms, "round_trips": round_trips(redial_ms),
                          "all_first_frame_ms": redials}})
    );
}

/// A session under 120 s old: the roam's reassertion is a keepalive.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "measurement"]
async fn rtt_20ms() {
    measure(20, impair::<10>, Duration::from_secs(2)).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "measurement"]
async fn rtt_300ms() {
    measure(300, impair::<150>, Duration::from_secs(2)).await;
}

/// Away past 120 s: the roam's reassertion is a handshake (one more round trip).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "measurement"]
async fn rtt_20ms_after_125s() {
    let bench = Bench::start(impair::<10>).await;
    let (probed, first_frame) = parked(&bench, Duration::from_secs(125)).await;
    let redial_ms = redial(&bench).await;
    println!(
        "PARK_RESUME_RTT {}",
        json!({"rtt_ms": 20, "silent_s": 125, "samples": 1,
               "parked": {"probe_ms": probed, "first_frame_ms": first_frame, "round_trips": (first_frame / 2.0).round() / 10.0},
               "redial": {"first_frame_ms": redial_ms, "round_trips": (redial_ms / 2.0).round() / 10.0}})
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "measurement"]
async fn rtt_300ms_after_125s() {
    let bench = Bench::start(impair::<150>).await;
    let (probed, first_frame) = parked(&bench, Duration::from_secs(125)).await;
    let redial_ms = redial(&bench).await;
    println!(
        "PARK_RESUME_RTT {}",
        json!({"rtt_ms": 300, "silent_s": 125, "samples": 1,
               "parked": {"probe_ms": probed, "first_frame_ms": first_frame, "round_trips": (first_frame / 30.0).round() / 10.0},
               "redial": {"first_frame_ms": redial_ms, "round_trips": (redial_ms / 30.0).round() / 10.0}})
    );
}
