//! The relay-held send queue end to end (RFD 0142 R8, the harness's mac-asleep x send cell): a phone and a
//! Mac on a real WireGuard link over the fake backend's relay (`testing.rs`, which keeps held items as the
//! Worker's `LinkRelay` does), the phone's [`HoldRoute`] and the Mac's [`drain_held`] on their sessions'
//! relay sockets. Each run puts the Mac to sleep (its relay socket killed, its joins frozen until it
//! wakes), sends, wakes it, and checks the send was answered at once, applied exactly once on wake, and
//! reported delivered; every other run also kills the phone's relay socket while the item is held.
//!
//! `RELAY_HOLD_RUNS` runs (default 10) per mode: `idle`, and `duress` (a 50 KB echo loop on the same link
//! and two busy CPU threads throughout). Each mode prints one `ROW` line for the harness table. The Mac's
//! apply here is an in-test spent-id set; hostd's mailbox (its own tests) is what applies it in the app.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_mobile_link::dial::relay::RelayEndpoint;
use cmux_mobile_link::dial::wireguard::relay_hold_port;
use cmux_mobile_link::dial::{self, SessionEvents};
use cmux_mobile_link::hold_route::{HoldOutcome, HoldRoute, drain_held};
use cmux_mobile_link::relay_hold::SendState;
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_mobile_link::{ChannelEvent, DialOptions, LinkConfig, SignalingClient, TransportKind};

fn options() -> DialOptions {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_test_writer()
        .try_init();
    DialOptions { include_loopback: true, timeout: Duration::from_secs(20), ..DialOptions::default() }
}

fn relay(server: &FakeSignaling, device: &str) -> Option<RelayEndpoint> {
    Some(RelayEndpoint::with_token(server.base_url.clone(), None, device, "user:alice"))
}

/// id -> how many times the Mac applied it.
type Applied = Arc<Mutex<HashMap<String, u32>>>;

