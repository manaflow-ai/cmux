//! The exported API end to end against a fake backend and an echo Mac.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_mobile_link::dial::{self, SessionEvents};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_mobile_link::{ChannelEvent, DialOptions, LinkConfig, SignalingClient};
use cmux_mobile_link_ffi::{
    ChannelMessage, ConnectRequest, LinkEvent, LinkObserver, LinkPath, Transport, WarmPool, connect_inner,
};

#[derive(Default)]
struct Recorder(Mutex<Vec<LinkEvent>>);

impl LinkObserver for Recorder {
    fn on_event(&self, event: LinkEvent) {
        self.0.lock().unwrap().push(event);
    }
}

/// `body`, or a panic naming `what` once `limit` passes.
async fn within<F: std::future::Future<Output = ()>>(limit: Duration, what: &str, body: F) {
    if tokio::time::timeout(limit, body).await.is_err() {
        panic!("{what} still running after {limit:?}: a stalled link or socket");
    }
}

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
                let connected =
                    dial::answer(&mac, first, events, &options, LinkConfig::default()).await.unwrap();
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

async fn round_trip(transport: Transport) {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    spawn_echo_mac(SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap());
    let recorder = Arc::new(Recorder::default());
    let handle = connect_inner(
        ConnectRequest {
            base_url: server.base_url.clone(),
            token: "user:alice".into(),
            team_id: "team".into(),
            device_id: uuid::Uuid::new_v4().to_string(),
            mac_device_id: mac_id,
            transport,
            include_loopback: true,
            relay_only: false,
            block_udp: false,
            proxy_only: false,
            drop_wireguard: false,
            force_relay: false,
            video_lane: false,
            webrtc_media: false,
            ultra: cmux_mobile_link::UltraSetting::Off,
        },
        Some(recorder.clone() as Arc<dyn LinkObserver>),
    )
    .await
    .expect("connect");
    assert_eq!(handle.transport(), transport);
    // WireGuard reports the path its peer's datagrams arrive on: direct on
    // loopback.
    for _ in 0..100 {
        if handle.path() == LinkPath::Direct {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(handle.path(), LinkPath::Direct);
    // A direct path names where its peer is (the host's loopback, LAN or tailnet address the
    // dial picked); only a relayed path names none.
    assert!(["lan", "tailnet", "wan"].contains(&handle.peer_scope().as_str()), "{}", handle.peer_scope());
    let channel = handle.open_channel("echo".into(), String::new()).await.unwrap();
    channel.send(b"hello".to_vec()).await.unwrap();
    assert_eq!(channel.recv().await, ChannelMessage::Data { bytes: b"hello".to_vec() });
    assert!(handle.ping().await.unwrap() < 5000);
    assert!(handle.open_channel("echo".into(), "[1]".into()).await.is_err());
    handle.close();
    match tokio::time::timeout(Duration::from_secs(5), channel.recv()).await.unwrap() {
        ChannelMessage::Closed { code, .. } => assert_eq!(code, "link_closed"),
        other => panic!("unexpected {other:?}"),
    }
    tokio::time::sleep(Duration::from_millis(100)).await;
    let events = recorder.0.lock().unwrap().clone();
    assert_eq!(events.first(), Some(&LinkEvent::Connecting { transport }));
    assert!(
        events.iter().any(|e| matches!(e, LinkEvent::Connected { transport: t, .. } if *t == transport)),
        "{events:?}"
    );
    assert!(
        events.contains(&LinkEvent::Connected { transport, path: LinkPath::Direct })
            || events.contains(&LinkEvent::PathChanged { path: LinkPath::Direct }),
        "{events:?}"
    );
    assert!(events.iter().any(|e| matches!(e, LinkEvent::Rtt { .. })), "{events:?}");
    assert!(matches!(events.last(), Some(LinkEvent::Disconnected { .. })), "{events:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn webrtc_round_trip() {
    round_trip(Transport::WebRtc).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn wireguard_round_trip() {
    round_trip(Transport::WireGuard).await;
}

/// Relay only: WireGuard rides the phone's TURN allocation and never
/// moves to the direct path (there is no backend relay any more).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn wireguard_relay_only_rides_turn() {
    // Its own deadline: a link that stalls (cmux#41791: another test's
    // network change roamed it onto a socket whose runtime was gone) fails
    // here with a message instead of hanging the binary.
    within(Duration::from_secs(60), "wireguard_relay_only_rides_turn", async {
        let turn = cmux_mobile_link::testing::TestTurn::start().await;
        let server = FakeSignaling::start(FakeOptions {
            ice_servers: vec![turn.udp_only()],
            ..FakeOptions::default()
        })
        .await;
        let mac_id = uuid::Uuid::new_v4().to_string();
        spawn_echo_mac(
            SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap(),
        );
        let recorder = Arc::new(Recorder::default());
        let handle = connect_inner(
            ConnectRequest {
                base_url: server.base_url.clone(),
                token: "user:alice".into(),
                team_id: "team".into(),
                device_id: uuid::Uuid::new_v4().to_string(),
                mac_device_id: mac_id,
                transport: Transport::WireGuard,
                include_loopback: true,
                relay_only: true,
                block_udp: false,
                proxy_only: false,
                drop_wireguard: false,
                force_relay: false,
                video_lane: false,
                webrtc_media: false,
                ultra: cmux_mobile_link::UltraSetting::Off,
            },
            Some(recorder.clone() as Arc<dyn LinkObserver>),
        )
        .await
        .expect("connect");
        let channel = handle.open_channel("echo".into(), String::new()).await.unwrap();
        let payload = vec![7u8; 200_000];
        channel.send(payload.clone()).await.unwrap();
        let mut received = Vec::new();
        while received.len() < payload.len() {
            match channel.recv().await {
                ChannelMessage::Data { bytes } => received.extend(bytes),
                other => panic!("unexpected {other:?}"),
            }
        }
        assert_eq!(received, payload);
        // The direct UDP path would have been confirmed well within this.
        tokio::time::sleep(Duration::from_secs(2)).await;
        assert_eq!(handle.path(), LinkPath::Turn);
        // Through TURN there is no peer address of its own: not the LAN, not a tailnet.
        assert_eq!(handle.peer_scope(), "");
        let events = recorder.0.lock().unwrap().clone();
        assert!(!events.contains(&LinkEvent::PathChanged { path: LinkPath::Direct }), "{events:?}");
        handle.close();
    })
    .await;
}

/// UDP blocked over WireGuard without a TURN server, toward a Mac whose build
/// has no cmux relay: no path at all. The dial fails at once with
/// `network_blocked` and what each path did, which the app turns into the
/// person's sentence (PROTOCOL.md "When no path works").
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn wireguard_with_no_path_says_the_network_blocks_it() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    spawn_echo_mac(SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap());
    let started = std::time::Instant::now();
    let result = connect_inner(
        ConnectRequest {
            base_url: server.base_url.clone(),
            token: "user:alice".into(),
            team_id: "team".into(),
            device_id: uuid::Uuid::new_v4().to_string(),
            mac_device_id: mac_id,
            transport: Transport::WireGuard,
            include_loopback: true,
            relay_only: false,
            block_udp: true,
            proxy_only: false,
            drop_wireguard: false,
            force_relay: false,
            video_lane: false,
            webrtc_media: false,
            ultra: cmux_mobile_link::UltraSetting::Off,
        },
        None,
    )
    .await;
    match result {
        Err(cmux_mobile_link_ffi::CmuxMobileError::Refused { code, message }) => {
            assert_eq!(code, cmux_mobile_link_ffi::NETWORK_BLOCKED);
            let failures: serde_json::Value = serde_json::from_str(&message).unwrap();
            assert_eq!(failures["udp"], "off", "{message}");
            assert_eq!(failures["turn"], "none_offered", "{message}");
            assert_eq!(failures["relay"], "peer_cannot", "{message}");
        }
        Err(other) => panic!("unexpected error {other:?}"),
        Ok(_) => panic!("UDP-blocked WireGuard connected with no path"),
    }
    assert!(started.elapsed() < Duration::from_secs(10));
}

/// Debug "Relay via cmux (HTTPS) only" through the FFI: the phone's dial
/// joins the service's relay (the fake's, at the request's base URL) and
/// the link rides it, path `HttpsRelay`.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn wireguard_forced_relay_rides_the_services_relay() {
    within(Duration::from_secs(60), "wireguard_forced_relay_rides_the_services_relay", async {
        let server = FakeSignaling::start(FakeOptions::default()).await;
        let mac_id = uuid::Uuid::new_v4().to_string();
        let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
        let relay = cmux_mobile_link::dial::relay::RelayEndpoint::with_token(
            server.base_url.clone(),
            None,
            mac_id.clone(),
            "user:alice",
        );
        tokio::spawn(async move {
            while let Some(session) = mac.next_session().await {
                let first = session.first;
                let events = SessionEvents {
                    backend: mac.events(),
                    session_id: first.session_id.clone(),
                    session: session.events,
                };
                let (mac, relay) = (mac.clone(), relay.clone());
                tokio::spawn(async move {
                    let options =
                        DialOptions { include_loopback: true, relay: Some(relay), ..DialOptions::default() };
                    let connected =
                        dial::answer(&mac, first, events, &options, LinkConfig::default()).await.unwrap();
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
        let handle = connect_inner(
            ConnectRequest {
                base_url: server.base_url.clone(),
                token: "user:alice".into(),
                team_id: "team".into(),
                device_id: uuid::Uuid::new_v4().to_string(),
                mac_device_id: mac_id,
                transport: Transport::WireGuard,
                include_loopback: true,
                relay_only: false,
                block_udp: false,
                proxy_only: false,
                drop_wireguard: false,
                force_relay: true,
                video_lane: false,
                webrtc_media: false,
                ultra: cmux_mobile_link::UltraSetting::Off,
            },
            None,
        )
        .await
        .expect("connect through the relay");
        let channel = handle.open_channel("echo".into(), String::new()).await.unwrap();
        let payload = vec![9u8; 100_000];
        channel.send(payload.clone()).await.unwrap();
        let mut received = Vec::new();
        while received.len() < payload.len() {
            match channel.recv().await {
                ChannelMessage::Data { bytes } => received.extend(bytes),
                other => panic!("unexpected {other:?}"),
            }
        }
        assert_eq!(received, payload);
        assert_eq!(handle.path(), LinkPath::HttpsRelay);
        assert_eq!(server.relay_joins(), 2);
        handle.close();
    })
    .await;
}

/// The service refusing the access token (401 on the signaling upgrade) comes
/// out typed, `Refused` with code `unauthorized`, for every transport: the app
/// refreshes the token once on it, and a refused fresh token is a revoked
/// session that stops redialing (reliability matrix `pairing_revoked_token`).
/// Before, it was `Signaling` with the status only in the message.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refused_token_is_typed_unauthorized() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    for transport in [Transport::WireGuard, Transport::WebRtc] {
        let result = connect_inner(
            ConnectRequest {
                base_url: server.base_url.clone(),
                // The fake backend admits only `user:<name>` tokens.
                token: "revoked".into(),
                team_id: "team".into(),
                device_id: uuid::Uuid::new_v4().to_string(),
                mac_device_id: uuid::Uuid::new_v4().to_string(),
                transport,
                include_loopback: true,
                relay_only: false,
                block_udp: false,
                proxy_only: false,
                drop_wireguard: false,
                force_relay: false,
                video_lane: false,
                webrtc_media: false,
                ultra: cmux_mobile_link::UltraSetting::Off,
            },
            None,
        )
        .await;
        match result {
            Err(cmux_mobile_link_ffi::CmuxMobileError::Refused { code, .. }) => {
                assert_eq!(code, cmux_mobile_link_ffi::UNAUTHORIZED, "{transport:?}");
            }
            Err(other) => panic!("{transport:?}: a refused token gave {other:?}"),
            Ok(_) => panic!("{transport:?}: a refused token connected"),
        }
    }
}

/// Relay only over WebRTC needs TURN; the fake backend offers none, so the
/// dial fails at once instead of waiting for ICE to time out.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn webrtc_relay_only_without_turn_fails_fast() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    spawn_echo_mac(SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap());
    let started = std::time::Instant::now();
    let result = connect_inner(
        ConnectRequest {
            base_url: server.base_url.clone(),
            token: "user:alice".into(),
            team_id: "team".into(),
            device_id: uuid::Uuid::new_v4().to_string(),
            mac_device_id: mac_id,
            transport: Transport::WebRtc,
            include_loopback: true,
            relay_only: true,
            block_udp: false,
            proxy_only: false,
            drop_wireguard: false,
            force_relay: false,
            video_lane: false,
            webrtc_media: false,
            ultra: cmux_mobile_link::UltraSetting::Off,
        },
        None,
    )
    .await;
    match result {
        Err(cmux_mobile_link_ffi::CmuxMobileError::Transport { message }) => {
            assert!(message.contains("TURN"), "{message}");
        }
        Err(other) => panic!("unexpected error {other:?}"),
        Ok(_) => panic!("relay-only WebRTC connected without TURN"),
    }
    assert!(started.elapsed() < Duration::from_secs(10));
}

fn request(server: &FakeSignaling, device_id: &str, mac_id: &str) -> ConnectRequest {
    ConnectRequest {
        base_url: server.base_url.clone(),
        token: "user:alice".into(),
        team_id: "team".into(),
        device_id: device_id.to_owned(),
        mac_device_id: mac_id.to_owned(),
        transport: Transport::WebRtc,
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

// Every test that asserts what the warm pool holds (a reused or alive socket,
// cached ICE servers, one socket opened) dials on a `WarmPool` of its own:
// the tests of this binary run in parallel, and the process's shared pool is
// emptied by any of them calling `reset_warm_state` and trimmed to
// `MAX_WARM_SOCKETS` by the sockets of all of them.

fn names(marks: &[cmux_mobile_link_ffi::TimingMark]) -> Vec<&str> {
    marks.iter().map(|m| m.name.as_str()).collect()
}

// The phone's local-link ads (`local_link_observe`, `local_link_pair`) are one table per process,
// and a network change (`network_changed`) forgets every ad in it. A test that puts an ad there
// and dials on it, or that roams, holds this lock for its whole body: otherwise a parallel roam
// wipes its hub's ad mid-test and the service dial wins a race the hub was to win (run
// 45786635352, `the_losing_service_dial_leaves_the_pool_sound`).
static LOCAL_ADS: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

async fn local_ads() -> tokio::sync::MutexGuard<'static, ()> {
    LOCAL_ADS.lock().await
}

/// `prewarm` opens the signaling socket and fetches the ICE servers, so the
/// dial that follows does neither; a redial after the link closed reuses
/// the same socket and servers. Every dial records its steps.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn prewarm_and_redial_reuse_the_socket_and_ice_servers() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    spawn_echo_mac(SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap());
    let device = uuid::Uuid::new_v4().to_string();
    let pool = WarmPool::new();
    let warmed =
        pool.prewarm(server.base_url.clone(), "user:alice".into(), "team".into(), device.clone()).await;
    assert!(names(&warmed).contains(&"signaling_open"), "{warmed:?}");
    assert!(names(&warmed).contains(&"ice_servers_fetched"), "{warmed:?}");

    let first = pool.connect(request(&server, &device, &mac_id), None).await.expect("connect");
    let marks = first.timings();
    for step in [
        "signaling_reused",
        "ice_servers_cached",
        "offer_sent",
        "answer_received",
        "channel_open",
        "link_ready",
    ] {
        assert!(names(&marks).contains(&step), "missing {step}: {marks:?}");
    }
    assert!(!names(&marks).contains(&"signaling_open"), "{marks:?}");
    first.close();
    drop(first);

    // The socket outlives the link: the next dial skips signaling again.
    let second = pool.connect(request(&server, &device, &mac_id), None).await.expect("redial");
    assert!(names(&second.timings()).contains(&"signaling_reused"), "{:?}", second.timings());
    let channel = second.open_channel("echo".into(), String::new()).await.unwrap();
    channel.send(b"warm".to_vec()).await.unwrap();
    assert_eq!(channel.recv().await, ChannelMessage::Data { bytes: b"warm".to_vec() });

    // A second prewarm finds the socket alive.
    let again = pool.prewarm(server.base_url.clone(), "user:alice".into(), "team".into(), device).await;
    assert!(names(&again).contains(&"signaling_alive"), "{again:?}");
    assert!(names(&again).contains(&"ice_servers_cached"), "{again:?}");
    second.close();
    pool.reset().await;
}

/// A socket the backend dropped is not reused: the next dial opens a new one.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_closed_warm_socket_is_replaced() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    spawn_echo_mac(SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap());
    let device = uuid::Uuid::new_v4().to_string();
    let pool = WarmPool::new();
    let first = pool.connect(request(&server, &device, &mac_id), None).await.expect("connect");
    first.close();
    drop(first);
    // Another socket for the same device makes the backend close ours (4000 replaced).
    let usurper = SignalingClient::connect(&server.base_url, "user:alice", "team", &device).await.unwrap();
    tokio::time::sleep(Duration::from_millis(200)).await;
    let second = pool.connect(request(&server, &device, &mac_id), None).await.expect("redial");
    assert!(names(&second.timings()).contains(&"signaling_open"), "{:?}", second.timings());
    second.close();
    drop(usurper);
}

/// A dial that starts while `prewarm` is still opening the socket waits for
/// that socket instead of opening a second one (the service keeps one per
/// device and would close the first).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_dial_during_prewarm_joins_its_socket() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    spawn_echo_mac(SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap());
    let device = uuid::Uuid::new_v4().to_string();
    let pool = WarmPool::new();
    let (warmed, handle) = tokio::join!(
        pool.prewarm(server.base_url.clone(), "user:alice".into(), "team".into(), device.clone()),
        pool.connect(request(&server, &device, &mac_id), None),
    );
    let handle = handle.expect("connect");
    let opened = names(&warmed).contains(&"signaling_open") as usize
        + names(&handle.timings()).contains(&"signaling_open") as usize;
    assert_eq!(opened, 1, "prewarm {warmed:?} dial {:?}", handle.timings());
    handle.close();
}

/// One phone, two Macs, one signaling socket (PROTOCOL.md "One link per Mac").
/// When the shared socket dies and the next dial (to the second Mac) opens a
/// new one, the first Mac's live WireGuard session moves onto it at once, so
/// that Mac's `wg-endpoints` and `bye` keep reaching the phone. Before, it
/// stayed subscribed on the dead socket until the next network change.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_new_socket_carries_every_live_link() {
    let _ads = local_ads().await;
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let first_mac = uuid::Uuid::new_v4().to_string();
    let second_mac = uuid::Uuid::new_v4().to_string();
    spawn_echo_mac(
        SignalingClient::connect(&server.base_url, "user:alice", "team", &first_mac).await.unwrap(),
    );
    spawn_echo_mac(
        SignalingClient::connect(&server.base_url, "user:alice", "team", &second_mac).await.unwrap(),
    );
    let device = uuid::Uuid::new_v4().to_string();
    let pool = WarmPool::new();
    let wireguard =
        |mac: &str| ConnectRequest { transport: Transport::WireGuard, ..request(&server, &device, mac) };

    let first = pool.connect(wireguard(&first_mac), None).await.expect("first Mac");
    server.kick(&device);
    tokio::time::sleep(Duration::from_millis(200)).await;
    let second = pool.connect(wireguard(&second_mac), None).await.expect("second Mac");
    assert!(names(&second.timings()).contains(&"signaling_open"), "{:?}", second.timings());
    // The new socket took the first Mac's live session at once, at this dial.
    assert!(names(&second.timings()).contains(&"rehomed"), "{:?}", second.timings());

    // Both links are up at once.
    for handle in [&first, &second] {
        let channel = handle.open_channel("echo".into(), String::new()).await.unwrap();
        channel.send(b"both".to_vec()).await.unwrap();
        assert_eq!(channel.recv().await, ChannelMessage::Data { bytes: b"both".to_vec() });
    }
    // A network change opens another socket and both live links move onto it
    // (`open` rehomes every live session); both still carry traffic after.
    let marks =
        pool.network_changed(server.base_url.clone(), "user:alice".into(), "team".into(), device).await;
    assert!(names(&marks).contains(&"signaling:rehomed"), "{marks:?}");
    for handle in [&first, &second] {
        let channel = handle.open_channel("echo".into(), String::new()).await.unwrap();
        channel.send(b"moved".to_vec()).await.unwrap();
        assert_eq!(channel.recv().await, ChannelMessage::Data { bytes: b"moved".to_vec() });
    }
    first.close();
    second.close();
    pool.reset().await;
}

