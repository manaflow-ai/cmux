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
async fn stun_server(profile: Shared, seed: u64) -> String {
    let socket = Arc::new(UdpSocket::bind("127.0.0.1:0").await.unwrap());
    let address = socket.local_addr().unwrap();
    tokio::spawn(async move {
        let mut rng = seed;
        let mut buffer = [0u8; 1500];
        while let Ok((len, from)) = socket.recv_from(&mut buffer).await {
            if len < 20 || buffer[0..2] != [0, 1] {
                continue;
            }
            let profile = profile.lock().unwrap().clone();
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

/// The path's current profile: the flapping path switches it at each flip.
type Shared = Arc<Mutex<LinkProfile>>;

fn shared(profile: LinkProfile) -> Shared {
    Arc::new(Mutex::new(profile))
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
    /// TCP connections the phone opened on this path (signaling sockets, HTTP).
    accepts: Arc<AtomicU64>,
    /// Of those, WebSocket upgrades (signaling sockets).
    upgrades: Arc<AtomicU64>,
    profile: Shared,
}

impl PhonePath {
    async fn start(upstream: &str, profile: Shared, seed: u64) -> Self {
        let target = upstream.trim_start_matches("http://").trim_end_matches('/').to_owned();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let generation = Arc::new(AtomicU64::new(0));
        let shared = Arc::clone(&generation);
        let accepts = Arc::new(AtomicU64::new(0));
        let accepted = Arc::clone(&accepts);
        let upgrades = Arc::new(AtomicU64::new(0));
        let upgraded = Arc::clone(&upgrades);
        let current = Arc::clone(&profile);
        tokio::spawn(async move {
            let mut connection = 0u64;
            while let Ok((phone, _)) = listener.accept().await {
                connection += 1;
                accepted.fetch_add(1, Ordering::SeqCst);
                let born = shared.load(Ordering::SeqCst);
                // A connection keeps the path it opened on.
                let profile = current.lock().unwrap().clone();
                let Ok(service) = TcpStream::connect(&target).await else { continue };
                let (phone_read, phone_write) = phone.into_split();
                let (service_read, service_write) = service.into_split();
                let (a, b) =
                    (seed ^ connection.wrapping_mul(2), seed ^ connection.wrapping_mul(2).wrapping_add(1));
                tokio::spawn(pump(
                    phone_read,
                    service_write,
                    born,
                    Arc::clone(&shared),
                    profile.clone(),
                    a,
                    Some(Arc::clone(&upgraded)),
                ));
                tokio::spawn(pump(
                    service_read,
                    phone_write,
                    born,
                    Arc::clone(&shared),
                    profile.clone(),
                    b,
                    None,
                ));
            }
        });
        Self { url, generation, accepts, upgrades, profile }
    }

    fn cut(&self) {
        self.generation.fetch_add(1, Ordering::SeqCst);
    }

    /// The phone moved to another network: every connection open now goes silent, new ones
    /// (and STUN answers) run on `profile`. The tunnel's datagram shaper is left as it is (see
    /// `settle_cell`).
    fn switch(&self, profile: &LinkProfile) {
        *self.profile.lock().unwrap() = profile.clone();
        self.cut();
    }
}

async fn pump(
    mut read: tokio::net::tcp::OwnedReadHalf,
    write: tokio::net::tcp::OwnedWriteHalf,
    born: u64,
    generation: Arc<AtomicU64>,
    profile: LinkProfile,
    seed: u64,
    upgrades: Option<Arc<AtomicU64>>,
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
        if let Some(upgrades) = upgrades.as_ref()
            && String::from_utf8_lossy(&buffer[..n]).to_ascii_lowercase().contains("upgrade: websocket")
        {
            upgrades.fetch_add(1, Ordering::SeqCst);
        }
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
        let stun = stun_server(shared(profile.clone()), 0x5455).await;
        let stun_for_mac = stun.clone();
        let server =
            FakeSignaling::start(FakeOptions { ice_stun: Some(stun.clone()), ..FakeOptions::default() })
                .await;
        let path = PhonePath::start(&server.base_url, shared(profile.clone()), 0x7061_7468).await;
        let mac_id = uuid::Uuid::new_v4().to_string();
        let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
        let mac_links = Arc::new(Mutex::new(Vec::<cmux_mobile_link::Link>::new()));
        let mac_sessions = Arc::new(AtomicU64::new(0));
        {
            let mac_links = Arc::clone(&mac_links);
            let mac_sessions = Arc::clone(&mac_sessions);
            let stun = stun_for_mac;
            tokio::spawn(async move {
                while let Some(session) = mac.next_session().await {
                    mac_sessions.fetch_add(1, Ordering::SeqCst);
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
        let (mut readies, mut got_old, mut redial_opened) = (Vec::new(), 0, 0);
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
            let (_, _, old) = pool
                .dial_socket(path.url.clone(), "user:alice".into(), "team".into(), pool_id.clone())
                .await
                .expect("the pooled socket");
            path.cut();
            let started = Instant::now();
            let marks = pool
                .network_changed(path.url.clone(), "user:alice".into(), "team".into(), pool_id.clone())
                .await;
            let call = ms(started.elapsed());
            // The redial `send(.networkChanged)` starts when the call returns: the time until its
            // dial has a signaling socket (the dial's `pooled_or_open`, the same code).
            let redial =
                pool.dial_socket(path.url.clone(), "user:alice".into(), "team".into(), pool_id).await;
            let ready = ms(started.elapsed());
            let (redial_marks, redial_reused, socket) = redial.expect("the redial's signaling socket");
            if socket == old {
                got_old += 1;
            }
            if !redial_reused {
                redial_opened += 1;
            }
            readies.push(ready);
            let open =
                marks.iter().find(|mark| mark.name == "signaling:signaling_open").map(|mark| mark.millis);
            // The phone's roam on its own (a second one on the same session).
            let started = Instant::now();
            let roamed = wireguard::roam_session(&connected.session_id, true).await;
            assert!(roamed.is_some(), "the phone's session is not live");
            let alone = ms(started.elapsed());
            println!(
                "REDIAL_SAMPLE profile={name} call_ms={call:.1} redial_ready_ms={ready:.1} redial_reused={redial_reused} redial_old_socket={} signaling_open_ms={open:?} roam_alone_ms={alone:.1} marks={:?} redial_marks={:?}",
                socket == old,
                marks.iter().map(|mark| format!("{}={:.0}", mark.name, mark.millis)).collect::<Vec<_>>(),
                redial_marks
                    .iter()
                    .map(|mark| format!("{}={:.0}", mark.name, mark.millis))
                    .collect::<Vec<_>>()
            );
            calls.push(call);
            if let Some(open) = open {
                opens.push(open);
            }
            roams_alone.push(alone);
            // The roam inside the call: when `roam()` returned (`roam_gathered`) on the slowest session.
            if let Some(roam) = marks
                .iter()
                .filter(|mark| mark.name == "roam_gathered")
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
        // A steady link: the pooled socket, no network change, for as long as the redials above
        // waited in all; then one dial on it. Every TCP connect or Mac session here is extra.
        let steady_id = uuid::Uuid::new_v4().to_string();
        let _ = pool.prewarm(path.url.clone(), "user:alice".into(), "team".into(), steady_id.clone()).await;
        let (accepts, sessions) = (path.accepts.load(Ordering::SeqCst), mac_sessions.load(Ordering::SeqCst));
        tokio::time::sleep(Duration::from_secs_f64(readies.iter().sum::<f64>() / 1000.0)).await;
        let (_, steady_reused, _) = pool
            .dial_socket(path.url.clone(), "user:alice".into(), "team".into(), steady_id)
            .await
            .expect("the steady socket");
        let steady_connects = path.accepts.load(Ordering::SeqCst) - accepts;
        let steady_sessions = mac_sessions.load(Ordering::SeqCst) - sessions;
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
            "REDIAL_SUMMARY profile={name} n={} setup_failed={failed} settle_ms={SETTLE_MS} | rust_call p50={call50:.0} p95={call95:.0} | {} | redial_got_old_socket={got_old} redial_opened_own={redial_opened} | {} | {} | {} | total(settle+call) p50={:.0} p95={:.0} | send=assumed<1ms | steady: {:.0} ms, tcp_connects={steady_connects} mac_sessions={steady_sessions} dial_reused={steady_reused} | udp delivered={delivered} dropped={dropped}",
            calls.len(),
            line("redial_ready(call start to redial socket)", &readies),
            line("signaling_open", &opens),
            line("roam_in_call(roam_gathered, slowest session)", &roams),
            line("roam_alone", &roams_alone),
            call50 + SETTLE_MS,
            call95 + SETTLE_MS,
            readies.iter().sum::<f64>(),
        );
    }
    set_link_profile(None, 0);
}

// MARK: The Swift settle (`LinkController.networkSettle`)

/// What the app does after a network change, on a link that already failed (`.waiting`, the
/// case that redials), modelled on `LinkController.networkChanged` and `LinkMachine`:
/// - each change cancels the change before it (`networkTask?.cancel()`); a cancel during the
///   settle sleep drops that change; a cancel after the FFI call started does not stop the Rust
///   `network_changed` (detached, on the library runtime) but skips `send(.networkChanged)`;
/// - `send(.networkChanged)` redials while no redial has connected (`.waiting`, `.connecting`:
///   a new dial supersedes the one in flight; the superseded Rust dial runs on, as `connect`
///   runs on the library runtime, and its link is closed when it lands), and does nothing once
///   one has (`.connected`: the link roams in place).
struct App {
    pool: WarmPool,
    url: String,
    device: String,
    mac: String,
    settle: Duration,
    /// The change in flight (`networkTask`): bumped by each change, so an older one sees it.
    change: Arc<AtomicU64>,
    /// The dial generation (`LinkMachine.generation`) and whether that dial connected.
    generation: Arc<AtomicU64>,
    connected: Arc<Mutex<Option<Arc<cmux_mobile_link_ffi::LinkHandle>>>>,
    tasks: Mutex<Vec<tokio::task::JoinHandle<()>>>,
    ffi: Arc<Mutex<Vec<tokio::task::JoinHandle<()>>>>,
    /// Each send(.networkChanged) that ran: (time, the change it ran for, the redial it started
    /// with that redial's socket time, if any).
    sends: Arc<Mutex<Vec<Sent>>>,
    started: Instant,
}

#[derive(Clone, Debug)]
struct Sent {
    change: u64,
    /// A redial started, and when (since `started`) its dial had its signaling socket.
    redial: Option<Arc<Mutex<Option<f64>>>>,
    /// No redial (a link was up): when (since `started`) a dial would have the pool's socket.
    probe: Option<f64>,
}

impl App {
    fn changed(self: &Arc<Self>) {
        let mine = self.change.fetch_add(1, Ordering::SeqCst) + 1;
        let app = Arc::clone(self);
        let task = tokio::spawn(async move {
            tokio::time::sleep(app.settle).await;
            if app.change.load(Ordering::SeqCst) != mine {
                return; // cancelled in the settle: the change is dropped
            }
            let ffi = {
                let (pool, url, device) = (app.pool.clone(), app.url.clone(), app.device.clone());
                tokio::spawn(async move {
                    pool.network_changed(url, "user:alice".into(), "team".into(), device).await;
                })
            };
            let (done_tx, done_rx) = tokio::sync::oneshot::channel();
            app.ffi.lock().unwrap().push(tokio::spawn(async move {
                let _ = ffi.await;
                let _ = done_tx.send(());
            }));
            let _ = done_rx.await;
            if app.change.load(Ordering::SeqCst) != mine {
                return; // cancelled while the FFI ran: no send(.networkChanged)
            }
            app.send_network_changed(mine).await;
        });
        self.tasks.lock().unwrap().push(task);
    }

    async fn send_network_changed(self: &Arc<Self>, change: u64) {
        if self.connected.lock().unwrap().is_some() {
            // `.connected`: the link roamed in place. When would a dial have the pool's socket?
            let at = self.pool.dial_socket(
                self.url.clone(),
                "user:alice".into(),
                "team".into(),
                self.device.clone(),
            );
            let probe = at.await.ok().map(|_| ms(self.started.elapsed()));
            self.sends.lock().unwrap().push(Sent { change, redial: None, probe });
            return;
        }
        let generation = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        let ready = Arc::new(Mutex::new(None));
        self.sends.lock().unwrap().push(Sent { change, redial: Some(Arc::clone(&ready)), probe: None });
        let app = Arc::clone(self);
        let dial = tokio::spawn(async move {
            let began = ms(app.started.elapsed());
            let request = cmux_mobile_link_ffi::ConnectRequest {
                base_url: app.url.clone(),
                token: "user:alice".into(),
                team_id: "team".into(),
                device_id: app.device.clone(),
                mac_device_id: app.mac.clone(),
                transport: cmux_mobile_link_ffi::Transport::WireGuard,
                include_loopback: true,
                relay_only: false,
                block_udp: false,
                video_lane: false,
                webrtc_media: false,
                ultra: cmux_mobile_link::UltraSetting::default(),
            };
            match app.pool.connect(request, None).await {
                Ok(link) => {
                    let socket = link
                        .timings()
                        .into_iter()
                        .filter(|mark| mark.name == "signaling_reused" || mark.name == "signaling_open")
                        .map(|mark| mark.millis)
                        .reduce(f64::min);
                    *ready.lock().unwrap() = socket.map(|at| began + at);
                    let mut connected = app.connected.lock().unwrap();
                    if app.generation.load(Ordering::SeqCst) == generation && connected.is_none() {
                        *connected = Some(link);
                    } else {
                        link.close(); // superseded: Swift closes the link it no longer wants
                    }
                }
                Err(error) => println!("SETTLE_DIAL_FAILED generation={generation} {error}"),
            }
        });
        self.tasks.lock().unwrap().push(dial);
    }

    /// Wait for every task this model started (each bounded by the dial timeout).
    async fn settle_down(&self) {
        loop {
            let tasks: Vec<_> = self.tasks.lock().unwrap().drain(..).collect();
            let ffi: Vec<_> = self.ffi.lock().unwrap().drain(..).collect();
            if tasks.is_empty() && ffi.is_empty() {
                return;
            }
            for task in tasks.into_iter().chain(ffi) {
                let _ = tokio::time::timeout(Duration::from_secs(60), task).await;
            }
        }
    }
}

/// The flapping path: wifi (`good-wifi`) to cell (`lte`) and back, `FLIPS` flips evenly over
/// `FLAP_WINDOW` (at 0, 667 and 1333 ms), each one network change. The phone starts on wifi
/// and ends on cell.
const FLIPS: u32 = 3;
const FLAP_WINDOW: Duration = Duration::from_secs(2);

#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
#[ignore = "timed measurement: run alone with --ignored"]
async fn settle_matrix() {
    let samples: usize = std::env::var("REDIAL_SAMPLES").ok().and_then(|n| n.parse().ok()).unwrap_or(20);
    let settles: Vec<u64> = std::env::var("SETTLE_MS_LIST")
        .unwrap_or_else(|_| "150,50,0".into())
        .split(',')
        .filter_map(|n| n.trim().parse().ok())
        .collect();
    let paths = std::env::var("SETTLE_PATHS").unwrap_or_else(|_| "lte,lossy-3,lossy-10,flap".into());
    for settle in settles {
        for name in paths.split(',').map(str::trim).filter(|name| !name.is_empty()) {
            settle_cell(settle, name, samples).await;
        }
    }
    set_link_profile(None, 0);
}

async fn settle_cell(settle_ms: u64, name: &str, samples: usize) {
    let flap = name == "flap";
    let (wifi, cell) = (LinkProfile::named("good-wifi"), LinkProfile::named("lte"));
    let first = if flap { wifi.clone() } else { LinkProfile::named(name) };
    // The tunnel's datagrams: the flapping path keeps them on `lte` throughout (a live tunnel
    // dialed on `good-wifi` through the harness shaper timed out at setup, 40 s, in 10 of 12
    // tries; not investigated). Signaling TCP and STUN do switch.
    set_link_profile(Some(if flap { cell.clone() } else { first.clone() }), 0x6e65_7463);
    let profile = shared(first.clone());
    let stun = stun_server(Arc::clone(&profile), 0x5455).await;
    let server =
        FakeSignaling::start(FakeOptions { ice_stun: Some(stun.clone()), ..FakeOptions::default() }).await;
    let path = PhonePath::start(&server.base_url, Arc::clone(&profile), 0x7061_7468).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let mac_links = Arc::new(Mutex::new(Vec::<cmux_mobile_link::Link>::new()));
    let mac_sessions = Arc::new(AtomicU64::new(0));
    {
        let (mac_links, mac_sessions, stun) =
            (Arc::clone(&mac_links), Arc::clone(&mac_sessions), stun.clone());
        tokio::spawn(async move {
            while let Some(session) = mac.next_session().await {
                mac_sessions.fetch_add(1, Ordering::SeqCst);
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
    let (mut readies, mut extra_opens, mut extra_sessions, mut failed, mut no_ready, mut roamed_only) =
        (Vec::new(), Vec::new(), Vec::new(), 0, 0, 0);
    let mut ran = 0;
    while readies.len() + no_ready < samples && ran < samples * 3 {
        ran += 1;
        if flap {
            path.switch(&wifi);
        }
        // A phone with a live shaped tunnel (the roam has a session to move), and the pooled
        // signaling socket the app keeps; the app's link to this Mac already failed (`.waiting`).
        let phone_id = uuid::Uuid::new_v4().to_string();
        let device = uuid::Uuid::new_v4().to_string();
        let phone =
            SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
        let setup = Instant::now();
        let live = match dial::connect(
            &phone,
            &mac_id,
            TransportKind::WireGuard,
            &shaped_options(&stun),
            LinkConfig::default(),
        )
        .await
        {
            Ok(live) => live,
            Err(error) => {
                println!("SETTLE_SETUP_FAILED path={name} after={:?} {error}", setup.elapsed());
                failed += 1;
                continue;
            }
        };
        let _ = pool.prewarm(path.url.clone(), "user:alice".into(), "team".into(), device.clone()).await;
        tokio::time::sleep(Duration::from_millis(100)).await;
        let (opens_before, sessions_before) =
            (path.upgrades.load(Ordering::SeqCst), mac_sessions.load(Ordering::SeqCst));
        let app = Arc::new(App {
            pool: pool.clone(),
            url: path.url.clone(),
            device,
            mac: mac_id.clone(),
            settle: Duration::from_millis(settle_ms),
            change: Arc::new(AtomicU64::new(0)),
            generation: Arc::new(AtomicU64::new(0)),
            connected: Arc::new(Mutex::new(None)),
            tasks: Mutex::new(Vec::new()),
            ffi: Arc::new(Mutex::new(Vec::new())),
            sends: Arc::new(Mutex::new(Vec::new())),
            started: Instant::now(),
        });
        let changes = if flap { FLIPS } else { 1 };
        for flip in 0..changes {
            if flap {
                let due = app.started + FLAP_WINDOW * flip / FLIPS;
                tokio::time::sleep_until(due.into()).await;
                let to = if flip % 2 == 0 { &cell } else { &wifi };
                path.switch(to);
            } else {
                path.cut();
            }
            app.changed();
        }
        app.settle_down().await;
        let sends = app.sends.lock().unwrap().clone();
        // The redial-ready time on the final path: the send for the last change (never
        // cancelled: nothing comes after it).
        let last = sends.iter().find(|send| send.change == u64::from(changes));
        let ready = match last {
            Some(Sent { redial: Some(at), .. }) => *at.lock().unwrap(),
            Some(Sent { probe, .. }) => {
                roamed_only += 1;
                *probe
            }
            None => None,
        };
        let opens = path.upgrades.load(Ordering::SeqCst) - opens_before;
        let sessions = mac_sessions.load(Ordering::SeqCst) - sessions_before;
        println!(
            "SETTLE_SAMPLE settle_ms={settle_ms} path={name} ready_ms={ready:?} signaling_opens={opens} mac_sessions={sessions} sends={:?}",
            sends
                .iter()
                .map(|send| format!(
                    "change{}:{}",
                    send.change,
                    match (&send.redial, send.probe) {
                        (Some(at), _) => format!("redial@{:?}", *at.lock().unwrap()),
                        (None, probe) => format!("roamed,probe@{probe:?}"),
                    }
                ))
                .collect::<Vec<_>>()
        );
        match ready {
            Some(ready) => readies.push(ready),
            None => no_ready += 1,
        }
        extra_opens.push(opens.saturating_sub(1) as f64);
        extra_sessions.push(sessions.saturating_sub(1) as f64);
        if let Some(link) = app.connected.lock().unwrap().take() {
            link.close();
        }
        live.link.close("done");
        for link in mac_links.lock().unwrap().drain(..) {
            link.close("done");
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    let sum = |values: &[f64]| values.iter().sum::<f64>();
    let max = |values: &[f64]| values.iter().copied().fold(0.0, f64::max);
    let ready = if readies.is_empty() {
        "none".to_owned()
    } else {
        let (p50, p95) = stats(&readies);
        format!("p50={p50:.0} p95={p95:.0}")
    };
    println!(
        "SETTLE_SUMMARY settle_ms={settle_ms} path={name} n={} setup_failed={failed} no_ready={no_ready} roamed_only={roamed_only} | redial_ready(first change to socket on final path) {ready} | extra_signaling_opens total={} max={} | extra_mac_sessions total={} max={}",
        readies.len(),
        sum(&extra_opens),
        max(&extra_opens),
        sum(&extra_sessions),
        max(&extra_sessions),
    );
}
