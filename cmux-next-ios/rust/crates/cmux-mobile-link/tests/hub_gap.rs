//! The measured gap when the Mac dies mid-stream (RFD 0142 R6), before and
//! after the three-way hub, over LTE, five seeds. Replaces the 5600 ms that
//! `cmux-transport`'s `hub_scoreboard` derived from the timings.
//!
//! The session's log makes one event every [`PERIOD`]; the Mac dies just
//! after event [`KILL_AT`]. The gap is the phone's longest silence across
//! the kill: from the last event it got before it to the next one.
//!
//! Before: one source at a time, today's reconnect. The phone holds a real
//! WireGuard link to the Mac, every datagram both ends receive on the LTE
//! profile (`testing::shape_by_profile`, cmux-fault's `link-profiles.json`
//! per datagram: the TCP `Shaper` cannot carry WireGuard's UDP). It reads
//! the stream on the controller's own path: the link controller's state
//! machine (`reconnect::Machine`), its heartbeat (a probe after a quiet
//! [`timings::HEARTBEAT`], bounded by [`timings::PROBE_TIMEOUT`] plus
//! [`timings::PROBE_GRACE`]) and the link's suspect signal (the quick probe,
//! [`timings::PRESENCE_PROBE_TIMEOUT`]), as `LinkController.swift` runs
//! them. The Mac's tunnel goes dark (`simulate_blackout`) and it stops
//! writing. When the probe fails the machine asks for a redial; the runner
//! dials the AutoCloud VM, which holds the same log, and resumes from the
//! last event. Today's app redials the sleeping Mac and waits for it, so
//! this "before" is the best a one-source reconnect can do.
//!
//! After: the hub. The Mac and the VM publish every event to the session's
//! room (`testing::FakeHub`, the Worker's relay rule), the phone views it,
//! each of the three connections through its own cmux-fault `Shaper` on the
//! `lte` profile. The Mac's shaper goes dark and it stops writing.
//!
//! `cargo test -p cmux-mobile-link --test hub_gap -- --ignored --nocapture`

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_fault::Trace;
use cmux_fault::shaper::{ProfileFile, Shaper};
use cmux_mobile_link::dial::{self, SessionEvents, wireguard};
use cmux_mobile_link::hub::{HubParams, HubSource, HubViewer, ViewerEvent};
use cmux_mobile_link::reconnect::{Effect, Event, Machine, Target, timings};
use cmux_mobile_link::testing::{
    FakeHub, FakeHubMode, FakeOptions, FakeSignaling, set_link_profile, shape_by_profile,
};
use cmux_mobile_link::{ChannelEvent, DialOptions, LinkConfig, SignalingClient, TransportKind};
use cmux_transport::hub::{HubPos, HubRole};
use cmux_transport::hub_truth::{TruthConfig, TruthEvent};

/// One event of the session's log every 50 ms (a streaming agent turn).
const PERIOD: Duration = Duration::from_millis(50);
const EVENTS: u64 = 160;
/// The Mac dies just after writing this event.
const KILL_AT: u64 = 40;
/// An ACP event's size, about.
const EVENT_BYTES: usize = 200;
const SEEDS: [u64; 5] = [1, 2, 3, 4, 5];
const PROFILE: &str = "lte";

/// When event `seq` of the log is written.
fn written(start: Instant, seq: u64) -> Instant {
    start + PERIOD * seq as u32
}

fn event(seq: u64) -> Vec<u8> {
    let mut out = seq.to_be_bytes().to_vec();
    out.resize(EVENT_BYTES, b'.');
    out
}

#[derive(Debug)]
struct Run {
    /// The phone's silence across the kill: the last event the Mac wrote
    /// arriving, to the first event after it arriving.
    gap: Duration,
    /// How late the first event after the kill arrived, from when it was written.
    next_late: Duration,
    /// The latest any event arrived after it was written.
    worst_late: Duration,
    missing: u64,
    duplicates: u64,
}

fn score(start: Instant, arrivals: &[(u64, Instant)]) -> Run {
    let mut first = BTreeMap::new();
    let mut duplicates = 0;
    for (seq, at) in arrivals {
        if first.insert(*seq, *at).is_some() {
            duplicates += 1;
        }
    }
    let missing = (1..=EVENTS).filter(|seq| !first.contains_key(seq)).count() as u64;
    // The stall a user sees: from the last event the dead Mac wrote reaching the
    // phone to the first event after it reaching the phone.
    let last_before = first.range(..=KILL_AT).map(|(_, at)| *at).max();
    let first_after = first.range(KILL_AT + 1..).map(|(_, at)| *at).min();
    let gap = match (last_before, first_after) {
        (Some(before), Some(after)) => after.saturating_duration_since(before),
        _ => Duration::MAX,
    };
    let next_late = first
        .get(&(KILL_AT + 1))
        .map_or(Duration::MAX, |at| at.saturating_duration_since(written(start, KILL_AT + 1)));
    let worst_late = first
        .iter()
        .map(|(seq, at)| at.saturating_duration_since(written(start, *seq)))
        .max()
        .unwrap_or(Duration::MAX);
    Run { gap, next_late, worst_late, missing, duplicates }
}

