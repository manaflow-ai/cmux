//! cmux's WebSocket relay (PROTOCOL.md "WebSocket relay"): the last way a
//! WireGuard link reaches the Mac, through the fake backend's relay (the
//! Worker's `LinkRelay`), when the network lets neither UDP nor any TURN
//! host through. And when the relay is blocked too, the dial says why
//! instead of timing out (PROTOCOL.md "When no path works").

use std::time::Duration;

use bytes::Bytes;
use cmux_mobile_link::dial::relay::RelayEndpoint;
use cmux_mobile_link::dial::{self, SessionEvents};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling, TestTurn};
use cmux_mobile_link::{
    ChannelEvent, DialError, DialOptions, LinkConfig, LinkPath, SignalingClient, TransportKind,
};

fn options() -> DialOptions {
    // RUST_LOG=cmux_mobile_link=debug shows the relay's joins and leaves.
    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_test_writer()
        .try_init();
    DialOptions { include_loopback: true, timeout: Duration::from_secs(20), ..DialOptions::default() }
}

fn relay(server: &FakeSignaling, device: &str) -> Option<RelayEndpoint> {
    Some(RelayEndpoint::with_token(server.base_url.clone(), None, device, "user:alice"))
}

/// A Mac that answers with `mac_options` (its relay endpoint filled in) and
/// echoes every channel; its link's path goes to the returned watch.
fn spawn_mac(
    server: &FakeSignaling,
    mac: SignalingClient,
    mac_id: &str,
    mac_options: DialOptions,
    with_relay: bool,
) -> std::sync::Arc<std::sync::Mutex<Vec<tokio::sync::watch::Receiver<LinkPath>>>> {
    let paths = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    mac.accept_early_relay_cue(mac_options.relay_first);
    let slot = std::sync::Arc::clone(&paths);
    let endpoint = if with_relay { relay(server, mac_id) } else { None };
    tokio::spawn(async move {
        while let Some(session) = mac.next_session().await {
            let events = SessionEvents {
                backend: mac.events(),
                session_id: session.first.session_id.clone(),
                session: session.events,
            };
            let (mac, slot) = (mac.clone(), std::sync::Arc::clone(&slot));
            let options = DialOptions { relay: endpoint.clone(), ..mac_options.clone() };
            tokio::spawn(async move {
                let Ok(connected) =
                    dial::answer(&mac, session.first, events, &options, LinkConfig::default()).await
                else {
                    return;
                };
                slot.lock().unwrap().push(connected.path.clone());
                while let Some(mut incoming) = connected.link.accept().await {
                    tokio::spawn(async move {
                        while let Some(ChannelEvent::Data(bytes)) = incoming.channel.recv().await {
                            if incoming.channel.send(bytes).await.is_err() {
                                return;
                            }
                        }
                    });
                }
            });
        }
    });
    paths
}

/// Echo `rounds` of 50 KB on `link` (each within 20 s).
async fn echo(link: &cmux_mobile_link::Link, rounds: u8) {
    let mut channel = link.open("echo", serde_json::json!({})).await.unwrap();
    for round in 0..rounds {
        channel.send(Bytes::from(vec![round; 50_000])).await.unwrap();
        let mut got = 0;
        while got < 50_000 {
            match tokio::time::timeout(Duration::from_secs(20), channel.recv()).await.expect("echo in time") {
                Some(ChannelEvent::Data(bytes)) => got += bytes.len(),
                other => panic!("unexpected {other:?}"),
            }
        }
    }
}

struct Rig {
    server: FakeSignaling,
    phone: SignalingClient,
    phone_id: String,
    mac_id: String,
    mac_paths: std::sync::Arc<std::sync::Mutex<Vec<tokio::sync::watch::Receiver<LinkPath>>>>,
}

async fn rig(fake: FakeOptions, mac_options: DialOptions, mac_relay: bool) -> Rig {
    let server = FakeSignaling::start(fake).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let mac_paths = spawn_mac(&server, mac, &mac_id, mac_options, mac_relay);
    let phone_id = uuid::Uuid::new_v4().to_string();
    let phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    Rig { server, phone, phone_id, mac_id, mac_paths }
}

impl Rig {
    fn mac_path(&self) -> Option<LinkPath> {
        self.mac_paths.lock().unwrap().last().map(|path| *path.borrow())
    }
}

/// The phone's network passes neither UDP nor the TURN host (only the
/// cmux service, on HTTPS): the link rides cmux's relay, both directions,
/// and both sides label it so.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn with_udp_and_the_turn_host_blocked_the_link_rides_the_relay() {
    // The TURN host is unreachable from the phone's network: nothing
    // answers on the ports the service names.
    let unreachable_turn = cmux_mobile_link::api::IceServer {
        urls: vec!["turn:127.0.0.1:9?transport=udp".into(), "turns:127.0.0.1:9?transport=tcp".into()],
        username: Some("u".into()),
        credential: Some("c".into()),
    };
    let rig = rig(FakeOptions::default(), options(), true).await;
    let phone = DialOptions {
        ice_servers: vec![unreachable_turn],
        block_udp: true,
        relay: relay(&rig.server, &rig.phone_id),
        ..options()
    };
    let started = std::time::Instant::now();
    let connected =
        dial::connect(&rig.phone, &rig.mac_id, TransportKind::WireGuard, &phone, LinkConfig::default())
            .await
            .expect("dial through the relay");
    eprintln!("relay dial took {:?}", started.elapsed());
    echo(&connected.link, 6).await;
    assert_eq!(*connected.path.borrow(), LinkPath::HttpsRelay);
    assert_eq!(rig.mac_path(), Some(LinkPath::HttpsRelay));
    assert_eq!(rig.server.relay_joins(), 2, "the phone and the Mac each joined once");
    assert!(rig.server.relay_frames() > 10);
    assert!(connected.link.ping().await.unwrap() < Duration::from_secs(5));
    connected.link.close("done");
}

/// Debug "Relay via cmux (HTTPS) only": no plain UDP, no TURN allocation
/// (with a TURN server that works), the link on the relay from the start.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn forcing_the_relay_rides_it_even_with_turn_and_udp_working() {
    let turn = TestTurn::start().await;
    let rig = rig(FakeOptions::default(), options(), true).await;
    let phone = DialOptions {
        ice_servers: vec![turn.ice.clone()],
        turn_tls_roots: Some(std::sync::Arc::clone(&turn.roots)),
        force_relay: true,
        relay: relay(&rig.server, &rig.phone_id),
        ..options()
    };
    let connected =
        dial::connect(&rig.phone, &rig.mac_id, TransportKind::WireGuard, &phone, LinkConfig::default())
            .await
            .expect("dial through the relay");
    echo(&connected.link, 4).await;
    assert_eq!(*connected.path.borrow(), LinkPath::HttpsRelay);
    assert_eq!(turn.stream_connections(), 0, "no TURN allocation when the relay is forced");
    // Still on it after a while: a forced relay is never left.
    tokio::time::sleep(Duration::from_secs(2)).await;
    echo(&connected.link, 1).await;
    assert_eq!(*connected.path.borrow(), LinkPath::HttpsRelay);
    connected.link.close("done");
}

/// Forcing the relay without one fails at once, as relay only without TURN does.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn forcing_the_relay_without_one_fails_fast() {
    let rig = rig(FakeOptions::default(), options(), true).await;
    let started = std::time::Instant::now();
    let error = dial::connect(
        &rig.phone,
        &rig.mac_id,
        TransportKind::WireGuard,
        &DialOptions { force_relay: true, ..options() },
        LinkConfig::default(),
    )
    .await
    .err()
    .expect("no relay");
    assert!(matches!(error, DialError::Transport(ref message) if message.contains("relay")), "{error}");
    assert!(started.elapsed() < Duration::from_secs(1));
}

/// As production: no tickets. A join is admitted by its Bearer token only for a
/// device the session's first admitted signal bound: before any signal, `403`; after
/// the phone's signal (an early `wg-relay`), both its devices
/// join with no ticket, and a third device of the same user does not.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_join_is_admitted_by_the_session_its_first_signal_bound() {
    use cmux_mobile_link::dial::relay::{RelayCarrier, RelayFailure};
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let phone_id = uuid::Uuid::new_v4().to_string();
    let mac_id = uuid::Uuid::new_v4().to_string();
    let phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    let _mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let session = uuid::Uuid::new_v4().to_string();
    let endpoint = |device: &str| {
        RelayEndpoint::with_token(server.base_url.clone(), None, device.to_owned(), "user:alice")
    };
    let refused =
        RelayCarrier::join(&endpoint(&phone_id), &session, &mac_id, None).await.expect_err("no session");
    assert!(matches!(refused, RelayFailure::Refused { status: 403, .. }), "{refused:?}");
    phone.send_signal(&mac_id, &session, cmux_mobile_link::signaling::SignalPayload::WgRelay {}).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    let _phone =
        RelayCarrier::join(&endpoint(&phone_id), &session, &mac_id, None).await.expect("the phone joins");
    let _mac =
        RelayCarrier::join(&endpoint(&mac_id), &session, &phone_id, None).await.expect("the Mac joins");
    let stranger = uuid::Uuid::new_v4().to_string();
    let refused =
        RelayCarrier::join(&endpoint(&stranger), &session, &mac_id, None).await.expect_err("not a party");
    assert!(matches!(refused, RelayFailure::Refused { status: 403, .. }), "{refused:?}");
    assert_eq!(server.relay_joins(), 2);
}

