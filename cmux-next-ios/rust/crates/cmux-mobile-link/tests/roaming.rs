//! WireGuard roaming: the phone's network changes in the middle of a
//! stream (its socket stops working and, with a roam, a new one takes
//! over). The stream must go on with no data lost and no stall a user
//! would notice.

use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_mobile_link::dial::{self, SessionEvents, wireguard};
use cmux_mobile_link::testing::{
    FakeOptions, FakeSignaling, LinkProfile, TestTurn, set_link_profile, shape_by_profile, shaped_counts,
};
use cmux_mobile_link::{ChannelEvent, DialOptions, LinkConfig, LinkPath, SignalingClient, TransportKind};

fn options() -> DialOptions {
    DialOptions { include_loopback: true, timeout: Duration::from_secs(20), ..DialOptions::default() }
}

/// What a measurement puts the link under besides its blackout, named in
/// every line it prints.
#[derive(Clone, Copy, Debug, Default)]
struct Duress {
    /// Every datagram either tunnel receives goes through the link profile
    /// set by `testing::set_link_profile` (cmux-fault's `link-profiles.json`,
    /// the profiles cmux#49310's `UdpShaper` plays).
    shaped: bool,
    /// The Mac streams terminal rows to the phone the whole run
    /// ([`STREAM_ROWS_PER_SECOND`]).
    stream: bool,
}

/// [`options`], with the tunnel's received datagrams on the link profile
/// when `duress.shaped`.
fn duress_options(duress: Duress) -> DialOptions {
    if !duress.shaped {
        return options();
    }
    // A lost handshake message costs WireGuard a 5 s retry: room for a few.
    DialOptions { impair_inbound: Some(shape_by_profile), timeout: Duration::from_secs(40), ..options() }
}

/// A long streaming session: the Mac writes this many terminal rows a
/// second (a build log, `cat` of a large file), in frames of
/// [`STREAM_ROWS_PER_FRAME`], about 2 Mbit/s with framing.
const STREAM_ROWS_PER_SECOND: u64 = 2000;
const STREAM_ROWS_PER_FRAME: u64 = 20;
/// One row: 120 bytes, as a wide terminal line.
const STREAM_ROW_BYTES: usize = 120;

/// The Mac's side of a `stream` channel: rows at [`STREAM_ROWS_PER_SECOND`]
/// until the channel closes. A send that waits (the link backed up, a
/// blackout) holds the producer, as a pty's reader would; it never catches
/// up in a burst.
async fn stream_rows(channel: cmux_mobile_link::Channel) {
    let (sender, _receiver) = channel.split();
    let interval = Duration::from_micros(1_000_000 * STREAM_ROWS_PER_FRAME / STREAM_ROWS_PER_SECOND);
    let mut tick = tokio::time::interval(interval);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut row = 0u64;
    loop {
        tick.tick().await;
        let mut frame = Vec::with_capacity(STREAM_ROW_BYTES * STREAM_ROWS_PER_FRAME as usize);
        for _ in 0..STREAM_ROWS_PER_FRAME {
            let line = format!("{row:010} ");
            frame.extend_from_slice(line.as_bytes());
            frame.resize(frame.len() + STREAM_ROW_BYTES - line.len() - 2, b'x');
            frame.extend_from_slice(b"\r\n");
            row += 1;
        }
        if sender.send(Bytes::from(frame)).await.is_err() {
            return;
        }
    }
}

/// The phone's side of a `stream` channel: counts rows; the arrival times
/// of every frame go to `arrivals`.
fn read_rows(
    channel: cmux_mobile_link::Channel,
    rows: std::sync::Arc<std::sync::atomic::AtomicU64>,
    arrivals: Option<std::sync::Arc<std::sync::Mutex<Vec<Instant>>>>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let (_sender, mut receiver) = channel.split();
        while let Some(ChannelEvent::Data(bytes)) = receiver.recv().await {
            if let Some(arrivals) = &arrivals {
                arrivals.lock().unwrap().push(Instant::now());
            }
            rows.fetch_add((bytes.len() / STREAM_ROW_BYTES) as u64, std::sync::atomic::Ordering::Relaxed);
        }
    })
}

/// Bytes `[start, start + len)` of the endless test pattern.
fn pattern(start: usize, len: usize) -> Vec<u8> {
    (start..start + len).map(|i| (i % 251) as u8).collect()
}

/// What a run measured.
#[derive(Debug)]
struct Run {
    /// The longest time no echoed byte arrived, from the network change on.
    stall: Duration,
    /// The phone's path before the change and at the end.
    before: LinkPath,
    after: LinkPath,
    /// The Mac's label of the same path before the change and at the end.
    mac_before: Option<LinkPath>,
    mac_after: Option<LinkPath>,
    /// The endpoints the phone told the Mac before the change and at the end.
    endpoints_before: Vec<String>,
    endpoints_after: Vec<String>,
    /// The endpoints the Mac told the phone before the change and at the end.
    mac_endpoints_before: Vec<String>,
    mac_endpoints_after: Vec<String>,
    marks: Vec<(String, Duration)>,
}

/// What happens to the phone at 1 s.
#[derive(Clone)]
enum Change {
    /// Its network goes away; it roams this much later (as the OS reports
    /// the new path), or never.
    Network(Option<Duration>),
    /// The backend drops its signaling socket; it opens a new one and the
    /// session moves there.
    Signaling,
    /// The TCP or TLS stream of its TURN allocation dies; the session takes
    /// a new allocation.
    TurnStream,
    /// Its network starts dropping UDP to the TURN server (`TestTurn`
    /// blocks it), and it roams: the new allocation must use TLS. With a
    /// delay, UDP to the server comes back that much later.
    UdpBlocked(std::sync::Arc<TestTurn>, Option<Duration>),
    /// As `UdpBlocked`, but the Mac moves to that network and roams (the
    /// phone's network stays as it was).
    MacUdpBlocked(std::sync::Arc<TestTurn>, Option<Duration>),
}

/// Stream through an echo channel, take the phone's network away at 1 s
/// (and roam `roam` later, as the OS reports the new path), keep streaming
/// for `after_change`, then check every byte came back in order.
async fn stream_across_a_change(
    phone_options: DialOptions,
    mac_options: DialOptions,
    roam: Option<Duration>,
    after_change: Duration,
) -> Run {
    stream_across(phone_options, mac_options, Change::Network(roam), after_change).await
}

