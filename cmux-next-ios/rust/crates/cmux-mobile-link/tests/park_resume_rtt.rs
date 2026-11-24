//! Measurement, not a check (ignored by default): resume to the first frame for a parked link
//! (PROTOCOL.md "Parked link") against a full redial, at a 20 ms and a 300 ms round trip.
//!
//! Both ends' tunnel datagrams are held for half the round trip on receive
//! (`DialOptions::impair_inbound`), switched on just before the timed step: the link under test
//! is dialed undelayed, so only the resume or the redial pays the round trip. The signaling legs
//! to the in-process fake are not delayed, so the redial figure is a lower bound: a real redial
//! also pays the token, the signaling Worker and the internet round trips of offer and answer.
//!
//! - parked: the phone parks, stays silent, then `resume` (the tunnel roams onto a fresh socket),
//!   one probe (1.5 s, as the app), and the first frame back on the channel it had before the park.
//! - redial: what the app does without a park: a new `dial::connect` on the same signaling
//!   client, a new channel, and its first frame back. `null` when the dial timed out (25 s).
//!
//! `cargo test -p cmux-mobile-link --test park_resume_rtt -- --ignored --nocapture`
//! prints one `PARK_RESUME_RTT {json}` line per case.
//!
//! `profiles` plays cmux-fault's named phone links (`lte`, `lossy-3`: rate, delay, jitter and loss
//! per datagram, `testing::shape_by_profile`) instead of a fixed delay, each idle and under
//! duress: the Mac streams 512-byte frames every 10 ms on the channel from just before the park
//! (a terminal or chat streaming while the phone locks), so the parked Mac holds a backlog the
//! resume must flush ahead of the first echo. It prints `PARK_RESUME_PROFILE {json}`; the profile
//! is process-wide, so run it alone: `... --test park_resume_rtt profiles -- --ignored --nocapture`.

use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_mobile_link::dial::{self, SessionEvents};
use cmux_mobile_link::testing::{
    FakeOptions, FakeSignaling, LinkProfile, set_link_profile, shape_by_profile, shaped_counts,
};
use cmux_mobile_link::{
    Channel, ChannelEvent, DialOptions, Link, LinkConfig, SignalingClient, TransportKind,
};
use serde_json::json;

/// One delay per test (tests in this file run in parallel), in ms one way.
static ONE_WAY_MS: [AtomicU64; 4] = [const { AtomicU64::new(0) }; 4];

/// Every tunnel datagram arrives `ONE_WAY_MS[SLOT]` late.
fn impair<const SLOT: usize>(_via_turn: bool, _from: &SocketAddr, _len: usize) -> Option<Duration> {
    Some(Duration::from_millis(ONE_WAY_MS[SLOT].load(Ordering::Relaxed)))
}

fn ms(duration: Duration) -> f64 {
    (duration.as_secs_f64() * 10_000.0).round() / 10.0
}

struct Bench {
    _server: FakeSignaling,
    phone: SignalingClient,
    mac_id: String,
    options: DialOptions,
    slot: usize,
    rtt_ms: u64,
    /// A named link profile instead of a fixed delay (`delay` switches it).
    profile: Option<LinkProfile>,
    /// The Mac streams on the echo channel once the phone sends `go`.
    duress: bool,
}

impl Bench {
    async fn start<const SLOT: usize>(rtt_ms: u64) -> Bench {
        let options = DialOptions {
            include_loopback: true,
            impair_inbound: Some(impair::<SLOT>),
            ..DialOptions::default()
        };
        Self::start_with(options, SLOT, rtt_ms, None, false).await
    }

    async fn start_profiled(profile: &str, duress: bool) -> Bench {
        let profile = LinkProfile::named(profile);
        let options = DialOptions {
            include_loopback: true,
            impair_inbound: Some(shape_by_profile),
            timeout: Duration::from_secs(40),
            ..DialOptions::default()
        };
        let rtt_ms = profile.rtt_ms;
        Self::start_with(options, 0, rtt_ms, Some(profile), duress).await
    }