/// A service that stamps relay tickets (`relay_tickets`): a join presents this
/// device's own, as the service stamped it on the session's signals to this device;
/// without it the relay refuses the join.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn with_tickets_a_join_without_its_ticket_is_refused() {
    let server = FakeSignaling::start(FakeOptions { relay_tickets: true, ..FakeOptions::default() }).await;
    let endpoint = RelayEndpoint::with_token(
        server.base_url.clone(),
        None,
        uuid::Uuid::new_v4().to_string(),
        "user:alice",
    );
    let session = uuid::Uuid::new_v4().to_string();
    let peer = uuid::Uuid::new_v4().to_string();
    for ticket in [None, Some("not-the-ticket")] {
        let failure = cmux_mobile_link::dial::relay::RelayCarrier::join(&endpoint, &session, &peer, ticket)
            .await
            .expect_err("refused");
        assert!(
            matches!(failure, cmux_mobile_link::dial::relay::RelayFailure::Refused { status: 403, .. }),
            "{failure:?}"
        );
    }
    assert_eq!(server.relay_joins(), 0);
}

/// Under the older rule (a peer that does not dial the relay first), a
/// working network never touches the relay: direct UDP wins, nobody joins.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_network_that_passes_udp_never_joins_the_relay() {
    let older = DialOptions { relay_first: false, ..options() };
    let rig = rig(FakeOptions::default(), older.clone(), true).await;
    let phone = DialOptions { relay: relay(&rig.server, &rig.phone_id), ..older };
    let connected =
        dial::connect(&rig.phone, &rig.mac_id, TransportKind::WireGuard, &phone, LinkConfig::default())
            .await
            .expect("dial");
    echo(&connected.link, 2).await;
    // Past the relay's join delay: still nobody on it.
    tokio::time::sleep(Duration::from_secs(4)).await;
    echo(&connected.link, 1).await;
    assert_eq!(*connected.path.borrow(), LinkPath::Direct);
    assert_eq!(rig.server.relay_joins(), 0);
    connected.link.close("done");
}

/// Relay first on a working network: both sides join as the dial starts (the
/// Mac before it heard anything, so its join is kept), yet the link is direct,
/// and the relay is let go by the leave rule once direct UDP has been
/// confirmed for the leave time (2 s here, 60 s in a build).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn relay_first_on_a_network_that_passes_udp_rides_direct_and_lets_the_relay_go() {
    let leave = Some(Duration::from_secs(2));
    let mac_options = DialOptions { relay_leave_after: leave, ..options() };
    let rig = rig(FakeOptions::default(), mac_options, true).await;
    let phone =
        DialOptions { relay: relay(&rig.server, &rig.phone_id), relay_leave_after: leave, ..options() };
    let connected =
        dial::connect(&rig.phone, &rig.mac_id, TransportKind::WireGuard, &phone, LinkConfig::default())
            .await
            .expect("dial");
    echo(&connected.link, 2).await;
    assert_eq!(*connected.path.borrow(), LinkPath::Direct);
    let session = connected.session_id.clone();
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    loop {
        echo(&connected.link, 1).await;
        assert_eq!(*connected.path.borrow(), LinkPath::Direct);
        let phone_held = cmux_mobile_link::dial::wireguard::relay_held(&session, true);
        let mac_held = cmux_mobile_link::dial::wireguard::relay_held(&session, false);
        if phone_held != Some(true) && mac_held != Some(true) {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "phone holds the relay: {phone_held:?}, Mac: {mac_held:?}"
        );
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    assert!(rig.server.relay_joins() <= 2, "one join per side: {}", rig.server.relay_joins());
    connected.link.close("done");
}

/// The relay socket dies under a live link (a proxy resets it): the session
/// joins again and the link goes on.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_relay_socket_that_dies_is_joined_again() {
    let rig = rig(FakeOptions::default(), options(), true).await;
    let phone = DialOptions { force_relay: true, relay: relay(&rig.server, &rig.phone_id), ..options() };
    let connected =
        dial::connect(&rig.phone, &rig.mac_id, TransportKind::WireGuard, &phone, LinkConfig::default())
            .await
            .expect("dial");
    echo(&connected.link, 2).await;
    let joins = rig.server.relay_joins();
    rig.server.kick_relay(&rig.phone_id);
    echo(&connected.link, 3).await;
    assert!(rig.server.relay_joins() > joins, "the phone joined again");
    assert_eq!(*connected.path.borrow(), LinkPath::HttpsRelay);
    connected.link.close("done");
}

/// Every way is blocked, the relay too (turned off): the dial fails with
/// what each path did, well before its timeout.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn with_every_path_blocked_the_dial_says_why() {
    let rig = rig(FakeOptions { relay_off: true, ..FakeOptions::default() }, options(), true).await;
    let unreachable_turn = cmux_mobile_link::api::IceServer {
        urls: vec!["turns:127.0.0.1:9?transport=tcp".into()],
        username: Some("u".into()),
        credential: Some("c".into()),
    };
    let phone = DialOptions {
        ice_servers: vec![unreachable_turn],
        block_udp: true,
        relay: relay(&rig.server, &rig.phone_id),
        ..options()
    };
    let started = std::time::Instant::now();
    let error =
        dial::connect(&rig.phone, &rig.mac_id, TransportKind::WireGuard, &phone, LinkConfig::default())
            .await
            .err()
            .expect("blocked");
    let DialError::Blocked(failures) = error else { panic!("not blocked: {error}") };
    eprintln!("blocked after {:?}: {failures}", started.elapsed());
    assert!(started.elapsed() < Duration::from_secs(12), "waited {:?}", started.elapsed());
    assert_eq!(failures.udp.as_deref(), Some("off"));
    assert_eq!(failures.turn.as_deref(), Some("no_allocation"));
    assert_eq!(failures.turn_host.as_deref(), Some("127.0.0.1"));
    assert_eq!(failures.relay.as_deref(), Some("off"));
    assert_eq!(failures.relay_status, Some(503));
}

/// The relay's host is unreachable (a firewall that drops the service's
/// own host): the diagnosis names it, and the dial still ends early.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_unreachable_relay_host_is_named() {
    let rig = rig(FakeOptions::default(), options(), true).await;
    let phone = DialOptions {
        block_udp: true,
        relay: Some(RelayEndpoint::with_token(
            "http://127.0.0.1:9",
            None,
            rig.phone_id.clone(),
            "user:alice",
        )),
        ..options()
    };
    let error =
        dial::connect(&rig.phone, &rig.mac_id, TransportKind::WireGuard, &phone, LinkConfig::default())
            .await
            .err()
            .expect("blocked");
    let DialError::Blocked(failures) = error else { panic!("not blocked: {error}") };
    assert_eq!(failures.relay.as_deref(), Some("unreachable"), "{failures}");
    assert_eq!(failures.relay_host.as_deref(), Some("127.0.0.1:9"));
    assert_eq!(failures.turn.as_deref(), Some("none_offered"));
}

/// A Mac whose build has no relay: a phone that needs it fails with
/// `peer_cannot` (update the Mac), not with a timeout.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_mac_without_the_relay_is_named_as_the_reason() {
    let rig = rig(FakeOptions::default(), options(), false).await;
    let phone = DialOptions { block_udp: true, relay: relay(&rig.server, &rig.phone_id), ..options() };
    let started = std::time::Instant::now();
    let error =
        dial::connect(&rig.phone, &rig.mac_id, TransportKind::WireGuard, &phone, LinkConfig::default())
            .await
            .err()
            .expect("blocked");
    let DialError::Blocked(failures) = error else { panic!("not blocked: {error}") };
    assert_eq!(failures.relay.as_deref(), Some("peer_cannot"));
    assert!(started.elapsed() < Duration::from_secs(5));
    // The phone's early join (relay first, or on its early ticket with no other path,
    // PROTOCOL.md "Early relay ticket"), before the Mac's `wg-resp` says it has no relay,
    // is the one join this dial may make; it is aborted, and nothing joins after.
    assert!(rig.server.relay_joins() <= 1, "joins: {}", rig.server.relay_joins());
}

/// Plain UDP is lost on both sides (this test's switch); `drop_udp_to`
/// takes a plain `fn`, so the switch is a static.
static UDP_LOST: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(true);
fn udp_lost(_: &std::net::SocketAddr) -> bool {
    UDP_LOST.load(std::sync::atomic::Ordering::Relaxed)
}