async fn stream_across(
    phone_options: DialOptions,
    mac_options: DialOptions,
    change: Change,
    after_change: Duration,
) -> Run {
    // `RUST_LOG=cmux_mobile_link=debug` shows what the tunnel did around a stall.
    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_test_writer()
        .try_init();
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let mac_path = std::sync::Arc::new(std::sync::Mutex::new(None::<tokio::sync::watch::Receiver<LinkPath>>));
    let mac_path_slot = std::sync::Arc::clone(&mac_path);
    tokio::spawn(async move {
        while let Some(session) = mac.next_session().await {
            let events = SessionEvents {
                backend: mac.events(),
                session_id: session.first.session_id.clone(),
                session: session.events,
            };
            let (mac, options) = (mac.clone(), mac_options.clone());
            let mac_path_slot = std::sync::Arc::clone(&mac_path_slot);
            tokio::spawn(async move {
                let connected =
                    dial::answer(&mac, session.first, events, &options, LinkConfig::default()).await.unwrap();
                *mac_path_slot.lock().unwrap() = Some(connected.path.clone());
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
    let session_id = connected.session_id.clone();
    let mut path = connected.path.clone();
    let _ = tokio::time::timeout(Duration::from_secs(10), path.wait_for(|p| *p != LinkPath::NoPath)).await;
    let channel = connected.link.open("echo", serde_json::json!({})).await.unwrap();
    let (sender, mut receiver) = channel.split();

    // Terminal-like output: 1 KB every 10 ms.
    const CHUNK: usize = 1000;
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let writer = {
        let stop = std::sync::Arc::clone(&stop);
        tokio::spawn(async move {
            let mut sent = 0usize;
            let mut tick = tokio::time::interval(Duration::from_millis(10));
            while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                tick.tick().await;
                sender.send(Bytes::from(pattern(sent, CHUNK))).await.expect("send");
                sent += CHUNK;
            }
            // Dropping the sender would close the channel before the echo
            // of the last bytes arrives.
            (sent, sender)
        })
    };
    let (progress_tx, mut progress) = tokio::sync::watch::channel(0usize);
    let reader = tokio::spawn(async move {
        let mut got = 0usize;
        let mut arrivals = Vec::new();
        while let Some(event) = receiver.recv().await {
            match event {
                ChannelEvent::Data(bytes) => {
                    assert_eq!(&bytes[..], &pattern(got, bytes.len())[..], "echo out of order at {got}");
                    got += bytes.len();
                    arrivals.push(Instant::now());
                    progress_tx.send_replace(got);
                }
                ChannelEvent::Closed(_) => break,
            }
        }
        arrivals
    });

    tokio::time::sleep(Duration::from_secs(1)).await;
    let before = *connected.path.borrow();
    let mac_label = || mac_path.lock().unwrap().as_ref().map(|path| *path.borrow());
    let mac_before = mac_label();
    let endpoints_of = |dialer| wireguard::session_endpoints(&session_id, dialer).unwrap_or_default();
    let (endpoints_before, mac_endpoints_before) = (endpoints_of(true), endpoints_of(false));
    let phone_roams = !matches!(change, Change::MacUdpBlocked(..));
    let changed_at = Instant::now();
    let mut _new_phone = None;
    let roam_task = match change {
        Change::Network(roam) => {
            assert_eq!(wireguard::simulate_network_loss(Some(&session_id), true), 1);
            roam.map(|delay| {
                let session_id = session_id.clone();
                tokio::spawn(async move {
                    tokio::time::sleep(delay).await;
                    wireguard::roam_session(&session_id, true).await
                })
            })
        }
        Change::Signaling => {
            server.kick(&phone_id);
            let mut closed = phone.events();
            while !matches!(
                closed.recv().await,
                Ok(cmux_mobile_link::signaling::SignalingEvent::Disconnected(_))
            ) {}
            let fresh =
                SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
            assert!(wireguard::rehome(&fresh) >= 1);
            _new_phone = Some(fresh);
            None
        }
        Change::TurnStream => {
            assert_eq!(wireguard::simulate_turn_loss(Some(&session_id), true), 1);
            None
        }
        Change::UdpBlocked(turn, unblock) | Change::MacUdpBlocked(turn, unblock) => {
            turn.set_udp_blocked(true);
            if let Some(delay) = unblock {
                tokio::spawn(async move {
                    tokio::time::sleep(delay).await;
                    turn.set_udp_blocked(false);
                });
            }
            if phone_roams {
                assert_eq!(wireguard::simulate_network_loss(Some(&session_id), true), 1);
            }
            let session_id = session_id.clone();
            Some(tokio::spawn(async move { wireguard::roam_session(&session_id, phone_roams).await }))
        }
    };
    tokio::time::sleep(after_change).await;
    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    let (sent, _sender) = writer.await.unwrap();
    let timeline = match roam_task {
        Some(task) => task.await.unwrap(),
        None => None,
    };
    // Every byte comes back.
    let all =
        tokio::time::timeout(Duration::from_secs(25), progress.wait_for(|got| *got >= sent)).await.is_ok();
    let got = *progress.borrow();
    let (endpoints_after, mac_endpoints_after) = (endpoints_of(true), endpoints_of(false));
    connected.link.close("done");
    let arrivals = reader.await.unwrap();
    assert!(all && got == sent, "bytes lost: sent {sent}, echoed {got}");
    let mut last = changed_at;
    let mut stall = Duration::ZERO;
    for at in arrivals.iter().filter(|at| **at >= changed_at) {
        stall = stall.max(at.duration_since(last));
        last = *at;
    }
    let after = *connected.path.borrow();
    let mac_after = mac_label();
    Run {
        stall,
        before,
        after,
        mac_before,
        mac_after,
        endpoints_before,
        endpoints_after,
        mac_endpoints_before,
        mac_endpoints_after,
        marks: timeline.map(|t| t.marks()).unwrap_or_default(),
    }
}

fn names(run: &Run) -> Vec<&str> {
    run.marks.iter().map(|(name, _)| name.as_str()).collect()
}

/// Plain roam: the phone moves to a new socket (a new local port, as on a
/// new network). The Mac roams with WireGuard's endpoint roaming the moment
/// the phone's first datagram from the new socket authenticates.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_roams_to_a_new_socket_without_a_stall() {
    let run =
        stream_across_a_change(options(), options(), Some(Duration::ZERO), Duration::from_secs(3)).await;
    eprintln!("roam: {run:?}");
    assert_eq!(run.before, LinkPath::Direct);
    assert_eq!(run.after, LinkPath::Direct);
    assert_eq!(run.mac_after, Some(LinkPath::Direct));
    assert!(run.stall < Duration::from_secs(1), "stalled {:?}", run.stall);
    for mark in ["network_changed", "roam_reasserted", "roam_first_packet", "roam_direct"] {
        assert!(names(&run).contains(&mark), "no {mark} in {:?}", run.marks);
    }
}

/// The Mac sits behind an address-restricted NAT: it drops the phone's UDP
/// from the new address until it has sent there itself. Only the phone's
/// endpoint announcement (inside the tunnel, over its new route) lets
/// the Mac open its side.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_roams_through_an_address_restricted_nat() {
    let mac = DialOptions { restrict_inbound_udp: true, ..options() };
    let run = stream_across_a_change(options(), mac, Some(Duration::ZERO), Duration::from_secs(3)).await;
    eprintln!("restricted roam: {run:?}");
    assert_eq!(run.before, LinkPath::Direct);
    assert_eq!(run.after, LinkPath::Direct);
    assert!(run.stall < Duration::from_secs(1), "stalled {:?}", run.stall);
}

/// Relay only through TURN: the roam takes a fresh allocation (the old one
/// belongs to the old network) and the Mac follows the new relayed address.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_roam_takes_a_fresh_turn_allocation() {
    let turn = TestTurn::start().await;
    let phone = DialOptions { relay_only: true, ice_servers: vec![turn.udp_only()], ..options() };
    let run = stream_across_a_change(phone, options(), Some(Duration::ZERO), Duration::from_secs(3)).await;
    eprintln!("turn roam: {run:?}");
    assert_eq!(run.before, LinkPath::Turn);
    assert_eq!(run.after, LinkPath::Turn);
    // The Mac sends plain UDP to the phone's relayed address: still TURN,
    // also after the roam's new allocation (wg-init and the roam's
    // endpoint announcement say which address is relayed).
    assert_eq!(run.mac_before, Some(LinkPath::Turn));
    assert_eq!(run.mac_after, Some(LinkPath::Turn));
    assert!(run.stall < Duration::from_secs(1), "stalled {:?}", run.stall);
    for mark in ["roam_turn_allocated", "roam_first_packet", "roam_turn"] {
        assert!(names(&run).contains(&mark), "no {mark} in {:?}", run.marks);
    }
}

/// The phone's plain UDP reaches only TURN relayed addresses (a symmetric
/// CGNAT in front of a port-restricted Mac: no direct path, and STUN goes
/// unanswered). Its roam's TURN allocation comes back within a round trip;
/// the roam installs and announces it then, not after the STUN wait
/// (1.5 s) that the silent server runs out. Before, the allocation sat
/// unused for that wait and the stream stalled about 2 s (netlab `move`).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_roam_uses_its_turn_allocation_without_waiting_out_stun() {
    fn only_relays(addr: &std::net::SocketAddr) -> bool {
        !cmux_mobile_link::testing::is_test_relay(addr)
    }
    let turn = TestTurn::start().await;
    // A STUN server that never answers (as when the new network's route is
    // not up yet for the roam's one request, or the request is lost).
    let silent = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    let stun = cmux_mobile_link::api::IceServer {
        urls: vec![format!("stun:{}", silent.local_addr().unwrap())],
        ..turn.udp_only()
    };
    let phone =
        DialOptions { ice_servers: vec![turn.udp_only(), stun], drop_udp_to: Some(only_relays), ..options() };
    let run = stream_across_a_change(phone, options(), Some(Duration::ZERO), Duration::from_secs(4)).await;
    eprintln!("stun-silent roam: {run:?}");
    assert_eq!(run.after, LinkPath::Turn);
    let at = |name: &str| run.marks.iter().find(|(mark, _)| mark == name).map(|(_, at)| *at);
    let allocated = at("roam_turn_allocated").unwrap_or_else(|| panic!("no allocation: {:?}", run.marks));
    assert!(allocated < Duration::from_millis(700), "allocation installed at {allocated:?}: {:?}", run.marks);
    assert!(run.stall < Duration::from_millis(1000), "stalled {:?}", run.stall);
}

/// The OS reports the new path 300 ms after the old network died: what
/// was sent into the dead network meanwhile is sent again, so the stall is
/// that delay plus a round trip, not TCP's 1 s retransmission timeout.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_roams_after_a_late_path_update() {
    let mac = DialOptions { restrict_inbound_udp: true, ..options() };
    let run =
        stream_across_a_change(options(), mac, Some(Duration::from_millis(300)), Duration::from_secs(3))
            .await;
    eprintln!("late roam: {run:?}");
    assert_eq!(run.after, LinkPath::Direct);
    assert!(run.stall < Duration::from_millis(600), "stalled {:?}", run.stall);
}

