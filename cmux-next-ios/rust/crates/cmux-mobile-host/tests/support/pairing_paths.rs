//! Real signed pairing and host admission over each available link route.
//! LocalHub supplies signaling; its payload still travels over direct WireGuard.
//! The relay uses the production WebSocket wire against a loopback server (no TLS,
//! provider login, Bonjour discovery, iOS UI, or physical radio claim).

use super::*;
use cmux_mobile_host::auth::{TokenSource, Tokens};
use cmux_mobile_link::LinkPath;
use cmux_mobile_link::dial::relay::RelayEndpoint;
use cmux_mobile_link::local::{LOCAL_USER, connect_hub};
use cmux_mobile_link::local_hub::LocalHub;
use cmux_mobile_link::testing::TestTurn;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicUsize, Ordering};

static RECEIVED: [AtomicUsize; 4] = [const { AtomicUsize::new(0) }; 4];
static DROPPED: [AtomicUsize; 4] = [const { AtomicUsize::new(0) }; 4];
const DELAY: Duration = Duration::from_millis(8);

// Each path owns its counters, so late teardown traffic cannot contaminate the
// next row. The first datagram and every seventeenth one are dropped; all others
// arrive 8 ms later. This hook runs below the real WG/stream/auth implementation.
fn impair<const PATH: usize>(_: bool, _: &SocketAddr, _: usize) -> Option<Duration> {
    let n = RECEIVED[PATH].fetch_add(1, Ordering::Relaxed) + 1;
    if n == 1 || n % 17 == 0 {
        DROPPED[PATH].fetch_add(1, Ordering::Relaxed);
        None
    } else {
        Some(DELAY)
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn signed_pairing_survives_loss_on_local_udp_turn_and_websocket_relay() {
    for (index, label, expected, impairment) in [
        (0, "LocalHub", LinkPath::Direct, impair::<0> as cmux_mobile_link::dial::ImpairInbound),
        (1, "Udp", LinkPath::Direct, impair::<1>),
        (2, "TurnUdp", LinkPath::Turn, impair::<2>),
        (3, "WssRelay", LinkPath::HttpsRelay, impair::<3>),
    ] {
        let started = std::time::Instant::now();
        tokio::time::timeout(Duration::from_secs(40), async {
            let mut fixture = fixture_with(FakeOptions::default(), true).await;
            let turn = if expected == LinkPath::Turn { Some(TestTurn::start().await) } else { None };
            let ice_servers = turn.as_ref().map(|t| vec![t.ice.clone()]).unwrap_or_default();
            let server = FakeSignaling::start(FakeOptions {
                strip_direct_endpoints: expected == LinkPath::Turn,
                ice_servers: ice_servers.clone(),
                ..FakeOptions::default()
            }).await;
            let hub = if label == "LocalHub" {
                let phone_id = fixture.phone_id.clone();
                Some(LocalHub::bind("127.0.0.1:0".parse().unwrap(), &fixture.mac_id,
                    Arc::new(move |device| device == phone_id)).await.unwrap())
            } else { None };
            let (mac, owner, ice) = if let Some(hub) = &hub {
                fixture.phone = connect_hub(
                    &[format!("127.0.0.1:{}", hub.port()).parse().unwrap()], &fixture.phone_id
                ).await.unwrap();
                let mac = SignalingClient::connect_local(&hub.loopback_url(), hub.secret(), &fixture.mac_id).await.unwrap();
                assert!(fixture.phone.is_local() && mac.is_local());
                (mac, LOCAL_USER, IceSource::Fixed(Vec::new()))
            } else {
                fixture.phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &fixture.phone_id).await.unwrap();
                let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &fixture.mac_id).await.unwrap();
                let tokens = Arc::new(Tokens::new(TokenSource::Access("user:alice".into())));
                (mac, "alice", IceSource::api(server.base_url.clone(), None, tokens))
            };
            let host = tokio::spawn(serve_signaling(mac, AnswerContext {
                owner_user_id: owner.into(), services: Arc::clone(&fixture.services), ice,
                include_loopback: true, exclude_cgnat: false, mailbox: None, session_exposure: None,
            }));
            let dial = DialOptions {
                ice_servers,
                relay_only: expected == LinkPath::Turn,
                force_relay: expected == LinkPath::HttpsRelay,
                relay: (expected == LinkPath::HttpsRelay).then(|| RelayEndpoint::with_token(
                    server.base_url.clone(), None, &fixture.phone_id, "user:alice")),
                impair_inbound: Some(impairment),
                ..options()
            };
            let connected = connect_with(&fixture, TransportKind::WireGuard, &dial).await.expect(label);
            let link = &connected.link;
            assert_eq!(*connected.path.borrow(), expected, "{label} selected route");
            let mut refused = link.open("echo", serde_json::json!({})).await.unwrap();
            assert_eq!(drain(&mut refused).await.1, "unpaired");
            let keys = phone_keys();
            let mut forged = auth(link, &fixture, &keys, &p256(), "pair").await;
            assert_eq!(drain(&mut forged).await.1, "unpaired");
            let mut auth = auth(link, &fixture, &keys, &keys.identity, "pair").await;
            assert_eq!(json_frame(auth.recv().await), serde_json::json!({"pending": true}));
            let request = fixture.events.as_ref().unwrap().lock().await.recv().await.unwrap();
            assert!(matches!(request, Event::PairRequest { phone_device_id, identity_key, approval_key, .. }
                if phone_device_id == fixture.phone_id && identity_key == keys.identity_hex && approval_key == keys.approval_hex));
            fixture.trust.as_ref().unwrap().send_replace(Some(trusting(&fixture, &keys)));
            assert_eq!(json_frame(auth.recv().await), serde_json::json!({"ok": true}));
            let payload = Bytes::from((0..32768).map(|n| (n % 251) as u8).collect::<Vec<_>>());
            let mut echo = link.open("echo", serde_json::json!({})).await.unwrap();
            echo.send(payload.clone()).await.unwrap();
            let mut echoed = Vec::new();
            while echoed.len() < payload.len() {
                match echo.recv().await {
                    Some(ChannelEvent::Data(bytes)) => echoed.extend_from_slice(&bytes),
                    other => panic!("{label}: echo interrupted: {other:?}"),
                }
            }
            assert_eq!(echoed, payload);
            assert_eq!(*connected.path.borrow(), expected, "{label} stayed on route");
            if expected == LinkPath::HttpsRelay {
                assert_eq!(server.relay_joins(), 2);
                assert!(server.relay_frames() > 0);
            }
            let received = RECEIVED[index].load(Ordering::Relaxed);
            let dropped = DROPPED[index].load(Ordering::Relaxed);
            assert!(dropped > 0 && received > dropped, "{label}: impairment must execute");
            eprintln!("PAIRING_PATH {}", serde_json::json!({
                "carrier": label, "path": expected.as_str(), "elapsed_ms": started.elapsed().as_millis(),
                "delay_ms": DELAY.as_millis(), "received": received, "dropped": dropped,
                "echo_bytes": echoed.len(), "paired": true
            }));
            link.close("done");
            host.abort();
        }).await.unwrap_or_else(|_| panic!("{label}: signed pairing/echo exceeded 40 seconds"));
    }
}