/// How roaming moves off the relay: a link that had nothing but the relay
/// (every plain UDP datagram lost, no TURN) rides it; once UDP works again
/// it upgrades to the direct path, and both sides let the relay socket go.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_link_on_the_relay_moves_to_direct_udp_and_leaves_it() {
    let leave = Some(Duration::from_secs(2));
    let mac_options = DialOptions { drop_udp_to: Some(udp_lost), relay_leave_after: leave, ..options() };
    let rig = rig(FakeOptions::default(), mac_options, true).await;
    let phone = DialOptions {
        drop_udp_to: Some(udp_lost),
        relay: relay(&rig.server, &rig.phone_id),
        relay_leave_after: leave,
        ..options()
    };
    let connected =
        dial::connect(&rig.phone, &rig.mac_id, TransportKind::WireGuard, &phone, LinkConfig::default())
            .await
            .expect("dial through the relay once nothing else answers");
    echo(&connected.link, 2).await;
    assert_eq!(*connected.path.borrow(), LinkPath::HttpsRelay);
    let session = connected.session_id.clone();
    assert_eq!(cmux_mobile_link::dial::wireguard::relay_held(&session, true), Some(true));
    // The network lets UDP through again.
    UDP_LOST.store(false, std::sync::atomic::Ordering::Relaxed);
    let deadline = std::time::Instant::now() + Duration::from_secs(25);
    loop {
        echo(&connected.link, 1).await;
        let direct = *connected.path.borrow() == LinkPath::Direct;
        let left = cmux_mobile_link::dial::wireguard::relay_held(&session, true) == Some(false)
            && cmux_mobile_link::dial::wireguard::relay_held(&session, false) == Some(false);
        if direct && left {
            break;
        }
        assert!(std::time::Instant::now() < deadline, "still on the relay: {:?}", *connected.path.borrow());
        tokio::time::sleep(Duration::from_millis(300)).await;
    }
    assert_eq!(rig.mac_path(), Some(LinkPath::Direct));
    connected.link.close("done");
}

/// Plain UDP for the two tests below, each its own switch (tests run side by
/// side in one process).
static UDP_LOST_REJOIN: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(true);
fn udp_lost_rejoin(_: &std::net::SocketAddr) -> bool {
    UDP_LOST_REJOIN.load(std::sync::atomic::Ordering::Relaxed)
}
static UDP_LOST_RESET: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(true);
fn udp_lost_reset(_: &std::net::SocketAddr) -> bool {
    UDP_LOST_RESET.load(std::sync::atomic::Ordering::Relaxed)
}

/// The relay socket dies (a proxy resets it) just as the network starts
/// passing UDP again: the session goes direct and does not keep opening and
/// dropping relay joins. Each join here takes 1.5 s, so the peer answers on
/// UDP while one runs (review of #53163: 10 joins in 12 s on a direct path).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_good_network_does_not_rejoin_the_relay_after_its_socket_dies() {
    let fake = FakeOptions { relay_join_delay: Duration::from_millis(1500), ..FakeOptions::default() };
    let leave = Some(Duration::from_secs(2));
    let mac_options =
        DialOptions { drop_udp_to: Some(udp_lost_rejoin), relay_leave_after: leave, ..options() };
    let rig = rig(fake, mac_options, true).await;
    let phone = DialOptions {
        drop_udp_to: Some(udp_lost_rejoin),
        relay: relay(&rig.server, &rig.phone_id),
        relay_leave_after: leave,
        timeout: Duration::from_secs(30),
        ..options()
    };
    let connected =
        dial::connect(&rig.phone, &rig.mac_id, TransportKind::WireGuard, &phone, LinkConfig::default())
            .await
            .expect("dial through the relay once nothing else answers");
    echo(&connected.link, 1).await;
    assert_eq!(*connected.path.borrow(), LinkPath::HttpsRelay);
    let session = connected.session_id.clone();
    // The phone's relay socket dies while it rides it, and UDP comes back.
    rig.server.kick_relay(&rig.phone_id);
    UDP_LOST_REJOIN.store(false, std::sync::atomic::Ordering::Relaxed);
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    while *connected.path.borrow() != LinkPath::Direct {
        assert!(std::time::Instant::now() < deadline, "never went direct: {:?}", *connected.path.borrow());
        echo(&connected.link, 1).await;
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    // On the direct path, keep the link busy for 8 s: at most the one join that
    // raced the recovery, never a loop of them.
    let joins = rig.server.relay_joins();
    let until = std::time::Instant::now() + Duration::from_secs(8);
    while std::time::Instant::now() < until {
        echo(&connected.link, 1).await;
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    let rejoins = rig.server.relay_joins() - joins;
    assert!(rejoins <= 1, "{rejoins} relay joins in 8 s on a direct path");
    assert_eq!(*connected.path.borrow(), LinkPath::Direct);
    assert_eq!(cmux_mobile_link::dial::wireguard::relay_held(&session, true), Some(false));
    connected.link.close("done");
}

/// A relay socket that resets while the session needs it is joined again,
/// and that rejoin does not pin the session to the relay: once UDP works,
/// the phone leaves the relay on schedule (review of #53163: still held 10 s
/// past a 2 s leave time).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_relay_reset_does_not_keep_the_session_on_the_relay() {
    let leave = Some(Duration::from_secs(2));
    let mac_options =
        DialOptions { drop_udp_to: Some(udp_lost_reset), relay_leave_after: leave, ..options() };
    let rig = rig(FakeOptions::default(), mac_options, true).await;
    let phone = DialOptions {
        drop_udp_to: Some(udp_lost_reset),
        relay: relay(&rig.server, &rig.phone_id),
        relay_leave_after: leave,
        ..options()
    };
    let connected =
        dial::connect(&rig.phone, &rig.mac_id, TransportKind::WireGuard, &phone, LinkConfig::default())
            .await
            .expect("dial through the relay once nothing else answers");
    echo(&connected.link, 1).await;
    let session = connected.session_id.clone();
    // A reset while nothing else works: the phone joins again at once.
    let joins = rig.server.relay_joins();
    rig.server.kick_relay(&rig.phone_id);
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while rig.server.relay_joins() == joins {
        assert!(std::time::Instant::now() < deadline, "the phone never joined again");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    echo(&connected.link, 1).await;
    assert_eq!(*connected.path.borrow(), LinkPath::HttpsRelay);
    // UDP works again: direct, and the relay let go within the leave time.
    UDP_LOST_RESET.store(false, std::sync::atomic::Ordering::Relaxed);
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    loop {
        echo(&connected.link, 1).await;
        let direct = *connected.path.borrow() == LinkPath::Direct;
        if direct && cmux_mobile_link::dial::wireguard::relay_held(&session, true) == Some(false) {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "path {:?}, phone holds the relay: {:?}",
            *connected.path.borrow(),
            cmux_mobile_link::dial::wireguard::relay_held(&session, true)
        );
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    connected.link.close("done");
}

/// A network whose only way out is its HTTP proxy (P6, PROTOCOL.md
/// "Corporate networks"): the relay join leaves through `CONNECT`, as
/// signaling and TURN over TLS do, with or without Basic sign-in, and the
/// link rides the relay. "Proxy only" never goes around the proxy.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_relay_goes_through_the_system_http_proxy() {
    use cmux_mobile_link::egress::Egress;
    use cmux_mobile_link::testing::{ProxyAuth, TestProxy};
    for auth in [ProxyAuth::None, ProxyAuth::Basic("ann@corp".into(), "s3cret:pw".into())] {
        let proxy = TestProxy::start(auth.clone()).await;
        let rig = rig(FakeOptions::default(), options(), true).await;
        let phone = DialOptions {
            force_relay: true,
            relay: relay(&rig.server, &rig.phone_id),
            egress: Egress { proxy: proxy.config(), require_proxy: true, ..Egress::default() },
            ..options()
        };
        let started = std::time::Instant::now();
        let connected =
            dial::connect(&rig.phone, &rig.mac_id, TransportKind::WireGuard, &phone, LinkConfig::default())
                .await
                .unwrap_or_else(|error| panic!("{auth:?}: {error}"));
        eprintln!("{auth:?}: relay through the proxy, link up in {:?}", started.elapsed());
        echo(&connected.link, 2).await;
        assert_eq!(*connected.path.borrow(), LinkPath::HttpsRelay, "{auth:?}");
        let service = rig.server.base_url.trim_start_matches("http://").trim_end_matches('/').to_owned();
        assert!(
            proxy.tunnels().contains(&service),
            "{auth:?}: the join skipped the proxy: {:?}",
            proxy.tunnels()
        );
        assert_eq!(proxy.refused(), 0, "{auth:?}");
        connected.link.close("done");
    }
}

/// A proxy the relay join cannot sign in to (NTLM or Kerberos only): the
/// join fails at once as the proxy's refusal (407), not as a timeout.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_proxy_the_relay_cannot_sign_in_to_is_a_refusal() {
    use cmux_mobile_link::dial::relay::{RelayCarrier, RelayFailure};
    use cmux_mobile_link::egress::Egress;
    use cmux_mobile_link::testing::{ProxyAuth, TestProxy};
    let proxy = TestProxy::start(ProxyAuth::NtlmOrNegotiate).await;
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mut endpoint = RelayEndpoint::with_token(
        server.base_url.clone(),
        None,
        uuid::Uuid::new_v4().to_string(),
        "user:alice",
    );
    endpoint.egress = Egress { proxy: proxy.config(), require_proxy: true, ..Egress::default() };
    let started = std::time::Instant::now();
    let failure = RelayCarrier::join(
        &endpoint,
        &uuid::Uuid::new_v4().to_string(),
        &uuid::Uuid::new_v4().to_string(),
        None,
    )
    .await
    .expect_err("refused by the proxy");
    assert!(matches!(failure, RelayFailure::Refused { status: 407, .. }), "{failure:?}");
    assert!(started.elapsed() < Duration::from_secs(2));
    assert_eq!(server.relay_joins(), 0);
}