/// A Mac that answers over the relay, echoes every channel, and drains held items into `applied` (once per
/// id, as hostd's spent ids do), acking every one it settled.
fn spawn_mac(server: &FakeSignaling, mac: SignalingClient, mac_id: &str, applied: Applied) {
    let endpoint = relay(server, mac_id);
    tokio::spawn(async move {
        while let Some(session) = mac.next_session().await {
            let events = SessionEvents {
                backend: mac.events(),
                session_id: session.first.session_id.clone(),
                session: session.events,
            };
            let options = DialOptions { relay: endpoint.clone(), force_relay: true, ..options() };
            let (mac, applied) = (mac.clone(), Arc::clone(&applied));
            tokio::spawn(async move {
                let Ok(connected) =
                    dial::answer(&mac, session.first, events, &options, LinkConfig::default()).await
                else {
                    return;
                };
                let ports = relay_hold_port(&connected.session_id, false).expect("the Mac's session");
                tokio::spawn(drain_held(ports, move |items| {
                    let applied = Arc::clone(&applied);
                    async move {
                        let mut spent = applied.lock().unwrap();
                        items
                            .into_iter()
                            .map(|item| {
                                *spent.entry(item.id.clone()).or_default() += 1;
                                item.id
                            })
                            .collect()
                    }
                }));
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
}

fn pct(values: &mut [u64], p: f64) -> u64 {
    values.sort_unstable();
    if values.is_empty() {
        return 0;
    }
    values[((values.len() as f64 - 1.0) * p).round() as usize]
}

async fn wait_until(limit: Duration, mut done: impl FnMut() -> bool) -> bool {
    let until = Instant::now() + limit;
    while Instant::now() < until {
        if done() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(2)).await;
    }
    done()
}

async fn cell(duress: bool) {
    let runs: usize = std::env::var("RELAY_HOLD_RUNS").ok().and_then(|v| v.parse().ok()).unwrap_or(10);
    let server = FakeSignaling::start(FakeOptions { relay_hold: true, ..FakeOptions::default() }).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let applied: Applied = Arc::default();
    spawn_mac(&server, mac, &mac_id, Arc::clone(&applied));
    let phone_id = uuid::Uuid::new_v4().to_string();
    let phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    let dial_options = DialOptions { force_relay: true, relay: relay(&server, &phone_id), ..options() };
    let connected =
        dial::connect(&phone, &mac_id, TransportKind::WireGuard, &dial_options, LinkConfig::default())
            .await
            .expect("dial through the relay");
    let route = HoldRoute::start(relay_hold_port(&connected.session_id, true).expect("the phone's session"));
    // The phone's relay socket is up before the first send.
    assert!(
        wait_until(Duration::from_secs(10), || cmux_mobile_link::dial::wireguard::relay_held(
            &connected.session_id,
            true
        ) == Some(true))
        .await
    );

    let stop = Arc::new(AtomicBool::new(false));
    let mut load = Vec::new();
    let mut flood = None;
    if duress {
        for _ in 0..2 {
            let stop = Arc::clone(&stop);
            load.push(std::thread::spawn(move || {
                let mut x = 0u64;
                while !stop.load(Ordering::Relaxed) {
                    x = x.wrapping_mul(6364136223846793005).wrapping_add(1);
                    std::hint::black_box(x);
                }
            }));
        }
        let mut channel = connected.link.open("echo", serde_json::json!({})).await.unwrap();
        let stop = Arc::clone(&stop);
        flood = Some(tokio::spawn(async move {
            let mut round = 0u8;
            while !stop.load(Ordering::Relaxed) {
                if channel.send(Bytes::from(vec![round; 50_000])).await.is_err() {
                    return;
                }
                let mut got = 0;
                while got < 50_000 {
                    match tokio::time::timeout(Duration::from_secs(5), channel.recv()).await {
                        Ok(Some(ChannelEvent::Data(bytes))) => got += bytes.len(),
                        // The Mac is asleep half the time: its echo waits for the wake.
                        Err(_) => {}
                        Ok(_) => return,
                    }
                }
                round = round.wrapping_add(1);
            }
        }));
    }

    let (mut accept, mut apply, mut delivered) = (Vec::new(), Vec::new(), Vec::new());
    let mut failures = Vec::new();
    for run in 0..runs {
        server.set_asleep(&mac_id, true);
        // The relay has dropped the Mac's socket.
        tokio::time::sleep(Duration::from_millis(100)).await;
        let id = uuid::Uuid::new_v4().to_string();
        let sealed = format!("c2VhbGVk{run:06}");
        let started = Instant::now();
        let outcome = route.send(&id, &sealed, Duration::from_secs(5)).await;
        match outcome {
            HoldOutcome::Accepted { .. } => accept.push(started.elapsed().as_millis() as u64),
            other => {
                failures.push(format!("run {run}: send {other:?}"));
                server.set_asleep(&mac_id, false);
                tokio::time::sleep(Duration::from_secs(2)).await;
                continue;
            }
        }
        if run % 2 == 1 {
            // The phone's relay socket dies while the item waits; the relay keeps it.
            server.kick_relay(&phone_id);
        }
        tokio::time::sleep(Duration::from_millis(1000)).await;
        assert_eq!(applied.lock().unwrap().get(&id), None, "nothing reaches a sleeping Mac");
        let woke = Instant::now();
        server.set_asleep(&mac_id, false);
        let got = wait_until(Duration::from_secs(15), || applied.lock().unwrap().contains_key(&id)).await;
        if !got {
            failures.push(format!("run {run}: not applied 15 s after the wake"));
            continue;
        }
        apply.push(woke.elapsed().as_millis() as u64);
        let acked = wait_until(Duration::from_secs(15), || {
            route.state(&id) == Some(SendState::Delivered) || route.state(&id).is_none()
        })
        .await;
        if acked {
            delivered.push(woke.elapsed().as_millis() as u64);
        } else {
            failures.push(format!("run {run}: the phone never heard delivered"));
        }
    }
    stop.store(true, Ordering::Relaxed);
    if let Some(flood) = flood {
        flood.abort();
    }
    for thread in load {
        let _ = thread.join();
    }
    // Once each, nothing left waiting.
    tokio::time::sleep(Duration::from_millis(300)).await;
    let twice: Vec<_> =
        applied.lock().unwrap().iter().filter(|(_, n)| **n != 1).map(|(id, n)| format!("{id}x{n}")).collect();
    let (taken, acked) = server.relay_holds();
    let waiting = server.relay_held_waiting(&connected.session_id);
    let mode = if duress { "duress" } else { "idle" };
    println!(
        "ROW cell=mac-asleep-x-send mode={mode} runs={runs} ok={} accept_p50={}ms accept_p95={}ms accept_max={}ms \
         wake_apply_p50={}ms wake_apply_p95={}ms wake_apply_max={}ms wake_delivered_p50={}ms wake_delivered_p95={}ms \
         applied_twice={} relay_taken={taken} relay_acked={acked} left_waiting={waiting}",
        delivered.len(),
        pct(&mut accept, 0.5),
        pct(&mut accept, 0.95),
        pct(&mut accept, 1.0),
        pct(&mut apply, 0.5),
        pct(&mut apply, 0.95),
        pct(&mut apply, 1.0),
        pct(&mut delivered, 0.5),
        pct(&mut delivered, 0.95),
        twice.len(),
    );
    connected.link.close("done");
    assert!(failures.is_empty(), "{failures:#?}");
    assert!(twice.is_empty(), "applied more than once: {twice:?}");
    assert_eq!(waiting, 0);
    assert_eq!(taken as usize, runs);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_send_to_a_sleeping_mac_is_held_and_applied_once_on_wake() {
    cell(false).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_send_to_a_sleeping_mac_is_held_and_applied_once_on_wake_under_duress() {
    cell(true).await;
}

/// An off relay refuses a hold at once, so the phone routes the same id another way.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_off_relay_refuses_the_hold() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    spawn_mac(&server, mac, &mac_id, Arc::default());
    let phone_id = uuid::Uuid::new_v4().to_string();
    let phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    let dial_options = DialOptions { force_relay: true, relay: relay(&server, &phone_id), ..options() };
    let connected =
        dial::connect(&phone, &mac_id, TransportKind::WireGuard, &dial_options, LinkConfig::default())
            .await
            .expect("dial through the relay");
    let route = HoldRoute::start(relay_hold_port(&connected.session_id, true).unwrap());
    let outcome = route.send(&uuid::Uuid::new_v4().to_string(), "c2VhbGVk", Duration::from_secs(5)).await;
    assert_eq!(outcome, HoldOutcome::Refused(cmux_mobile_link::relay_hold::RefusedCode::Off));
    connected.link.close("done");
}
