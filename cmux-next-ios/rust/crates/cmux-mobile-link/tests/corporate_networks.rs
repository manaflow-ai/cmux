//! The link on company networks (PROTOCOL.md "Corporate networks"), each
//! played on loopback with no network access:
//!
//! - TLS inspection: TURN over TLS presents a certificate a company root
//!   issued, trusted by the OS (an MDM profile), not by the public web PKI.
//! - Proxy only: no UDP, and TCP leaves only through an HTTP proxy
//!   (`CONNECT`), with or without Basic sign-in; one that wants NTLM or
//!   Kerberos fails the dial at once, saying so.
//! - A firewall that drops WireGuard: STUN and TURN over UDP work, every
//!   WireGuard datagram on them is dropped, and the link still comes up
//!   through TURN over TLS, within a bound.

use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_mobile_link::dial::{self, SessionEvents};
use cmux_mobile_link::egress::{Egress, TlsTrust};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling, ProxyAuth, TestCa, TestProxy, TestTurn};
use cmux_mobile_link::{
    ChannelEvent, DialError, DialOptions, LinkConfig, LinkPath, SignalingClient, TransportKind,
};

fn options() -> DialOptions {
    DialOptions { include_loopback: true, timeout: Duration::from_secs(20), ..DialOptions::default() }
}