/// The interleaving that failed `prewarm_and_redial_reuse_the_socket_and_ice_servers`
/// once in CI, made deterministic: between this test's redial and its second
/// prewarm, another test resets the process's warm state (its cleanup) and
/// fills the shared pool past `MAX_WARM_SOCKETS`. A pool of its own keeps
/// its socket and ICE servers through both; before `WarmPool`, every test
/// dialed on the one process pool and the second prewarm reopened.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn another_tests_reset_and_sockets_leave_this_pool_warm() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    spawn_echo_mac(SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap());
    let device = uuid::Uuid::new_v4().to_string();
    let pool = WarmPool::new();
    let warmed =
        pool.prewarm(server.base_url.clone(), "user:alice".into(), "team".into(), device.clone()).await;
    assert!(names(&warmed).contains(&"signaling_open"), "{warmed:?}");
    let link = pool.connect(request(&server, &device, &mac_id), None).await.expect("connect");
    assert!(names(&link.timings()).contains(&"signaling_reused"), "{:?}", link.timings());

    // Another test: its cleanup, then more sockets than the shared pool keeps.
    cmux_mobile_link_ffi::reset_warm_state().await;
    let other = FakeSignaling::start(FakeOptions::default()).await;
    for _ in 0..9 {
        let marks = cmux_mobile_link_ffi::prewarm(
            other.base_url.clone(),
            "user:bob".into(),
            "team".into(),
            uuid::Uuid::new_v4().to_string(),
        )
        .await;
        assert!(names(&marks).contains(&"signaling_open"), "{marks:?}");
    }

    let again = pool.prewarm(server.base_url.clone(), "user:alice".into(), "team".into(), device).await;
    assert!(names(&again).contains(&"signaling_alive"), "{again:?}");
    assert!(names(&again).contains(&"ice_servers_cached"), "{again:?}");
    link.close();
    cmux_mobile_link_ffi::reset_warm_state().await;
}

