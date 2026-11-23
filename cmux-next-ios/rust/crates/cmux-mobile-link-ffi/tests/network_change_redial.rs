//! Network change to redial (mobile-speed): how long from the path change to the moment
//! `LinkController.networkChanged` calls `send(.networkChanged)`, on shaped link profiles.
//!
//! That Swift function sleeps `networkSettle` (150 ms, a constant), awaits the Rust FFI
//! `network_changed` (this file times `WarmPool::network_changed`, the same code), then sends
//! the event (a main-actor hop, not measured here). A sample is one `WarmPool::network_changed`
//! call on a phone with a live WireGuard session and a pooled signaling socket whose connections
//! just went silent (the old path).
//!
//! What is shaped, exactly:
//! - the WireGuard tunnel's inbound datagrams, both ends, by the harness's own
//!   `testing::shape_by_profile` (the `roaming.rs` duress_matrix link model). STUN answers are
//!   consumed before that hook, so they are NOT shaped by it;
//! - the roam's STUN server is a local responder in this file that answers after the profile's
//!   round trip and drops `loss_percent` of the answers (this file's emulation, not the harness's);
//! - the signaling socket (TCP) goes through a proxy in this file that models the profile on a
//!   byte stream: one round trip for the connect, `rtt/2` plus seeded jitter per chunk, in order,
//!   serialization at the profile's rate, and a lost chunk costs one retransmit timeout
//!   (`max(200 ms, 2 rtt)`). The harness has no TCP shaper; this is a model of one.
//!
//! The Mac's end of each session runs in this process, so `network_changed` also roams the Mac's
//! session (the app never does): its STUN wait runs beside the phone's.
//!
//! `cargo test --release -p cmux-mobile-link-ffi --test network_change_redial -- --ignored --nocapture --test-threads=1`
//! `REDIAL_PROFILES=lte,lossy-3,lossy-10` picks profiles, `REDIAL_SAMPLES=20` the samples.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_mobile_link::dial::{self, SessionEvents, wireguard};
use cmux_mobile_link::testing::{
    FakeOptions, FakeSignaling, LinkProfile, set_link_profile, shape_by_profile, shaped_counts,
};
use cmux_mobile_link::{DialOptions, LinkConfig, SignalingClient, TransportKind};
use cmux_mobile_link_ffi::WarmPool;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UdpSocket};

/// `LinkController.networkSettle`.
const SETTLE_MS: f64 = 150.0;

fn ms(duration: Duration) -> f64 {
    duration.as_secs_f64() * 1000.0
}