/// A Mac that answers every session with `mac_options` and echoes; its
/// path once it answered goes to `paths`.
fn spawn_mac(
    mac: SignalingClient,
    mac_options: DialOptions,
) -> std::sync::Arc<std::sync::Mutex<Option<tokio::sync::watch::Receiver<LinkPath>>>> {
    let slot = std::sync::Arc::new(std::sync::Mutex::new(None));
    let paths = std::sync::Arc::clone(&slot);
    tokio::spawn(async move {
        while let Some(session) = mac.next_session().await {
            let events = SessionEvents {
                backend: mac.events(),
                session_id: session.first.session_id.clone(),
                session: session.events,
            };
            let (mac, options, paths) = (mac.clone(), mac_options.clone(), std::sync::Arc::clone(&paths));
            tokio::spawn(async move {
                let Ok(connected) =
                    dial::answer(&mac, session.first, events, &options, LinkConfig::default()).await
                else {
                    return;
                };
                *paths.lock().unwrap() = Some(connected.path.clone());
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
    slot
}

/// What a dial on one of these networks did.
#[derive(Debug)]
struct Run {
    phone: LinkPath,
    mac: Option<LinkPath>,
    /// From the dial's start until 200 KB came back through the link.
    took: Duration,
}

/// Dial a Mac on `mac_options` from a phone on `phone_options` (whose
/// signaling leaves as `signaling_egress` says), echo 200 KB, and report.
async fn link(
    phone_options: DialOptions,
    mac_options: DialOptions,
    signaling_egress: &Egress,
) -> Result<Run, DialError> {
    // `RUST_LOG=cmux_mobile_link=debug` shows the routes, allocations and proxy hops.
    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_test_writer()
        .try_init();
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let mac_path = spawn_mac(mac, mac_options);
    let phone_id = uuid::Uuid::new_v4().to_string();
    let phone = SignalingClient::connect_via(
        &server.base_url,
        "user:alice",
        "team",
        &phone_id,
        None,
        signaling_egress,
    )
    .await
    .expect("the phone's signaling socket");
    let started = Instant::now();
    let connected =
        dial::connect(&phone, &mac_id, TransportKind::WireGuard, &phone_options, LinkConfig::default())
            .await?;
    let mut channel = connected.link.open("echo", serde_json::json!({})).await.unwrap();
    let payload: Vec<u8> = (0..200_000u32).map(|i| (i % 251) as u8).collect();
    channel.send(Bytes::from(payload.clone())).await.unwrap();
    let mut echoed = Vec::new();
    while echoed.len() < payload.len() {
        match tokio::time::timeout(Duration::from_secs(20), channel.recv()).await.expect("echo in time") {
            Some(ChannelEvent::Data(bytes)) => echoed.extend_from_slice(&bytes),
            other => panic!("unexpected {other:?}"),
        }
    }
    assert_eq!(echoed, payload);
    let took = started.elapsed();
    // Let the Mac's label settle on the route its peer confirmed.
    tokio::time::sleep(Duration::from_millis(300)).await;
    let run = Run {
        phone: *connected.path.borrow(),
        mac: mac_path.lock().unwrap().as_ref().map(|path| *path.borrow()),
        took,
    };
    connected.link.close("done");
    Ok(run)
}

/// (a) A company network that inspects TLS: the TURN server's certificate
/// comes from the company's root, which an MDM profile made the OS trust.
/// The phone links through TURN over TLS. With the web PKI bundled in the
/// app alone (what the link trusted before), the same dial has no path.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_company_tls_inspection_root_the_os_trusts_carries_the_link() {
    let ca = TestCa::new();
    let turn = TestTurn::start_signed_by(&ca).await;
    let phone = |trust: TlsTrust| DialOptions {
        ice_servers: vec![turn.ice.clone()],
        block_udp: true,
        egress: Egress { trust, ..Egress::default() },
        ..options()
    };
    let run = link(phone(TlsTrust::SystemWith(ca.roots())), options(), &Egress::default())
        .await
        .expect("a link through the company's TLS inspection");
    assert_eq!(run.phone, LinkPath::TurnTls, "{run:?}");
    assert_eq!(run.mac, Some(LinkPath::TurnTls), "{run:?}");
    let refused = link(phone(TlsTrust::Bundled), options(), &Egress::default()).await;
    assert!(
        matches!(refused, Err(DialError::Transport(ref message)) if message.contains("TURN")),
        "the bundled web PKI alone accepted the company's root: {refused:?}"
    );
}

/// (b) A network whose only way out is its HTTP proxy: no UDP at all, and
/// every TCP connection (the signaling socket and TURN over TLS) goes through
/// `CONNECT`, with no sign-in or with Basic sign-in from the system's
/// settings. "Proxy only" never goes around it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_link_goes_through_the_system_http_proxy() {
    for auth in [ProxyAuth::None, ProxyAuth::Basic("ann@corp".into(), "s3cret:pw".into())] {
        let turn = TestTurn::start().await;
        let proxy = TestProxy::start(auth.clone()).await;
        let egress = Egress { proxy: proxy.config(), require_proxy: true, ..Egress::default() };
        let phone = DialOptions {
            ice_servers: vec![turn.ice.clone()],
            turn_tls_roots: Some(std::sync::Arc::clone(&turn.roots)),
            block_udp: true,
            egress: egress.clone(),
            ..options()
        };
        let run = link(phone, options(), &egress).await.unwrap_or_else(|error| panic!("{auth:?}: {error}"));
        assert_eq!(run.phone, LinkPath::TurnTls, "{auth:?}: {run:?}");
        let tunnels = proxy.tunnels();
        assert!(
            tunnels.contains(&turn.tls_address()),
            "{auth:?}: TURN over TLS did not use the proxy: {tunnels:?}"
        );
        // The signaling socket went through it too (to the fake service).
        assert!(tunnels.len() >= 2, "{auth:?}: the signaling socket did not use the proxy: {tunnels:?}");
        assert_eq!(proxy.refused(), 0, "{auth:?}");
    }
}

/// (b) A proxy that wants NTLM or Kerberos (Negotiate) sign-in, which the
/// link cannot do, and a Basic proxy with no password in the settings: the
/// dial fails at once with a sentence that names the proxy and what it
/// wants, not with a timeout 20 s later.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_proxy_the_link_cannot_sign_in_to_fails_the_dial_saying_why() {
    let turn = TestTurn::start().await;
    let cases = [
        (ProxyAuth::NtlmOrNegotiate, vec!["Negotiate", "NTLM", "sign-in"]),
        (ProxyAuth::Basic("ann".into(), "pw".into()), vec!["user name and password", "none"]),
    ];
    for (auth, words) in cases {
        let proxy = TestProxy::start(auth.clone()).await;
        // The settings name the proxy without its credentials.
        let egress = Egress {
            proxy: cmux_mobile_link::egress::ProxyConfig::Fixed(vec![cmux_mobile_link::egress::Hop::Http(
                proxy.server(),
            )]),
            require_proxy: true,
            ..Egress::default()
        };
        let phone = DialOptions {
            ice_servers: vec![turn.ice.clone()],
            turn_tls_roots: Some(std::sync::Arc::clone(&turn.roots)),
            block_udp: true,
            egress,
            ..options()
        };
        let started = Instant::now();
        // Signaling reaches the fake service directly here (its own proxy
        // answer is the same sentence; see the egress unit tests).
        let error = link(phone, options(), &Egress::default()).await.expect_err("no link");
        let took = started.elapsed();
        let DialError::Transport(message) = &error else { panic!("{auth:?}: {error:?}") };
        for word in &words {
            assert!(message.contains(word), "{auth:?}: {message:?} does not say {word:?}");
        }
        assert!(message.contains(&proxy.server().to_string()), "{auth:?}: {message:?} names no proxy");
        assert!(took < Duration::from_secs(5), "{auth:?}: said so after {took:?}");
        assert!(proxy.refused() >= 1, "{auth:?}");
    }
}

/// (c) A firewall whose packet inspection drops WireGuard: STUN answers and
/// TURN over UDP grants an allocation, so UDP looks open, but every
/// datagram that carries WireGuard is dropped, bare or relayed (ChannelData),
/// both ways. The tunnel hears nothing, takes TURN over TLS, and the link
/// comes up through it within `WITHIN` of the dial's start.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_firewall_that_drops_wireguard_still_links_over_turn_tls() {
    const WITHIN: Duration = Duration::from_secs(10);
    let turn = TestTurn::start().await;
    let dropped_before = dial::dropped_wireguard_datagrams();
    let phone = DialOptions {
        ice_servers: vec![turn.ice.clone(), turn.stun()],
        turn_tls_roots: Some(std::sync::Arc::clone(&turn.roots)),
        drop_wireguard_udp: true,
        ..options()
    };
    let mac = DialOptions {
        ice_servers: vec![turn.ice.clone()],
        turn_tls_roots: Some(std::sync::Arc::clone(&turn.roots)),
        ..options()
    };
    let run =
        link(phone, mac, &Egress::default()).await.expect("a link past the WireGuard-dropping firewall");
    eprintln!("WireGuard-dropping firewall: {run:?}");
    assert_eq!(run.phone, LinkPath::TurnTls, "{run:?}");
    assert_eq!(run.mac, Some(LinkPath::TurnTls), "{run:?}");
    assert!(run.took < WITHIN, "linked after {:?}, not within {WITHIN:?}", run.took);
    assert!(
        dial::dropped_wireguard_datagrams() > dropped_before,
        "the firewall dropped nothing: the test proves nothing"
    );
    assert!(turn.stream_connections() >= 1, "TURN over TLS never opened");
}