/// Airplane mode for 5 s, then the network comes back: the same session
/// resumes (no redial), and TCP inside it does not wait out a backed-off
/// retransmission timeout.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_resumes_after_airplane_mode() {
    let run =
        stream_across_a_change(options(), options(), Some(Duration::from_secs(5)), Duration::from_secs(7))
            .await;
    eprintln!("airplane: {run:?}");
    assert_eq!(run.after, LinkPath::Direct);
    assert!(run.stall < Duration::from_millis(5500), "stalled {:?}", run.stall);
}

/// The backend drops the phone's signaling socket, as a network change
/// does. The tunnel never used it for data: the stream goes on, and the
/// session moves to the new socket (for `bye`).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_session_follows_a_new_signaling_socket() {
    let run = stream_across(options(), options(), Change::Signaling, Duration::from_secs(3)).await;
    eprintln!("rehome: {run:?}");
    assert_eq!(run.after, LinkPath::Direct);
    assert!(run.stall < Duration::from_millis(500), "stalled {:?}", run.stall);
}

/// A TCP relay between a signaling client and the fake backend that can go dark: every byte
/// either way is then read and dropped, and the connection stays open (a phone's socket on a
/// network it left: half open, never answering).
struct DarkableRelay {
    base_url: String,
    dark: std::sync::Arc<std::sync::atomic::AtomicBool>,
}

impl DarkableRelay {
    async fn start(upstream_base_url: &str) -> Self {
        let upstream = upstream_base_url.trim_start_matches("http://").to_owned();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base_url = format!("http://{}", listener.local_addr().unwrap());
        let dark = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let relay_dark = std::sync::Arc::clone(&dark);
        tokio::spawn(async move {
            while let Ok((client, _)) = listener.accept().await {
                let Ok(server) = tokio::net::TcpStream::connect(&upstream).await else { continue };
                let (client_read, client_write) = client.into_split();
                let (server_read, server_write) = server.into_split();
                for (mut from, mut to) in [(client_read, server_write), (server_read, client_write)] {
                    let dark = std::sync::Arc::clone(&relay_dark);
                    tokio::spawn(async move {
                        use tokio::io::{AsyncReadExt, AsyncWriteExt};
                        let mut buffer = vec![0u8; 16 * 1024];
                        loop {
                            let read = match from.read(&mut buffer).await {
                                Ok(0) | Err(_) => break,
                                Ok(read) => read,
                            };
                            if !dark.load(std::sync::atomic::Ordering::Relaxed)
                                && to.write_all(&buffer[..read]).await.is_err()
                            {
                                break;
                            }
                        }
                        // Keep the other half open: a dead path never says it is closed.
                        std::future::pending::<()>().await;
                        drop(to);
                    });
                }
            }
        });
        Self { base_url, dark }
    }

    fn go_dark(&self) {
        self.dark.store(true, std::sync::atomic::Ordering::Relaxed);
    }
}

/// A network change with the phone's signaling socket half open on the network it left: the new
/// socket opens at once and the session moves onto it, without first waiting out a probe of the
/// old one. Probing first put the probe's whole window (`network_probe`, 300 ms to 1 s) before
/// the new socket, and only the new socket carries the phone's new address to a port-restricted
/// Mac (netlab `move`: the rehome landed about 1.2 s after the change).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_network_change_opens_new_signaling_without_waiting_for_the_old_ones_probe() {
    use cmux_mobile_link::signaling::{AfterNetworkChange, after_network_change, network_probe};
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let relay = DarkableRelay::start(&server.base_url).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    tokio::spawn(async move {
        while let Some(session) = mac.next_session().await {
            let events = SessionEvents {
                backend: mac.events(),
                session_id: session.first.session_id.clone(),
                session: session.events,
            };
            let mac = mac.clone();
            tokio::spawn(async move {
                let connected = dial::answer(&mac, session.first, events, &options(), LinkConfig::default())
                    .await
                    .unwrap();
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
    let old = SignalingClient::connect(&relay.base_url, "user:alice", "team", &phone_id).await.unwrap();
    let connected = dial::connect(&old, &mac_id, TransportKind::WireGuard, &options(), LinkConfig::default())
        .await
        .expect("dial");
    let session_id = connected.session_id.clone();
    // The old socket has timed a pong: the window its probe would get.
    let deadline = Instant::now() + Duration::from_secs(5);
    while old.rtt().is_none() && Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let probe_window = network_probe(old.rtt());

    relay.go_dark();
    let changed_at = Instant::now();
    // This session's roam only: the process-wide `network_changed` would roam the sessions of the
    // tests running beside this one.
    let roam = {
        let session_id = session_id.clone();
        tokio::spawn(async move { wireguard::roam_session(&session_id, true).await })
    };
    let (base_url, phone) = (server.base_url.clone(), phone_id.clone());
    let open = async move { SignalingClient::connect(&base_url, "user:alice", "team", &phone).await };
    let fresh = match after_network_change(Some(&old), open).await {
        AfterNetworkChange::Opened(fresh) => fresh,
        other => panic!("no new signaling socket after the change: {other:?}"),
    };
    assert!(wireguard::rehome(&fresh) >= 1, "the session did not move onto the new socket");
    let rehomed = changed_at.elapsed();
    eprintln!("rehomed {rehomed:?} after the change (the old socket's probe window: {probe_window:?})");
    assert!(
        rehomed < probe_window,
        "the new signaling socket waited for the old one's probe: rehomed {rehomed:?}, probe window {probe_window:?}"
    );
    let _ = roam.await;
    assert!(wireguard::session_endpoints(&session_id, true).is_some());

    // The link still carries data after the change.
    let channel = connected.link.open("echo", serde_json::json!({})).await.unwrap();
    let (sender, mut receiver) = channel.split();
    sender.send(Bytes::from_static(b"after the change")).await.unwrap();
    let echoed = tokio::time::timeout(Duration::from_secs(10), receiver.recv()).await;
    assert!(matches!(echoed, Ok(Some(ChannelEvent::Data(_)))), "no echo after the change: {echoed:?}");
    connected.link.close("done");
    fresh.close();
}

/// UDP blocked: the roam takes a fresh TURN allocation over TLS, and the
/// Mac follows the new relayed address (still labeled TURN over TLS).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_roam_with_udp_blocked_takes_a_fresh_turn_tls_allocation() {
    let turn = TestTurn::start().await;
    let phone = DialOptions {
        block_udp: true,
        ice_servers: vec![turn.ice.clone()],
        turn_tls_roots: Some(std::sync::Arc::clone(&turn.roots)),
        ..options()
    };
    let run = stream_across_a_change(phone, options(), Some(Duration::ZERO), Duration::from_secs(3)).await;
    eprintln!("turn-tls roam: {run:?}");
    assert_eq!(run.before, LinkPath::TurnTls);
    assert_eq!(run.after, LinkPath::TurnTls);
    assert_eq!(run.mac_before, Some(LinkPath::TurnTls));
    assert_eq!(run.mac_after, Some(LinkPath::TurnTls));
    assert!(run.stall < Duration::from_secs(1), "stalled {:?}", run.stall);
    assert_eq!(turn.stream_connections(), 2, "the roam did not take a new TLS allocation");
    for mark in ["roam_turn_tls_allocated", "roam_first_packet", "roam_turn"] {
        assert!(names(&run).contains(&mark), "no {mark} in {:?}", run.marks);
    }
}

/// Roaming across TURN transports: the phone rides TURN over UDP, then
/// moves to a network that drops UDP. The roam's new allocation falls back
/// to TLS and the stream goes on with every byte.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_roams_from_turn_udp_to_turn_tls() {
    let turn = std::sync::Arc::new(TestTurn::start().await);
    let phone = DialOptions {
        relay_only: true,
        ice_servers: vec![turn.ice.clone()],
        turn_tls_roots: Some(std::sync::Arc::clone(&turn.roots)),
        ..options()
    };
    let run = stream_across(
        phone,
        options(),
        Change::UdpBlocked(std::sync::Arc::clone(&turn), None),
        Duration::from_secs(4),
    )
    .await;
    eprintln!("udp to tls roam: {run:?}");
    assert_eq!(run.before, LinkPath::Turn);
    assert_eq!(run.after, LinkPath::TurnTls);
    assert_eq!(run.mac_after, Some(LinkPath::TurnTls));
    // The UDP attempt waits out its stagger before TLS starts.
    assert!(run.stall < Duration::from_secs(3), "stalled {:?}", run.stall);
    assert!(names(&run).contains(&"roam_turn_tls_allocated"), "{:?}", run.marks);
}

/// Relay only through TURN over UDP, and the new network drops UDP to the
/// TURN server for 3 s: the roam's own allocation times out. The session
/// keeps asking for one, and once the server answers the stream goes on
/// through it (it does not wait for the next network change).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_takes_the_turn_allocation_its_roam_missed() {
    let turn = std::sync::Arc::new(TestTurn::start().await);
    let phone = DialOptions { relay_only: true, ice_servers: vec![turn.udp_only()], ..options() };
    let run = stream_across(
        phone,
        options(),
        Change::UdpBlocked(std::sync::Arc::clone(&turn), Some(Duration::from_secs(3))),
        Duration::from_secs(8),
    )
    .await;
    eprintln!("missed roam allocation: {run:?}");
    assert_eq!(run.before, LinkPath::Turn);
    assert_eq!(run.after, LinkPath::Turn);
    assert_eq!(run.mac_after, Some(LinkPath::Turn));
    assert!(!names(&run).contains(&"roam_turn_allocated"), "the roam was meant to miss: {:?}", run.marks);
    // The old network's relayed address is dead: the phone no longer offers it.
    assert!(!run.endpoints_before.is_empty() && !run.endpoints_after.is_empty(), "{run:?}");
    assert!(run.endpoints_before.iter().all(|old| !run.endpoints_after.contains(old)), "{run:?}");
}

/// The Mac answered on a network whose STUN server answers (so it took no
/// TURN allocation), then roams onto one that drops UDP to the server, STUN
/// and TURN alike, for 6 s. The roam asks for an allocation and misses it;
/// the session keeps asking and offers the phone the relayed address once
/// the server answers (it does not wait for the next network change).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_mac_takes_the_turn_allocation_its_stun_silent_roam_missed() {
    let turn = std::sync::Arc::new(TestTurn::start().await);
    // The TURN server answers STUN on its UDP port too.
    let stun = cmux_mobile_link::api::IceServer {
        urls: vec![turn.ice.urls[0].replacen("turn:", "stun:", 1)],
        ..turn.udp_only()
    };
    let mac = DialOptions { ice_servers: vec![turn.udp_only(), stun], ..options() };
    let run = stream_across(
        options(),
        mac,
        Change::MacUdpBlocked(std::sync::Arc::clone(&turn), Some(Duration::from_secs(6))),
        Duration::from_secs(10),
    )
    .await;
    eprintln!("stun-silent Mac roam: {run:?}");
    let relayed = |endpoints: &[String]| {
        endpoints
            .iter()
            .any(|endpoint| endpoint.parse::<std::net::SocketAddr>().is_ok_and(|addr| turn.is_relayed(&addr)))
    };
    assert!(!run.mac_endpoints_before.is_empty() && !relayed(&run.mac_endpoints_before), "{run:?}");
    // Its STUN wait (1.5 s) and allocation window (2 s) end well before 6 s.
    assert!(!names(&run).contains(&"roam_turn_allocated"), "the roam was meant to miss: {:?}", run.marks);
    assert!(relayed(&run.mac_endpoints_after), "the Mac never took an allocation: {run:?}");
}

