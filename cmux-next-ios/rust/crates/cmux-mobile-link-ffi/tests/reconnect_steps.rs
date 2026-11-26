//! Reconnect steps (iOS chat reconnect, ask-48f698fc26): what the phone does when the app comes back
//! to the foreground or its network changes, timed step by step on the exported API the app calls.
//!
//! The rig: the app's own warm pool (`WarmPool`), the fake service (`FakeSignaling`) behind a TCP
//! proxy that adds a phone network's round trip to every byte and can cut the connections it holds
//! without closing them (a phone that slept, a NAT that forgot the socket), an echo Mac, and the
//! real STUN servers the fake service lists. A sample is what the app does on `.resume`
//! (`LiveCoordinator.foreground` and `LinkMachine`): `prewarm` and a fresh dial at once, then the
//! first channel and its first event.
//!
//! Ignored by default (they time themselves and wait out a suspension): run alone, in release,
//! `cargo test --release -p cmux-mobile-link-ffi --test reconnect_steps -- --ignored --nocapture --test-threads=1`.
//! Each sample prints one `RECONNECT {json}` line; each scenario ends with a `RECONNECT_SUMMARY`
//! line (n, p50 and p95 of every step).

use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use cmux_mobile_link::dial::{self, SessionEvents};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_mobile_link::{ChannelEvent, DialOptions, LinkConfig, SignalingClient};
use cmux_mobile_link_ffi::{ChannelMessage, ConnectRequest, Transport, WarmPool};
use serde_json::json;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

/// A phone network's round trip to the service (LTE, good signal).
const RTT: Duration = Duration::from_millis(80);
/// Samples per scenario.
const SAMPLES: usize = 20;
/// How long the phone stays in the background with its sockets cut: longer than one signaling
/// keepalive (15 s), so the socket missed a pong, as after any background of more than a moment.
const SUSPENDED: Duration = Duration::from_secs(20);
/// How long a dial waits on a reused socket that does not answer (`STALE_PROBE` in the crate).
const STALE_PROBE_MS: f64 = 2500.0;

