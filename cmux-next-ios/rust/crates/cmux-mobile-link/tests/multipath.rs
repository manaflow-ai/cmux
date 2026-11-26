//! Wi-Fi and cell together (P3, RFD 0164 B6): the phone holds a second,
//! warm socket on its cellular interface beside Wi-Fi. Keystrokes and echo
//! ride both; when Wi-Fi dies the session is already on cell, before the
//! OS says so. Its own test binary: the interface list is process-wide.
//!
//! On loopback the "cellular" socket is bound to `lo` and a small STUN
//! responder plays the carrier's reflexive address.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_mobile_link::dial::{self, SessionEvents, wireguard};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_mobile_link::{ChannelEvent, DialOptions, LinkConfig, SignalingClient, TransportKind};
use wireguard::{InterfaceKind, NetInterface};

/// A keystroke every 20 ms (fast typing), each echoed by the Mac.
const KEY_INTERVAL: Duration = Duration::from_millis(20);
/// The OS reports Wi-Fi gone this long after it died (iOS's NWPath lags
/// a dead Wi-Fi by hundreds of milliseconds to seconds).
const OS_LAG: Duration = Duration::from_millis(500);

fn interface(name: &str, kind: InterfaceKind, primary: bool) -> NetInterface {
    NetInterface {
        name: name.into(),
        kind,
        expensive: kind == InterfaceKind::Cellular,
        constrained: false,
        primary,
    }
}

/// A STUN server on loopback: answers every binding request with the
/// address it came from.
async fn stun_responder() -> String {
    let socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let address = socket.local_addr().unwrap().to_string();
    tokio::spawn(async move {
        let mut buffer = [0u8; 1500];
        while let Ok((len, from)) = socket.recv_from(&mut buffer).await {
            if len < 20 {
                continue;
            }
            let mut transaction = [0u8; 12];
            transaction.copy_from_slice(&buffer[8..20]);
            let _ = socket.send_to(&cmux_transport::stun::binding_success(transaction, from), from).await;
        }
    });
    address
}

#[derive(Debug)]
struct Handoff {
    /// Echo round trips before Wi-Fi died (ms, sorted).
    before: Vec<u128>,
    /// Echo round trips of keystrokes sent from 1 s before Wi-Fi died to
    /// 2.5 s after (ms, sorted; a keystroke never echoed counts as 10 s).
    through: Vec<u128>,
    /// Longest the phone saw no echo, in the same window.
    longest_gap: Duration,
    lost: usize,
}

fn percentile(sorted: &[u128], p: f64) -> u128 {
    if sorted.is_empty() {
        return 0;
    }
    let index = ((sorted.len() as f64 - 1.0) * p).round() as usize;
    sorted[index.min(sorted.len() - 1)]
}