/// The TLS stream to the TURN server dies (a middlebox resets it) without
/// any network change: the session takes a new allocation, tells the Mac,
/// and resends what went into the dead one.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_replaces_a_dead_turn_tls_stream() {
    let turn = TestTurn::start().await;
    let phone = DialOptions {
        block_udp: true,
        ice_servers: vec![turn.ice.clone()],
        turn_tls_roots: Some(std::sync::Arc::clone(&turn.roots)),
        ..options()
    };
    let run = stream_across(phone, options(), Change::TurnStream, Duration::from_secs(3)).await;
    eprintln!("dead TLS stream: {run:?}");
    assert_eq!(run.after, LinkPath::TurnTls);
    assert_eq!(run.mac_after, Some(LinkPath::TurnTls));
    assert_eq!(turn.stream_connections(), 2);
    assert!(run.stall < Duration::from_secs(2), "stalled {:?}", run.stall);
}

/// The baseline: the network goes away and nothing roams. With no TURN
/// server and no backend relay (retired), nothing carries the stream again
/// without a roam: the bytes sent meanwhile never come back. Run with
/// `--ignored` to see it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "takes about 35 s; the before-roaming baseline"]
#[should_panic(expected = "bytes lost")]
async fn wireguard_without_roaming_never_recovers() {
    let _ = stream_across_a_change(options(), options(), None, Duration::from_secs(5)).await;
}

/// What a blackout run measured.
#[derive(Debug)]
struct Blackout {
    /// From the network coming back to the first app frame the Mac read
    /// (phone to Mac) and the first echo the phone read (Mac to phone), on
    /// the link dialed before the blackout. `None`: none arrived.
    first_frame_up: Option<Duration>,
    first_frame_down: Option<Duration>,
    /// Why either end of the link closed, if it did.
    phone_closed: Option<String>,
    mac_closed: Option<String>,
    /// Sessions the Mac answered (1: no redial).
    sessions: usize,
    /// From the blackout's start to the phone's link turning suspect.
    phone_suspect: Option<Duration>,
    sent: usize,
    echoed: usize,
    /// With a stream: from the network coming back to the first row the
    /// phone read, and every row it read.
    first_row_down: Option<Duration>,
    rows: u64,
}

/// A full blackout of the phone's network for `dark` (nothing it sends
/// leaves, nothing reaches it, on its socket and its TURN allocation),
/// then the network back on the same socket and addresses. With
/// `network_changed`, the OS reports the path back as it returns (the app
/// roams the session). A small app frame goes each way every 100 ms all
/// along, on one channel of the one link.
async fn blackout(dark: Duration, network_changed: bool) -> Blackout {
    blackout_with(LinkConfig::default(), dark, network_changed, Duress::default()).await
}

