//! The link takes the direct path whenever one works (Leo's NIGHTLY,
//! 2026-11-22: the phone's link sat on TURN while the WebRTC media session
//! of the same phone and Mac ran direct). Both sides hold a TURN allocation,
//! as the phone and a Mac whose STUN went silent do, and plain UDP works
//! both ways (what made media direct): the link must be direct on both
//! sides within 2 s of coming up, and again within 2 s of each roam.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_mobile_link::dial::{self, SessionEvents, wireguard};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling, TestTurn};
use cmux_mobile_link::{ChannelEvent, DialOptions, LinkConfig, LinkPath, SignalingClient, TransportKind};
use tokio::sync::watch;

/// The direct path must win this soon (the ask's bound).
const DIRECT_WITHIN: Duration = Duration::from_secs(2);

fn options() -> DialOptions {
    DialOptions { include_loopback: true, timeout: Duration::from_secs(20), ..DialOptions::default() }
}

struct Pair {
    phone: watch::Receiver<LinkPath>,
    mac: watch::Receiver<LinkPath>,
    session_id: String,
    up_at: Instant,
    _turn: TestTurn,
    _server: FakeSignaling,
    _echo: tokio::task::JoinHandle<()>,
    _connected: dial::Connected,
}

async fn pair(phone_options: DialOptions, mac_options: DialOptions, turn: TestTurn) -> Pair {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_test_writer()
        .try_init();
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let mac_path = Arc::new(Mutex::new(None::<watch::Receiver<LinkPath>>));
    let slot = Arc::clone(&mac_path);
    tokio::spawn(async move {
        while let Some(session) = mac.next_session().await {
            let events = SessionEvents {
                backend: mac.events(),
                session_id: session.first.session_id.clone(),
                session: session.events,
            };
            let (mac, options, slot) = (mac.clone(), mac_options.clone(), Arc::clone(&slot));
            tokio::spawn(async move {
                let connected =
                    dial::answer(&mac, session.first, events, &options, LinkConfig::default()).await.unwrap();
                *slot.lock().unwrap() = Some(connected.path.clone());
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
    let phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    let connected =
        dial::connect(&phone, &mac_id, TransportKind::WireGuard, &phone_options, LinkConfig::default())
            .await
            .expect("dial");
    let up_at = Instant::now();
    let mac = loop {
        if let Some(path) = mac_path.lock().unwrap().clone() {
            break path;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    };
    // Terminal-like traffic: 1 KB echoed every 20 ms.
    let channel = connected.link.open("echo", serde_json::json!({})).await.unwrap();
    let (sender, mut receiver) = channel.split();
    let echo = tokio::spawn(async move {
        let drain = tokio::spawn(async move { while receiver.recv().await.is_some() {} });
        let mut tick = tokio::time::interval(Duration::from_millis(20));
        loop {
            tick.tick().await;
            if sender.send(Bytes::from(vec![7u8; 1000])).await.is_err() {
                break;
            }
        }
        drain.abort();
    });
    Pair {
        phone: connected.path.clone(),
        mac,
        session_id: connected.session_id.clone(),
        up_at,
        _turn: turn,
        _server: server,
        _echo: echo,
        _connected: connected,
    }
}

/// How long from `from` until both sides read Direct (and stay so for
/// 300 ms), or `None` within `limit`.
async fn direct_after(pair: &Pair, from: Instant, limit: Duration) -> Option<Duration> {
    let mut since: Option<Instant> = None;
    while from.elapsed() < limit + Duration::from_millis(300) {
        let both = *pair.phone.borrow() == LinkPath::Direct && *pair.mac.borrow() == LinkPath::Direct;
        match (both, since) {
            (true, None) => since = Some(Instant::now()),
            (true, Some(at)) if at.elapsed() >= Duration::from_millis(300) => {
                return Some(at.duration_since(from));
            }
            (false, _) => since = None,
            _ => {}
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    None
}

fn both_turn(turn: &TestTurn) -> (DialOptions, DialOptions) {
    let phone = DialOptions { ice_servers: vec![turn.udp_only()], ..options() };
    let mac = DialOptions { ice_servers: vec![turn.udp_only()], ..options() };
    (phone, mac)
}

/// Both sides hold TURN and plain UDP works: the link comes up direct, or
/// upgrades to direct within 2 s.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_link_is_direct_within_2s_when_direct_udp_works() {
    let turn = TestTurn::start().await;
    let (phone, mac) = both_turn(&turn);
    let pair = pair(phone, mac, turn).await;
    let took = direct_after(&pair, pair.up_at, DIRECT_WITHIN).await;
    eprintln!(
        "direct after link up: {took:?} (phone {:?}, mac {:?})",
        *pair.phone.borrow(),
        *pair.mac.borrow()
    );
    assert!(took.is_some_and(|took| took <= DIRECT_WITHIN), "not direct within 2 s: {took:?}");
}

/// The Mac roams (as every netwatch change made it, every 1-2 min on
/// Leo's wired Mac): after each roam the link is direct again within 2 s,
/// not left on TURN until the next one.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_link_is_direct_within_2s_after_each_mac_roam() {
    let turn = TestTurn::start().await;
    let (phone, mac) = both_turn(&turn);
    let pair = pair(phone, mac, turn).await;
    assert!(direct_after(&pair, pair.up_at, Duration::from_secs(5)).await.is_some(), "never direct");
    let mut took = Vec::new();
    for _ in 0..3 {
        let at = Instant::now();
        wireguard::roam_session(&pair.session_id, false).await.expect("the Mac side roams");
        took.push(direct_after(&pair, at, Duration::from_secs(6)).await);
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    eprintln!("direct after each Mac roam: {took:?}");
    assert!(took.iter().all(|t| t.is_some_and(|t| t <= DIRECT_WITHIN)), "{took:?}");
}

/// The phone roams (Wi-Fi to Wi-Fi): direct again within 2 s.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_link_is_direct_within_2s_after_each_phone_roam() {
    let turn = TestTurn::start().await;
    let (phone, mac) = both_turn(&turn);
    let pair = pair(phone, mac, turn).await;
    assert!(direct_after(&pair, pair.up_at, Duration::from_secs(5)).await.is_some(), "never direct");
    let mut took = Vec::new();
    for _ in 0..3 {
        let at = Instant::now();
        wireguard::roam_session(&pair.session_id, true).await.expect("the phone side roams");
        took.push(direct_after(&pair, at, Duration::from_secs(6)).await);
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    eprintln!("direct after each phone roam: {took:?}");
    assert!(took.iter().all(|t| t.is_some_and(|t| t <= DIRECT_WITHIN)), "{took:?}");
}

/// While set, plain UDP to anything but a TURN relayed address is lost on
/// both sides (the direct path does not work yet).
static DIRECT_DOWN: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

fn direct_down(addr: &std::net::SocketAddr) -> bool {
    DIRECT_DOWN.load(std::sync::atomic::Ordering::Relaxed) && !cmux_mobile_link::testing::is_test_relay(addr)
}

/// The link came up on TURN because the direct path did not work yet (the
/// direct probes of the dial all went unanswered, so those paths are dead).
/// The moment direct UDP works both ways, as when WebRTC media found its
/// direct pair, the link moves onto it within 2 s, not at a dead path's
/// 30 s probe.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_link_upgrades_to_direct_within_2s_once_direct_works() {
    use std::sync::atomic::Ordering;
    let turn = TestTurn::start().await;
    DIRECT_DOWN.store(true, Ordering::Relaxed);
    let (phone, mac) = both_turn(&turn);
    let phone = DialOptions { drop_udp_to: Some(direct_down), ..phone };
    let mac = DialOptions { drop_udp_to: Some(direct_down), ..mac };
    let pair = pair(phone, mac, turn).await;
    // Long enough for every direct probe of the dial to be lost (3 lost
    // probes make a path dead).
    tokio::time::sleep(Duration::from_secs(6)).await;
    let before = (*pair.phone.borrow(), *pair.mac.borrow());
    assert_eq!(before, (LinkPath::Turn, LinkPath::Turn), "the dial must settle on TURN first");
    let at = Instant::now();
    DIRECT_DOWN.store(false, Ordering::Relaxed);
    let took = direct_after(&pair, at, Duration::from_secs(40)).await;
    DIRECT_DOWN.store(false, Ordering::Relaxed);
    eprintln!("direct after direct UDP works: {took:?} (before {before:?})");
    assert!(took.is_some_and(|took| took <= DIRECT_WITHIN), "not direct within 2 s: {took:?}");
}
