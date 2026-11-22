//! The direct peer path (`DialOptions::direct_path`): while a TURN relay
//! carries the link, the direct routes keep being probed, so a direct path
//! that opens later (the Mac's Local Network permission granted, a tailnet
//! direct connection made) carries the link without a redial; and a direct
//! path that is cut still falls back to the relay without a long stall.

use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_mobile_link::dial::{self, SessionEvents};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling, TestTurn, is_test_relay};
use cmux_mobile_link::{ChannelEvent, DialOptions, LinkConfig, LinkPath, SignalingClient, TransportKind};
use tokio::sync::watch;

fn trace() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_test_writer()
        .try_init();
}

/// A Mac with `options` that echoes every channel.
async fn echo_mac(server: &FakeSignaling, options: DialOptions) -> String {
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    tokio::spawn(async move {
        let Some(session) = mac.next_session().await else { return };
        let events = SessionEvents {
            backend: mac.events(),
            session_id: session.first.session_id.clone(),
            session: session.events,
        };
        let connected =
            dial::answer(&mac, session.first, events, &options, LinkConfig::default()).await.unwrap();
        while let Some(mut incoming) = connected.link.accept().await {
            tokio::spawn(async move {
                while let Some(ChannelEvent::Data(bytes)) = incoming.channel.recv().await {
                    let _ = incoming.channel.send(bytes).await;
                }
            });
        }
    });
    mac_id
}

/// What a run saw: every echo's arrival, and every path the phone was on
/// with when it moved there.
struct Run {
    arrivals: Vec<Instant>,
    sent: usize,
    paths: Vec<(Instant, LinkPath)>,
}

/// Dial the Mac and stream 500-byte messages every 20 ms for `length`,
/// calling `during` (with the time the link came up) meanwhile.
async fn stream<F: std::future::Future<Output = ()>>(
    server: &FakeSignaling,
    mac_id: &str,
    options: &DialOptions,
    length: Duration,
    during: impl FnOnce(Instant) -> F,
) -> Run {
    let phone_id = uuid::Uuid::new_v4().to_string();
    let phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    let connected = dial::connect(&phone, mac_id, TransportKind::WireGuard, options, LinkConfig::default())
        .await
        .unwrap();
    let up = Instant::now();
    let paths = record_paths(connected.path.clone());
    let channel = connected.link.open("echo", serde_json::json!({})).await.unwrap();
    let (sender, mut receiver) = channel.split();
    let writer = tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_millis(20));
        let started = Instant::now();
        let mut sent = 0usize;
        while started.elapsed() < length {
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
    during(up).await;
    let (sent, _sender) = writer.await.unwrap();
    tokio::time::sleep(Duration::from_secs(2)).await;
    connected.link.close("done");
    let arrivals = reader.await.unwrap();
    let paths = paths.await.unwrap();
    Run { arrivals, sent, paths }
}

fn record_paths(mut path: watch::Receiver<LinkPath>) -> tokio::task::JoinHandle<Vec<(Instant, LinkPath)>> {
    tokio::spawn(async move {
        let mut seen = vec![(Instant::now(), *path.borrow_and_update())];
        while path.changed().await.is_ok() {
            seen.push((Instant::now(), *path.borrow_and_update()));
        }
        seen
    })
}

/// The longest gap between echoes from `from` on.
fn longest_stall(arrivals: &[Instant], from: Instant) -> Duration {
    let mut last = from;
    let mut stall = Duration::ZERO;
    for at in arrivals.iter().filter(|at| **at >= from) {
        stall = stall.max(at.duration_since(last));
        last = *at;
    }
    stall
}

/// When the phone first moved onto `want` at or after `from`.
fn moved_to(run: &Run, want: LinkPath, from: Instant) -> Option<Instant> {
    run.paths.iter().find(|(at, path)| *at >= from && *path == want).map(|(at, _)| *at)
}

fn base(direct_path: bool) -> DialOptions {
    DialOptions {
        include_loopback: true,
        timeout: Duration::from_secs(20),
        direct_path,
        ..DialOptions::default()
    }
}

static REFUSING: AtomicBool = AtomicBool::new(true);

