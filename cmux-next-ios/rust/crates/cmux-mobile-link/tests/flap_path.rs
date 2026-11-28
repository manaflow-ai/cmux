//! A flapping Wi-Fi/cellular path: the phone's network goes away and a new
//! one takes over, again and again (Leo's ask-7a463b923d: "Do not call it
//! fixed until a new Mac NIGHTLY and iOS/TestFlight build are both
//! exercised on a flapping Wi-Fi/cellular path. The likely trigger is
//! #54697, but that remains unbisected").
//!
//! Each flap: the current socket stops working, the OS reports the new path
//! `FLAP_ROAM_MS` later (default 300), and the stream must resume. The test
//! prints one line per flap with the time from the loss to the first echoed
//! byte after the network came back, and fails if any flap takes longer than
//! `FLAP_BOUND_MS` (default 3000) or loses a byte. `FLAP_MODE` picks the
//! flap: `roam` (default), `late` or `dark`.
//!
//! `FLAPS=20 cargo test -p cmux-mobile-link --test flap_path -- --nocapture`

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_mobile_link::dial::{self, SessionEvents, wireguard};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_mobile_link::{ChannelEvent, DialOptions, LinkConfig, LinkPath, SignalingClient, TransportKind};

fn env_u64(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

fn options() -> DialOptions {
    DialOptions { include_loopback: true, timeout: Duration::from_secs(20), ..DialOptions::default() }
}

fn pattern(start: usize, len: usize) -> Vec<u8> {
    (start..start + len).map(|i| (i % 251) as u8).collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_reconnects_across_twenty_flaps() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_test_writer()
        .try_init();
    let flaps = env_u64("FLAPS", 20) as usize;
    // `roam`: the network goes away and the OS reports a new one
    // `FLAP_ROAM_MS` later (default 300). `late`: the same, reported 3 s
    // later. `dark`: the network goes dark and comes back `FLAP_ROAM_MS`
    // later (default 2000) on the same socket, with no OS event, so only
    // the link's own probes can notice it is back (what #54697 changed).
    let mode = std::env::var("FLAP_MODE").unwrap_or_else(|_| "roam".into());
    let default_ms = match mode.as_str() {
        "roam" => 300,
        "late" => 3000,
        "dark" => 2000,
        other => panic!("FLAP_MODE {other}: roam, late or dark"),
    };
    let roam_after = Duration::from_millis(env_u64("FLAP_ROAM_MS", default_ms));
    // Time on each network before the next flap: long enough for the
    // proven-path skip (#54697) to kick in on the new path.
    let dwell = Duration::from_millis(env_u64("FLAP_DWELL_MS", 6000));
    let bound = Duration::from_millis(env_u64("FLAP_BOUND_MS", 3000));

    let server = FakeSignaling::start(FakeOptions::default()).await;
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
    let phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    let connected =
        dial::connect(&phone, &mac_id, TransportKind::WireGuard, &options(), LinkConfig::default())
            .await
            .expect("dial");
    let session_id = connected.session_id.clone();
    let mut path = connected.path.clone();
    let _ = tokio::time::timeout(Duration::from_secs(10), path.wait_for(|p| *p != LinkPath::NoPath)).await;
    let channel = connected.link.open("echo", serde_json::json!({})).await.unwrap();
    let (sender, mut receiver) = channel.split();

    // Typing-like plus terminal output: 200 B every 50 ms.
    const CHUNK: usize = 200;
    let stop = Arc::new(AtomicBool::new(false));
    let writer = {
        let stop = Arc::clone(&stop);
        tokio::spawn(async move {
            let mut sent = 0usize;
            let mut tick = tokio::time::interval(Duration::from_millis(50));
            while !stop.load(Ordering::Relaxed) {
                tick.tick().await;
                sender.send(Bytes::from(pattern(sent, CHUNK))).await.expect("send");
                sent += CHUNK;
            }
            (sent, sender)
        })
    };
    let (progress_tx, mut progress) = tokio::sync::watch::channel(0usize);
    let arrivals = Arc::new(std::sync::Mutex::new(Vec::<Instant>::new()));
    let reader = {
        let arrivals = Arc::clone(&arrivals);
        tokio::spawn(async move {
            let mut got = 0usize;
            while let Some(event) = receiver.recv().await {
                match event {
                    ChannelEvent::Data(bytes) => {
                        assert_eq!(&bytes[..], &pattern(got, bytes.len())[..], "echo out of order at {got}");
                        got += bytes.len();
                        arrivals.lock().unwrap().push(Instant::now());
                        progress_tx.send_replace(got);
                    }
                    ChannelEvent::Closed(_) => break,
                }
            }
        })
    };

    tokio::time::sleep(dwell).await;
    let mut gaps = Vec::with_capacity(flaps);
    for flap in 0..flaps {
        let lost_at = Instant::now();
        if mode == "dark" {
            assert_eq!(wireguard::simulate_blackout(Some(&session_id), true, true), 1, "flap {flap}: dark");
        } else {
            assert_eq!(wireguard::simulate_network_loss(Some(&session_id), true), 1, "flap {flap}: loss");
        }
        tokio::time::sleep(roam_after).await;
        // The network is back (dark) or the OS reported the new one.
        let back_at = Instant::now();
        let roam = if mode == "dark" {
            assert_eq!(wireguard::simulate_blackout(Some(&session_id), true, false), 1, "flap {flap}: light");
            None
        } else {
            let session_id = session_id.clone();
            Some(tokio::spawn(async move { wireguard::roam_session(&session_id, true).await }))
        };
        // Reconnected: the first echo that arrives after the network came back.
        let deadline = back_at + bound + Duration::from_secs(10);
        let back = loop {
            if let Some(at) = arrivals.lock().unwrap().iter().find(|at| **at > back_at).copied() {
                break Some(at);
            }
            if Instant::now() > deadline {
                break None;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        };
        if let Some(roam) = roam {
            let _ = roam.await;
        }
        // What the link controls: from the network's return to the first echo.
        let gap = back.map(|at| at.duration_since(back_at));
        eprintln!(
            "flap {:>2} [{mode}]: back->first echo {} (loss->echo {}, outage {} ms), path {:?}",
            flap + 1,
            gap.map(|g| format!("{} ms", g.as_millis())).unwrap_or_else(|| "NEVER".into()),
            back.map(|at| format!("{} ms", at.duration_since(lost_at).as_millis()))
                .unwrap_or_else(|| "-".into()),
            roam_after.as_millis(),
            *connected.path.borrow()
        );
        gaps.push(gap);
        tokio::time::sleep(dwell).await;
    }
    stop.store(true, Ordering::Relaxed);
    let (sent, _sender) = writer.await.unwrap();
    let all =
        tokio::time::timeout(Duration::from_secs(25), progress.wait_for(|got| *got >= sent)).await.is_ok();
    let got = *progress.borrow();
    connected.link.close("done");
    let _ = reader.await;

    let mut ms: Vec<u128> = gaps.iter().flatten().map(|g| g.as_millis()).collect();
    ms.sort_unstable();
    let pick = |q: f64| ms.get(((ms.len() as f64 - 1.0) * q).round() as usize).copied().unwrap_or(0);
    eprintln!(
        "flap summary [{mode}]: {}/{} reconnected (back->first echo), p50 {} ms, p90 {} ms, max {} ms, bytes {}/{}",
        ms.len(),
        flaps,
        pick(0.5),
        pick(0.9),
        ms.last().copied().unwrap_or(0),
        got,
        sent
    );
    assert!(all && got == sent, "bytes lost: sent {sent}, echoed {got}");
    assert_eq!(ms.len(), flaps, "a flap never reconnected");
    assert!(ms.iter().all(|m| *m <= bound.as_millis()), "a flap took over {bound:?}: {ms:?}");
}