/// The class detector: a test of this crate that asserts what a warm pool
/// holds (a reused, joined or alive socket, cached ICE servers, a socket it
/// opened) builds its own `WarmPool`, so no parallel test can change the pool
/// it reads. Any test file of the crate, any such mark.
#[test]
fn every_test_reading_warm_state_dials_on_its_own_pool() {
    const MARKS: [&str; 6] = [
        "\"signaling_reused\"",
        "\"signaling_joined\"",
        "\"signaling_alive\"",
        "\"signaling_open\"",
        "\"ice_servers_cached\"",
        "\"signaling:",
    ];
    let files = [
        ("ffi.rs", include_str!("ffi.rs")),
        ("browser.rs", include_str!("browser.rs")),
        ("upload.rs", include_str!("upload.rs")),
        ("prediction_latency.rs", include_str!("prediction_latency.rs")),
    ];
    let mut offenders = Vec::new();
    for (file, source) in files {
        // Each test is the text from one `#[tokio::test` or `#[test]` to the next.
        let starts: Vec<usize> = source
            .match_indices("#[tokio::test")
            .chain(source.match_indices("#[test]"))
            .map(|(at, _)| at)
            .collect::<std::collections::BTreeSet<_>>()
            .into_iter()
            .collect();
        for (n, &start) in starts.iter().enumerate() {
            let end = starts.get(n + 1).copied().unwrap_or(source.len());
            let test = &source[start..end];
            let name = test.split("fn ").nth(1).and_then(|rest| rest.split('(').next()).unwrap_or("?");
            if name == "every_test_reading_warm_state_dials_on_its_own_pool" {
                continue;
            }
            if MARKS.iter().any(|mark| test.contains(mark)) && !test.contains("WarmPool::new()") {
                offenders.push(format!("{file}: {name}"));
            }
        }
    }
    assert!(
        offenders.is_empty(),
        "these tests assert warm-pool marks on the process's shared pool, which parallel tests reset and \
         trim; give each a `WarmPool::new()`: {offenders:?}"
    );
}