/// A network that needs a proxy with none set for the relay: the join fails
/// at once as the proxy's refusal, not a service `403`, and is tried again
/// (the proxy settings can change with the network).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_relay_join_the_proxy_policy_refuses_is_tried_again() {
    use cmux_mobile_link::dial::relay::{RelayCarrier, RelayFailure};
    use cmux_mobile_link::egress::Egress;
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mut endpoint = RelayEndpoint::with_token(
        server.base_url.clone(),
        None,
        uuid::Uuid::new_v4().to_string(),
        "user:alice",
    );
    endpoint.egress = Egress { require_proxy: true, ..Egress::default() };
    let failure = RelayCarrier::join(
        &endpoint,
        &uuid::Uuid::new_v4().to_string(),
        &uuid::Uuid::new_v4().to_string(),
        None,
    )
    .await
    .expect_err("no proxy to carry it");
    assert!(matches!(failure, RelayFailure::ProxyRefused { .. }), "{failure:?}");
    assert!(!failure.is_final());
    assert_eq!(server.relay_joins(), 0);
}

/// The Mac's network drops UDP, so its trickled answer takes its own TURN
/// allocation after the tunnel starts, and that allocation is slow (its TLS
/// connection takes 3.2 s, past the relay's 3 s). The relay waits for it: the
/// Mac joins neither on its own clock nor on the phone's ask while its TURN
/// allocation is still under way, and once that allocation works the link
/// rides it, with the Mac never on the relay. (A UDP allocation capped at
/// 3 s by #52961, after 250 ms of STUN silence, overruns the relay's 3 s the
/// same way.)
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_slow_turn_allocation_on_the_mac_gets_its_window_before_the_relay() {
    let turn = TestTurn::start().await;
    turn.set_udp_blocked(true);
    turn.delay_streams(Duration::from_millis(3200));
    // Nothing answers STUN on the discard port: the Mac's UDP looks blocked.
    let silent_stun =
        cmux_mobile_link::api::IceServer { urls: vec!["stun:127.0.0.1:9".into()], ..turn.udp_only() };
    let mac_options = DialOptions {
        ice_servers: vec![turn.ice.clone(), silent_stun],
        turn_tls_roots: Some(std::sync::Arc::clone(&turn.roots)),
        drop_udp_to: Some(|addr| !cmux_mobile_link::testing::is_test_relay(addr)),
        // The older rule: relay first would carry the link before this slow
        // allocation finishes, which is the point of it.
        relay_first: false,
        ..options()
    };
    let rig = rig(FakeOptions::default(), mac_options, true).await;
    let leave = Some(Duration::from_secs(2));
    let phone = DialOptions {
        relay: relay(&rig.server, &rig.phone_id),
        relay_leave_after: leave,
        relay_first: false,
        ..options()
    };
    let connected =
        dial::connect(&rig.phone, &rig.mac_id, TransportKind::WireGuard, &phone, LinkConfig::default())
            .await
            .expect("dial through the Mac's TURN allocation");
    echo(&connected.link, 2).await;
    assert_eq!(turn.stream_connections(), 1, "the Mac's allocation over TLS");
    // Past the relay's window after that allocation: still no Mac on it.
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    loop {
        echo(&connected.link, 1).await;
        let path = *connected.path.borrow();
        let phone_left =
            cmux_mobile_link::dial::wireguard::relay_held(&connected.session_id, true) != Some(true);
        if matches!(path, LinkPath::Turn | LinkPath::TurnTls) && phone_left {
            break;
        }
        assert!(std::time::Instant::now() < deadline, "path {path:?}, phone left the relay: {phone_left}");
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    tokio::time::sleep(Duration::from_secs(4)).await;
    echo(&connected.link, 1).await;
    assert!(
        rig.server.relay_joins_of(&rig.mac_id).is_empty(),
        "the Mac joined the relay while its TURN allocation was under way"
    );
    assert!(matches!(rig.mac_path(), Some(LinkPath::Turn | LinkPath::TurnTls)), "{:?}", rig.mac_path());
    connected.link.close("done");
}

/// Plain UDP to the peer goes nowhere (both NATs map per destination, as
/// symmetric NAT and CGNAT do, so no punch lands).
fn udp_to_the_peer_lost(_: &std::net::SocketAddr) -> bool {
    true
}

/// Direct UDP and TURN both fail; how long the WireGuard dial takes to be
/// up on the relay, and when each side joined it (since the dial started).
/// No TURN server, rather than an unreachable one: a TURN host that never
/// answers holds the phone's gather (and so `wg-init`) about 2 s before the
/// relay plays any part, which is the gather's cost, not the relay's.
async fn dial_with_direct_and_turn_failing(relay_first: bool) -> (Duration, Duration, Duration) {
    dial_with_direct_and_turn_failing_by(relay_first, relay_first).await
}

/// The same, with each side's build chosen: `phone_first` and `mac_first` say whether it
/// offers `relay: "first"` (a build with relay first) or `ready` (one before it).
async fn dial_with_direct_and_turn_failing_by(
    phone_first: bool,
    mac_first: bool,
) -> (Duration, Duration, Duration) {
    let mac_options =
        DialOptions { drop_udp_to: Some(udp_to_the_peer_lost), relay_first: mac_first, ..options() };
    let rig = rig(FakeOptions::default(), mac_options, true).await;
    let phone = DialOptions {
        drop_udp_to: Some(udp_to_the_peer_lost),
        relay: relay(&rig.server, &rig.phone_id),
        relay_first: phone_first,
        ..options()
    };
    let started = std::time::Instant::now();
    let connected =
        dial::connect(&rig.phone, &rig.mac_id, TransportKind::WireGuard, &phone, LinkConfig::default())
            .await
            .expect("dial through the relay");
    let up = started.elapsed();
    echo(&connected.link, 2).await;
    assert_eq!(*connected.path.borrow(), LinkPath::HttpsRelay);
    assert_eq!(rig.mac_path(), Some(LinkPath::HttpsRelay));
    let joined = |device: &str| {
        let joins = rig.server.relay_joins_of(device);
        joins.first().expect("joined the relay").duration_since(started)
    };
    let (phone_joined, mac_joined) = (joined(&rig.phone_id), joined(&rig.mac_id));
    connected.link.close("done");
    (up, phone_joined, mac_joined)
}

/// Relay first (`relay: "first"` from both sides): when direct UDP and TURN
/// both fail, each side joins the relay as its dial starts (the Mac on the
/// phone's offer, the phone as its tunnel starts, beside the direct race),
/// and the phone's pending handshake goes through it as it joins, so the
/// link is up on the relay well under the 3 s the older join rule waited
/// for nothing to authenticate.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn with_direct_udp_and_turn_failing_the_relay_carries_the_dial_from_its_start() {
    let (up, phone_joined, mac_joined) = dial_with_direct_and_turn_failing(true).await;
    eprintln!("relay first: link up {up:?}, phone joined at {phone_joined:?}, Mac at {mac_joined:?}");
    assert!(up < Duration::from_secs(1), "link up after {up:?}");
    assert!(phone_joined < Duration::from_millis(500), "the phone joined at {phone_joined:?}");
    assert!(mac_joined < Duration::from_millis(500), "the Mac joined at {mac_joined:?}");
}