/// [`blackout`] with both ends on `config`, under `duress`.
async fn blackout_with(
    config: LinkConfig,
    dark: Duration,
    network_changed: bool,
    duress: Duress,
) -> Blackout {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex};
    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_test_writer()
        .try_init();
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let sessions = Arc::new(AtomicUsize::new(0));
    let mac_arrivals = Arc::new(Mutex::new(Vec::<Instant>::new()));
    let mac_link = Arc::new(Mutex::new(None::<cmux_mobile_link::Link>));
    {
        let (sessions, mac_arrivals, mac_link) =
            (Arc::clone(&sessions), Arc::clone(&mac_arrivals), Arc::clone(&mac_link));
        let config = LinkConfig { foreground_probe: false, ..config.clone() };
        tokio::spawn(async move {
            while let Some(session) = mac.next_session().await {
                sessions.fetch_add(1, Ordering::SeqCst);
                let events = SessionEvents {
                    backend: mac.events(),
                    session_id: session.first.session_id.clone(),
                    session: session.events,
                };
                let mac = mac.clone();
                let (mac_arrivals, mac_link) = (Arc::clone(&mac_arrivals), Arc::clone(&mac_link));
                let config = config.clone();
                tokio::spawn(async move {
                    let connected =
                        dial::answer(&mac, session.first, events, &duress_options(duress), config)
                            .await
                            .unwrap();
                    *mac_link.lock().unwrap() = Some(connected.link.clone());
                    while let Some(mut incoming) = connected.link.accept().await {
                        if incoming.service == "stream" {
                            tokio::spawn(stream_rows(incoming.channel));
                            continue;
                        }
                        let mac_arrivals = Arc::clone(&mac_arrivals);
                        tokio::spawn(async move {
                            while let Some(ChannelEvent::Data(bytes)) = incoming.channel.recv().await {
                                mac_arrivals.lock().unwrap().push(Instant::now());
                                let _ = incoming.channel.send(bytes).await;
                            }
                        });
                    }
                });
            }
        });
    }
    let phone_id = uuid::Uuid::new_v4().to_string();
    let phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    let connected =
        dial::connect(&phone, &mac_id, TransportKind::WireGuard, &duress_options(duress), config.clone())
            .await
            .expect("dial");
    let session_id = connected.session_id.clone();
    let rows = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let row_arrivals = Arc::new(Mutex::new(Vec::<Instant>::new()));
    let row_reader = if duress.stream {
        let channel = connected.link.open("stream", serde_json::json!({})).await.unwrap();
        Some(read_rows(channel, Arc::clone(&rows), Some(Arc::clone(&row_arrivals))))
    } else {
        None
    };
    let channel = connected.link.open("echo", serde_json::json!({})).await.unwrap();
    let (sender, mut receiver) = channel.split();
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let sent = Arc::new(AtomicUsize::new(0));
    let writer = {
        let (stop, sent) = (Arc::clone(&stop), Arc::clone(&sent));
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_millis(100));
            while !stop.load(Ordering::Relaxed) {
                tick.tick().await;
                let n = sent.load(Ordering::Relaxed);
                if sender.send(Bytes::from(format!("frame {n:08}"))).await.is_err() {
                    break;
                }
                sent.fetch_add(1, Ordering::Relaxed);
            }
            sender
        })
    };
    let phone_arrivals = Arc::new(Mutex::new(Vec::<Instant>::new()));
    let reader = {
        let phone_arrivals = Arc::clone(&phone_arrivals);
        tokio::spawn(async move {
            while let Some(ChannelEvent::Data(_)) = receiver.recv().await {
                phone_arrivals.lock().unwrap().push(Instant::now());
            }
        })
    };
    // The worst moment: just before the phone's next keepalive ping (one
    // interval after its last pong), so the link's keepalive deadline is
    // closest to the start of the blackout.
    let mut rtt = connected.link.rtt();
    rtt.borrow_and_update();
    let interval = config.keepalive.unwrap();
    tokio::time::timeout(interval + Duration::from_secs(5), rtt.changed()).await.unwrap().unwrap();
    tokio::time::sleep(interval.saturating_sub(Duration::from_millis(100))).await;
    assert_eq!(wireguard::simulate_blackout(Some(&session_id), true, true), 1);
    let went_dark = Instant::now();
    let suspect_watch = {
        let mut suspect = connected.link.suspect_state();
        tokio::spawn(async move {
            suspect.wait_for(|suspect| *suspect).await.ok()?;
            Some(went_dark.elapsed())
        })
    };
    tokio::time::sleep(dark).await;
    let back = Instant::now();
    // 0 once the session is gone (the link closed in the dark).
    wireguard::simulate_blackout(Some(&session_id), true, false);
    if network_changed {
        let session_id = session_id.clone();
        tokio::spawn(async move { wireguard::roam_session(&session_id, true).await });
    }
    // Watch for the first frame each way, up to 10 s.
    let first_after = |arrivals: &Mutex<Vec<Instant>>| {
        arrivals.lock().unwrap().iter().find(|at| **at >= back).map(|at| at.duration_since(back))
    };
    let deadline = back + Duration::from_secs(10);
    while Instant::now() < deadline
        && (first_after(&mac_arrivals).is_none() || first_after(&phone_arrivals).is_none())
    {
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    let (first_frame_up, first_frame_down) = (first_after(&mac_arrivals), first_after(&phone_arrivals));
    let first_row_down = first_after(&row_arrivals);
    tokio::time::sleep(Duration::from_secs(2)).await;
    stop.store(true, Ordering::Relaxed);
    let _sender = tokio::time::timeout(Duration::from_secs(5), writer).await;
    let sent = sent.load(Ordering::Relaxed);
    let all = tokio::time::timeout(Duration::from_secs(10), async {
        while phone_arrivals.lock().unwrap().len() < sent {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await;
    let _ = all;
    let echoed = phone_arrivals.lock().unwrap().len();
    let phone_closed = connected.link.closed_state().borrow().clone();
    let mac_closed = mac_link.lock().unwrap().as_ref().and_then(|link| link.closed_state().borrow().clone());
    connected.link.close("done");
    reader.abort();
    if let Some(row_reader) = row_reader {
        row_reader.abort();
    }
    suspect_watch.abort();
    let phone_suspect = suspect_watch.await.ok().flatten();
    Blackout {
        first_frame_up,
        first_frame_down,
        phone_closed,
        mac_closed,
        sessions: sessions.load(Ordering::SeqCst),
        phone_suspect,
        sent,
        echoed,
        first_row_down,
        rows: rows.load(std::sync::atomic::Ordering::Relaxed),
    }
}

fn check_blackout(name: &str, run: &Blackout) {
    let ms = |d: Option<Duration>| d.map(|d| d.as_millis() as i64).unwrap_or(-1);
    eprintln!(
        "BLACKOUT {name}: first_frame_up_ms={} first_frame_down_ms={} phone_suspect_ms={} phone_closed={:?} mac_closed={:?} sessions={} sent={} echoed={}",
        ms(run.first_frame_up),
        ms(run.first_frame_down),
        ms(run.phone_suspect),
        run.phone_closed,
        run.mac_closed,
        run.sessions,
        run.sent,
        run.echoed
    );
    assert_eq!(run.phone_closed, None, "the phone's link closed: {run:?}");
    assert_eq!(run.mac_closed, None, "the Mac's link closed: {run:?}");
    assert_eq!(run.sessions, 1, "redialed: {run:?}");
    let bound = Duration::from_millis(1500);
    assert!(run.first_frame_up.is_some_and(|d| d < bound), "phone to Mac: {run:?}");
    assert!(run.first_frame_down.is_some_and(|d| d < bound), "Mac to phone: {run:?}");
    assert_eq!(run.echoed, run.sent, "frames lost: {run:?}");
    // Detection is apart from teardown: a busy link is suspect in about 5 s.
    assert!(
        run.phone_suspect.is_some_and(|d| d <= Duration::from_secs(10)),
        "not suspect within 10 s: {run:?}"
    );
}

/// An elevator: the phone's network goes dark for 8 s and comes back on
/// the same socket with no OS event. The same link carries frames again
/// within about a second, both ways, with no redial.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_link_survives_an_8s_blackout() {
    check_blackout("8s", &blackout(Duration::from_secs(8), false).await);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_link_survives_a_10s_blackout() {
    check_blackout("10s", &blackout(Duration::from_secs(10), false).await);
}

/// 30 s dark: past the link's old 20 s keepalive timeout.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_link_survives_a_30s_blackout() {
    check_blackout("30s", &blackout(Duration::from_secs(30), false).await);
}

/// 30 s dark, and the OS reports the path as it comes back (the app roams).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_link_survives_a_30s_blackout_then_network_changed() {
    check_blackout("30s+network_changed", &blackout(Duration::from_secs(30), true).await);
}

/// 60 s dark: past the link's keepalive timeout (`KEEPALIVE_TIMEOUT`), so
/// the link closes on both ends and the app redials (its own probes noticed
/// long before). The bound is the timeout, not sooner.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_link_closes_after_a_60s_blackout() {
    let run = blackout(Duration::from_secs(60), false).await;
    eprintln!("BLACKOUT 60s: {run:?}");
    assert!(cmux_mobile_link::KEEPALIVE_TIMEOUT < Duration::from_secs(60));
    assert_eq!(run.phone_closed.as_deref(), Some("keepalive timed out"), "{run:?}");
}

static PHONE_SENDS: std::sync::Mutex<Vec<std::time::Instant>> = std::sync::Mutex::new(Vec::new());
static MAC_SENDS: std::sync::Mutex<Vec<std::time::Instant>> = std::sync::Mutex::new(Vec::new());

fn count_phone(_: &std::net::SocketAddr) -> bool {
    PHONE_SENDS.lock().unwrap().push(std::time::Instant::now());
    false
}

fn count_mac(_: &std::net::SocketAddr) -> bool {
    MAC_SENDS.lock().unwrap().push(std::time::Instant::now());
    false
}

/// Datagrams one side sent in `[from, to)`, and its wakeups: bursts of
/// sends a second or more apart (a ping and its WireGuard keepalive in the
/// same moment wake the radio once).
fn sends_between(
    sends: &std::sync::Mutex<Vec<std::time::Instant>>,
    from: std::time::Instant,
    to: std::time::Instant,
) -> (usize, usize) {
    let sends = sends.lock().unwrap();
    let window: Vec<_> = sends.iter().filter(|at| **at >= from && **at < to).collect();
    let wakes =
        window.windows(2).filter(|pair| pair[1].duration_since(*pair[0]) >= Duration::from_secs(1)).count()
            + usize::from(!window.is_empty());
    (window.len(), wakes)
}

/// One idle minute on a direct link with both ends on `config`: datagrams
/// and wakeups (phone, Mac).
async fn idle_minute(config: LinkConfig) -> ((usize, usize), (usize, usize)) {
    idle_minute_with(config.clone(), false, config, false).await
}

