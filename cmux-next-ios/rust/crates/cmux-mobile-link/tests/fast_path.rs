//! The shared path selector on the mobile link: with a direct path and a
//! TURN relay to the Mac, a stream goes direct, and when the direct path is
//! cut (both ways, the relay still up) it moves to the relay within the
//! quiet-path window instead of after the route rules' 14 s silence.

use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_mobile_link::dial::{self, SessionEvents};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling, TEST_RELAY_PORTS_START, TestTurn};
use cmux_mobile_link::{ChannelEvent, DialOptions, LinkConfig, LinkPath, SignalingClient, TransportKind};

static CUT: AtomicBool = AtomicBool::new(false);

/// Direct datagrams vanish while `CUT` is set; relayed ones (through a TURN
/// server) always arrive, 10 ms late each way.
fn impair(via_turn: bool, from: &SocketAddr) -> Option<Duration> {
    let relayed = via_turn || (from.ip().is_loopback() && from.port() >= TEST_RELAY_PORTS_START);
    if relayed {
        Some(Duration::from_millis(10))
    } else if CUT.load(Ordering::Relaxed) {
        None
    } else {
        Some(Duration::ZERO)
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_cut_direct_path_moves_to_the_relay_without_a_long_stall() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_test_writer()
        .try_init();
    let turn = TestTurn::start().await;
    let options = DialOptions {
        include_loopback: true,
        timeout: Duration::from_secs(20),
        ice_servers: vec![turn.udp_only()],
        impair_inbound: Some(impair),
        ..DialOptions::default()
    };
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let mac_options = options.clone();
    tokio::spawn(async move {
        let Some(session) = mac.next_session().await else { return };
        let events = SessionEvents {
            backend: mac.events(),
            session_id: session.first.session_id.clone(),
            session: session.events,
        };
        let connected =
            dial::answer(&mac, session.first, events, &mac_options, LinkConfig::default()).await.unwrap();
        while let Some(mut incoming) = connected.link.accept().await {
            tokio::spawn(async move {
                while let Some(ChannelEvent::Data(bytes)) = incoming.channel.recv().await {
                    let _ = incoming.channel.send(bytes).await;
                }
            });
        }
    });
    let phone_id = uuid::Uuid::new_v4().to_string();
    let phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    let connected = dial::connect(&phone, &mac_id, TransportKind::WireGuard, &options, LinkConfig::default())
        .await
        .unwrap();
    let channel = connected.link.open("echo", serde_json::json!({})).await.unwrap();
    let (sender, mut receiver) = channel.split();
    let writer = tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_millis(20));
        let started = Instant::now();
        let mut sent = 0usize;
        while started.elapsed() < Duration::from_secs(6) {
            tick.tick().await;
            sender.send(Bytes::from(vec![7u8; 500])).await.unwrap();
            sent += 1;
        }
        (sent, sender)
    });
    let reader = tokio::spawn(async move {
        let mut arrivals = Vec::new();
        while let Some(ChannelEvent::Data(_)) = receiver.recv().await {
            arrivals.push(Instant::now());
        }
        arrivals
    });
    tokio::time::sleep(Duration::from_secs(2)).await;
    assert_eq!(*connected.path.borrow(), LinkPath::Direct, "the direct path carries the stream");
    let cut_at = Instant::now();
    CUT.store(true, Ordering::Relaxed);
    let (sent, _sender) = writer.await.unwrap();
    tokio::time::sleep(Duration::from_secs(2)).await;
    let after = *connected.path.borrow();
    connected.link.close("done");
    let arrivals = reader.await.unwrap();
    assert_eq!(arrivals.len(), sent, "every message comes back");
    let mut last = cut_at;
    let mut stall = Duration::ZERO;
    for at in arrivals.iter().filter(|at| **at >= cut_at) {
        stall = stall.max(at.duration_since(last));
        last = *at;
    }
    assert!(matches!(after, LinkPath::Turn), "ends on the relay, not {after:?}");
    assert!(stall < Duration::from_secs(3), "stalled {stall:?} after the cut");
}

/// The Mac's direct address reaches the phone only in its datagrams (no
/// announcement names it, as with a peer-reflexive NAT mapping): the phone
/// starts on the relay, learns the address, probes it, and moves direct.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_unannounced_direct_address_still_wins_over_the_relay() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_test_writer()
        .try_init();
    let turn = TestTurn::start().await;
    let options = DialOptions {
        include_loopback: true,
        timeout: Duration::from_secs(20),
        ice_servers: vec![turn.udp_only()],
        ..DialOptions::default()
    };
    let server =
        FakeSignaling::start(FakeOptions { strip_answer_direct_endpoints: true, ..FakeOptions::default() })
            .await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let mac_options = options.clone();
    tokio::spawn(async move {
        let Some(session) = mac.next_session().await else { return };
        let events = SessionEvents {
            backend: mac.events(),
            session_id: session.first.session_id.clone(),
            session: session.events,
        };
        let connected =
            dial::answer(&mac, session.first, events, &mac_options, LinkConfig::default()).await.unwrap();
        while let Some(mut incoming) = connected.link.accept().await {
            tokio::spawn(async move {
                while let Some(ChannelEvent::Data(bytes)) = incoming.channel.recv().await {
                    let _ = incoming.channel.send(bytes).await;
                }
            });
        }
    });
    let phone_id = uuid::Uuid::new_v4().to_string();
    let phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    let connected = dial::connect(&phone, &mac_id, TransportKind::WireGuard, &options, LinkConfig::default())
        .await
        .unwrap();
    let channel = connected.link.open("echo", serde_json::json!({})).await.unwrap();
    let (sender, mut receiver) = channel.split();
    let started = Instant::now();
    let mut direct = false;
    while started.elapsed() < Duration::from_secs(8) {
        sender.send(Bytes::from(vec![7u8; 200])).await.unwrap();
        let _ = tokio::time::timeout(Duration::from_millis(500), receiver.recv()).await;
        if *connected.path.borrow() == LinkPath::Direct {
            direct = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let path = *connected.path.borrow();
    connected.link.close("done");
    assert!(direct, "still {path:?} after {:?}", started.elapsed());
}