/// The Mac's OS refuses UDP to the phone's direct addresses while
/// `REFUSING` is set (macOS Local Network privacy before the person allows
/// it); the phone's TURN relayed address is on the internet and works.
fn refuse_until_allowed(addr: &SocketAddr) -> bool {
    REFUSING.load(Ordering::Relaxed) && !is_test_relay(addr)
}

/// The Mac's Local Network permission is granted 3 s into a link the relay
/// carries: the link moves onto the direct path by itself, within the
/// upgrade schedule (0.25, 0.5, 1, 2 s, then every 5 s), with no stall.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_direct_path_that_opens_later_carries_the_link_without_a_redial() {
    trace();
    let turn = TestTurn::start().await;
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac = DialOptions { refuse_udp_to: Some(refuse_until_allowed), ..base(true) };
    let mac_id = echo_mac(&server, mac).await;
    let phone = DialOptions { ice_servers: vec![turn.udp_only()], ..base(true) };
    let allowed = std::sync::Arc::new(std::sync::Mutex::new(None));
    let allowed_at = allowed.clone();
    let run = stream(&server, &mac_id, &phone, Duration::from_secs(14), |_| async move {
        tokio::time::sleep(Duration::from_secs(3)).await;
        REFUSING.store(false, Ordering::Relaxed);
        *allowed_at.lock().unwrap() = Some(Instant::now());
    })
    .await;
    let allowed = allowed.lock().unwrap().expect("allowed");
    let before: Vec<LinkPath> =
        run.paths.iter().filter(|(at, _)| *at < allowed).map(|(_, path)| *path).collect();
    assert!(
        !before.contains(&LinkPath::Direct),
        "no direct path while the Mac's OS refuses it: {:?}",
        run.paths
    );
    assert!(before.contains(&LinkPath::Turn), "the relay carries the link first: {:?}", run.paths);
    let direct = moved_to(&run, LinkPath::Direct, allowed)
        .unwrap_or_else(|| panic!("moves to the direct path: {:?}", run.paths));
    let took = direct.duration_since(allowed);
    assert!(took <= Duration::from_secs(7), "direct {took:?} after the permission");
    assert_eq!(run.arrivals.len(), run.sent, "every message comes back");
    let stall = longest_stall(&run.arrivals, allowed);
    assert!(stall < Duration::from_secs(1), "stalled {stall:?} across the upgrade");
}

/// Direct datagrams (both ways) vanish while `flag` is set; relayed ones
/// always arrive, 10 ms late each way.
fn impair_while(flag: &AtomicBool, via_turn: bool, from: &SocketAddr) -> Option<Duration> {
    if via_turn || is_test_relay(from) {
        Some(Duration::from_millis(10))
    } else if flag.load(Ordering::Relaxed) {
        None
    } else {
        Some(Duration::ZERO)
    }
}

/// Dial with direct datagrams lost both ways (a tailnet that has no direct
/// connection yet, a Wi-Fi that isolates its clients for a while) and open
/// the direct path 3 s in; returns the run and when it opened.
async fn blocked_then_open(
    direct_path: bool,
    blocked: &'static AtomicBool,
    impair: fn(bool, &SocketAddr) -> Option<Duration>,
) -> (Run, Instant) {
    let turn = TestTurn::start().await;
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let options =
        DialOptions { ice_servers: vec![turn.udp_only()], impair_inbound: Some(impair), ..base(direct_path) };
    let mac_id = echo_mac(&server, options.clone()).await;
    let opened = std::sync::Arc::new(std::sync::Mutex::new(None));
    let opened_at = opened.clone();
    let run = stream(&server, &mac_id, &options, Duration::from_secs(12), |_| async move {
        tokio::time::sleep(Duration::from_secs(3)).await;
        blocked.store(false, Ordering::Relaxed);
        *opened_at.lock().unwrap() = Some(Instant::now());
    })
    .await;
    let opened = opened.lock().unwrap().expect("opened");
    (run, opened)
}

static BLOCKED_ON: AtomicBool = AtomicBool::new(true);