fn tunnel_options() -> DialOptions {
    // A lost handshake message costs WireGuard a 5 s retry: room for a few.
    DialOptions {
        include_loopback: true,
        impair_inbound: Some(shape_by_profile),
        timeout: Duration::from_secs(40),
        ..DialOptions::default()
    }
}

/// A source device on the fake signaling server: answers each dial and
/// serves `stream` from the `from` its args name, on the log's clock, until
/// `alive` goes false.
async fn serve_source(
    server: &FakeSignaling,
    start: Arc<OnceLock<Instant>>,
    alive: Arc<AtomicBool>,
) -> String {
    let id = uuid::Uuid::new_v4().to_string();
    let client = SignalingClient::connect(&server.base_url, "user:alice", "team", &id).await.unwrap();
    tokio::spawn(async move {
        while let Some(session) = client.next_session().await {
            let events = SessionEvents {
                backend: client.events(),
                session_id: session.first.session_id.clone(),
                session: session.events,
            };
            let (client, start, alive) = (client.clone(), Arc::clone(&start), Arc::clone(&alive));
            tokio::spawn(async move {
                let config = LinkConfig { foreground_probe: false, ..LinkConfig::default() };
                let Ok(connected) =
                    dial::answer(&client, session.first, events, &tunnel_options(), config).await
                else {
                    return;
                };
                while let Some(incoming) = connected.link.accept().await {
                    if incoming.service != "stream" {
                        continue;
                    }
                    let from = incoming.args["from"].as_u64().unwrap_or(1);
                    let (start, alive) = (*start.get().expect("the log started"), Arc::clone(&alive));
                    tokio::spawn(async move {
                        let channel = incoming.channel;
                        for seq in from..=EVENTS {
                            tokio::time::sleep_until(written(start, seq).into()).await;
                            if !alive.load(Ordering::SeqCst)
                                || channel.send(Bytes::from(event(seq))).await.is_err()
                            {
                                return;
                            }
                        }
                        // Keep the channel open until the run ends.
                        std::future::pending::<()>().await;
                    });
                }
            });
        }
    });
    id
}

/// Reads `[u64 seq]...` events into `arrivals`.
fn read_stream(
    channel: cmux_mobile_link::Channel,
    arrivals: Arc<Mutex<Vec<(u64, Instant)>>>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let (_sender, mut receiver) = channel.split();
        while let Some(ChannelEvent::Data(bytes)) = receiver.recv().await {
            let seq = u64::from_be_bytes(bytes[..8].try_into().unwrap());
            arrivals.lock().unwrap().push((seq, Instant::now()));
        }
    })
}