/// The class detector for the process's local-link ads: a test of this crate that puts an ad in
/// the table, dials on one, or roams (which forgets them all) holds `local_ads()` for its body, so
/// no parallel test changes the ads it reads. Any test file of the crate, any such call.
#[test]
fn every_test_touching_local_ads_holds_the_lock() {
    const CALLS: [&str; 6] = [
        "local_link_observe(",
        "local_link_pair(",
        "local_link_remove(",
        "local_link_forget_all(",
        "network_changed(",
        "nearby_hub(",
    ];
    let files = [
        ("ffi.rs", include_str!("ffi.rs")),
        ("browser.rs", include_str!("browser.rs")),
        ("upload.rs", include_str!("upload.rs")),
        ("prediction_latency.rs", include_str!("prediction_latency.rs")),
    ];
    let mut offenders = Vec::new();
    for (file, source) in files {
        let starts: Vec<usize> = source
            .match_indices("#[tokio::test")
            .chain(source.match_indices("#[test]"))
            .map(|(at, _)| at)
            .collect::<std::collections::BTreeSet<_>>()
            .into_iter()
            .collect();
        for (n, &start) in starts.iter().enumerate() {
            let end = starts.get(n + 1).copied().unwrap_or(source.len());
            let test = &source[start..end];
            let name = test.split("fn ").nth(1).and_then(|rest| rest.split('(').next()).unwrap_or("?");
            if name == "every_test_touching_local_ads_holds_the_lock" {
                continue;
            }
            // Only the test's own body: helpers defined after it in the file are not its calls.
            let body = test.find("\n}\n").map_or(test, |close| &test[..close]);
            if CALLS.iter().any(|call| body.contains(call)) && !body.contains("local_ads().await") {
                offenders.push(format!("{file}: {name}"));
            }
        }
    }
    assert!(
        offenders.is_empty(),
        "these tests touch the process's local-link ads, which a parallel roam forgets; hold \
         `let _ads = local_ads().await;` for the test's body: {offenders:?}"
    );
}