/// One relay-first dial with direct UDP and TURN failing, a Mac that answers
/// `answer` late and relay joins that take `join` (TCP, TLS and the upgrade):
/// link up, the phone's first relay join landed, and `wg-resp` forwarded, all
/// since the dial started. `old_hub`: a hub that never answers `ticketEarly`,
/// which is also what a phone before this change got in relay first (it never
/// asked), so the phone's ticket comes only on `wg-resp`; that phone also had no
/// Bearer join right after its early `wg-relay` (`relay_join_early`), so it is off too.
async fn relay_first_dial_with_a_slow_answer(
    old_hub: bool,
    mac_first: bool,
    answer: Duration,
    join: Duration,
) -> (Duration, Duration, Duration, usize) {
    let fake = FakeOptions {
        no_early_ticket: old_hub,
        answer_delay: answer,
        relay_join_delay: join,
        ..FakeOptions::default()
    };
    let mac_options =
        DialOptions { drop_udp_to: Some(udp_to_the_peer_lost), relay_first: mac_first, ..options() };
    let rig = rig(fake, mac_options, true).await;
    let phone = DialOptions {
        drop_udp_to: Some(udp_to_the_peer_lost),
        relay: relay(&rig.server, &rig.phone_id),
        relay_join_early: !old_hub,
        ..options()
    };
    let started = std::time::Instant::now();
    let connected =
        dial::connect(&rig.phone, &rig.mac_id, TransportKind::WireGuard, &phone, LinkConfig::default())
            .await
            .expect("dial through the relay");
    let up = started.elapsed();
    echo(&connected.link, 1).await;
    assert_eq!(*connected.path.borrow(), LinkPath::HttpsRelay);
    let session = rig.server.sessions_with("wg-init").remove(0);
    let resp = rig.server.forwarded_at(&session, "wg-resp").expect("wg-resp forwarded");
    let joins = rig.server.relay_joins_of(&rig.phone_id);
    let phone_joined = joins.first().expect("the phone joined the relay").duration_since(started);
    connected.link.close("done");
    (up, phone_joined, resp.duration_since(started), joins.len())
}

fn median(mut samples: Vec<Duration>) -> Duration {
    samples.sort();
    samples[samples.len() / 2]
}

/// RFD 0142 R1, ticket at dial start: in relay first the phone asks for its
/// relay ticket in its `wg-init` (`ticketEarly`), so its join starts when the
/// hub forwards the offer, beside the direct race and the Mac's own join,
/// instead of after `wg-resp`. With a Mac that answers 300 ms late and joins
/// that take 200 ms, the phone's join lands before `wg-resp` and the session
/// takes it (one join); an older hub leaves it after `wg-resp`, as before.
/// `CMUX_RELAY_TICKET_RUNS=8` prints medians over 8 dials of each.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn relay_first_takes_its_ticket_at_dial_start_and_joins_before_the_answer() {
    let (answer, join) = (Duration::from_millis(300), Duration::from_millis(200));
    let runs: usize = std::env::var("CMUX_RELAY_TICKET_RUNS").ok().and_then(|n| n.parse().ok()).unwrap_or(1);
    let mut rows = Vec::new();
    for old_hub in [true, false] {
        let (mut ups, mut joined, mut resps) = (Vec::new(), Vec::new(), Vec::new());
        for _ in 0..runs {
            let (up, phone_joined, resp, joins) =
                relay_first_dial_with_a_slow_answer(old_hub, true, answer, join).await;
            assert_eq!(joins, 1, "old hub {old_hub}: the phone joined once");
            if old_hub {
                assert!(phone_joined > resp, "an older hub: the phone joins after wg-resp");
            } else {
                assert!(
                    phone_joined < resp,
                    "the ticket at dial start: joined {phone_joined:?}, wg-resp {resp:?}"
                );
            }
            ups.push(up);
            joined.push(phone_joined);
            resps.push(resp);
        }
        let row = (median(ups), median(joined), median(resps));
        eprintln!(
            "{} (n={runs}): link up {:?}, phone's relay join landed {:?}, wg-resp {:?}",
            if old_hub { "before: ticket on wg-resp" } else { "after: ticket at dial start" },
            row.0,
            row.1,
            row.2
        );
        rows.push(row);
    }
    assert!(rows[1].0 < rows[0].0, "link up: before {:?}, after {:?}", rows[0].0, rows[1].0);
}

/// A new phone against a Mac that offers only `ready` (a build before relay
/// first): the phone's early join is let go, the Mac keeps the 3 s rule, and
/// the link still comes up on the relay.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn relay_first_ticket_at_dial_start_with_an_older_mac_still_rides_the_relay() {
    let (up, _, _, _) =
        relay_first_dial_with_a_slow_answer(false, false, Duration::ZERO, Duration::ZERO).await;
    assert!(up >= Duration::from_secs(3), "an older Mac keeps the 3 s rule: up after {up:?}");
}

/// A side whose peer offers only `relay: "ready"` (a build before relay
/// first) keeps the older rule: it joins only once nothing authenticated
/// for 3 s, and the link still comes up on the relay.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_older_peer_keeps_the_three_second_relay_rule() {
    let (up, phone_joined, mac_joined) = dial_with_direct_and_turn_failing(false).await;
    eprintln!("older rule: link up {up:?}, phone joined at {phone_joined:?}, Mac at {mac_joined:?}");
    assert!(phone_joined >= Duration::from_secs(3), "the phone joined at {phone_joined:?}");
    assert!(mac_joined >= Duration::from_secs(3), "the Mac joined at {mac_joined:?}");
}

/// An older phone (it offers `relay: "ready"`) against a Mac with relay first: the
/// Mac reads `ready` and keeps the older rule, so neither side joins before 3 s, and
/// the link still comes up on the relay.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_older_phone_against_a_new_mac_keeps_the_three_second_relay_rule() {
    let (up, phone_joined, mac_joined) = dial_with_direct_and_turn_failing_by(false, true).await;
    eprintln!(
        "older phone, new Mac: link up {up:?}, phone joined at {phone_joined:?}, Mac at {mac_joined:?}"
    );
    assert!(phone_joined >= Duration::from_secs(3), "the phone joined at {phone_joined:?}");
    assert!(mac_joined >= Duration::from_secs(3), "the Mac joined at {mac_joined:?}");
}

/// Direct UDP and TURN fail and the phone's STUN gather is slow (a TURN host
/// that never answers), so its `wg-init` is late. How long the link takes, and
/// when the Mac joined the relay against when the server forwarded `wg-init`
/// to it. `early_signal` is whether the Mac's build gets the phone's `early wg-relay`.
/// `hold_init`: the phone holds `wg-init` for its gather (as before #59649 sent
/// the offer first), so a Mac join that does not wait for it shows as earlier.
async fn dial_with_a_slow_gather(
    phone_first: bool,
    mac_first: bool,
    early_signal: bool,
    hold_init: bool,
) -> (Duration, Duration, Duration, Duration) {
    let mac_options =
        DialOptions { drop_udp_to: Some(udp_to_the_peer_lost), relay_first: mac_first, ..options() };
    let fake = FakeOptions {
        // A relay join takes a while, as over a real network (loopback takes 2 ms).
        relay_join_delay: Duration::from_millis(200),
        enforce_signal_kinds: true,
        drop_early_wg_relay: !early_signal,
        ..FakeOptions::default()
    };
    let rig = rig(fake, mac_options, true).await;
    // A TURN host that never answers holds the phone's gather, and so its `wg-init`.
    let unreachable_turn = cmux_mobile_link::api::IceServer {
        urls: vec!["turn:127.0.0.1:9?transport=udp".into()],
        username: Some("u".into()),
        credential: Some("c".into()),
    };
    let phone = DialOptions {
        drop_udp_to: Some(udp_to_the_peer_lost),
        relay: relay(&rig.server, &rig.phone_id),
        relay_first: phone_first,
        ice_servers: vec![unreachable_turn],
        init_after_gather: hold_init,
        ..options()
    };
    let started = std::time::Instant::now();
    let connected =
        dial::connect(&rig.phone, &rig.mac_id, TransportKind::WireGuard, &phone, LinkConfig::default())
            .await
            .expect("dial through the relay");
    let up = started.elapsed();
    echo(&connected.link, 2).await;
    let mac_joined =
        rig.server.relay_joins_of(&rig.mac_id).first().expect("the Mac joined").duration_since(started);
    // The last join: a phone that joined early for a Mac that cannot (and let that join go)
    // joins again on the 3 s rule.
    let phone_joined =
        rig.server.relay_joins_of(&rig.phone_id).last().expect("the phone joined").duration_since(started);
    let init_at = rig
        .server
        .forwarded_at(&connected.session_id, "wg-init")
        .expect("wg-init forwarded")
        .duration_since(started);
    connected.link.close("done");
    (up, mac_joined, init_at, phone_joined)
}

/// The Mac's relay join does not wait for `wg-init`: the phone's `early wg-relay`
/// (sent before its gather) starts it, so it is up before `wg-init` is even sent.
/// The phone holds `wg-init` for its gather here: since #59649 relay first sends
/// it at once (about 40 ms), before any 200 ms join could finish, which would
/// say nothing about what starts the Mac's join.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_mac_joins_the_relay_before_the_phones_wg_init_arrives() {
    let (up, mac_joined, init_at, phone_joined) = dial_with_a_slow_gather(true, true, true, true).await;
    eprintln!(
        "early: link up {up:?}, Mac joined at {mac_joined:?}, wg-init at {init_at:?}, phone joined at {phone_joined:?}"
    );
    assert!(mac_joined < init_at, "the Mac joined at {mac_joined:?}, wg-init arrived at {init_at:?}");
    // The dial still comes up on the relay, no later than without it.
    assert!(up < Duration::from_secs(5), "link up after {up:?}");
}