/// SplitMix64, as the harness's shaper.
fn next(state: &mut u64) -> u64 {
    *state = state.wrapping_add(0x9E37_79B9_7F4A_7C15);
    let mut z = *state;
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

fn unit(state: &mut u64) -> f64 {
    (next(state) >> 11) as f64 / (1_u64 << 53) as f64
}

/// A local STUN server on the profile's link: a binding answer after one round trip, lost with
/// `loss_percent`.
async fn stun_server(profile: LinkProfile, seed: u64) -> String {
    let socket = Arc::new(UdpSocket::bind("127.0.0.1:0").await.unwrap());
    let address = socket.local_addr().unwrap();
    tokio::spawn(async move {
        let mut rng = seed;
        let mut buffer = [0u8; 1500];
        while let Ok((len, from)) = socket.recv_from(&mut buffer).await {
            if len < 20 || buffer[0..2] != [0, 1] {
                continue;
            }
            let jitter = match profile.jitter_ms {
                0 => 0,
                most => next(&mut rng) % (most + 1),
            };
            if unit(&mut rng) * 100.0 < profile.loss_percent {
                continue;
            }
            let SocketAddr4(ip, port) = SocketAddr4::of(from);
            let mut answer = vec![0x01, 0x01, 0, 12];
            answer.extend_from_slice(&buffer[4..20]);
            answer.extend_from_slice(&[0, 0x20, 0, 8, 0, 1]);
            answer.extend_from_slice(&(port ^ 0x2112).to_be_bytes());
            answer.extend_from_slice(&(ip ^ 0x2112_A442).to_be_bytes());
            let socket = Arc::clone(&socket);
            let delay = Duration::from_millis(profile.rtt_ms + jitter);
            tokio::spawn(async move {
                tokio::time::sleep(delay).await;
                let _ = socket.send_to(&answer, from).await;
            });
        }
    });
    address.to_string()
}

struct SocketAddr4(u32, u16);

impl SocketAddr4 {
    fn of(address: std::net::SocketAddr) -> Self {
        match address {
            std::net::SocketAddr::V4(v4) => Self(u32::from(*v4.ip()), v4.port()),
            std::net::SocketAddr::V6(_) => Self(0, address.port()),
        }
    }
}

/// The phone's TCP path to the service, on `profile`; `cut` silences every connection open now
/// (bytes vanish, nothing closes), as a path that is gone does.
struct PhonePath {
    url: String,
    generation: Arc<AtomicU64>,
}

impl PhonePath {
    async fn start(upstream: &str, profile: LinkProfile, seed: u64) -> Self {
        let target = upstream.trim_start_matches("http://").trim_end_matches('/').to_owned();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let generation = Arc::new(AtomicU64::new(0));
        let shared = Arc::clone(&generation);
        tokio::spawn(async move {
            let mut connection = 0u64;
            while let Ok((phone, _)) = listener.accept().await {
                connection += 1;
                let born = shared.load(Ordering::SeqCst);
                let Ok(service) = TcpStream::connect(&target).await else { continue };
                let (phone_read, phone_write) = phone.into_split();
                let (service_read, service_write) = service.into_split();
                let (a, b) =
                    (seed ^ connection.wrapping_mul(2), seed ^ connection.wrapping_mul(2).wrapping_add(1));
                tokio::spawn(pump(phone_read, service_write, born, Arc::clone(&shared), profile.clone(), a));
                tokio::spawn(pump(service_read, phone_write, born, Arc::clone(&shared), profile.clone(), b));
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
    profile: LinkProfile,
    seed: u64,
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
        std::future::pending::<()>().await;
    });
    let rate = match (profile.up_kbit, profile.down_kbit) {
        (0, rate) | (rate, 0) => rate,
        (up, down) => up.min(down),
    };
    let rto = Duration::from_millis(200.max(2 * profile.rtt_ms));
    let mut rng = seed;
    // The connect's round trip comes before the first byte moves.
    let mut previous = tokio::time::Instant::now() + Duration::from_millis(profile.rtt_ms);
    let mut free = tokio::time::Instant::now();
    let mut buffer = vec![0u8; 1460];
    loop {
        let n = match read.read(&mut buffer).await {
            Ok(0) | Err(_) => {
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
        let now = tokio::time::Instant::now();
        let jitter = match profile.jitter_ms {
            0 => 0,
            most => next(&mut rng) % (most + 1),
        };
        let mut delay = Duration::from_millis(profile.rtt_ms / 2 + jitter);
        if unit(&mut rng) * 100.0 < profile.loss_percent {
            delay += rto;
        }
        if rate > 0 {
            free = free.max(now) + Duration::from_micros(n as u64 * 8 * 1000 / rate);
            delay += free - now;
        }
        // TCP delivers in order: nothing overtakes the chunk before it.
        let due = (now + delay).max(previous);
        previous = due;
        if tx.send((due, buffer[..n].to_vec())).is_err() {
            return;
        }
    }
}

fn percentile(sorted: &[f64], p: f64) -> f64 {
    let rank = ((p * sorted.len() as f64).ceil() as usize).clamp(1, sorted.len());
    sorted[rank - 1]
}

fn stats(values: &[f64]) -> (f64, f64) {
    let mut sorted = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    (percentile(&sorted, 0.5), percentile(&sorted, 0.95))
}

/// The options the app's dial gets: the tunnel shaped, and the STUN server `GET /v1/ice` names
/// (the app passes the service's ICE servers; without them a roam gathers nothing).
fn shaped_options(stun: &str) -> DialOptions {
    DialOptions {
        ice_servers: vec![cmux_mobile_link::api::IceServer {
            urls: vec![format!("stun:{stun}")],
            username: None,
            credential: None,
        }],
        include_loopback: true,
        impair_inbound: Some(shape_by_profile),
        timeout: Duration::from_secs(40),
        ..DialOptions::default()
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
#[ignore = "timed measurement: run alone with --ignored"]
async fn network_change_to_redial() {
    let samples: usize = std::env::var("REDIAL_SAMPLES").ok().and_then(|n| n.parse().ok()).unwrap_or(20);
    let names = std::env::var("REDIAL_PROFILES").unwrap_or_else(|_| "lte,lossy-3,lossy-10".into());
    for name in names.split(',').map(str::trim).filter(|name| !name.is_empty()) {
        let profile = LinkProfile::named(name);
        set_link_profile(Some(profile.clone()), 0x6e65_7463);
        let stun = stun_server(profile.clone(), 0x5455).await;
        let stun_for_mac = stun.clone();
        let server =
            FakeSignaling::start(FakeOptions { ice_stun: Some(stun.clone()), ..FakeOptions::default() })
                .await;
        let path = PhonePath::start(&server.base_url, profile.clone(), 0x7061_7468).await;
        let mac_id = uuid::Uuid::new_v4().to_string();
        let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
        let mac_links = Arc::new(Mutex::new(Vec::<cmux_mobile_link::Link>::new()));
        {
            let mac_links = Arc::clone(&mac_links);
            let stun = stun_for_mac;
            tokio::spawn(async move {
                while let Some(session) = mac.next_session().await {
                    let events = SessionEvents {
                        backend: mac.events(),
                        session_id: session.first.session_id.clone(),
                        session: session.events,
                    };
                    let (mac, mac_links, stun) = (mac.clone(), Arc::clone(&mac_links), stun.clone());
                    tokio::spawn(async move {
                        let config = LinkConfig { foreground_probe: false, ..LinkConfig::default() };
                        if let Ok(connected) =
                            dial::answer(&mac, session.first, events, &shaped_options(&stun), config).await
                        {
                            mac_links.lock().unwrap().push(connected.link.clone());
                            while connected.link.accept().await.is_some() {}
                        }
                    });
                }
            });
        }
        let pool = WarmPool::new();
        let (mut calls, mut opens, mut roams, mut roams_alone, mut failed) =
            (Vec::new(), Vec::new(), Vec::new(), Vec::new(), 0);
        let mut ran = 0;
        while calls.len() < samples && ran < samples * 3 {
            ran += 1;
            // A phone with a live shaped tunnel, and the pooled signaling socket the app keeps.
            let phone_id = uuid::Uuid::new_v4().to_string();
            let pool_id = uuid::Uuid::new_v4().to_string();
            let phone =
                SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
            let Ok(connected) = dial::connect(
                &phone,
                &mac_id,
                TransportKind::WireGuard,
                &shaped_options(&stun),
                LinkConfig::default(),
            )
            .await
            else {
                failed += 1;
                continue;
            };
            let _ = pool.prewarm(path.url.clone(), "user:alice".into(), "team".into(), pool_id.clone()).await;
            path.cut();
            let started = Instant::now();
            let marks =
                pool.network_changed(path.url.clone(), "user:alice".into(), "team".into(), pool_id).await;
            let call = ms(started.elapsed());
            let open =
                marks.iter().find(|mark| mark.name == "signaling:signaling_open").map(|mark| mark.millis);
            // The phone's roam on its own (a second one on the same session).
            let started = Instant::now();
            let roamed = wireguard::roam_session(&connected.session_id, true).await;
            assert!(roamed.is_some(), "the phone's session is not live");
            let alone = ms(started.elapsed());
            println!(
                "REDIAL_SAMPLE profile={name} call_ms={call:.1} signaling_open_ms={open:?} roam_alone_ms={alone:.1} marks={:?}",
                marks.iter().map(|mark| format!("{}={:.0}", mark.name, mark.millis)).collect::<Vec<_>>()
            );
            calls.push(call);
            if let Some(open) = open {
                opens.push(open);
            }
            roams_alone.push(alone);
            // The roam inside the call: the slowest session's last roam mark, when it has one.
            if let Some(roam) = marks
                .iter()
                .filter(|mark| !mark.name.starts_with("signaling:"))
                .map(|mark| mark.millis)
                .reduce(f64::max)
            {
                roams.push(roam);
            }
            connected.link.close("done");
            for link in mac_links.lock().unwrap().drain(..) {
                link.close("done");
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
        let (delivered, dropped) = shaped_counts();
        let (call50, call95) = stats(&calls);
        let line = |label: &str, values: &[f64]| {
            if values.is_empty() {
                return format!("{label}: none");
            }
            let (p50, p95) = stats(values);
            format!("{label}: n={} p50={p50:.0} p95={p95:.0}", values.len())
        };
        println!(
            "REDIAL_SUMMARY profile={name} n={} setup_failed={failed} settle_ms={SETTLE_MS} | rust_call p50={call50:.0} p95={call95:.0} | {} | {} | {} | total(settle+call) p50={:.0} p95={:.0} | send=assumed<1ms | udp delivered={delivered} dropped={dropped}",
            calls.len(),
            line("signaling_open", &opens),
            line("roam_in_call(last roam mark)", &roams),
            line("roam_alone", &roams_alone),
            call50 + SETTLE_MS,
            call95 + SETTLE_MS,
        );
    }
    set_link_profile(None, 0);
}