    async fn start_with(
        options: DialOptions,
        slot: usize,
        rtt_ms: u64,
        profile: Option<LinkProfile>,
        duress: bool,
    ) -> Bench {
        let server = FakeSignaling::start(FakeOptions::default()).await;
        let mac_id = uuid::Uuid::new_v4().to_string();
        let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
        let mac_options = options.clone();
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
                            let mut streaming = false;
                            let mut tick = tokio::time::interval(Duration::from_millis(10));
                            loop {
                                tokio::select! {
                                    event = incoming.channel.recv() => {
                                        let Some(ChannelEvent::Data(bytes)) = event else { break };
                                        if duress && bytes.as_ref() == b"go" {
                                            streaming = true;
                                        } else {
                                            let _ = incoming.channel.send(bytes).await;
                                        }
                                    }
                                    _ = tick.tick(), if streaming => {
                                        let _ = incoming.channel.send(Bytes::from(vec![b'S'; 512])).await;
                                    }
                                }
                            }
                        });
                    }
                });
            }
        });
        let phone_id = uuid::Uuid::new_v4().to_string();
        let phone =
            SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
        Bench { _server: server, phone, mac_id, options, slot, rtt_ms, profile, duress }
    }

    fn delay(&self, on: bool) {
        if let Some(profile) = &self.profile {
            set_link_profile(on.then(|| profile.clone()), 0x5052_0000);
            return;
        }
        ONE_WAY_MS[self.slot].store(if on { self.rtt_ms / 2 } else { 0 }, Ordering::Relaxed);
    }

    /// A link with an echo channel that carried one frame; `None` when the dial failed.
    async fn link_up(&self) -> Option<(Link, String, Channel)> {
        let connected = match dial::connect(
            &self.phone,
            &self.mac_id,
            TransportKind::WireGuard,
            &self.options,
            LinkConfig::default(),
        )
        .await
        {
            Ok(connected) => connected,
            Err(error) => {
                println!("dial failed at {} ms RTT: {error:?}", self.rtt_ms);
                return None;
            }
        };
        let mut channel = connected.link.open("echo", json!({})).await.expect("channel");
        echo(&mut channel, b"before").await;
        Some((connected.link, connected.session_id, channel))
    }
}

/// Send `frame` and return the number of stream data frames seen before its
/// exact echo, including output from before, during and after the park.
async fn echo(channel: &mut Channel, frame: &'static [u8]) -> usize {
    channel.send(Bytes::from_static(frame)).await.unwrap();
    let mut preceding_frames = 0;
    let back = loop {
        let back =
            tokio::time::timeout(Duration::from_secs(20), channel.recv()).await.expect("the first frame");
        // The duress stream's frames (`S...`) are not the echo.
        if !matches!(back, Some(ChannelEvent::Data(ref bytes)) if bytes.first() == Some(&b'S')) {
            break back;
        }
        preceding_frames += 1;
    };
    assert!(matches!(back, Some(ChannelEvent::Data(ref bytes)) if bytes.as_ref() == frame), "{back:?}");
    preceding_frames
}

