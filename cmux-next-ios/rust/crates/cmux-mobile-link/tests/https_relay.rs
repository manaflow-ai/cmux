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

/// A join presents this device's own relay ticket, as the service stamped
/// it on the session's signals to this device: without it (an older
/// service, or a device that never received it) the relay refuses the join.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_join_without_its_ticket_is_refused() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
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
    assert_eq!(rig.server.relay_joins(), 0);
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
async fn dial_with_a_slow_gather(
    phone_first: bool,
    mac_first: bool,
    early_signal: bool,
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
    let phone_joined =
        rig.server.relay_joins_of(&rig.phone_id).first().expect("the phone joined").duration_since(started);
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
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_mac_joins_the_relay_before_the_phones_wg_init_arrives() {
    let (up, mac_joined, init_at, phone_joined) = dial_with_a_slow_gather(true, true, true).await;
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
    let (up, mac_joined, init_at, phone_joined) = dial_with_a_slow_gather(true, true, false).await;
    eprintln!(
        "no early: link up {up:?}, Mac joined at {mac_joined:?}, wg-init at {init_at:?}, phone joined at {phone_joined:?}"
    );
    assert!(mac_joined >= init_at, "the Mac joined at {mac_joined:?}, wg-init arrived at {init_at:?}");
}

/// A new phone against an older Mac (no `early wg-relay`, and it offers `relay: "ready"`):
/// the phone sees `ready` and keeps the three-second rule, as today.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_new_phone_against_an_older_mac_keeps_the_three_second_relay_rule() {
    let (up, mac_joined, init_at, phone_joined) = dial_with_a_slow_gather(true, false, false).await;
    eprintln!(
        "new phone, older Mac: link up {up:?}, Mac at {mac_joined:?}, wg-init {init_at:?}, phone at {phone_joined:?}"
    );
    assert!(phone_joined >= Duration::from_secs(3), "the phone joined at {phone_joined:?}");
    assert!(mac_joined >= Duration::from_secs(3), "the Mac joined at {mac_joined:?}");
}

/// A new Mac that does not offer relay first still ignores `early wg-relay`: no early join.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_mac_without_relay_first_ignores_early_wg_relay() {
    let (_, mac_joined, init_at, _) = dial_with_a_slow_gather(true, false, true).await;
    assert!(mac_joined >= init_at, "the Mac joined at {mac_joined:?}, wg-init arrived at {init_at:?}");
    assert!(mac_joined >= Duration::from_secs(3), "the Mac joined at {mac_joined:?}");
}