/// A Mac whose ad outlived its network (the phone left the Wi-Fi; the hub socket opens and then
/// says nothing, or the WireGuard dial over host candidates stalls) costs the service dial
/// nothing: the hub races it instead of going first, and the service link wins.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stale_local_ad_does_not_delay_the_service_dial() {
    let _ads = local_ads().await;
    use cmux_mobile_link_ffi::local_link::{
        LocalEndpoint, LocalTxt, local_link_nearby, local_link_observe, local_link_pair, local_link_remove,
    };

    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    spawn_echo_mac(SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap());
    let device = uuid::Uuid::new_v4().to_string();
    let pool = WarmPool::new();

    // The baseline: the same dial with no ad.
    let started = std::time::Instant::now();
    let plain = pool.connect(request(&server, &device, &mac_id), None).await.expect("connect");
    let baseline = started.elapsed();
    plain.close();
    drop(plain);

    // A hub that accepts and never answers: its connect alone would wait HUB_CONNECT_WAIT.
    let silent = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = silent.local_addr().unwrap().port();
    tokio::spawn(async move {
        let mut held = Vec::new();
        while let Ok((stream, _)) = silent.accept().await {
            held.push(stream);
        }
    });
    let instance = format!("stale-{mac_id}");
    // A paired Mac's ad with its key's tag: the one kind of ad a dial trusts.
    let key = b"stale-mac-key".to_vec();
    local_link_pair(mac_id.clone(), Some(key.clone()));
    assert!(local_link_observe(
        instance.clone(),
        vec![
            LocalTxt { key: "id".into(), value: mac_id.clone() },
            LocalTxt { key: "v".into(), value: "1".into() },
            LocalTxt { key: "k".into(), value: cmux_mobile_link::local::key_tag(&key) },
        ],
        vec![LocalEndpoint { host: "127.0.0.1".into(), port }],
    ));
    assert!(local_link_nearby(mac_id.clone()), "the dial below must race the stale hub");

    let started = std::time::Instant::now();
    let raced = pool.connect(request(&server, &device, &mac_id), None).await.expect("connect");
    let elapsed = started.elapsed();
    let marks = raced.timings();
    assert!(!names(&marks).contains(&"local_link"), "{marks:?}");
    assert!(
        elapsed < baseline + Duration::from_millis(500),
        "the stale ad delayed the service dial: {elapsed:?} against {baseline:?} with no ad"
    );
    println!(
        "MATRIX {{\"cell\": \"nearby_stale_ad\", \"variant\": \"WebRtc\", \"no_ad_ms\": {:.1}, \"stale_ad_ms\": {:.1}}}",
        baseline.as_secs_f64() * 1000.0,
        elapsed.as_secs_f64() * 1000.0
    );
    raced.close();
    local_link_remove(instance);
    local_link_pair(mac_id, None);
    pool.reset().await;
}