fn spawn_echo_mac(mac: SignalingClient) {
    tokio::spawn(async move {
        while let Some(session) = mac.next_session().await {
            let first = session.first;
            let events = SessionEvents {
                backend: mac.events(),
                session_id: first.session_id.clone(),
                session: session.events,
            };
            let mac = mac.clone();
            tokio::spawn(async move {
                let options = DialOptions { include_loopback: true, ..DialOptions::default() };
                let Ok(connected) = dial::answer(&mac, first, events, &options, LinkConfig::default()).await
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
}

/// The phone's path to the service: half of [`RTT`] each way, and `cut` silences every
/// connection open now (bytes vanish, nothing closes), as a sleeping phone's do. With
/// `blackhole` on, a new connection is accepted and then hears nothing (a new route that drops
/// its packets), while the connections already open keep working.
struct PhonePath {
    url: String,
    generation: Arc<AtomicU64>,
    blackholed: Arc<std::sync::atomic::AtomicBool>,
}

impl PhonePath {
    async fn start(upstream: &str) -> Self {
        let target = upstream.trim_start_matches("http://").trim_end_matches('/').to_owned();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let generation = Arc::new(AtomicU64::new(0));
        let blackholed = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let shared = Arc::clone(&generation);
        let holes = Arc::clone(&blackholed);
        tokio::spawn(async move {
            while let Ok((phone, _)) = listener.accept().await {
                if holes.load(Ordering::SeqCst) {
                    // Held open, never answered: the dial waits on it as on a dropped SYN.
                    tokio::spawn(async move {
                        let _phone = phone;
                        std::future::pending::<()>().await;
                    });
                    continue;
                }
                let born = shared.load(Ordering::SeqCst);
                let Ok(service) = TcpStream::connect(&target).await else { continue };
                let (phone_read, phone_write) = phone.into_split();
                let (service_read, service_write) = service.into_split();
                tokio::spawn(pump(phone_read, service_write, born, Arc::clone(&shared)));
                tokio::spawn(pump(service_read, phone_write, born, Arc::clone(&shared)));
            }
        });
        Self { url, generation, blackholed }
    }

    fn cut(&self) {
        self.generation.fetch_add(1, Ordering::SeqCst);
    }

    fn blackhole(&self, on: bool) {
        self.blackholed.store(on, Ordering::SeqCst);
    }
}

async fn pump(
    mut read: tokio::net::tcp::OwnedReadHalf,
    write: tokio::net::tcp::OwnedWriteHalf,
    born: u64,
    generation: Arc<AtomicU64>,
) {
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<(tokio::time::Instant, Vec<u8>)>();
    tokio::spawn(async move {
        let mut write = write;
        while let Some((due, bytes)) = rx.recv().await {
            tokio::time::sleep_until(due).await;
            if write.write_all(&bytes).await.is_err() {
                return;
            }
        }
        // Kept open, never closed: a cut connection stays half open.
        std::future::pending::<()>().await;
    });
    let mut buffer = vec![0u8; 32 * 1024];
    loop {
        let n = match read.read(&mut buffer).await {
            Ok(0) | Err(_) => {
                // A cut connection never tells the other end.
                if generation.load(Ordering::SeqCst) != born {
                    std::future::pending::<()>().await;
                }
                return;
            }
            Ok(n) => n,
        };
        if generation.load(Ordering::SeqCst) != born {
            continue;
        }
        if tx.send((tokio::time::Instant::now() + RTT / 2, buffer[..n].to_vec())).is_err() {
            return;
        }
    }
}

struct Rig {
    _server: FakeSignaling,
    path: PhonePath,
    pool: WarmPool,
    device: String,
    mac: String,
}

impl Rig {
    async fn start() -> Self {
        let server = FakeSignaling::start(FakeOptions::default()).await;
        let mac = uuid::Uuid::new_v4().to_string();
        spawn_echo_mac(SignalingClient::connect(&server.base_url, "user:alice", "team", &mac).await.unwrap());
        let path = PhonePath::start(&server.base_url).await;
        Self { _server: server, path, pool: WarmPool::new(), device: uuid::Uuid::new_v4().to_string(), mac }
    }

    fn request(&self) -> ConnectRequest {
        ConnectRequest {
            base_url: self.path.url.clone(),
            token: "user:alice".into(),
            team_id: "team".into(),
            device_id: self.device.clone(),
            mac_device_id: self.mac.clone(),
            transport: Transport::WireGuard,
            include_loopback: true,
            relay_only: false,
            block_udp: false,
            proxy_only: false,
            drop_wireguard: false,
            force_relay: false,
            video_lane: false,
            webrtc_media: false,
            ultra: cmux_mobile_link::UltraSetting::Off,
        }
    }

    /// What `.resume` does: `prewarm` and a fresh dial at once, then the first channel's first
    /// event. Every step in ms from the start.
    async fn resume(&self) -> BTreeMap<String, f64> {
        self.resume_once().await.expect("redial or first echo")
    }

    async fn resume_once(&self) -> Option<BTreeMap<String, f64>> {
        let start = Instant::now();
        let (warmed, handle) = tokio::join!(
            self.pool.prewarm(self.path.url.clone(), "user:alice".into(), "team".into(), self.device.clone()),
            self.pool.connect(self.request(), None),
        );
        let handle = handle.ok()?;
        let mut steps = BTreeMap::new();
        for mark in handle.timings() {
            steps.insert(mark.name, mark.millis);
        }
        for mark in warmed {
            steps.insert(format!("prewarm:{}", mark.name), mark.millis);
        }
        steps.insert("dialed".into(), ms(start.elapsed()));
        let channel = handle.open_channel("echo".into(), String::new()).await.ok()?;
        steps.insert("channel_opened".into(), ms(start.elapsed()));
        channel.send(b"first".to_vec()).await.ok()?;
        let echoed = tokio::time::timeout(Duration::from_secs(20), channel.recv()).await.ok()?;
        if echoed != (ChannelMessage::Data { bytes: b"first".to_vec() }) {
            return None;
        }
        steps.insert("first_event".into(), ms(start.elapsed()));
        handle.close();
        Some(steps)
    }

    /// A link up and idle, as the chat is before the app leaves the foreground.
    async fn settle(&self) {
        let _ = self
            .pool
            .prewarm(self.path.url.clone(), "user:alice".into(), "team".into(), self.device.clone())
            .await;
        let handle = self.pool.connect(self.request(), None).await.expect("connect");
        handle.close();
    }
}

fn ms(duration: Duration) -> f64 {
    (duration.as_secs_f64() * 10_000.0).round() / 10.0
}

fn percentile(sorted: &[f64], p: f64) -> f64 {
    let rank = ((p * sorted.len() as f64).ceil() as usize).clamp(1, sorted.len());
    sorted[rank - 1]
}

fn summarize(scenario: &str, samples: &[BTreeMap<String, f64>]) {
    let mut steps: BTreeMap<String, Vec<f64>> = BTreeMap::new();
    for sample in samples {
        for (name, at) in sample {
            steps.entry(name.clone()).or_default().push(*at);
        }
    }
    // One short line per step: CI logs cut long lines.
    for (name, mut values) in steps {
        values.sort_by(f64::total_cmp);
        println!(
            "RECONNECT_STEP {}",
            json!({"scenario": scenario, "rtt_ms": ms(RTT), "step": name, "n": values.len(),
                   "p50": percentile(&values, 0.5), "p95": percentile(&values, 0.95)})
        );
    }
    let mut first_events: Vec<_> =
        samples.iter().filter_map(|sample| sample.get("first_event").copied()).collect();
    if !first_events.is_empty() {
        first_events.sort_by(f64::total_cmp);
        println!(
            "RECONNECT_SUMMARY {}",
            json!({"scenario": scenario, "n": samples.len(), "ok": first_events.len(),
                   "first_event_p50": percentile(&first_events, 0.5),
                   "first_event_p95": percentile(&first_events, 0.95)})
        );
    }
}

/// Foreground after a short background: the warm socket still answers.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "timed rig: run alone with --ignored"]
async fn resume_with_a_live_socket() {
    let rig = Rig::start().await;
    rig.settle().await;
    let mut samples = Vec::new();
    for sample in 0..SAMPLES {
        tokio::time::sleep(Duration::from_millis(500)).await;
        let steps = rig.resume().await;
        println!("RECONNECT {}", json!({"scenario": "resume_live_socket", "sample": sample, "steps": steps}));
        samples.push(steps);
    }
    summarize("resume_live_socket", &samples);
}

/// Foreground after a background long enough to miss a keepalive, its sockets silently dead (a
/// phone that slept, a NAT that forgot it): the case of a chat opened after the phone was away.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "timed rig: run alone with --ignored"]
async fn resume_after_a_suspension() {
    let rig = Rig::start().await;
    let mut samples = Vec::new();
    for sample in 0..SAMPLES {
        rig.settle().await;
        rig.path.cut();
        tokio::time::sleep(SUSPENDED).await;
        let steps = rig.resume().await;
        println!(
            "RECONNECT {}",
            json!({"scenario": "resume_after_suspension", "sample": sample, "steps": steps})
        );
        samples.push(steps);
    }
    summarize("resume_after_suspension", &samples);
}

/// FFI-path redial timing harness. Run once idle and once while the mobile-link
/// duress matrix runs in another process, with the load label in the summary.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "timed FFI redial measurement"]
async fn ffi_redial_first_echo_n20() {
    let scenario = std::env::var("RECONNECT_SCENARIO").unwrap_or_else(|_| "ffi_redial_idle".into());
    let rig = Rig::start().await;
    let mut samples = Vec::new();
    let mut ok = 0;
    for sample in 0..SAMPLES {
        rig.settle().await;
        rig.path.cut();
        tokio::time::sleep(SUSPENDED).await;
        if let Some(steps) = rig.resume_once().await {
            ok += 1;
            println!("RECONNECT {}", json!({"scenario": scenario, "sample": sample, "steps": steps}));
            samples.push(steps);
        } else {
            println!("RECONNECT {}", json!({"scenario": scenario, "sample": sample, "ok": false}));
        }
    }
    summarize(&scenario, &samples);
    assert_eq!(ok, SAMPLES, "FFI redial samples failed");
}

/// Regression (ask-48f698fc26): after a suspension the warm signaling socket is half open, and a
/// resume opens a new one at once instead of first waiting `STALE_PROBE` (2.5 s) for it to answer.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "timed rig: run alone with --ignored"]
async fn a_resume_after_a_suspension_does_not_wait_on_the_dead_socket() {
    let rig = Rig::start().await;
    rig.settle().await;
    rig.path.cut();
    tokio::time::sleep(SUSPENDED).await;
    let steps = rig.resume().await;
    assert!(!steps.contains_key("signaling_stale"), "the dial waited on the dead socket: {steps:?}");
    assert!(steps["dialed"] < STALE_PROBE_MS, "dialed after {} ms: {steps:?}", steps["dialed"]);
}

/// Regression (ask-48f698fc26): after a network change the old path's socket is silent, and the
/// roam gives it a few of its round trips, not a flat second, before opening a new one.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "timed rig: run alone with --ignored"]
async fn a_network_change_waits_on_the_old_socket_only_a_few_round_trips() {
    let rig = Rig::start().await;
    rig.settle().await;
    rig.path.cut();
    let start = Instant::now();
    let roamed = rig
        .pool
        .network_changed(rig.path.url.clone(), "user:alice".into(), "team".into(), rig.device.clone())
        .await;
    let roamed_ms = ms(start.elapsed());
    assert!(roamed_ms < 800.0, "the roam took {roamed_ms} ms: {roamed:?}");
}

/// Regression (ask-48f698fc26): a network change is proof that the old path's socket is gone, as
/// Chromium treats an IP address change for its TCP sockets (`ERR_NETWORK_CHANGED`): the phone
/// reaches the chat's first event within two round trips plus the dial itself, with no wait on
/// the old socket (before: four of its round trips, about 500 ms at an 80 ms round trip).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "timed rig: run alone with --ignored"]
async fn a_network_change_reaches_the_first_event_within_two_round_trips_and_a_dial() {
    let rig = Rig::start().await;
    rig.settle().await;
    rig.path.cut();
    let steps = rig.network_change().await;
    let outside_the_dial = steps["first_event"] - (steps["dialed"] - steps["roamed"]);
    let budget = 2.0 * ms(RTT) + 40.0;
    assert!(!steps.contains_key("roam:signaling:stale"), "the roam waited on the old socket: {steps:?}");
    assert!(
        outside_the_dial <= budget,
        "the first event came {outside_the_dial} ms past the dial's own time (budget {budget} ms): {steps:?}"
    );
}

/// A network change in the foreground (Wi-Fi to cellular): the old path's socket is silent, the
/// app roams (`network_changed`) and then dials, as `.networkChanged` does for a link that failed.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "timed rig: run alone with --ignored"]
async fn network_change() {
    let rig = Rig::start().await;
    let mut samples = Vec::new();
    for sample in 0..SAMPLES {
        rig.settle().await;
        rig.path.cut();
        let steps = rig.network_change().await;
        println!("RECONNECT {}", json!({"scenario": "network_change", "sample": sample, "steps": steps}));
        samples.push(steps);
    }
    summarize("network_change", &samples);
}

/// How long a roam may take when the new route drops everything and the old socket still
/// answers: the open's budget after a network change (`NETWORK_OPEN_FLOOR`, 1 s at an 80 ms
/// round trip) plus scheduling.
const BLACKHOLE_ROAM_BOUND_MS: f64 = 1500.0;
/// Where a timed rig gives up on a roam that never ends (base: the open waits on the OS).
const ROAM_CAP: Duration = Duration::from_secs(5);

/// Regression (ask-48f698fc26): after a network change the new signaling socket's open is
/// bounded. When the new route drops everything and the old socket still answers, the roam
/// keeps the old socket within [`BLACKHOLE_ROAM_BOUND_MS`] instead of waiting for the OS to give
/// up on the open (minutes on iOS; never, in this rig).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "timed rig: run alone with --ignored"]
async fn a_blackholed_new_route_keeps_the_live_old_socket_within_a_bound() {
    let rig = Rig::start().await;
    rig.settle().await;
    rig.path.blackhole(true);
    let start = Instant::now();
    let roamed = tokio::time::timeout(
        ROAM_CAP,
        rig.pool.network_changed(
            rig.path.url.clone(),
            "user:alice".into(),
            "team".into(),
            rig.device.clone(),
        ),
    )
    .await;
    let roamed_ms = ms(start.elapsed());
    let roamed = roamed.unwrap_or_else(|_| panic!("the roam never ended: cut off after {roamed_ms} ms"));
    let names: Vec<_> = roamed.iter().map(|mark| mark.name.as_str()).collect();
    assert!(names.contains(&"signaling:alive"), "the roam did not keep the old socket: {names:?}");
    assert!(roamed_ms <= BLACKHOLE_ROAM_BOUND_MS, "the roam took {roamed_ms} ms: {names:?}");
}

/// Regression (ask-48f698fc26): two network changes at once (path updates come in bursts) open
/// one new signaling socket between them. The second waits for the first's open and then uses
/// that socket; it never opens another, and never falls back onto the socket it saw before the
/// first replaced it. Here the second's own open would fail (a refused token stands for a
/// network that flapped again), which before sent it back to the replaced socket.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "timed rig: run alone with --ignored"]
async fn two_network_changes_at_once_end_on_the_one_new_socket() {
    let rig = Rig::start().await;
    rig.settle().await;
    rig.path.cut();
    let first = rig.pool.network_changed(
        rig.path.url.clone(),
        "user:alice".into(),
        "team".into(),
        rig.device.clone(),
    );
    let second = async {
        tokio::time::sleep(Duration::from_millis(10)).await;
        rig.pool
            .network_changed(rig.path.url.clone(), "refused".into(), "team".into(), rig.device.clone())
            .await
    };
    let (first, second) = tokio::time::timeout(ROAM_CAP, async { tokio::join!(first, second) })
        .await
        .expect("the two roams never ended");
    let names =
        |marks: &[cmux_mobile_link_ffi::TimingMark]| marks.iter().map(|m| m.name.clone()).collect::<Vec<_>>();
    let (first, second) = (names(&first), names(&second));
    let opened = first.iter().chain(&second).filter(|name| *name == "signaling:signaling_open").count();
    assert_eq!(opened, 1, "two changes opened {opened} sockets: first {first:?}, second {second:?}");
    assert!(
        second.iter().any(|name| name == "signaling:signaling_joined"),
        "the second change did not end on the first's socket: {second:?}"
    );
    assert!(
        !second.iter().any(|name| name == "signaling:alive" || name == "signaling:failed"),
        "the second change fell back to the socket it saw before: {second:?}"
    );
}

/// A network change whose new route drops everything while the old socket still answers (a
/// captive Wi-Fi, a VPN that came up half way): roam, then dial, then the first event. A roam
/// that never ends is cut off at [`ROAM_CAP`] and counted (`roam_capped`).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "timed rig: run alone with --ignored"]
async fn network_change_blackholed_route() {
    let rig = Rig::start().await;
    let mut samples = Vec::new();
    for sample in 0..SAMPLES {
        rig.path.blackhole(false);
        rig.settle().await;
        rig.path.blackhole(true);
        let start = Instant::now();
        let roamed = tokio::time::timeout(
            ROAM_CAP,
            rig.pool.network_changed(
                rig.path.url.clone(),
                "user:alice".into(),
                "team".into(),
                rig.device.clone(),
            ),
        )
        .await;
        let mut steps = BTreeMap::new();
        match roamed {
            Ok(marks) => {
                for mark in marks {
                    steps.insert(format!("roam:{}", mark.name), mark.millis);
                }
            }
            Err(_) => {
                steps.insert("roam_capped".into(), ms(ROAM_CAP));
            }
        }
        steps.insert("roamed".into(), ms(start.elapsed()));
        let dial_at = ms(start.elapsed());
        let handle = rig.pool.connect(rig.request(), None).await.expect("dial");
        for mark in handle.timings() {
            steps.insert(mark.name, dial_at + mark.millis);
        }
        steps.insert("dialed".into(), ms(start.elapsed()));
        let channel = handle.open_channel("echo".into(), String::new()).await.expect("channel");
        channel.send(b"first".to_vec()).await.unwrap();
        assert_eq!(channel.recv().await, ChannelMessage::Data { bytes: b"first".to_vec() });
        steps.insert("first_event".into(), ms(start.elapsed()));
        handle.close();
        println!(
            "RECONNECT {}",
            json!({"scenario": "network_change_blackholed_route", "sample": sample, "steps": steps})
        );
        samples.push(steps);
    }
    rig.path.blackhole(false);
    summarize("network_change_blackholed_route", &samples);
}

impl Rig {
    /// What `.networkChanged` does after the path changed: roam, then dial, then the first
    /// channel's first event. Every step in ms from the change.
    async fn network_change(&self) -> BTreeMap<String, f64> {
        let rig = self;
        let start = Instant::now();
        let roamed = rig
            .pool
            .network_changed(rig.path.url.clone(), "user:alice".into(), "team".into(), rig.device.clone())
            .await;
        let mut steps = BTreeMap::new();
        for mark in roamed {
            steps.insert(format!("roam:{}", mark.name), mark.millis);
        }
        steps.insert("roamed".into(), ms(start.elapsed()));
        let dial_at = ms(start.elapsed());
        let handle = rig.pool.connect(rig.request(), None).await.expect("dial");
        for mark in handle.timings() {
            steps.insert(mark.name, dial_at + mark.millis);
        }
        steps.insert("dialed".into(), ms(start.elapsed()));
        let channel = handle.open_channel("echo".into(), String::new()).await.expect("channel");
        channel.send(b"first".to_vec()).await.unwrap();
        assert_eq!(channel.recv().await, ChannelMessage::Data { bytes: b"first".to_vec() });
        steps.insert("first_event".into(), ms(start.elapsed()));
        handle.close();
        steps
    }
}
