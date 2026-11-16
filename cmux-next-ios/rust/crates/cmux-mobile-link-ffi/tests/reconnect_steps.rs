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
const SAMPLES: usize = 10;
/// How long the phone stays in the background with its sockets cut: longer than one signaling
/// keepalive (15 s), so the socket missed a pong, as after any background of more than a moment.
const SUSPENDED: Duration = Duration::from_secs(18);

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
/// connection open now (bytes vanish, nothing closes), as a sleeping phone's do.
struct PhonePath {
    url: String,
    generation: Arc<AtomicU64>,
}

impl PhonePath {
    async fn start(upstream: &str) -> Self {
        let target = upstream.trim_start_matches("http://").trim_end_matches('/').to_owned();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let generation = Arc::new(AtomicU64::new(0));
        let shared = Arc::clone(&generation);
        tokio::spawn(async move {
            while let Ok((phone, _)) = listener.accept().await {
                let born = shared.load(Ordering::SeqCst);
                let Ok(service) = TcpStream::connect(&target).await else { continue };
                let (phone_read, phone_write) = phone.into_split();
                let (service_read, service_write) = service.into_split();
                tokio::spawn(pump(phone_read, service_write, born, Arc::clone(&shared)));
                tokio::spawn(pump(service_read, phone_write, born, Arc::clone(&shared)));
            }
        });
        Self { url, generation }
    }

    fn cut(&self) {
        self.generation.fetch_add(1, Ordering::SeqCst);
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
            video_lane: false,
            webrtc_media: false,
            ultra: cmux_mobile_link::UltraSetting::Off,
        }
    }

    /// What `.resume` does: `prewarm` and a fresh dial at once, then the first channel's first
    /// event. Every step in ms from the start.
    async fn resume(&self) -> BTreeMap<String, f64> {
        let start = Instant::now();
        let (warmed, handle) = tokio::join!(
            self.pool.prewarm(self.path.url.clone(), "user:alice".into(), "team".into(), self.device.clone()),
            self.pool.connect(self.request(), None),
        );
        let handle = handle.expect("redial");
        let mut steps = BTreeMap::new();
        for mark in handle.timings() {
            steps.insert(mark.name, mark.millis);
        }
        for mark in warmed {
            steps.insert(format!("prewarm:{}", mark.name), mark.millis);
        }
        steps.insert("dialed".into(), ms(start.elapsed()));
        let channel = handle.open_channel("echo".into(), String::new()).await.expect("channel");
        steps.insert("channel_opened".into(), ms(start.elapsed()));
        channel.send(b"first".to_vec()).await.unwrap();
        assert_eq!(channel.recv().await, ChannelMessage::Data { bytes: b"first".to_vec() });
        steps.insert("first_event".into(), ms(start.elapsed()));
        handle.close();
        steps
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
    let mut out = serde_json::Map::new();
    for (name, mut values) in steps {
        values.sort_by(f64::total_cmp);
        out.insert(
            name,
            json!({"n": values.len(), "p50": percentile(&values, 0.5), "p95": percentile(&values, 0.95)}),
        );
    }
    println!("RECONNECT_SUMMARY {}", json!({"scenario": scenario, "rtt_ms": ms(RTT), "steps": out}));
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
        println!("RECONNECT {}", json!({"scenario": "network_change", "sample": sample, "steps": steps}));
        samples.push(steps);
    }
    summarize("network_change", &samples);
}