/// A network change drops the ads: they were seen on the old network, and a dial now would spend
/// the hub bound on a dead one.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_network_change_forgets_the_local_ads() {
    let _ads = local_ads().await;
    use cmux_mobile_link_ffi::local_link::{
        LocalEndpoint, LocalTxt, local_link_nearby, local_link_observe, local_link_pair, local_link_remove,
    };

    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let device = uuid::Uuid::new_v4().to_string();
    let instance = format!("roam-{mac_id}");
    let key = b"roam-mac-key".to_vec();
    local_link_pair(mac_id.clone(), Some(key.clone()));
    assert!(local_link_observe(
        instance.clone(),
        vec![
            LocalTxt { key: "id".into(), value: mac_id.clone() },
            LocalTxt { key: "v".into(), value: "1".into() },
            LocalTxt { key: "k".into(), value: cmux_mobile_link::local::key_tag(&key) },
        ],
        vec![LocalEndpoint { host: "127.0.0.1".into(), port: 9 }],
    ));
    assert!(local_link_nearby(mac_id.clone()));
    let pool = WarmPool::new();
    pool.network_changed(server.base_url.clone(), "user:alice".into(), "team".into(), device).await;
    let mac_id_unpin = mac_id.clone();
    assert!(!local_link_nearby(mac_id), "the old network's ad outlived the roam");
    local_link_remove(instance);
    local_link_pair(mac_id_unpin, None);
    pool.reset().await;
}