/// Direct is blocked for the first 3 s, then opens: with the flag the link
/// moves from the relay to the direct path within the upgrade schedule,
/// with no stall.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_blocked_direct_path_that_opens_is_adopted_from_the_relay() {
    trace();
    let (run, opened) =
        blocked_then_open(true, &BLOCKED_ON, |turn, from| impair_while(&BLOCKED_ON, turn, from)).await;
    let before: Vec<LinkPath> =
        run.paths.iter().filter(|(at, _)| *at < opened).map(|(_, path)| *path).collect();
    assert!(!before.contains(&LinkPath::Direct), "no direct path while blocked: {:?}", run.paths);
    let direct = moved_to(&run, LinkPath::Direct, opened)
        .unwrap_or_else(|| panic!("moves to the direct path: {:?}", run.paths));
    let took = direct.duration_since(opened);
    assert!(took <= Duration::from_secs(7), "direct {took:?} after it opened");
    assert_eq!(run.arrivals.len(), run.sent, "every message comes back");
    let stall = longest_stall(&run.arrivals, opened);
    assert!(stall < Duration::from_secs(1), "stalled {stall:?} across the upgrade");
}

static CUT_ON: AtomicBool = AtomicBool::new(false);

/// Stream on a link whose direct path is cut 2 s in (both ways; the relay
/// stays up) and heals 6 s later; returns the run, the cut and the heal.
async fn cut_and_heal(
    direct_path: bool,
    cut: &'static AtomicBool,
    impair: fn(bool, &SocketAddr) -> Option<Duration>,
) -> (Run, Instant, Instant) {
    let turn = TestTurn::start().await;
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let options =
        DialOptions { ice_servers: vec![turn.udp_only()], impair_inbound: Some(impair), ..base(direct_path) };
    let mac_id = echo_mac(&server, options.clone()).await;
    let marks = std::sync::Arc::new(std::sync::Mutex::new((None, None)));
    let marks_in = marks.clone();
    let run = stream(&server, &mac_id, &options, Duration::from_secs(16), |_| async move {
        tokio::time::sleep(Duration::from_secs(2)).await;
        marks_in.lock().unwrap().0 = Some(Instant::now());
        cut.store(true, Ordering::Relaxed);
        tokio::time::sleep(Duration::from_secs(6)).await;
        marks_in.lock().unwrap().1 = Some(Instant::now());
        cut.store(false, Ordering::Relaxed);
    })
    .await;
    let (cut_at, healed) = *marks.lock().unwrap();
    (run, cut_at.expect("cut"), healed.expect("healed"))
}

/// With the flag on, a cut direct path still moves to the relay within the
/// quiet-path window (no stall over 3 s), and once the cut heals the
/// link comes back onto the direct path within the upgrade schedule (by
/// then the path is dead: the upgrade probes do not wait for its 30 s
/// turn, nor for the peer to send on it).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_cut_direct_path_falls_back_to_the_relay_and_comes_back() {
    trace();
    let (run, cut, healed) =
        cut_and_heal(true, &CUT_ON, |turn, from| impair_while(&CUT_ON, turn, from)).await;
    let before: Vec<LinkPath> = run.paths.iter().filter(|(at, _)| *at < cut).map(|(_, path)| *path).collect();
    assert_eq!(before.last(), Some(&LinkPath::Direct), "direct before the cut: {:?}", run.paths);
    let relay = run
        .paths
        .iter()
        .find(|(at, path)| *at >= cut && *at < healed && *path == LinkPath::Turn)
        .unwrap_or_else(|| panic!("the relay takes over during the cut: {:?}", run.paths));
    assert!(relay.0.duration_since(cut) <= Duration::from_secs(5), "relay {:?} after the cut", relay.0 - cut);
    assert_eq!(run.arrivals.len(), run.sent, "every message comes back");
    let stall = longest_stall(&run.arrivals, cut);
    assert!(stall < Duration::from_secs(3), "stalled {stall:?} after the cut");
    let back = moved_to(&run, LinkPath::Direct, healed)
        .unwrap_or_else(|| panic!("back on the direct path after the cut heals: {:?}", run.paths));
    assert!(
        back.duration_since(healed) <= Duration::from_secs(7),
        "direct {:?} after healing",
        back - healed
    );
}
