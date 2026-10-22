//! The exported API end to end against a fake backend and an echo Mac.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_mobile_link::dial::{self, SessionEvents};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_mobile_link::{ChannelEvent, DialOptions, LinkConfig, SignalingClient};
use cmux_mobile_link_ffi::{
    ChannelMessage, ConnectRequest, LinkEvent, LinkObserver, LinkPath, Transport, connect_inner,
};

#[derive(Default)]
struct Recorder(Mutex<Vec<LinkEvent>>);

impl LinkObserver for Recorder {
    fn on_event(&self, event: LinkEvent) {
        self.0.lock().unwrap().push(event);
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
            video_lane: false,
            webrtc_media: false,
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
    let turn = cmux_mobile_link::testing::TestTurn::start().await;
    let server =
        FakeSignaling::start(FakeOptions { ice_servers: vec![turn.udp_only()], ..FakeOptions::default() })
            .await;
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
            transport: Transport::WireGuard,
            include_loopback: true,
            relay_only: true,
            block_udp: false,
            video_lane: false,
            webrtc_media: false,
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
    let events = recorder.0.lock().unwrap().clone();
    assert!(!events.contains(&LinkEvent::PathChanged { path: LinkPath::Direct }), "{events:?}");
    handle.close();
}

/// Relay only over WireGuard without a TURN server has no path at all (the
/// backend relay is retired): the dial fails at once.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn wireguard_relay_only_without_turn_fails_fast() {
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
            video_lane: false,
            webrtc_media: false,
        },
        None,
    )
    .await;
    match result {
        Err(cmux_mobile_link_ffi::CmuxMobileError::Transport { message }) => {
            assert!(message.contains("TURN"), "{message}");
        }
        Err(other) => panic!("unexpected error {other:?}"),
        Ok(_) => panic!("UDP-blocked WireGuard connected without TURN"),
    }
    assert!(started.elapsed() < Duration::from_secs(10));
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
            video_lane: false,
            webrtc_media: false,
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
        video_lane: false,
        webrtc_media: false,
    }
}

fn names(marks: &[cmux_mobile_link_ffi::TimingMark]) -> Vec<&str> {
    marks.iter().map(|m| m.name.as_str()).collect()
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
    let warmed = cmux_mobile_link_ffi::prewarm(
        server.base_url.clone(),
        "user:alice".into(),
        "team".into(),
        device.clone(),
    )
    .await;
    assert!(names(&warmed).contains(&"signaling_open"), "{warmed:?}");
    assert!(names(&warmed).contains(&"ice_servers_fetched"), "{warmed:?}");

    let first = connect_inner(request(&server, &device, &mac_id), None).await.expect("connect");
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
    let second = connect_inner(request(&server, &device, &mac_id), None).await.expect("redial");
    assert!(names(&second.timings()).contains(&"signaling_reused"), "{:?}", second.timings());
    let channel = second.open_channel("echo".into(), String::new()).await.unwrap();
    channel.send(b"warm".to_vec()).await.unwrap();
    assert_eq!(channel.recv().await, ChannelMessage::Data { bytes: b"warm".to_vec() });

    // A second prewarm finds the socket alive.
    let again =
        cmux_mobile_link_ffi::prewarm(server.base_url.clone(), "user:alice".into(), "team".into(), device)
            .await;
    assert!(names(&again).contains(&"signaling_alive"), "{again:?}");
    assert!(names(&again).contains(&"ice_servers_cached"), "{again:?}");
    second.close();
    cmux_mobile_link_ffi::reset_warm_state().await;
}

/// A socket the backend dropped is not reused: the next dial opens a new one.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_closed_warm_socket_is_replaced() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    spawn_echo_mac(SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap());
    let device = uuid::Uuid::new_v4().to_string();
    let first = connect_inner(request(&server, &device, &mac_id), None).await.expect("connect");
    first.close();
    drop(first);
    // Another socket for the same device makes the backend close ours (4000 replaced).
    let usurper = SignalingClient::connect(&server.base_url, "user:alice", "team", &device).await.unwrap();
    tokio::time::sleep(Duration::from_millis(200)).await;
    let second = connect_inner(request(&server, &device, &mac_id), None).await.expect("redial");
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
    let (warmed, handle) = tokio::join!(
        cmux_mobile_link_ffi::prewarm(
            server.base_url.clone(),
            "user:alice".into(),
            "team".into(),
            device.clone()
        ),
        connect_inner(request(&server, &device, &mac_id), None),
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
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let first_mac = uuid::Uuid::new_v4().to_string();
    let second_mac = uuid::Uuid::new_v4().to_string();
    spawn_echo_mac(SignalingClient::connect(&server.base_url, "user:alice", "team", &first_mac).await.unwrap());
    spawn_echo_mac(SignalingClient::connect(&server.base_url, "user:alice", "team", &second_mac).await.unwrap());
    let device = uuid::Uuid::new_v4().to_string();
    let wireguard = |mac: &str| ConnectRequest { transport: Transport::WireGuard, ..request(&server, &device, mac) };

    let first = connect_inner(wireguard(&first_mac), None).await.expect("first Mac");
    server.kick(&device);
    tokio::time::sleep(Duration::from_millis(200)).await;
    let second = connect_inner(wireguard(&second_mac), None).await.expect("second Mac");
    assert!(names(&second.timings()).contains(&"signaling_open"), "{:?}", second.timings());

    // Both links are up at once.
    for handle in [&first, &second] {
        let channel = handle.open_channel("echo".into(), String::new()).await.unwrap();
        channel.send(b"both".to_vec()).await.unwrap();
        assert_eq!(channel.recv().await, ChannelMessage::Data { bytes: b"both".to_vec() });
    }
    // Nothing is left on the dead socket: a network change has no session to move.
    let marks =
        cmux_mobile_link_ffi::network_changed(server.base_url.clone(), "user:alice".into(), "team".into(), device)
            .await;
    assert!(!names(&marks).contains(&"signaling:rehomed"), "{marks:?}");
    first.close();
    second.close();
    cmux_mobile_link_ffi::reset_warm_state().await;
}