/// A paired Mac's hub on loopback with an echo Mac on it, and the phone's pinned ad for it: what
/// the phone sees on a LAN with no internet. Returns the hub (dropping it stops accepting) and the
/// ad's instance name.
async fn nearby_hub(mac_id: &str, phone: &str, tag: &str) -> (cmux_mobile_link::local_hub::LocalHub, String) {
    use cmux_mobile_link_ffi::local_link::{LocalEndpoint, LocalTxt, local_link_observe, local_link_pair};
    let phone = phone.to_owned();
    let hub = cmux_mobile_link::local_hub::LocalHub::bind(
        "127.0.0.1:0".parse().unwrap(),
        mac_id,
        Arc::new(move |device: &str| device == phone),
    )
    .await
    .unwrap();
    spawn_echo_mac(SignalingClient::connect_local(&hub.loopback_url(), hub.secret(), mac_id).await.unwrap());
    let key = format!("{tag}-mac-key").into_bytes();
    local_link_pair(mac_id.to_owned(), Some(key.clone()));
    let instance = format!("{tag}-{mac_id}");
    assert!(local_link_observe(
        instance.clone(),
        vec![
            LocalTxt { key: "id".into(), value: mac_id.to_owned() },
            LocalTxt { key: "v".into(), value: "1".into() },
            LocalTxt { key: "k".into(), value: cmux_mobile_link::local::key_tag(&key) },
        ],
        vec![LocalEndpoint { host: "127.0.0.1".into(), port: hub.port() }],
    ));
    (hub, instance)
}

fn forget_hub(instance: String, mac_id: String) {
    cmux_mobile_link_ffi::local_link::local_link_remove(instance);
    cmux_mobile_link_ffi::local_link::local_link_pair(mac_id, None);
}

async fn echo_once(handle: &std::sync::Arc<cmux_mobile_link_ffi::LinkHandle>) {
    let channel = handle.open_channel("echo".into(), String::new()).await.expect("open channel");
    channel.send(b"nearby".to_vec()).await.expect("send");
    let echoed = tokio::time::timeout(Duration::from_secs(5), channel.recv()).await.expect("echo in time");
    assert_eq!(echoed, ChannelMessage::Data { bytes: b"nearby".to_vec() });
}