/// A Mac that does not know `early wg-relay` (an older build; the server drops it
/// here) joins only after `wg-init`, as before, and the dial still comes up.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_mac_that_never_saw_early_wg_relay_joins_after_wg_init() {
    let (up, mac_joined, init_at, phone_joined) = dial_with_a_slow_gather(true, true, false, false).await;
    eprintln!(
        "no early: link up {up:?}, Mac joined at {mac_joined:?}, wg-init at {init_at:?}, phone joined at {phone_joined:?}"
    );
    assert!(mac_joined >= init_at, "the Mac joined at {mac_joined:?}, wg-init arrived at {init_at:?}");
}

/// A new phone against an older Mac (no `early wg-relay`, and it offers `relay: "ready"`):
/// the phone sees `ready` and keeps the three-second rule, as today.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_new_phone_against_an_older_mac_keeps_the_three_second_relay_rule() {
    let (up, mac_joined, init_at, phone_joined) = dial_with_a_slow_gather(true, false, false, false).await;
    eprintln!(
        "new phone, older Mac: link up {up:?}, Mac at {mac_joined:?}, wg-init {init_at:?}, phone at {phone_joined:?}"
    );
    assert!(phone_joined >= Duration::from_secs(3), "the phone joined at {phone_joined:?}");
    assert!(mac_joined >= Duration::from_secs(3), "the Mac joined at {mac_joined:?}");
}

/// A new Mac that does not offer relay first still ignores `early wg-relay`: no early join.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_mac_without_relay_first_ignores_early_wg_relay() {
    let (_, mac_joined, init_at, _) = dial_with_a_slow_gather(true, false, true, false).await;
    assert!(mac_joined >= init_at, "the Mac joined at {mac_joined:?}, wg-init arrived at {init_at:?}");
    assert!(mac_joined >= Duration::from_secs(3), "the Mac joined at {mac_joined:?}");
}

/// A Mac whose `dial::answer` result goes to the returned channel, with a phone that
/// only sends `wg-relay` (the early cue) and never a `wg-init`; what the phone hears
/// back, when the Mac joined the relay, and how the answer ended.
async fn early_cue_alone(
    relay_first: bool,
    timeout: Duration,
) -> (Option<Result<(), DialError>>, Duration, Vec<String>, usize) {
    let server =
        FakeSignaling::start(FakeOptions { enforce_signal_kinds: true, ..FakeOptions::default() }).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let phone_id = uuid::Uuid::new_v4().to_string();
    let phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    let session_id = uuid::Uuid::new_v4().to_string();
    let mut heard = phone.subscribe(&session_id);
    mac.accept_early_relay_cue(relay_first);
    let (done_tx, done_rx) = tokio::sync::oneshot::channel();
    let options = DialOptions { relay: relay(&server, &mac_id), relay_first, timeout, ..options() };
    tokio::spawn(async move {
        let session = mac.next_session().await.expect("the Mac sees a session");
        let events = SessionEvents {
            backend: mac.events(),
            session_id: session.first.session_id.clone(),
            session: session.events,
        };
        let result = dial::answer(&mac, session.first, events, &options, LinkConfig::default()).await;
        let _ = done_tx.send((result.map(|_| ()), std::time::Instant::now()));
    });
    let started = std::time::Instant::now();
    phone.send_signal(&mac_id, &session_id, cmux_mobile_link::signaling::SignalPayload::WgRelay {}).unwrap();
    // An answer that never opened (the cue was dropped) never ends.
    let (result, ended) = match tokio::time::timeout(timeout + Duration::from_secs(2), done_rx).await {
        Ok(Ok((result, ended))) => (Some(result), ended),
        _ => (None, std::time::Instant::now()),
    };
    // Anything the Mac sent the phone meanwhile.
    tokio::time::sleep(Duration::from_millis(300)).await;
    let mut signals = Vec::new();
    while let Ok(event) = heard.try_recv() {
        signals.push(format!("{event:?}"));
    }
    let joins = server.relay_joins_of(&mac_id).len();
    (result, ended.duration_since(started), signals, joins)
}

/// (a) Without relay first, a `wg-relay` for an unknown session opens nothing: no
/// join, no bye, as a Mac before relay first drops it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_early_wg_relay_opens_nothing_without_relay_first() {
    let (result, _, signals, joins) = early_cue_alone(false, Duration::from_secs(1)).await;
    assert!(result.is_none(), "a session opened: {result:?}");
    assert!(signals.is_empty(), "the phone heard {signals:?}");
    assert_eq!(joins, 0, "the Mac joined the relay");
}

/// (b) With relay first and no `wg-init` after it: the Mac joins early, then ends
/// the session quietly after the dial timeout, with no bye to the phone.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_early_wg_relay_with_no_wg_init_ends_quietly_after_the_timeout() {
    let (result, took, signals, joins) = early_cue_alone(true, Duration::from_secs(2)).await;
    assert!(matches!(result, Some(Err(DialError::Bye(_)))), "{result:?}");
    assert!(took >= Duration::from_millis(1500) && took < Duration::from_secs(4), "ended after {took:?}");
    assert!(signals.is_empty(), "the phone heard {signals:?}");
    assert_eq!(joins, 1, "the Mac joined early");
}

/// What one relay-only dial measured: when the link was up, each side's first and
/// last relay join (since the dial started), and the path each side labels.
struct Timed {
    up: Duration,
    phone_joins: Vec<Duration>,
    mac_joins: Vec<Duration>,
}

/// Direct UDP and TURN both fail, over a network of `leg` per one-way leg (zero: the
/// in-process loopback). Each side's build is chosen: `phone` and `mac` (its
/// `relay_first`, and for the phone `relay_join_early`); `tickets` has the service
/// stamp relay tickets and require them on a join.
async fn timed_relay_dial(
    leg: Duration,
    phone_first: bool,
    phone_early: bool,
    mac_first: bool,
    tickets: bool,
) -> Timed {
    let fake = FakeOptions { signal_leg: leg, relay_tickets: tickets, ..FakeOptions::default() };
    let mac_options =
        DialOptions { drop_udp_to: Some(udp_to_the_peer_lost), relay_first: mac_first, ..options() };
    let rig = rig(fake, mac_options, true).await;
    let phone = DialOptions {
        drop_udp_to: Some(udp_to_the_peer_lost),
        relay: relay(&rig.server, &rig.phone_id),
        relay_first: phone_first,
        relay_join_early: phone_early,
        ..options()
    };
    let started = std::time::Instant::now();
    let connected =
        dial::connect(&rig.phone, &rig.mac_id, TransportKind::WireGuard, &phone, LinkConfig::default())
            .await
            .expect("dial through the relay");
    let up = started.elapsed();
    echo(&connected.link, 2).await;
    assert_eq!(*connected.path.borrow(), LinkPath::HttpsRelay);
    assert_eq!(rig.mac_path(), Some(LinkPath::HttpsRelay));
    let joins = |device: &str| {
        rig.server.relay_joins_of(device).into_iter().map(|at| at.duration_since(started)).collect::<Vec<_>>()
    };
    let timed = Timed { up, phone_joins: joins(&rig.phone_id), mac_joins: joins(&rig.mac_id) };
    connected.link.close("done");
    timed
}

/// Relay-only dial, one network leg 25 ms: joining right after the early `wg-relay`
/// puts the phone's join (4 legs) beside the Mac's (the cue 2, join 4) instead of after
/// the Mac's `wg-resp` (2 + 2 + 4). Eight dials each, the median.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_phones_early_join_does_not_slow_a_relay_only_dial() {
    let leg = Duration::from_millis(25);
    let (mut off, mut on) = (Vec::new(), Vec::new());
    for _ in 0..8 {
        off.push(timed_relay_dial(leg, true, false, true, false).await.up);
        on.push(timed_relay_dial(leg, true, true, true, false).await.up);
    }
    let (off, on) = (median(off), median(on));
    eprintln!(
        "phone joins on the answer: {off:?} ({:.1} legs); right after its cue: {on:?} ({:.1} legs)",
        off.as_secs_f64() / leg.as_secs_f64(),
        on.as_secs_f64() / leg.as_secs_f64()
    );
    // The Mac's join (on the cue: 2 legs + 4 to join) is the longer way and runs beside
    // the phone's, so the phone's early join saves up to two legs here, within the noise
    // of a loaded runner: it must not cost one.
    assert!(on <= off + leg, "{on:?} against {off:?}");
}

/// A phone that does not join early (an older build) against a new Mac: the Mac joins on
/// the cue, the phone on the Mac's answer, and the link rides the relay.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_older_phone_without_the_early_join_against_a_new_mac_still_rides_the_relay() {
    let timed = timed_relay_dial(Duration::ZERO, true, false, true, false).await;
    assert!(timed.up < Duration::from_secs(1), "link up after {:?}", timed.up);
    assert_eq!(timed.phone_joins.len(), 1, "{:?}", timed.phone_joins);
    assert!(timed.mac_joins[0] < Duration::from_millis(500), "{:?}", timed.mac_joins);
}

