//! DNS down, the dial still links: TURN and STUN names resolve to the literals they last
//! resolved to (`route_literals`), and TURN over TLS still verifies the server by name.
//! Each test prints its before (no remembered literals) and after (remembered) times.

use std::net::{IpAddr, Ipv4Addr};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_mobile_link::dial::{self, SessionEvents};
use cmux_mobile_link::route_literals::{Lookup, Resolver, RouteLiterals};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling, TEST_TURN_HOST, TestTurn, ice_named};
use cmux_mobile_link::{ChannelEvent, DialOptions, LinkConfig, LinkPath, SignalingClient, TransportKind};

#[derive(Clone, Copy)]
enum Dns {
    Up,
    /// SERVFAIL at once.
    Fails,
    /// No answer at all (the resolver's upstream is down).
    Hangs,
}

/// A resolver that names every host `127.0.0.1` while up.
struct Switch(Mutex<Dns>);

impl Resolver for Switch {
    fn lookup(&self, _host: &str) -> Lookup {
        let dns = *self.0.lock().unwrap();
        Box::pin(async move {
            match dns {
                Dns::Up => Ok(vec![IpAddr::V4(Ipv4Addr::LOCALHOST)]),
                Dns::Fails => Err(std::io::Error::other("SERVFAIL")),
                Dns::Hangs => std::future::pending().await,
            }
        })
    }
}

fn options() -> DialOptions {
    DialOptions { include_loopback: true, timeout: Duration::from_secs(8), ..DialOptions::default() }
}

struct Rig {
    server: FakeSignaling,
    mac_id: String,
    _mac: tokio::task::JoinHandle<()>,
}