/// No internet: the Worker cannot be reached at all (its port refuses), and the only path to the
/// Mac is its hub on the LAN. The service dial fails first; the dial then waits on the hub
/// instead of returning that error, and the link carries data. Both transports.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn with_no_internet_the_hub_is_the_whole_dial() {
    let _ads = local_ads().await;
    for transport in [Transport::WebRtc, Transport::WireGuard] {
        let mac_id = uuid::Uuid::new_v4().to_string();
        let device = uuid::Uuid::new_v4().to_string();
        let (_hub, instance) = nearby_hub(&mac_id, &device, "noinet").await;
        let refused = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
        let pool = WarmPool::new();
        let request = ConnectRequest {
            base_url: format!("http://{refused}"),
            transport,
            ..request_to(&device, &mac_id)
        };
        let started = std::time::Instant::now();
        let handle = pool.connect(request, None).await.expect("the hub alone carries the dial");
        let elapsed = started.elapsed();
        let marks = handle.timings();
        let names = names(&marks);
        assert!(
            names.contains(&"local_hub_open") && names.contains(&"local_link"),
            "{transport:?}: {marks:?}"
        );
        assert!(!names.contains(&"signaling_open"), "{transport:?}: {marks:?}");
        echo_once(&handle).await;
        println!(
            "MATRIX {{\"cell\": \"nearby_no_internet\", \"variant\": \"{transport:?}\", \"dial_ms\": {:.1}}}",
            elapsed.as_secs_f64() * 1000.0
        );
        handle.close();
        forget_hub(instance, mac_id);
        pool.reset().await;
    }
}

/// The Worker is reachable but hangs (its socket accepts and never upgrades: a captive portal, a
/// dying uplink): the hub wins the race and the dial does not wait on the Worker at all.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_hub_wins_against_a_hung_worker() {
    let _ads = local_ads().await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let device = uuid::Uuid::new_v4().to_string();
    let (_hub, instance) = nearby_hub(&mac_id, &device, "hung").await;
    let hung = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let hung_addr = hung.local_addr().unwrap();
    tokio::spawn(async move {
        let mut held = Vec::new();
        while let Ok((stream, _)) = hung.accept().await {
            held.push(stream);
        }
    });
    let pool = WarmPool::new();
    let request = ConnectRequest { base_url: format!("http://{hung_addr}"), ..request_to(&device, &mac_id) };
    let started = std::time::Instant::now();
    let handle = tokio::time::timeout(Duration::from_secs(10), pool.connect(request, None))
        .await
        .expect("the hung Worker held the dial")
        .expect("connect");
    let elapsed = started.elapsed();
    let marks = handle.timings();
    assert!(names(&marks).contains(&"local_link"), "{marks:?}");
    assert!(elapsed < Duration::from_secs(2), "the hub's win waited on the Worker: {elapsed:?}");
    echo_once(&handle).await;
    println!(
        "MATRIX {{\"cell\": \"nearby_hung_worker\", \"variant\": \"WebRtc\", \"dial_ms\": {:.1}}}",
        elapsed.as_secs_f64() * 1000.0
    );
    handle.close();
    forget_hub(instance, mac_id);
    pool.reset().await;
}

/// The service dial the hub beat is dropped mid-flight: here after its socket opened and while
/// `GET /v1/ice` was still out (a slow Worker). What it left behind is sound: the next dial (the
/// Mac no longer nearby) reuses the socket it opened, fetches ICE afresh, and comes up.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_losing_service_dial_leaves_the_pool_sound() {
    let _ads = local_ads().await;
    let server = FakeSignaling::start(FakeOptions {
        ice_delay: Duration::from_millis(1500),
        ..FakeOptions::default()
    })
    .await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let device = uuid::Uuid::new_v4().to_string();
    spawn_echo_mac(SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap());
    let (hub, instance) = nearby_hub(&mac_id, &device, "loser").await;
    let pool = WarmPool::new();

    let raced = pool.connect(request(&server, &device, &mac_id), None).await.expect("connect");
    let marks = raced.timings();
    assert!(names(&marks).contains(&"local_link"), "the hub was to win this race: {marks:?}");
    assert!(!names(&marks).contains(&"ice_servers_fetched"), "{marks:?}");
    raced.close();
    drop(raced);
    forget_hub(instance, mac_id.clone());
    drop(hub);
    // Let the dropped dial's socket finish opening if it had not.
    tokio::time::sleep(Duration::from_millis(200)).await;

    let next =
        tokio::time::timeout(Duration::from_secs(10), pool.connect(request(&server, &device, &mac_id), None))
            .await
            .expect("the dropped dial left the pool stuck")
            .expect("connect after the race");
    let marks = next.timings();
    let names = names(&marks);
    assert!(!names.contains(&"local_link"), "{marks:?}");
    assert!(names.contains(&"signaling_reused"), "the loser's socket was to be kept: {marks:?}");
    assert!(names.contains(&"ice_servers_fetched"), "{marks:?}");
    echo_once(&next).await;
    next.close();
    pool.reset().await;
}

fn request_to(device_id: &str, mac_id: &str) -> ConnectRequest {
    ConnectRequest {
        base_url: String::new(),
        token: "user:alice".into(),
        team_id: "team".into(),
        device_id: device_id.to_owned(),
        mac_device_id: mac_id.to_owned(),
        transport: Transport::WebRtc,
        include_loopback: true,
        relay_only: false,
        block_udp: false,
        force_relay: false,
        proxy_only: false,
        drop_wireguard: false,
        video_lane: false,
        webrtc_media: false,
        ultra: cmux_mobile_link::UltraSetting::Off,
    }
}
