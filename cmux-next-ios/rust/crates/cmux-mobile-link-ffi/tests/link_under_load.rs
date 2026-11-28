//! The phone's link answers on time while the library's shared work runs beside it
//! (plink, 2026-11-27: Leo's iPhone saw RTT 0.8-2.7 s on LAN and its tunnel re-keyed every
//! few seconds while it probed 3 Macs and its network path changed thousands of times).
//!
//! Three echo Macs, three WireGuard links on one pool, as the app holds them. The probe link's
//! ping (a frame through the tunnel's packet loop and back) is timed idle, then while the
//! process does what the phone did: a network change every second (every session roams onto a
//! new socket, the signaling socket reopens) and the other two links carry a steady echo.
//!
//! `cargo test -p cmux-mobile-link-ffi --test link_under_load -- --nocapture` prints one
//! `LINK_UNDER_LOAD {json}` line: ping p50/p95/max idle and under load, in ms.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use cmux_mobile_link::dial::{self, SessionEvents};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_mobile_link::{ChannelEvent, DialOptions, LinkConfig, SignalingClient};
use cmux_mobile_link_ffi::{ChannelMessage, ConnectRequest, LinkHandle, Transport, WarmPool};
use serde_json::json;

const MACS: usize = 3;
const SAMPLES: usize = 40;
/// One ping every this long while sampling.
const SPACING: Duration = Duration::from_millis(100);
/// A ping slower than this under load is the stall the phone showed (srtt 0.8-2.7 s on LAN).
const LOADED_P95_BOUND_MS: f64 = 250.0;

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
                let Ok(connected) = dial::answer(&mac, first, events, &options, LinkConfig::default()).await
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
}

fn request(server: &FakeSignaling, device_id: &str, mac_id: &str) -> ConnectRequest {
    ConnectRequest {
        base_url: server.base_url.clone(),
        token: "user:alice".into(),
        team_id: "team".into(),
        device_id: device_id.into(),
        mac_device_id: mac_id.into(),
        transport: Transport::WireGuard,
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

struct Stats {
    p50: f64,
    p95: f64,
    max: f64,
    failed: usize,
}

async fn sample(phone: &LinkHandle) -> Stats {
    let mut took = Vec::with_capacity(SAMPLES);
    let mut failed = 0;
    for _ in 0..SAMPLES {
        let start = Instant::now();
        match tokio::time::timeout(Duration::from_secs(5), phone.ping()).await {
            Ok(Ok(_)) => took.push(start.elapsed().as_secs_f64() * 1000.0),
            _ => failed += 1,
        }
        tokio::time::sleep(SPACING).await;
    }
    took.sort_by(f64::total_cmp);
    let at = |q: f64| took.get(((took.len() as f64 - 1.0) * q).round() as usize).copied().unwrap_or(f64::NAN);
    Stats { p50: at(0.5), p95: at(0.95), max: took.last().copied().unwrap_or(f64::NAN), failed }
}

fn row(stats: &Stats) -> serde_json::Value {
    let round = |v: f64| (v * 10.0).round() / 10.0;
    json!({"p50_ms": round(stats.p50), "p95_ms": round(stats.p95), "max_ms": round(stats.max), "failed": stats.failed})
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_link_answers_on_time_while_three_macs_and_path_changes_load_the_phone() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let pool = WarmPool::new();
    let device_id = uuid::Uuid::new_v4().to_string();
    let mut links: Vec<Arc<LinkHandle>> = Vec::new();
    for _ in 0..MACS {
        let mac_id = uuid::Uuid::new_v4().to_string();
        spawn_echo_mac(
            SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap(),
        );
        let phone =
            pool.connect(request(&server, &device_id, &mac_id), None).await.expect("the phone links up");
        links.push(phone);
    }
    let probe = Arc::clone(&links[0]);
    let idle = sample(&probe).await;

    let stop = Arc::new(AtomicBool::new(false));
    let mut load = Vec::new();
    // The other Macs' links carry a steady echo, as open terminals do.
    for phone in links.iter().skip(1) {
        let channel = phone.open_channel("echo".into(), String::new()).await.expect("channel");
        let stop = Arc::clone(&stop);
        load.push(tokio::spawn(async move {
            let payload = vec![7u8; 1200];
            while !stop.load(Ordering::Relaxed) {
                if channel.send(payload.clone()).await.is_err() {
                    break;
                }
                let _ = tokio::time::timeout(Duration::from_secs(2), channel.recv()).await;
            }
        }));
    }
    // A network path change every second: every session roams, the signaling socket reopens.
    let roams = Arc::new(std::sync::atomic::AtomicU64::new(0));
    {
        let (pool, stop, roams) = (pool.clone(), Arc::clone(&stop), Arc::clone(&roams));
        let (base_url, device_id) = (server.base_url.clone(), device_id.clone());
        load.push(tokio::spawn(async move {
            while !stop.load(Ordering::Relaxed) {
                pool.network_changed(base_url.clone(), "user:alice".into(), "team".into(), device_id.clone())
                    .await;
                roams.fetch_add(1, Ordering::Relaxed);
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        }));
    }
    tokio::time::sleep(Duration::from_secs(2)).await;
    let loaded = sample(&probe).await;
    stop.store(true, Ordering::Relaxed);
    for task in load {
        task.abort();
    }

    // The probe link still carries a frame after the storm.
    let channel = probe.open_channel("echo".into(), String::new()).await.expect("channel after the storm");
    channel.send(b"after".to_vec()).await.unwrap();
    let back =
        tokio::time::timeout(Duration::from_secs(5), channel.recv()).await.expect("a frame after the storm");
    assert_eq!(back, ChannelMessage::Data { bytes: b"after".to_vec() });

    println!(
        "LINK_UNDER_LOAD {}",
        json!({"macs": MACS, "roams": roams.load(Ordering::Relaxed), "idle": row(&idle), "loaded": row(&loaded)})
    );
    for phone in &links {
        phone.close();
    }
    assert_eq!(loaded.failed, 0, "{} of {SAMPLES} pings under load got no answer in 5 s", loaded.failed);
    assert!(
        loaded.p95 < LOADED_P95_BOUND_MS,
        "ping p95 under load {:.1} ms (idle {:.1} ms): the shared work starves the tunnel",
        loaded.p95,
        idle.p95
    );
}