/// Resume to the first frame of a parked link, after `silent`: (probe ms,
/// first frame ms, stream frames before the exact echo).
async fn parked(bench: &Bench, silent: Duration) -> (f64, f64, usize) {
    bench.delay(false);
    let (link, session_id, mut channel) = bench.link_up().await.expect("the phone links up");
    if bench.duress {
        channel.send(Bytes::from_static(b"go")).await.unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(link.park(Duration::from_secs(600), Duration::from_secs(5)).await.unwrap(), "parked");
    tokio::time::sleep(silent).await;
    bench.delay(true);
    let start = Instant::now();
    assert!(link.resume(), "the park had already ended");
    dial::wireguard::resume_session(&session_id);
    link.probe(Duration::from_millis(1_500)).await.expect("the resumed link answers its probe");
    let probed = ms(start.elapsed());
    let preceding_frames = echo(&mut channel, b"after").await;
    let first_frame = ms(start.elapsed());
    assert!(!link.is_parked());
    link.close("done");
    (probed, first_frame, preceding_frames)
}

/// A full redial to the first frame: the old link closed, a new dial, a new channel.
async fn redial(bench: &Bench) -> Option<f64> {
    bench.delay(false);
    let (link, _, _channel) = bench.link_up().await.expect("the phone links up");
    link.close("background");
    bench.delay(true);
    let start = Instant::now();
    let linked = bench.link_up().await;
    let first_frame = ms(start.elapsed());
    let (link, _, _channel) = linked?;
    link.close("done");
    Some(first_frame)
}

fn median(mut values: Vec<f64>) -> Option<f64> {
    values.sort_by(f64::total_cmp);
    values.get(values.len() / 2).copied()
}

fn round_trips(ms: Option<f64>, rtt_ms: u64) -> Option<f64> {
    ms.map(|ms| (ms / rtt_ms as f64 * 10.0).round() / 10.0)
}

async fn measure(bench: Bench, samples: usize, silent: Duration) {
    let (mut probe, mut first, mut redials, mut redial_failures) = (Vec::new(), Vec::new(), Vec::new(), 0);
    for _ in 0..samples {
        let (probed, first_frame, _) = parked(&bench, silent).await;
        probe.push(probed);
        first.push(first_frame);
        match redial(&bench).await {
            Some(ms) => redials.push(ms),
            None => redial_failures += 1,
        }
    }
    let rtt = bench.rtt_ms;
    let (parked_ms, redial_ms) = (median(first.clone()), median(redials.clone()));
    println!(
        "PARK_RESUME_RTT {}",
        json!({"rtt_ms": rtt, "silent_s": silent.as_secs(), "samples": samples,
               "parked": {"probe_ms": median(probe), "first_frame_ms": parked_ms,
                          "round_trips": round_trips(parked_ms, rtt), "all_first_frame_ms": first},
               "redial": {"first_frame_ms": redial_ms, "round_trips": round_trips(redial_ms, rtt),
                          "all_first_frame_ms": redials, "timed_out": redial_failures}})
    );
}

/// A session under 120 s old: the roam's reassertion is a keepalive.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "measurement"]
async fn rtt_20ms() {
    measure(Bench::start::<0>(20).await, 5, Duration::from_secs(2)).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "measurement"]
async fn rtt_300ms() {
    measure(Bench::start::<1>(300).await, 3, Duration::from_secs(2)).await;
}

/// Away past 120 s: the roam's reassertion is a handshake (one more round trip).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "measurement"]
async fn rtt_20ms_after_125s() {
    measure(Bench::start::<2>(20).await, 1, Duration::from_secs(125)).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "measurement"]
async fn rtt_300ms_after_125s() {
    measure(Bench::start::<3>(300).await, 1, Duration::from_secs(125)).await;
}

/// Resume against a redial under each named profile, idle and under duress (see the module doc).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "measurement"]
async fn profiles() {
    let names = std::env::var("PARK_PROFILES").unwrap_or_else(|_| "lte,lossy-3".into());
    for name in names.split(',').map(str::trim).filter(|name| !name.is_empty()) {
        for duress in [false, true] {
            let bench = Bench::start_profiled(name, duress).await;
            let samples = 5;
            let (mut probe, mut first, mut stream_frames, mut redials, mut redial_failures) =
                (Vec::new(), Vec::new(), Vec::new(), Vec::new(), 0);
            for _ in 0..samples {
                let (probed, first_frame, preceding_frames) = parked(&bench, Duration::from_secs(2)).await;
                probe.push(probed);
                first.push(first_frame);
                stream_frames.push(preceding_frames);
                match redial(&bench).await {
                    Some(ms) => redials.push(ms),
                    None => redial_failures += 1,
                }
            }
            let (parked_ms, redial_ms) = (median(first.clone()), median(redials.clone()));
            let (delivered, dropped) = shaped_counts();
            println!(
                "PARK_RESUME_PROFILE {}",
                json!({"profile": name, "duress": duress, "silent_s": 2, "samples": samples,
                       "parked": {"probe_ms": median(probe.clone()), "first_frame_ms": parked_ms,
                                  "all_probe_ms": probe, "all_first_frame_ms": first,
                                  "stream_frames_before_echo": stream_frames},
                       "redial": {"first_frame_ms": redial_ms, "all_first_frame_ms": redials,
                                  "timed_out": redial_failures},
                       "datagrams_delivered": delivered, "datagrams_dropped": dropped})
            );
            set_link_profile(None, 0);
        }
    }
}