async fn before(seed: u64) -> (Run, Duration, Duration) {
    set_link_profile(Some(cmux_mobile_link::testing::LinkProfile::named(PROFILE)), seed);
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let start = Arc::new(OnceLock::new());
    let mac_alive = Arc::new(AtomicBool::new(true));
    let mac_id = serve_source(&server, Arc::clone(&start), Arc::clone(&mac_alive)).await;
    let vm_id = serve_source(&server, Arc::clone(&start), Arc::new(AtomicBool::new(true))).await;
    let phone_id = uuid::Uuid::new_v4().to_string();
    let phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    let phone_config = LinkConfig { foreground_probe: true, ..LinkConfig::default() };

    // The controller's machine picks the Mac and asks for a dial.
    let mut machine = Machine::new(TransportKind::WireGuard, false, false);
    let effects = machine.handle(&Event::Target(Some(Target {
        mac_id: mac_id.clone(),
        name: "mac".into(),
        is_online: true,
    })));
    let Some(Effect::Dial { generation, mac_id: dial_id, .. }) =
        effects.iter().find(|e| matches!(e, Effect::Dial { .. })).cloned()
    else {
        panic!("no dial: {effects:?}")
    };
    let connected =
        dial::connect(&phone, &dial_id, TransportKind::WireGuard, &tunnel_options(), phone_config.clone())
            .await
            .expect("dial the Mac");
    machine.handle(&Event::DialSucceeded { generation, path: *connected.path.borrow() });
    let session_id = connected.session_id.clone();

    let log_start = Instant::now() + Duration::from_millis(500);
    start.set(log_start).unwrap();
    let arrivals = Arc::new(Mutex::new(Vec::new()));
    let mut readers = vec![read_stream(
        connected.link.open("stream", serde_json::json!({"from": 1})).await.unwrap(),
        Arc::clone(&arrivals),
    )];

    // The Mac dies just after writing KILL_AT.
    let killed = written(log_start, KILL_AT) + PERIOD / 2;
    {
        let (mac_alive, session_id) = (Arc::clone(&mac_alive), session_id.clone());
        tokio::spawn(async move {
            tokio::time::sleep_until(killed.into()).await;
            mac_alive.store(false, Ordering::SeqCst);
            assert_eq!(wireguard::simulate_blackout(Some(&session_id), false, true), 1);
        });
    }

    // The controller's heartbeat and suspect probes, as LinkController.swift runs them.
    let link = connected.link.clone();
    let mut suspect = link.suspect_state();
    let mut wait = timings::HEARTBEAT;
    let failure = loop {
        let timeout = tokio::select! {
            _ = tokio::time::sleep(wait) => {
                let quiet = link.received_ago();
                if quiet < timings::HEARTBEAT {
                    wait = timings::HEARTBEAT - quiet;
                    continue;
                }
                wait = timings::HEARTBEAT;
                timings::PROBE_TIMEOUT
            }
            changed = suspect.changed() => {
                if changed.is_err() || !*suspect.borrow_and_update() {
                    continue;
                }
                timings::PRESENCE_PROBE_TIMEOUT
            }
        };
        match tokio::time::timeout(timeout + timings::PROBE_GRACE, link.probe(timeout)).await {
            Ok(Ok(_)) => {}
            Ok(Err(error)) => break error.to_string(),
            Err(_) => break "probe bound".to_owned(),
        }
        if Instant::now() > written(log_start, EVENTS) + Duration::from_secs(30) {
            panic!("seed {seed}: the dead Mac was never noticed");
        }
    };
    let detected = Instant::now();
    let effects = machine.handle(&Event::ProbeFailed { generation, reason: failure });
    let Some(Effect::Dial { generation: redial, .. }) =
        effects.iter().find(|e| matches!(e, Effect::Dial { .. })).cloned()
    else {
        panic!("no redial: {effects:?}")
    };
    // The redial goes to the source that is up: the VM (see the module doc).
    let vm = dial::connect(&phone, &vm_id, TransportKind::WireGuard, &tunnel_options(), phone_config)
        .await
        .expect("dial the VM");
    let redialed = Instant::now();
    machine.handle(&Event::DialSucceeded { generation: redial, path: *vm.path.borrow() });
    let resume = arrivals.lock().unwrap().iter().map(|(seq, _)| *seq).max().unwrap_or(0) + 1;
    readers.push(read_stream(
        vm.link.open("stream", serde_json::json!({"from": resume})).await.unwrap(),
        Arc::clone(&arrivals),
    ));

    let deadline = written(log_start, EVENTS) + Duration::from_secs(20);
    while Instant::now() < deadline && arrivals.lock().unwrap().iter().all(|(seq, _)| *seq != EVENTS) {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    tokio::time::sleep(Duration::from_millis(300)).await;
    for reader in readers {
        reader.abort();
    }
    connected.link.close("done");
    vm.link.close("done");
    wireguard::simulate_blackout(Some(&session_id), false, false);
    set_link_profile(None, 0);
    let arrivals = arrivals.lock().unwrap().clone();
    (score(log_start, &arrivals), detected.saturating_duration_since(killed), redialed - detected)
}

async fn after(seed: u64) -> (Run, u64) {
    let profile = ProfileFile::builtin().get(PROFILE).expect("lte profile").clone();
    let trace = Trace::default();
    let hub = FakeHub::start(FakeHubMode::Hub).await.unwrap();
    let shaper = |n: u64| Shaper::start(hub.addr(), profile.clone(), seed * 10 + n, &trace);
    let (phone_link, mac_link, vm_link) =
        (shaper(0).await.unwrap(), shaper(1).await.unwrap(), shaper(2).await.unwrap());
    let session = uuid::Uuid::new_v4();
    let params = |via: &Shaper| HubParams {
        base_url: format!("http://{}", via.addr()),
        token: "user:alice".into(),
        build_space: None,
        session,
        device_id: uuid::Uuid::new_v4().to_string(),
        secret: [42; 32],
    };
    let mut viewer =
        HubViewer::join(&params(&phone_link), TruthConfig::default()).await.expect("viewer joins");
    let mac = HubSource::join(&params(&mac_link), HubRole::Mac).await.expect("mac joins");
    let vm = HubSource::join(&params(&vm_link), HubRole::Vm).await.expect("vm joins");

    let log_start = Instant::now() + Duration::from_millis(500);
    let killed = written(log_start, KILL_AT) + PERIOD / 2;
    let arrivals = Arc::new(Mutex::new(Vec::new()));
    let reader = {
        let arrivals = Arc::clone(&arrivals);
        tokio::spawn(async move {
            while let Some(event) = viewer.next().await {
                match event {
                    ViewerEvent::Truth(TruthEvent::Deliver { pos, .. }) => {
                        arrivals.lock().unwrap().push((pos.seq, Instant::now()));
                    }
                    ViewerEvent::Closed => break,
                    _ => {}
                }
            }
            viewer.bytes_received()
        })
    };
    let mac_writer = tokio::spawn(async move {
        for seq in 1..=EVENTS {
            tokio::time::sleep_until(written(log_start, seq).into()).await;
            if Instant::now() >= killed {
                // The Mac sleeps: its writes stop and its socket goes dark.
                mac_link.blackout(Duration::from_secs(120));
                return mac;
            }
            mac.publish(HubPos::new(1, seq), &event(seq)).unwrap();
        }
        mac
    });
    for seq in 1..=EVENTS {
        tokio::time::sleep_until(written(log_start, seq).into()).await;
        vm.publish(HubPos::new(1, seq), &event(seq)).unwrap();
    }
    let deadline = written(log_start, EVENTS) + Duration::from_secs(20);
    while Instant::now() < deadline && arrivals.lock().unwrap().iter().all(|(seq, _)| *seq != EVENTS) {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    tokio::time::sleep(Duration::from_millis(300)).await;
    let _mac = mac_writer.await;
    reader.abort();
    let stats = hub.stats(&session);
    let arrivals = arrivals.lock().unwrap().clone();
    (score(log_start, &arrivals), stats.dropped)
}

fn p50_worst(values: impl Iterator<Item = Duration>) -> (Duration, Duration) {
    let mut values: Vec<Duration> = values.collect();
    values.sort();
    (values[values.len() / 2], *values.last().unwrap())
}

/// The numbers RFD 0142 R6 quotes. Timed (about two minutes); run by hand.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "timed measurement, about two minutes"]
async fn hub_gap_when_the_mac_dies_mid_stream() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_test_writer()
        .try_init();
    let ms = |d: Duration| d.as_millis();
    let mut befores = Vec::new();
    let mut afters = Vec::new();
    for seed in SEEDS {
        let (run, detect, redial) = before(seed).await;
        eprintln!(
            "HUBGAP before seed={seed} profile={PROFILE} gap_ms={} next_late_ms={} worst_late_ms={} missing={} dups={} detect_ms={} redial_ms={}",
            ms(run.gap),
            ms(run.next_late),
            ms(run.worst_late),
            run.missing,
            run.duplicates,
            ms(detect),
            ms(redial)
        );
        befores.push(run);
        let (run, dropped) = after(seed).await;
        eprintln!(
            "HUBGAP after  seed={seed} profile={PROFILE} gap_ms={} next_late_ms={} worst_late_ms={} missing={} dups={} relay_dropped={dropped}",
            ms(run.gap),
            ms(run.next_late),
            ms(run.worst_late),
            run.missing,
            run.duplicates
        );
        afters.push(run);
    }
    // The headline is the stall a user sees: how late the first event after
    // the kill reaches the phone. The arrival-to-arrival gap reads short when
    // the last events before the kill were stuck behind the dead link too.
    let (bp50, bworst) = p50_worst(befores.iter().map(|r| r.next_late));
    let (ap50, aworst) = p50_worst(afters.iter().map(|r| r.next_late));
    let (bg50, bgw) = p50_worst(befores.iter().map(|r| r.gap));
    let (ag50, agw) = p50_worst(afters.iter().map(|r| r.gap));
    eprintln!(
        "HUBGAP summary profile={PROFILE} seeds={} events every {} ms, Mac dies after event {KILL_AT}: first event after the kill late by p50/worst: before {}/{} ms, after {}/{} ms; arrival gap p50/worst: before {}/{} ms, after {}/{} ms",
        SEEDS.len(),
        ms(PERIOD),
        ms(bp50),
        ms(bworst),
        ms(ap50),
        ms(aworst),
        ms(bg50),
        ms(bgw),
        ms(ag50),
        ms(agw)
    );
    for run in befores.iter().chain(&afters) {
        assert_eq!(run.missing, 0, "{run:?}");
        assert_eq!(run.duplicates, 0, "{run:?}");
    }
    assert!(aworst < bp50, "the hub must beat the reconnect: after worst {aworst:?}, before p50 {bp50:?}");
}