/// Type and watch the echo while the phone's Wi-Fi dies. With `cell`, the
/// phone has a cellular interface beside Wi-Fi and the OS reports cell as
/// primary [`OS_LAG`] after Wi-Fi died; without, today's path: the OS
/// reports the change and the session roams then.
async fn handoff(cell: bool) -> Handoff {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_test_writer()
        .try_init();
    let wifi = interface("wlan-mp-test", InterfaceKind::Wifi, true);
    let lo_cell = interface("lo", InterfaceKind::Cellular, false);
    wireguard::set_interfaces(Vec::new());
    let stun = stun_responder().await;
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let options = DialOptions {
        include_loopback: true,
        timeout: Duration::from_secs(20),
        ice_servers: vec![cmux_mobile_link::api::IceServer {
            urls: vec![format!("stun:{stun}")],
            username: None,
            credential: None,
        }],
        ..DialOptions::default()
    };
    let config = LinkConfig::default();
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    {
        let options = options.clone();
        let config = LinkConfig { foreground_probe: false, ..config.clone() };
        tokio::spawn(async move {
            while let Some(session) = mac.next_session().await {
                let events = SessionEvents {
                    backend: mac.events(),
                    session_id: session.first.session_id.clone(),
                    session: session.events,
                };
                let (mac, options, config) = (mac.clone(), options.clone(), config.clone());
                tokio::spawn(async move {
                    let connected =
                        dial::answer(&mac, session.first, events, &options, config).await.unwrap();
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
    let phone_id = uuid::Uuid::new_v4().to_string();
    let phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    let connected =
        dial::connect(&phone, &mac_id, TransportKind::WireGuard, &options, config).await.expect("dial");
    let session_id = connected.session_id.clone();
    if cell {
        wireguard::set_interfaces(vec![wifi.clone(), lo_cell.clone()]);
        assert!(!wireguard::cellular_path(), "Wi-Fi is the primary: not metered");
    }
    let channel = connected.link.open("echo", serde_json::json!({})).await.unwrap();
    let (sender, mut receiver) = channel.split();
    let sent_at = Arc::new(Mutex::new(Vec::<Instant>::new()));
    let echoed_at = Arc::new(Mutex::new(Vec::<(u64, Instant)>::new()));
    let stop = Arc::new(AtomicBool::new(false));
    let writer = {
        let (sent_at, stop) = (Arc::clone(&sent_at), Arc::clone(&stop));
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(KEY_INTERVAL);
            let mut n = 0u64;
            while !stop.load(Ordering::Relaxed) {
                tick.tick().await;
                sent_at.lock().unwrap().push(Instant::now());
                if sender.send(Bytes::from(format!("key {n:08}"))).await.is_err() {
                    break;
                }
                n += 1;
            }
        })
    };
    let reader = {
        let echoed_at = Arc::clone(&echoed_at);
        tokio::spawn(async move {
            while let Some(ChannelEvent::Data(bytes)) = receiver.recv().await {
                let text = String::from_utf8_lossy(&bytes);
                if let Some(n) = text.strip_prefix("key ").and_then(|n| n.parse::<u64>().ok()) {
                    echoed_at.lock().unwrap().push((n, Instant::now()));
                }
            }
        })
    };
    // Let the second socket learn its address, announce it and be heard.
    tokio::time::sleep(Duration::from_secs(3)).await;
    assert_eq!(wireguard::simulate_blackout(Some(&session_id), true, true), 1);
    let died = Instant::now();
    tokio::time::sleep(OS_LAG).await;
    if cell {
        wireguard::set_interfaces(vec![interface("lo", InterfaceKind::Cellular, true)]);
        assert!(wireguard::cellular_path(), "cell is the primary: Ultra's repair cap reads it");
    } else {
        wireguard::simulate_blackout(Some(&session_id), true, false);
        let session_id = session_id.clone();
        tokio::spawn(async move { wireguard::roam_session(&session_id, true).await });
    }
    tokio::time::sleep(Duration::from_secs(3)).await;
    stop.store(true, Ordering::Relaxed);
    let _ = writer.await;
    tokio::time::sleep(Duration::from_secs(2)).await;
    reader.abort();
    connected.link.close("done");
    wireguard::set_interfaces(Vec::new());

    let sent_at = sent_at.lock().unwrap().clone();
    let echoed_at = echoed_at.lock().unwrap().clone();
    let echo_of = |n: usize| echoed_at.iter().find(|(m, _)| *m as usize == n).map(|(_, at)| *at);
    let (start, end) = (died - Duration::from_secs(1), died + Duration::from_millis(2500));
    let mut before = Vec::new();
    let mut through = Vec::new();
    let mut lost = 0;
    for (n, at) in sent_at.iter().enumerate() {
        let rtt = echo_of(n).map(|echo| echo.duration_since(*at).as_millis());
        if *at < died - Duration::from_secs(1) && *at > died - Duration::from_secs(3) {
            before.extend(rtt);
        }
        if *at >= start && *at <= end {
            if rtt.is_none() {
                lost += 1;
            }
            through.push(rtt.unwrap_or(10_000));
        }
    }
    before.sort_unstable();
    through.sort_unstable();
    let mut arrivals: Vec<Instant> = echoed_at
        .iter()
        .map(|(_, at)| *at)
        .filter(|at| *at >= start && *at <= end + Duration::from_secs(1))
        .collect();
    arrivals.sort_unstable();
    let longest_gap =
        arrivals.windows(2).map(|pair| pair[1].duration_since(pair[0])).max().unwrap_or(Duration::MAX);
    Handoff { before, through, longest_gap, lost }
}

fn report(name: &str, run: &Handoff) {
    eprintln!(
        "HANDOFF {name}: rtt_before_p50_ms={} through_p50_ms={} through_p99_ms={} through_max_ms={} longest_echo_gap_ms={} lost={} keys={}",
        percentile(&run.before, 0.5),
        percentile(&run.through, 0.5),
        percentile(&run.through, 0.99),
        run.through.last().copied().unwrap_or(0),
        run.longest_gap.as_millis(),
        run.lost,
        run.through.len(),
    );
}

/// The stop condition's measurement: through Wi-Fi's death the echo of
/// every keystroke comes back within RTT + 50 ms (p99), with nothing lost,
/// before the OS reports the change. Today's path (no cell beside Wi-Fi)
/// runs alongside for the before number.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_echo_does_not_stall_when_wifi_dies_beside_cell() {
    let today = handoff(false).await;
    report("wifi-only (today)", &today);
    let run = handoff(true).await;
    report("wifi+cell", &run);
    assert_eq!(run.lost, 0, "keystrokes lost: {run:?}");
    let rtt = percentile(&run.before, 0.5);
    let p99 = percentile(&run.through, 0.99);
    assert!(p99 <= rtt + 50, "echo p99 {p99} ms through the handoff, RTT {rtt} ms: {run:?}");
    assert!(run.longest_gap < Duration::from_millis(150), "the echo stalled: {run:?}");
}