/// A new phone against an older Mac (it offers `relay: "ready"`): the phone's early join
/// is let go unused, and the 3 s rule holds on both sides.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_new_phone_against_an_older_mac_keeps_the_three_second_rule_and_drops_its_early_join() {
    let timed = timed_relay_dial(Duration::ZERO, true, true, false, false).await;
    assert!(timed.mac_joins[0] >= Duration::from_secs(3), "{:?}", timed.mac_joins);
    let last = *timed.phone_joins.last().expect("the phone joined");
    assert!(last >= Duration::from_secs(3), "{:?}", timed.phone_joins);
}

/// A service that stamps and requires relay tickets: the phone's ticketless early join
/// is refused, the Mac's (its ticket on the cue) is not, and the phone joins with the
/// ticket on the Mac's answer; the link still rides the relay at once.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn with_tickets_a_refused_early_join_falls_back_to_the_ticket_on_the_answer() {
    let timed = timed_relay_dial(Duration::ZERO, true, true, true, true).await;
    assert!(timed.up < Duration::from_secs(1), "link up after {:?}", timed.up);
    assert_eq!(timed.phone_joins.len(), 1, "{:?}", timed.phone_joins);
    assert!(timed.mac_joins[0] < Duration::from_millis(500), "{:?}", timed.mac_joins);
}

/// One bench dial: link-up, the phone's and the Mac's first relay join, and when
/// `wg-init` was forwarded, all since the dial started.
struct BenchDial {
    up: Duration,
    phone_join: Duration,
    mac_join: Duration,
    init_at: Duration,
}

/// Both sides dial the relay first, direct UDP lost, relay joins taking 200 ms. `early_wg_relay`:
/// the phone's early `wg-relay` reaches the Mac (else the server drops it, as an older Mac
/// would). `phone_early`: the phone joins right after its cue (else on the Mac's answer).
/// `slow_gather`: a TURN host that never answers. No relay tickets, as production.
async fn bench_dial(early_wg_relay: bool, phone_early: bool, slow_gather: bool) -> BenchDial {
    let mac_options = DialOptions { drop_udp_to: Some(udp_to_the_peer_lost), relay_first: true, ..options() };
    let fake = FakeOptions {
        relay_join_delay: Duration::from_millis(200),
        enforce_signal_kinds: true,
        drop_early_wg_relay: !early_wg_relay,
        ..FakeOptions::default()
    };
    let rig = rig(fake, mac_options, true).await;
    let ice_servers = if slow_gather {
        vec![cmux_mobile_link::api::IceServer {
            urls: vec!["turn:127.0.0.1:9?transport=udp".into()],
            username: Some("u".into()),
            credential: Some("c".into()),
        }]
    } else {
        Vec::new()
    };
    let phone = DialOptions {
        drop_udp_to: Some(udp_to_the_peer_lost),
        relay: relay(&rig.server, &rig.phone_id),
        relay_first: true,
        relay_join_early: phone_early,
        ice_servers,
        ..options()
    };
    let started = std::time::Instant::now();
    let connected =
        dial::connect(&rig.phone, &rig.mac_id, TransportKind::WireGuard, &phone, LinkConfig::default())
            .await
            .expect("dial through the relay");
    let up = started.elapsed();
    echo(&connected.link, 2).await;
    let first = |device: &str, what: &str| {
        rig.server.relay_joins_of(device).first().expect(what).duration_since(started)
    };
    let dial = BenchDial {
        up,
        phone_join: first(&rig.phone_id, "the phone joined"),
        mac_join: first(&rig.mac_id, "the Mac joined"),
        init_at: rig
            .server
            .forwarded_at(&connected.session_id, "wg-init")
            .expect("wg-init forwarded")
            .duration_since(started),
    };
    connected.link.close("done");
    dial
}

fn percentile(times: &[Duration], p: f64) -> Duration {
    let mut sorted = times.to_vec();
    sorted.sort();
    sorted[((sorted.len() as f64 * p).ceil() as usize).clamp(1, sorted.len()) - 1]
}

/// Before/after for a relay-first dial with direct UDP lost: relay first alone, with the
/// Mac's early join, and with both sides' early joins (the phone's too, right after its cue),
/// over a slow gather; and over a fast gather (no TURN host), where it must cost nothing.
/// `cargo test -p cmux-mobile-link --test https_relay -- --ignored --nocapture bench_relay_first_dial`
#[ignore = "bench: about two minutes"]
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn bench_relay_first_dial() {
    const RUNS: usize = 10;
    let configs = [
        ("slow gather, (a) relay first only", false, false, true),
        ("slow gather, (b) Mac early join only", true, false, true),
        ("slow gather, (c) both", true, true, true),
        ("fast gather, (a) relay first only", false, false, false),
        ("fast gather, (b) Mac early join only", true, false, false),
        ("fast gather, (c) both", true, true, false),
    ];
    eprintln!(
        "{:<38} {:>14} {:>14} {:>14} {:>14}",
        "p50 / p95 ms", "link up", "phone join", "Mac join", "wg-init"
    );
    for (name, early, phone_early, slow) in configs {
        let mut dials = Vec::new();
        for _ in 0..RUNS {
            dials.push(bench_dial(early, phone_early, slow).await);
        }
        let cell = |pick: fn(&BenchDial) -> Duration| {
            let times: Vec<Duration> = dials.iter().map(pick).collect();
            format!("{} / {}", percentile(&times, 0.5).as_millis(), percentile(&times, 0.95).as_millis())
        };
        eprintln!(
            "{name:<38} {:>14} {:>14} {:>14} {:>14}",
            cell(|d| d.up),
            cell(|d| d.phone_join),
            cell(|d| d.mac_join),
            cell(|d| d.init_at)
        );
    }
}

/// Disco over the relay (ledger 13h): two devices on one LAN whose signaling
/// carried no direct endpoint (an older or stripping signaling path, a
/// relay-only meeting) meet on cmux's relay. Plain UDP between them works, so
/// once the tunnel is up they must swap their LAN endpoints through it and
/// move the link to the direct path: relayed -> direct, both sides.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn peers_that_met_on_the_relay_swap_lan_endpoints_and_go_direct() {
    met_on_the_relay_goes_direct(false, "nearby_disco_over_relay").await;
}

/// The same with each side taking the other for an older peer (no `version`
/// in wg-init or wg-resp): the endpoints ride the roam announcement, which
/// older builds already take, so nothing new is negotiated.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_older_peer_met_on_the_relay_also_goes_direct() {
    met_on_the_relay_goes_direct(true, "nearby_disco_over_relay_old_peer").await;
}