/// One idle minute on a direct link, the phone on `phone_config` (and, with
/// `phone_aligned_keepalives`, its tunnel sending no WireGuard keepalive of
/// its own, as the app dials with Align Keepalives on), the Mac on
/// `mac_config`: datagrams and wakeups (phone, Mac).
async fn idle_minute_with(
    phone_config: LinkConfig,
    phone_aligned_keepalives: bool,
    mac_config: LinkConfig,
    shaped: bool,
) -> ((usize, usize), (usize, usize)) {
    let base = duress_options(Duress { shaped, stream: false });
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    {
        let config = mac_config.clone();
        let base = base.clone();
        tokio::spawn(async move {
            while let Some(session) = mac.next_session().await {
                let events = SessionEvents {
                    backend: mac.events(),
                    session_id: session.first.session_id.clone(),
                    session: session.events,
                };
                let (mac, config, base) = (mac.clone(), config.clone(), base.clone());
                tokio::spawn(async move {
                    let options = DialOptions { drop_udp_to: Some(count_mac), ..base };
                    let connected =
                        dial::answer(&mac, session.first, events, &options, config).await.unwrap();
                    while connected.link.accept().await.is_some() {}
                });
            }
        });
    }
    let phone_id = uuid::Uuid::new_v4().to_string();
    let phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    let phone_options =
        DialOptions { drop_udp_to: Some(count_phone), aligned_keepalives: phone_aligned_keepalives, ..base };
    let connected = dial::connect(&phone, &mac_id, TransportKind::WireGuard, &phone_options, phone_config)
        .await
        .expect("dial");
    tokio::time::sleep(Duration::from_secs(5)).await;
    let from = std::time::Instant::now();
    tokio::time::sleep(Duration::from_secs(60)).await;
    let to = std::time::Instant::now();
    assert!(!connected.link.is_closed());
    connected.link.close("done");
    (sends_between(&PHONE_SENDS, from, to), sends_between(&MAC_SENDS, from, to))
}

/// The cost of staying ready for a blackout: plain UDP datagrams and
/// wakeups each side sends in one idle minute on a direct link (keepalives
/// and probes; no app traffic), before (base) and after. The suspect
/// watchdog sends only after a ping or data goes unanswered, so a healthy
/// idle link costs the same; a longer keepalive timeout sends nothing more.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn blackout_cost_of_an_idle_minute() {
    let before = idle_minute(base_config()).await;
    let after = idle_minute(LinkConfig::default()).await;
    eprintln!(
        "BLACKOUT idle minute: before phone={:?} mac={:?} | after phone={:?} mac={:?} (datagrams, wakeups)",
        before.0, before.1, after.0, after.1
    );
    // One keepalive exchange of slack for where the minute's edges fall.
    assert!(after.0.0 <= before.0.0 + 2 && after.1.0 <= before.1.0 + 2, "before {before:?} after {after:?}");
}

/// What Align Keepalives (Settings, off by default) would cost if the
/// phone's link took its 10 s beat: one idle minute with the phone dialed as
/// the app dials today (`LinkConfig::default`, the tunnel's own WireGuard
/// keepalive) and as it dials with the setting on (`LinkConfig::aligned`,
/// no tunnel keepalive), the Mac on its default both times. A measurement
/// for the PR body, not a gate: run it alone with
/// `cargo test -p cmux-mobile-link --test roaming aligned_beat -- --ignored --nocapture`.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "measurement: two idle minutes; run on its own"]
async fn aligned_beat_cost_of_an_idle_minute() {
    let today = idle_minute_with(LinkConfig::default(), false, LinkConfig::default(), false).await;
    let aligned = idle_minute_with(LinkConfig::aligned(), true, LinkConfig::default(), false).await;
    eprintln!(
        "ALIGNED idle minute: today phone={:?} mac={:?} | aligned phone={:?} mac={:?} (datagrams, wakeups)",
        today.0, today.1, aligned.0, aligned.1
    );
}

/// The link as it was on base: the 15 s ping, a 20 s keepalive timeout and
/// no suspect signal (detection was teardown). The "before" column.
fn base_config() -> LinkConfig {
    LinkConfig { keepalive_timeout: Duration::from_secs(20), suspect_after: None, ..LinkConfig::default() }
}

/// Which end's network goes dark in a detection run.
#[derive(Clone, Copy, Debug)]
enum DarkSide {
    /// The phone's (an elevator): a hard blackout at the phone.
    Phone,
    /// The Mac's (asleep, its network gone): a silent peer to the phone.
    Mac,
}

/// When each end noticed, from the moment the network went dark: its link
/// turned suspect or closed, whichever came first. `None`: not within the
/// window.
#[derive(Debug, Clone, Copy)]
struct Detection {
    phone: Option<Duration>,
    mac: Option<Duration>,
    /// Times either end turned suspect before the network went dark (a
    /// false alarm on a lossy link), and the rows the phone read.
    false_suspects: u32,
    rows: u64,
}

/// What the app does on the link while it goes dark.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Load {
    /// Nothing: the phone backgrounded, the link's own keepalive only.
    Idle,
    /// The app in the foreground with nothing on screen moving: its
    /// heartbeat (`LinkController`) probes a link quiet for 2.5 s, 1.5 s
    /// timeout.
    Foreground,
    /// An app frame each way every 100 ms (a terminal scrolling).
    Busy,
    /// `Busy`, and the Mac streams terminal rows to the phone
    /// ([`STREAM_ROWS_PER_SECOND`]): a long streaming session.
    Stream,
}