async fn rig() -> Rig {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let task = tokio::spawn(async move {
        while let Some(session) = mac.next_session().await {
            let events = SessionEvents {
                backend: mac.events(),
                session_id: session.first.session_id.clone(),
                session: session.events,
            };
            let mac = mac.clone();
            tokio::spawn(async move {
                let Ok(connected) =
                    dial::answer(&mac, session.first, events, &options(), LinkConfig::default()).await
                else {
                    return;
                };
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
    Rig { server, mac_id, _mac: task }
}

/// Dial and echo once: the path and the time to the first echo, or the error and its time.
async fn dial_once(rig: &Rig, phone: &DialOptions) -> (Result<LinkPath, String>, Duration) {
    let client = SignalingClient::connect(
        &rig.server.base_url,
        "user:alice",
        "team",
        &uuid::Uuid::new_v4().to_string(),
    )
    .await
    .unwrap();
    let started = Instant::now();
    let connected =
        match dial::connect(&client, &rig.mac_id, TransportKind::WireGuard, phone, LinkConfig::default())
            .await
        {
            Ok(connected) => connected,
            Err(error) => return (Err(error.to_string()), started.elapsed()),
        };
    let mut channel = connected.link.open("echo", serde_json::json!({})).await.unwrap();
    channel.send(Bytes::from_static(b"ping")).await.unwrap();
    match tokio::time::timeout(Duration::from_secs(10), channel.recv()).await {
        Ok(Some(ChannelEvent::Data(bytes))) => assert_eq!(&bytes[..], b"ping"),
        other => panic!("no echo: {other:?}"),
    }
    let path = *connected.path.borrow();
    (Ok(path), started.elapsed())
}

fn memory(dns: &Arc<Switch>) -> Arc<RouteLiterals> {
    Arc::new(RouteLiterals::new(Arc::clone(dns) as Arc<dyn Resolver>))
}

/// TURN by name, relay only: with DNS down and nothing remembered the dial fails (before);
/// once a dial with DNS up remembered the literal, the same dial with DNS down links via TURN
/// (after), whether DNS fails at once or never answers.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dns_down_still_reaches_turn_by_its_remembered_literal() {
    let turn = TestTurn::start().await;
    let rig = rig().await;
    for down in [Dns::Hangs, Dns::Fails] {
        let dns = Arc::new(Switch(Mutex::new(down)));
        let routes = memory(&dns);
        let phone = DialOptions {
            relay_only: true,
            ice_servers: vec![ice_named(&turn.udp_only(), TEST_TURN_HOST)],
            routes: Arc::clone(&routes),
            ..options()
        };
        let (before, before_took) = dial_once(&rig, &phone).await;
        assert!(before.is_err(), "nothing remembered and no DNS: {before:?}");

        *dns.0.lock().unwrap() = Dns::Up;
        let (warm, _) = dial_once(&rig, &phone).await;
        assert_eq!(warm, Ok(LinkPath::Turn));
        assert_eq!(routes.remembered(TEST_TURN_HOST), Some(vec![IpAddr::V4(Ipv4Addr::LOCALHOST)]));

        *dns.0.lock().unwrap() = down;
        let (after, after_took) = dial_once(&rig, &phone).await;
        assert_eq!(after, Ok(LinkPath::Turn), "DNS down, remembered literal");
        let label = if matches!(down, Dns::Hangs) { "hangs" } else { "fails" };
        let failed = before.unwrap_err();
        eprintln!(
            "route literals, TURN/UDP, DNS {label}: before {before_took:?} (dial failed: {failed}) after {after_took:?} (link up)"
        );
    }
}

/// TURN over TLS by name with DNS down: the connect goes to the remembered literal and the
/// certificate is still checked against the host name (the test server's certificate names
/// [`TEST_TURN_HOST`]).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dns_down_turn_over_tls_still_verifies_the_name() {
    let turn = TestTurn::start().await;
    let rig = rig().await;
    let dns = Arc::new(Switch(Mutex::new(Dns::Up)));
    let routes = memory(&dns);
    let phone = DialOptions {
        block_udp: true,
        ice_servers: vec![ice_named(&turn.ice, TEST_TURN_HOST)],
        turn_tls_roots: Some(Arc::clone(&turn.roots)),
        routes: Arc::clone(&routes),
        ..options()
    };
    assert_eq!(dial_once(&rig, &phone).await.0, Ok(LinkPath::TurnTls));
    *dns.0.lock().unwrap() = Dns::Hangs;
    let (after, took) = dial_once(&rig, &phone).await;
    assert_eq!(after, Ok(LinkPath::TurnTls));
    eprintln!("route literals, TURN/TLS, DNS hangs: after {took:?} (link up)");

    // A name the certificate does not carry fails verification even at the right literal.
    routes.store("other.cmux.test", &[IpAddr::V4(Ipv4Addr::LOCALHOST)]);
    let wrong = DialOptions { ice_servers: vec![ice_named(&turn.ice, "other.cmux.test")], ..phone.clone() };
    assert!(dial_once(&rig, &wrong).await.0.is_err(), "TLS accepted a certificate for another name");
}

/// A stale literal (the server moved) does not slow a dial while DNS works: DNS's answer is
/// dialed, and replaces the stale literal.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stale_literal_does_not_slow_a_dial_with_dns_up() {
    let turn = TestTurn::start().await;
    let rig = rig().await;
    let dns = Arc::new(Switch(Mutex::new(Dns::Up)));
    let routes = memory(&dns);
    let phone = DialOptions {
        relay_only: true,
        ice_servers: vec![ice_named(&turn.udp_only(), TEST_TURN_HOST)],
        routes: Arc::clone(&routes),
        ..options()
    };
    let (fresh, fresh_took) = dial_once(&rig, &phone).await;
    assert_eq!(fresh, Ok(LinkPath::Turn));
    // Blackholed (TEST-NET-1): a dial there would wait out the whole TURN allocation.
    let stale = IpAddr::V4(Ipv4Addr::new(192, 0, 2, 1));
    routes.store(TEST_TURN_HOST, &[stale]);
    let (after, took) = dial_once(&rig, &phone).await;
    assert_eq!(after, Ok(LinkPath::Turn));
    assert!(
        took < fresh_took + Duration::from_secs(1),
        "stale literal slowed the dial: {took:?} vs {fresh_took:?}"
    );
    assert_eq!(routes.remembered(TEST_TURN_HOST), Some(vec![IpAddr::V4(Ipv4Addr::LOCALHOST)]));
    eprintln!("route literals, stale literal, DNS up: {took:?} (fresh memory {fresh_took:?})");
}