async fn met_on_the_relay_goes_direct(old_peer: bool, cell: &str) {
    let fake =
        FakeOptions { strip_direct_endpoints: true, strip_wg_version: old_peer, ..FakeOptions::default() };
    let rig = rig(fake, options(), true).await;
    let phone = DialOptions { relay: relay(&rig.server, &rig.phone_id), ..options() };
    let started = std::time::Instant::now();
    let connected =
        dial::connect(&rig.phone, &rig.mac_id, TransportKind::WireGuard, &phone, LinkConfig::default())
            .await
            .expect("dial with no direct endpoint in signaling");
    echo(&connected.link, 1).await;
    let up_ms = started.elapsed().as_secs_f64() * 1000.0;
    let first = *connected.path.borrow();
    let up = std::time::Instant::now();
    let deadline = up + Duration::from_secs(10);
    loop {
        echo(&connected.link, 1).await;
        if *connected.path.borrow() == LinkPath::Direct && rig.mac_path() == Some(LinkPath::Direct) {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "still {:?} (mac {:?}) 10 s after the link came up on {first:?}",
            *connected.path.borrow(),
            rig.mac_path()
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    println!(
        "MATRIX {{\"cell\": \"{cell}\", \"first_path\": \"{first:?}\", \"up_ms\": {up_ms:.1}, \"direct_after_ms\": {:.1}}}",
        up.elapsed().as_secs_f64() * 1000.0
    );
    connected.link.close("done");
}

/// PROTOCOL.md "Early relay ticket", new and old hub: a phone with no path but
/// the relay asks for its ticket in its `wg-init`; a hub that answers
/// (`wg-ticket`) lets its join run while a slow Mac answers, and the session
/// takes that join (one join per side). A hub that never answers leaves the
/// phone joining after `wg-resp`, as before. Prints both dial times.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_early_ticket_joins_while_the_mac_answers_and_an_older_hub_still_works() {
    let mut took = Vec::new();
    for old_hub in [false, true] {
        let fake = FakeOptions {
            no_early_ticket: old_hub,
            answer_delay: Duration::from_millis(600),
            relay_join_delay: Duration::from_millis(400),
            ..FakeOptions::default()
        };
        let rig = rig(fake, options(), true).await;
        // The ticket path alone: the relay-first Bearer join (`relay_join_early`, on by
        // default) would join before `wg-resp` on either hub and hide what the ticket buys.
        let phone = DialOptions {
            force_relay: true,
            relay_join_early: false,
            relay: relay(&rig.server, &rig.phone_id),
            ..options()
        };
        let started = std::time::Instant::now();
        let connected =
            dial::connect(&rig.phone, &rig.mac_id, TransportKind::WireGuard, &phone, LinkConfig::default())
                .await
                .expect("dial through the relay");
        echo(&connected.link, 2).await;
        took.push(started.elapsed());
        assert_eq!(*connected.path.borrow(), LinkPath::HttpsRelay);
        let session = rig.server.sessions_with("wg-init").remove(0);
        let resp = rig.server.forwarded_at(&session, "wg-resp").expect("wg-resp forwarded");
        let joins = rig.server.relay_joins_of(&rig.phone_id);
        assert_eq!(joins.len(), 1, "old hub {old_hub}: the phone joined once: {joins:?}");
        if old_hub {
            assert!(joins[0] > resp, "an older hub: the phone joins after wg-resp");
        } else {
            assert!(joins[0] < resp, "the early ticket's join ran before wg-resp");
        }
        connected.link.close("done");
    }
    eprintln!(
        "relay-only dial with a 600 ms Mac answer: early ticket {:?}, older hub {:?}",
        took[0], took[1]
    );
    assert!(took[0] < took[1], "{took:?}");
}

/// A STUN server on loopback that answers each binding request `delay`
/// late, with the address it came from: a gather that takes a cellular
/// round trip or two, instead of loopback's none.
async fn slow_stun(delay: Duration) -> String {
    let socket = std::sync::Arc::new(tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap());
    let address = socket.local_addr().unwrap().to_string();
    tokio::spawn(async move {
        let mut buffer = [0u8; 1500];
        while let Ok((len, from)) = socket.recv_from(&mut buffer).await {
            if len < 20 {
                continue;
            }
            let mut transaction = [0u8; 12];
            transaction.copy_from_slice(&buffer[8..20]);
            let socket = socket.clone();
            tokio::spawn(async move {
                tokio::time::sleep(delay).await;
                let _ = socket.send_to(&cmux_transport::stun::binding_success(transaction, from), from).await;
            });
        }
    });
    address
}

/// One relay-first dial with direct UDP and TURN failing and a phone whose
/// STUN gather takes `stun` (the Mac answers at once, joins take `join`):
/// link up and `wg-init` forwarded, since the dial started. `after_gather`:
/// the phone holds `wg-init` for its gather, as before the offer went first.
async fn relay_first_dial_with_a_slow_gather(
    after_gather: bool,
    mac_first: bool,
    stun: Duration,
    join: Duration,
) -> (Duration, Duration) {
    let fake = FakeOptions { relay_join_delay: join, ..FakeOptions::default() };
    let mac_options =
        DialOptions { drop_udp_to: Some(udp_to_the_peer_lost), relay_first: mac_first, ..options() };
    let rig = rig(fake, mac_options, true).await;
    let stun_server = cmux_mobile_link::api::IceServer {
        urls: vec![format!("stun:{}", slow_stun(stun).await)],
        username: None,
        credential: None,
    };
    let phone = DialOptions {
        drop_udp_to: Some(udp_to_the_peer_lost),
        relay: relay(&rig.server, &rig.phone_id),
        ice_servers: vec![stun_server],
        init_after_gather: after_gather,
        ..options()
    };
    let started = std::time::Instant::now();
    let connected =
        dial::connect(&rig.phone, &rig.mac_id, TransportKind::WireGuard, &phone, LinkConfig::default())
            .await
            .expect("dial through the relay");
    let up = started.elapsed();
    echo(&connected.link, 1).await;
    assert_eq!(*connected.path.borrow(), LinkPath::HttpsRelay);
    let session = rig.server.sessions_with("wg-init").remove(0);
    let init = rig.server.forwarded_at(&session, "wg-init").expect("wg-init forwarded");
    connected.link.close("done");
    (up, init.duration_since(started))
}

/// RFD 0142 R1, disco over the relay: in relay first the phone sends
/// `wg-init` before its STUN and TURN gather (host endpoints, the relay
/// offer and `ticketEarly`), and the gathered endpoints follow as a trickle
/// (`wg-endpoints` and the sealed in-tunnel announcement, which rides the
/// relay), so a slow gather no longer holds the offer, the ticket and both
/// joins. The tunnel still starts once both `wg-resp` and the gather are in,
/// so the link comes up after the longer of the gather and the join instead
/// of their sum: with a 400 ms gather and 200 ms joins, `wg-init` goes at
/// once and the link is up by about the gather, not gather plus join. The
/// baseline already overlaps the joins with the gather too (#54966's `early
/// wg-relay` starts both joins before `wg-init`), so sending the offer first
/// must not be slower than it; it no longer has a join to win back.
/// `CMUX_RELAY_TICKET_RUNS=8` prints medians over 8 dials of each.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn relay_first_sends_its_offer_before_the_gather_and_trickles_the_rest() {
    let (stun, join) = (Duration::from_millis(400), Duration::from_millis(200));
    let runs: usize = std::env::var("CMUX_RELAY_TICKET_RUNS").ok().and_then(|n| n.parse().ok()).unwrap_or(1);
    let mut rows = Vec::new();
    for after_gather in [true, false] {
        let (mut ups, mut inits) = (Vec::new(), Vec::new());
        for _ in 0..runs {
            let (up, init) = relay_first_dial_with_a_slow_gather(after_gather, true, stun, join).await;
            if after_gather {
                assert!(init >= stun, "the baseline holds wg-init for the gather ({init:?})");
            } else {
                assert!(init < Duration::from_millis(150), "wg-init went at {init:?}, before the gather");
            }
            ups.push(up);
            inits.push(init);
        }
        rows.push((after_gather, median(ups), median(inits)));
    }
    for (after_gather, up, init) in &rows {
        let label = if *after_gather { "wg-init after gather (before)" } else { "wg-init first (after)" };
        eprintln!("{label}: link up {up:?}, wg-init forwarded at {init:?} (median of {runs})");
    }
    let (before, after) = (rows[0].1, rows[1].1);
    assert!(after <= before + Duration::from_millis(100), "link up {after:?} vs {before:?} before");
    assert!(after < stun + join, "link up {after:?}: the gather and the join overlap");
}

/// The offer before the gather against a Mac before relay first (it
/// answers `ready`, so the relay waits its 3 s rule): the trickled
/// endpoints are the roam announcement it already takes, and the link still
/// comes up on the relay.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_offer_before_the_gather_with_an_older_mac_still_rides_the_relay() {
    let (up, init) =
        relay_first_dial_with_a_slow_gather(false, false, Duration::from_millis(400), Duration::ZERO).await;
    eprintln!("older Mac: link up {up:?}, wg-init at {init:?}");
    assert!(init < Duration::from_millis(150), "wg-init went at {init:?}");
}

/// Plain UDP for the test below, its own switch.
static UDP_LOST_LATE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(true);
fn udp_lost_late(_: &std::net::SocketAddr) -> bool {
    UDP_LOST_LATE.load(std::sync::atomic::Ordering::Relaxed)
}

/// RFD 0142 R1, disco's call-me-maybe: a link riding the relay whose direct
/// path opens a moment later (a late NAT mapping, a firewall that lets UDP
/// through again, a candidate learned through the relay) moves to it one
/// round trip after the peer's first direct datagram arrives
/// (`Paths::heard`). Before, the probe that went out while the path was
/// black-holed had to time out first (1 s). Prints the
/// `relay_then_direct_late` cell: time from UDP opening to both sides on the
/// direct path (the echo below keeps the link busy, as a live terminal does).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_direct_path_that_opens_just_after_the_relay_takes_over_within_a_spray() {
    let mac_options = DialOptions { drop_udp_to: Some(udp_lost_late), ..options() };
    let rig = rig(FakeOptions::default(), mac_options, true).await;
    let phone = DialOptions {
        drop_udp_to: Some(udp_lost_late),
        relay: relay(&rig.server, &rig.phone_id),
        ..options()
    };
    let connected =
        dial::connect(&rig.phone, &rig.mac_id, TransportKind::WireGuard, &phone, LinkConfig::default())
            .await
            .expect("dial through the relay once nothing else answers");
    echo(&connected.link, 1).await;
    assert_eq!(*connected.path.borrow(), LinkPath::HttpsRelay);
    // The direct path opens 1 s after the link rode the relay.
    tokio::time::sleep(Duration::from_millis(1000)).await;
    UDP_LOST_LATE.store(false, std::sync::atomic::Ordering::Relaxed);
    let opened = std::time::Instant::now();
    let deadline = opened + Duration::from_secs(25);
    loop {
        echo(&connected.link, 1).await;
        if *connected.path.borrow() == LinkPath::Direct && rig.mac_path() == Some(LinkPath::Direct) {
            break;
        }
        assert!(std::time::Instant::now() < deadline, "still on the relay: {:?}", *connected.path.borrow());
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let direct_after = opened.elapsed();
    println!(
        "MATRIX {{\"cell\": \"relay_then_direct_late\", \"direct_after_ms\": {:.1}}}",
        direct_after.as_secs_f64() * 1000.0
    );
    assert!(direct_after < Duration::from_millis(1500), "direct {direct_after:?} after UDP opened");
    connected.link.close("done");
}
