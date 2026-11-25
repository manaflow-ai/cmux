//! What the upgrade probes (`UPGRADE_PROBE_EVERY`, 750 ms) cost while a
//! busy link rides TURN and its direct paths stay dead, and that a
//! backgrounded phone app sends none (`wireguard::set_app_backgrounded`).
//! Its own test binary: the background flag is process-wide.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use bytes::Bytes;
use cmux_mobile_link::dial::{self, SessionEvents, wireguard};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling, TestTurn};
use cmux_mobile_link::{ChannelEvent, DialOptions, LinkConfig, LinkPath, SignalingClient, TransportKind};
use tokio::sync::watch;

fn options() -> DialOptions {
    DialOptions { include_loopback: true, timeout: Duration::from_secs(20), ..DialOptions::default() }
}

struct Pair {
    phone: watch::Receiver<LinkPath>,
    mac: watch::Receiver<LinkPath>,
    session_id: String,
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
        _turn: turn,
        _server: server,
        _echo: echo,
        _connected: connected,
    }
}

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

/// While set, plain UDP to anything but a TURN relayed address is lost.
static DIRECT_DOWN: AtomicBool = AtomicBool::new(false);
/// Datagrams lost to a dead direct path (both sides together).
static DIRECT_SENT: AtomicU64 = AtomicU64::new(0);

fn direct_down(addr: &std::net::SocketAddr) -> bool {
    let down = DIRECT_DOWN.load(Ordering::Relaxed) && !cmux_mobile_link::testing::is_test_relay(addr);
    if down {
        DIRECT_SENT.fetch_add(1, Ordering::Relaxed);
    }
    down
}

/// Datagrams per minute both sides send to dead direct paths over `span`.
async fn direct_per_min(span: Duration) -> f64 {
    let from = DIRECT_SENT.load(Ordering::Relaxed);
    tokio::time::sleep(span).await;
    (DIRECT_SENT.load(Ordering::Relaxed) - from) as f64 * 60.0 / span.as_secs_f64()
}

/// Both sides on TURN, every direct path dead, 1 KB echoed every 20 ms:
/// in front the upgrade probes add their datagrams; backgrounded they stop,
/// and back in front they resume.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn upgrade_probes_cost_and_stop_in_the_background() {
    let turn = TestTurn::start().await;
    DIRECT_DOWN.store(true, Ordering::Relaxed);
    let phone =
        DialOptions { ice_servers: vec![turn.udp_only()], drop_udp_to: Some(direct_down), ..options() };
    let mac = DialOptions { ice_servers: vec![turn.udp_only()], drop_udp_to: Some(direct_down), ..options() };
    let pair = pair(phone, mac, turn).await;
    // Every direct probe of the dial is lost: the paths die, TURN carries.
    tokio::time::sleep(Duration::from_secs(6)).await;
    assert_eq!((*pair.phone.borrow(), *pair.mac.borrow()), (LinkPath::Turn, LinkPath::Turn));
    let window = Duration::from_secs(20);
    let front = direct_per_min(window).await;
    wireguard::set_app_backgrounded(true);
    let background = direct_per_min(window).await;
    wireguard::set_app_backgrounded(false);
    let again = direct_per_min(window).await;
    DIRECT_DOWN.store(false, Ordering::Relaxed);
    eprintln!(
        "datagrams/min to dead direct paths, both sides: front {front:.0}, backgrounded {background:.0}, \
         front again {again:.0}"
    );
    assert_eq!(*pair.phone.borrow(), LinkPath::Turn, "nothing direct worked, the link stays on TURN");
    // 750 ms is 80 per minute per dead direct path per side.
    assert!(front >= background + 80.0, "front {front:.0} vs backgrounded {background:.0}");
    assert!(again >= background + 80.0, "front again {again:.0} vs backgrounded {background:.0}");
    let _ = &pair.session_id;
}