/// One link on `config` (both ends) under `load`; `phase` after the
/// phone's first pong, `side`'s network goes dark for good; how long until
/// each end noticed (up to `window`).
async fn detect(
    config: LinkConfig,
    side: DarkSide,
    load: Load,
    phase: Duration,
    window: Duration,
    shaped: bool,
) -> Detection {
    let duress = Duress { shaped, stream: load == Load::Stream };
    use std::sync::{Arc, Mutex};
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let mac_link = Arc::new(Mutex::new(None::<cmux_mobile_link::Link>));
    {
        // The foreground probe is the phone app's; the Mac never runs it.
        let (mac_link, config) =
            (Arc::clone(&mac_link), LinkConfig { foreground_probe: false, ..config.clone() });
        tokio::spawn(async move {
            while let Some(session) = mac.next_session().await {
                let events = SessionEvents {
                    backend: mac.events(),
                    session_id: session.first.session_id.clone(),
                    session: session.events,
                };
                let (mac, mac_link, config) = (mac.clone(), Arc::clone(&mac_link), config.clone());
                tokio::spawn(async move {
                    let connected =
                        dial::answer(&mac, session.first, events, &duress_options(duress), config)
                            .await
                            .unwrap();
                    *mac_link.lock().unwrap() = Some(connected.link.clone());
                    while let Some(mut incoming) = connected.link.accept().await {
                        if incoming.service == "stream" {
                            tokio::spawn(stream_rows(incoming.channel));
                            continue;
                        }
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
    let phone_id = uuid::Uuid::new_v4().to_string();
    let phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    let connected =
        dial::connect(&phone, &mac_id, TransportKind::WireGuard, &duress_options(duress), config.clone())
            .await
            .expect("dial");
    let link = connected.link.clone();
    let mut traffic = None;
    let rows = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let mut row_reader = None;
    if load == Load::Stream {
        let channel = link.open("stream", serde_json::json!({})).await.unwrap();
        row_reader = Some(read_rows(channel, Arc::clone(&rows), None));
    }
    if load == Load::Foreground {
        let link = link.clone();
        traffic = Some(tokio::spawn(async move {
            const QUIET: Duration = Duration::from_millis(2500);
            loop {
                tokio::time::sleep(QUIET.saturating_sub(link.received_ago())).await;
                if link.received_ago() >= QUIET && link.probe(Duration::from_millis(1500)).await.is_err() {
                    break;
                }
            }
        }));
    }
    if matches!(load, Load::Busy | Load::Stream) {
        let channel = link.open("echo", serde_json::json!({})).await.unwrap();
        let (sender, mut receiver) = channel.split();
        tokio::spawn(async move { while receiver.recv().await.is_some() {} });
        traffic = Some(tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_millis(100));
            loop {
                tick.tick().await;
                if sender.send(Bytes::from_static(b"frame")).await.is_err() {
                    break;
                }
            }
        }));
    }
    let mut rtt = link.rtt();
    rtt.borrow_and_update();
    tokio::time::timeout(Duration::from_secs(20), rtt.changed()).await.unwrap().unwrap();
    let mac_end = mac_link.lock().unwrap().clone().expect("the Mac's link");
    // False alarms: suspect turns while the network is still up.
    let alarms = Arc::new(std::sync::atomic::AtomicU32::new(0));
    let count_suspects = |link: cmux_mobile_link::Link| {
        let alarms = Arc::clone(&alarms);
        tokio::spawn(async move {
            let mut suspect = link.suspect_state();
            while suspect.changed().await.is_ok() {
                if *suspect.borrow_and_update() {
                    alarms.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                }
            }
        })
    };
    let watchers = [count_suspects(link.clone()), count_suspects(mac_end.clone())];
    tokio::time::sleep(phase).await;
    for watcher in watchers {
        watcher.abort();
    }
    let false_suspects = alarms.load(std::sync::atomic::Ordering::Relaxed);
    let dialer = matches!(side, DarkSide::Phone);
    assert_eq!(wireguard::simulate_blackout(Some(&connected.session_id), dialer, true), 1);
    let began = tokio::time::Instant::now();
    let noticed = |link: cmux_mobile_link::Link| async move {
        let mut suspect = link.suspect_state();
        let mut closed = link.closed_state();
        tokio::time::timeout_at(began + window, async {
            tokio::select! {
                _ = suspect.wait_for(|suspect| *suspect) => {}
                _ = closed.wait_for(Option::is_some) => {}
            }
        })
        .await
        .ok()?;
        Some(began.elapsed())
    };
    let (phone_at, mac_at) = tokio::join!(noticed(link.clone()), noticed(mac_end.clone()));
    if let Some(traffic) = traffic {
        traffic.abort();
    }
    if let Some(row_reader) = row_reader {
        row_reader.abort();
    }
    link.close("done");
    mac_end.close("done");
    Detection {
        phone: phone_at,
        mac: mac_at,
        false_suspects,
        rows: rows.load(std::sync::atomic::Ordering::Relaxed),
    }
}

fn percentile(samples: &[Option<Duration>], p: f64) -> String {
    let mut ms: Vec<f64> =
        samples.iter().map(|d| d.map_or(f64::INFINITY, |d| d.as_secs_f64() * 1000.0)).collect();
    ms.sort_by(f64::total_cmp);
    if ms.is_empty() {
        return "n/a".into();
    }
    let at = ((ms.len() as f64 - 1.0) * p).round() as usize;
    let value = ms[at];
    if value.is_finite() { format!("{:.1} s", value / 1000.0) } else { "none".into() }
}

/// Time to detect a dead link, before (base: detection was the keepalive
/// closing the link) and after (the suspect signal), over 20 runs per
/// case, the blackout's start spread evenly over the 15 s keepalive
/// interval. Each end's network in turn goes dark (a hard blackout at the
/// phone; a silent Mac), idle, foreground and busy. Runs of a case go at
/// once.
/// `cargo test -p cmux-mobile-link --test roaming detection_matrix -- --ignored --nocapture`
#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
#[ignore = "timed matrix (about 8 minutes): run by hand for the PR's numbers"]
async fn detection_matrix() {
    const RUNS: u32 = 20;
    let window = Duration::from_secs(40);
    for (label, config) in [("before", base_config()), ("after", LinkConfig::default())] {
        for side in [DarkSide::Phone, DarkSide::Mac] {
            for load in [Load::Idle, Load::Foreground, Load::Busy] {
                let runs = (0..RUNS).map(|i| {
                    let phase = Duration::from_millis(15_000 * u64::from(i) / u64::from(RUNS));
                    tokio::spawn(detect(config.clone(), side, load, phase, window, false))
                });
                let mut results = Vec::new();
                for run in runs.collect::<Vec<_>>() {
                    results.push(run.await.unwrap());
                }
                let phone: Vec<_> = results.iter().map(|r| r.phone).collect();
                let mac: Vec<_> = results.iter().map(|r| r.mac).collect();
                eprintln!(
                    "DETECT {label} dark={side:?} {load:?}: phone p50={} p95={} max={} | mac p50={} p95={} max={}",
                    percentile(&phone, 0.5),
                    percentile(&phone, 0.95),
                    percentile(&phone, 1.0),
                    percentile(&mac, 0.5),
                    percentile(&mac, 0.95),
                    percentile(&mac, 1.0),
                );
            }
        }
    }
}

/// Blackout survival before (base config) and after, same harness as the
/// blackout tests above: 8, 10, 30 and 60 s.
/// `cargo test -p cmux-mobile-link --test roaming blackout_matrix -- --ignored --nocapture`
#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
#[ignore = "timed matrix (about 2 minutes): run by hand for the PR's numbers"]
async fn blackout_matrix() {
    let mut runs = Vec::new();
    for (label, config) in [("before", base_config()), ("after", LinkConfig::default())] {
        for secs in [8u64, 10, 30, 60] {
            let config = config.clone();
            runs.push((
                label,
                secs,
                tokio::spawn(blackout_with(config, Duration::from_secs(secs), false, Duress::default())),
            ));
        }
    }
    for (label, secs, run) in runs {
        let run = run.await.unwrap();
        let ms = |d: Option<Duration>| d.map_or("none".to_owned(), |d| d.as_millis().to_string());
        eprintln!(
            "SURVIVE {label} {secs}s: link={} up_ms={} down_ms={} suspect_ms={} frames={}/{} sessions={}",
            match (&run.phone_closed, &run.mac_closed) {
                (None, None) => "same link".to_owned(),
                (phone, mac) => format!("closed (phone {phone:?}, mac {mac:?})"),
            },
            ms(run.first_frame_up),
            ms(run.first_frame_down),
            ms(run.phone_suspect),
            run.echoed,
            run.sent,
            run.sessions,
        );
    }
}

/// Detection, blackout survival and idle cost under a phone link profile,
/// before (base config) and after: Leo's "testing under duress", offline.
/// Each profile in `DURESS_PROFILES` (comma-separated cmux-fault profile
/// names, `none` for loopback; default `lte,lossy-3,lossy-10`) shapes every
/// datagram both tunnels receive (`testing::shape_by_profile`, the
/// `UdpShaper` model). Detection: 20 runs a case, the blackout's start
/// spread over the 15 s keepalive, idle and under a long stream (the Mac
/// writing [`STREAM_ROWS_PER_SECOND`] rows, the phone echoing a frame every
/// 100 ms). Survival: the 8, 10, 30 and 60 s blackouts under the stream.
/// Idle cost: one idle minute each, shaped, scaled to an hour.
/// `DURESS_SURVIVE_ONLY=1` runs only the survival part, and
/// `DURESS_SURVIVE_IDLE=1` runs it without the stream.
/// `DURESS_FOREGROUND=1` gives the "after" phone its foreground probe
/// (`Link::set_foreground_probe`: the app in front with a terminal or chat
/// on screen); the Mac stays on the default.
/// `DURESS_PROFILES=lte cargo test -p cmux-mobile-link --test roaming duress_matrix -- --ignored --nocapture`
#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
#[ignore = "timed matrix (about 9 minutes a profile): run by hand for the PR's numbers"]
async fn duress_matrix() {
    const RUNS: u32 = 20;
    let window = Duration::from_secs(40);
    let names = std::env::var("DURESS_PROFILES").unwrap_or_else(|_| "lte,lossy-3,lossy-10".into());
    // `DURESS_SURVIVE_ONLY=1`: only the survival runs.
    let survive_only = std::env::var_os("DURESS_SURVIVE_ONLY").is_some();
    // `DURESS_SURVIVE_IDLE=1`: the survival runs without the stream.
    let survive_stream = std::env::var_os("DURESS_SURVIVE_IDLE").is_none();
    // `DURESS_FOREGROUND=1`: the "after" phone runs its foreground probe.
    let after_config = || LinkConfig {
        foreground_probe: std::env::var_os("DURESS_FOREGROUND").is_some(),
        ..LinkConfig::default()
    };
    for name in names.split(',').map(str::trim).filter(|name| !name.is_empty()) {
        let profile = (name != "none").then(|| LinkProfile::named(name));
        eprintln!("DURESS profile={name} {profile:?}");
        set_link_profile(profile, 0x4934_2000);
        let configs =
            if survive_only { vec![] } else { vec![("before", base_config()), ("after", after_config())] };
        for (label, config) in configs {
            for side in [DarkSide::Phone, DarkSide::Mac] {
                for load in [Load::Idle, Load::Stream] {
                    let runs = (0..RUNS).map(|i| {
                        let phase = Duration::from_millis(15_000 * u64::from(i) / u64::from(RUNS));
                        tokio::spawn(detect(config.clone(), side, load, phase, window, true))
                    });
                    // A run that never set up (no dial, or no ping round trip in 20 s) under
                    // the profile counts, not aborts.
                    let mut results = Vec::new();
                    let mut failed = 0;
                    for run in runs.collect::<Vec<_>>() {
                        match run.await {
                            Ok(detection) => results.push(detection),
                            Err(_) => failed += 1,
                        }
                    }
                    let phone: Vec<_> = results.iter().map(|r| r.phone).collect();
                    let mac: Vec<_> = results.iter().map(|r| r.mac).collect();
                    let false_suspects: u32 = results.iter().map(|r| r.false_suspects).sum();
                    let rows = results.iter().map(|r| r.rows).min().unwrap_or(0);
                    eprintln!(
                        "DETECT profile={name} {label} dark={side:?} {load:?}: phone p50={} p95={} max={} | mac p50={} p95={} max={} | false_suspects={false_suspects} over {:.0} s up | min_rows={rows} | runs={} setup_failed={failed} (no dial or no first ping round trip in 20 s)",
                        percentile(&phone, 0.5),
                        percentile(&phone, 0.95),
                        percentile(&phone, 1.0),
                        percentile(&mac, 0.5),
                        percentile(&mac, 0.95),
                        percentile(&mac, 1.0),
                        7.5 * f64::from(RUNS),
                        results.len(),
                    );
                }
            }
        }
        let mut runs = Vec::new();
        for (label, config) in [("before", base_config()), ("after", after_config())] {
            for secs in [8u64, 10, 30, 60] {
                let duress = Duress { shaped: true, stream: survive_stream };
                let run = blackout_with(config.clone(), Duration::from_secs(secs), false, duress);
                runs.push((label, secs, tokio::spawn(run)));
            }
        }
        for (label, secs, run) in runs {
            let Ok(run) = run.await else {
                eprintln!(
                    "SURVIVE profile={name} {label} {secs}s: setup failed (no dial or no first ping round trip)"
                );
                continue;
            };
            let ms = |d: Option<Duration>| d.map_or("none".to_owned(), |d| d.as_millis().to_string());
            eprintln!(
                "SURVIVE profile={name} {label} {secs}s: link={} up_ms={} down_ms={} first_row_ms={} suspect_ms={} frames={}/{} rows={} sessions={}",
                match (&run.phone_closed, &run.mac_closed) {
                    (None, None) => "same link".to_owned(),
                    (phone, mac) => format!("closed (phone {phone:?}, mac {mac:?})"),
                },
                ms(run.first_frame_up),
                ms(run.first_frame_down),
                ms(run.first_row_down),
                ms(run.phone_suspect),
                run.echoed,
                run.sent,
                run.rows,
                run.sessions,
            );
        }
        if survive_only {
            continue;
        }
        let before = idle_minute_with(base_config(), false, base_config(), true).await;
        let after = idle_minute_with(after_config(), false, LinkConfig::default(), true).await;
        eprintln!(
            "WAKEUPS profile={name} idle, per hour (one minute x 60): before phone={} mac={} | after phone={} mac={} (datagrams before {}/{}, after {}/{})",
            before.0.1 * 60,
            before.1.1 * 60,
            after.0.1 * 60,
            after.1.1 * 60,
            before.0.0 * 60,
            before.1.0 * 60,
            after.0.0 * 60,
            after.1.0 * 60,
        );
        let (delivered, dropped) = shaped_counts();
        eprintln!("SHAPED profile={name}: delivered={delivered} dropped={dropped}");
    }
    set_link_profile(None, 0);
}

static COST_PHONE: std::sync::Mutex<Vec<(std::time::Instant, usize)>> = std::sync::Mutex::new(Vec::new());
static COST_PHONE_TARGETS: std::sync::Mutex<Vec<(std::time::Instant, std::net::SocketAddr, usize)>> =
    std::sync::Mutex::new(Vec::new());
static COST_MAC: std::sync::Mutex<Vec<(std::time::Instant, usize)>> = std::sync::Mutex::new(Vec::new());

fn cost_phone(target: &std::net::SocketAddr, len: usize) {
    COST_PHONE_TARGETS.lock().unwrap().push((std::time::Instant::now(), *target, len));
    COST_PHONE.lock().unwrap().push((std::time::Instant::now(), len));
}

fn cost_mac(_: &std::net::SocketAddr, len: usize) {
    COST_MAC.lock().unwrap().push((std::time::Instant::now(), len));
}

/// Bytes, datagrams and wakeups (bursts a second or more apart) one side
/// handed the OS in `[from, to)`.
fn cost_between(
    sends: &std::sync::Mutex<Vec<(std::time::Instant, usize)>>,
    from: std::time::Instant,
    to: std::time::Instant,
) -> (usize, usize, usize) {
    let sends = sends.lock().unwrap();
    let window: Vec<_> = sends.iter().filter(|(at, _)| *at >= from && *at < to).collect();
    let wakes = window
        .windows(2)
        .filter(|pair| pair[1].0.duration_since(pair[0].0) >= Duration::from_secs(1))
        .count()
        + usize::from(!window.is_empty());
    (window.iter().map(|(_, len)| len).sum(), window.len(), wakes)
}

/// One idle minute, one link alone in the process: the phone on
/// `LinkConfig::default` with `foreground_probe`, the Mac on the default.
/// (phone, Mac) as (bytes, datagrams, wakeups).
async fn cost_minute(foreground: bool) -> ((usize, usize, usize), (usize, usize, usize)) {
    let base = duress_options(Duress { shaped: true, stream: false });
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    {
        let base = base.clone();
        tokio::spawn(async move {
            while let Some(session) = mac.next_session().await {
                let events = SessionEvents {
                    backend: mac.events(),
                    session_id: session.first.session_id.clone(),
                    session: session.events,
                };
                let (mac, base) = (mac.clone(), base.clone());
                tokio::spawn(async move {
                    let options = DialOptions { on_udp_sent: Some(cost_mac), ..base };
                    let connected =
                        dial::answer(&mac, session.first, events, &options, LinkConfig::default())
                            .await
                            .unwrap();
                    while connected.link.accept().await.is_some() {}
                });
            }
        });
    }
    let phone_id = uuid::Uuid::new_v4().to_string();
    let phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    let phone_options = DialOptions { on_udp_sent: Some(cost_phone), ..base };
    let config = LinkConfig { foreground_probe: foreground, ..LinkConfig::default() };
    let connected =
        dial::connect(&phone, &mac_id, TransportKind::WireGuard, &phone_options, config).await.expect("dial");
    // Past the handshake and the first exchanges.
    tokio::time::sleep(Duration::from_secs(10)).await;
    let from = std::time::Instant::now();
    tokio::time::sleep(Duration::from_secs(60)).await;
    let to = std::time::Instant::now();
    assert!(!connected.link.is_closed());
    connected.link.close("done");
    tokio::time::sleep(Duration::from_secs(2)).await;
    if std::env::var_os("COST_BREAKDOWN").is_some() {
        let mut by: std::collections::BTreeMap<(std::net::SocketAddr, usize), usize> = Default::default();
        for (at, target, len) in COST_PHONE_TARGETS.lock().unwrap().iter() {
            if *at >= from && *at < to {
                *by.entry((*target, *len)).or_default() += 1;
            }
        }
        eprintln!("COST breakdown foreground={foreground} (target, len) -> count: {by:?}");
    }
    (cost_between(&COST_PHONE, from, to), cost_between(&COST_MAC, from, to))
}

/// What the foreground probe costs a minute, under each link profile: one
/// link at a time (the matrix's counts share statics with concurrent runs),
/// off then on, three minutes each, the median printed.
/// `COST_PROFILES=lte cargo test --release -p cmux-mobile-link --test roaming foreground_probe_cost -- --ignored --nocapture`
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "measurement: six idle minutes a profile; run on its own"]
async fn foreground_probe_cost() {
    let names = std::env::var("COST_PROFILES").unwrap_or_else(|_| "lte,lossy-3,lossy-10".into());
    let median = |mut v: Vec<usize>| {
        v.sort_unstable();
        v[v.len() / 2]
    };
    for name in names.split(',').map(str::trim).filter(|name| !name.is_empty()) {
        set_link_profile(Some(LinkProfile::named(name)), 0x5064_1000);
        let mut cols = Vec::new();
        for foreground in [false, true] {
            let mut runs = Vec::new();
            for _ in 0..std::env::var("COST_ROUNDS").ok().and_then(|n| n.parse().ok()).unwrap_or(3) {
                runs.push(cost_minute(foreground).await);
            }
            type Run = ((usize, usize, usize), (usize, usize, usize));
            let pick = |f: fn(&Run) -> usize| median(runs.iter().map(f).collect());
            let row = [
                pick(|r| r.0.0),
                pick(|r| r.1.0),
                pick(|r| r.0.0 + r.1.0),
                pick(|r| r.0.1),
                pick(|r| r.1.1),
                pick(|r| r.0.2),
                pick(|r| r.1.2),
            ];
            eprintln!(
                "COST profile={name} foreground={foreground}: per minute phone_bytes={} mac_bytes={} both_bytes={} phone_datagrams={} mac_datagrams={} phone_wakeups={} mac_wakeups={} runs={runs:?}",
                row[0], row[1], row[2], row[3], row[4], row[5], row[6]
            );
            cols.push(row);
        }
        let d = |i: usize| cols[1][i] as i64 - cols[0][i] as i64;
        eprintln!(
            "COST profile={name} delta: both_bytes={:+} phone_bytes={:+} mac_bytes={:+} phone_datagrams={:+} phone_wakeups={:+} mac_wakeups={:+}",
            d(2),
            d(0),
            d(1),
            d(3),
            d(5),
            d(6)
        );
    }
}
