//! Handshake-first redial: a WireGuard link that ended on its own leaves its
//! tunnel dormant on both sides, and the phone's next dial resumes it with
//! no signaling round trip (`dial::wireguard::dormant`), beside the full
//! dial.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_mobile_link::dial::wireguard::dormant::{self, Hedged};
use cmux_mobile_link::dial::{self, SessionEvents, wireguard};
use cmux_mobile_link::signaling::SignalPayload;
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_mobile_link::timing::Timeline;
use cmux_mobile_link::{
    ChannelEvent, DialOptions, Lane, LaneState, LinkConfig, SignalingClient, TransportKind,
};

/// The dormant bound is process-wide: one test at a time.
static SERIAL: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

fn options() -> DialOptions {
    DialOptions { include_loopback: true, timeout: Duration::from_secs(10), ..DialOptions::default() }
}

struct Pair {
    server: FakeSignaling,
    mac_id: String,
    phone_id: String,
    phone: SignalingClient,
    /// Links the Mac answered from a dormant tunnel.
    resumed: Arc<AtomicUsize>,
}

/// A Mac that answers every session (a dialed one or a resumed one) with an
/// echo service, and a phone, on one fake signaling server.
async fn pair() -> Pair {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let resumed = Arc::new(AtomicUsize::new(0));
    let counted = Arc::clone(&resumed);
    tokio::spawn(async move {
        while let Some(session) = mac.next_session().await {
            if matches!(session.first.payload, SignalPayload::WgResumed { .. }) {
                counted.fetch_add(1, Ordering::Relaxed);
            }
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
    let phone_id = uuid::Uuid::new_v4().to_string();
    let phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    Pair { server, mac_id, phone_id, phone, resumed }
}

async fn echo(link: &cmux_mobile_link::Link) {
    let mut channel = link.open("echo", serde_json::json!({})).await.expect("echo channel");
    channel.send(Bytes::from_static(b"ping")).await.expect("send");
    let reply = tokio::time::timeout(Duration::from_secs(5), channel.recv()).await.expect("echo in time");
    assert!(matches!(reply, Some(ChannelEvent::Data(bytes)) if &bytes[..] == b"ping"), "echoed");
}

async fn wait_until(what: &str, within: Duration, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + within;
    while !done() {
        assert!(Instant::now() < deadline, "{what} within {within:?}");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

/// Dial, echo once, then end the link as a keepalive timeout does: both
/// tunnels go dormant.
async fn linked_then_lost(pair: &Pair) {
    let connected =
        dial::connect(&pair.phone, &pair.mac_id, TransportKind::WireGuard, &options(), LinkConfig::default())
            .await
            .expect("first dial");
    echo(&connected.link).await;
    connected.link.close("keepalive timed out");
    drop(connected);
    wait_until("both tunnels dormant", Duration::from_secs(5), || {
        dormant::ticket(&pair.mac_id).is_some() && dormant::keeps(&pair.phone_id)
    })
    .await;
}

/// A redial within the bound links over the dormant tunnel while the full
/// dial is stuck (its signaling slowed by 10 s) and when the phone's
/// signaling socket is gone: no signaling round trip.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_redial_within_the_bound_links_with_no_signaling() {
    let _serial = SERIAL.lock().await;
    dormant::set_hold_for_tests(None);
    let pair = pair().await;

    // Signaling slowed: the full dial does not start for 10 s.
    linked_then_lost(&pair).await;
    let ticket = dormant::ticket(&pair.mac_id);
    let timeline = Timeline::new();
    let started = Instant::now();
    let slowed = async {
        tokio::time::sleep(Duration::from_secs(10)).await;
        dial::connect(&pair.phone, &pair.mac_id, TransportKind::WireGuard, &options(), LinkConfig::default())
            .await
    };
    let won = dormant::hedged(ticket, LinkConfig::default(), &timeline, slowed).await.expect("redial");
    let Hedged::Resumed(connected) = won else { panic!("the full dial won over a 10 s signaling stall") };
    echo(&connected.link).await;
    let elapsed = started.elapsed();
    assert!(elapsed < Duration::from_secs(2), "resumed and echoed in {elapsed:?}");
    assert_eq!(pair.resumed.load(Ordering::Relaxed), 1, "the Mac served it as a resumed link");
    assert!(timeline.get("dormant_resume").is_some() && timeline.get("link_ready").is_some());

    // Signaling dropped: the phone's socket is gone and the full dial fails.
    connected.link.close("keepalive timed out");
    drop(connected);
    wait_until("dormant again", Duration::from_secs(5), || {
        dormant::ticket(&pair.mac_id).is_some() && dormant::keeps(&pair.phone_id)
    })
    .await;
    pair.server.kick(&pair.phone_id);
    let ticket = dormant::ticket(&pair.mac_id);
    let dropped = async {
        tokio::time::sleep(Duration::from_millis(50)).await;
        dial::connect(&pair.phone, &pair.mac_id, TransportKind::WireGuard, &options(), LinkConfig::default())
            .await
    };
    let won =
        dormant::hedged(ticket, LinkConfig::default(), &Timeline::new(), dropped).await.expect("redial");
    let Hedged::Resumed(connected) = won else { panic!("no resume with signaling dropped") };
    echo(&connected.link).await;
    assert_eq!(pair.resumed.load(Ordering::Relaxed), 2);
    connected.link.close("done");
}

/// A dormant tunnel whose Mac end is gone (dark, as a Mac that slept or lost
/// its network) falls back to the full dial with no delay beyond the full
/// dial's own.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_dead_dormant_endpoint_falls_back_to_the_full_dial() {
    let _serial = SERIAL.lock().await;
    dormant::set_hold_for_tests(None);
    let pair = pair().await;

    // The full dial alone, for its time on this machine.
    let started = Instant::now();
    let solo =
        dial::connect(&pair.phone, &pair.mac_id, TransportKind::WireGuard, &options(), LinkConfig::default())
            .await
            .expect("solo dial");
    let solo_time = started.elapsed();
    solo.link.close("done");
    drop(solo);

    linked_then_lost(&pair).await;
    // The Mac's end of the dormant tunnel goes dark.
    assert!(wireguard::simulate_blackout(None, false, true) >= 1);
    let ticket = dormant::ticket(&pair.mac_id);
    let timeline = Timeline::new();
    let started = Instant::now();
    let full_options = options();
    let full = dial::connect(
        &pair.phone,
        &pair.mac_id,
        TransportKind::WireGuard,
        &full_options,
        LinkConfig::default(),
    );
    let won = dormant::hedged(ticket, LinkConfig::default(), &timeline, full).await.expect("redial");
    let hedged_time = started.elapsed();
    let Hedged::Full(connected) = won else { panic!("resumed over a dark tunnel") };
    echo(&connected.link).await;
    assert!(
        hedged_time < solo_time + Duration::from_millis(500),
        "hedged {hedged_time:?} against the full dial's {solo_time:?}"
    );
    assert_eq!(pair.resumed.load(Ordering::Relaxed), 0);
    // The losing resume closed the phone's dormant tunnel.
    assert!(dormant::ticket(&pair.mac_id).is_none());
    connected.link.close("done");
}

/// The dormant state ends at its bound on both sides; an app's close never
/// leaves one.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_dormant_tunnel_clears_at_its_bound() {
    let _serial = SERIAL.lock().await;
    dormant::set_hold_for_tests(Some(Duration::from_millis(800)));
    let pair = pair().await;
    linked_then_lost(&pair).await;
    tokio::time::sleep(Duration::from_millis(1200)).await;
    assert!(dormant::ticket(&pair.mac_id).is_none(), "the phone's dormant tunnel outlived its bound");
    assert!(!dormant::keeps(&pair.phone_id), "the Mac's dormant tunnel outlived its bound");

    // Closed on purpose: nothing is kept.
    let connected =
        dial::connect(&pair.phone, &pair.mac_id, TransportKind::WireGuard, &options(), LinkConfig::default())
            .await
            .expect("dial");
    echo(&connected.link).await;
    connected.link.close("closed by the app");
    drop(connected);
    assert!(dormant::ticket(&pair.mac_id).is_none(), "an app's close left the phone a dormant tunnel");
    wait_until("the Mac drops its tunnel on the phone's bye", Duration::from_millis(700), || {
        !dormant::keeps(&pair.phone_id)
    })
    .await;

    // Removing the phone ends the Mac's dormant tunnel at once.
    linked_then_lost(&pair).await;
    assert_eq!(dormant::forget(&pair.phone_id), 1);
    assert!(!dormant::keeps(&pair.phone_id));
    dormant::set_hold_for_tests(None);
}

/// Lockstep: no new message goes on the wire (a resumed link is a new
/// connection inside the tunnel both sides already run), so an old build on
/// either side keeps working. A new phone with an old Mac (its tunnel ended
/// with the link and it said `bye`): the phone keeps no ticket, or its
/// resume misses and the full dial links as fast as alone. A new Mac with an
/// old phone: the phone's `bye` ends the Mac's dormant tunnel, and its full
/// dial links.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_old_side_on_either_end_still_links() {
    let _serial = SERIAL.lock().await;
    dormant::set_hold_for_tests(None);

    // New phone, old Mac.
    dormant::act_old_for_tests(false, true);
    let old_mac = pair().await;
    let connected = dial::connect(
        &old_mac.phone,
        &old_mac.mac_id,
        TransportKind::WireGuard,
        &options(),
        LinkConfig::default(),
    )
    .await
    .expect("dial an old Mac");
    echo(&connected.link).await;
    connected.link.close("keepalive timed out");
    drop(connected);
    // The old Mac's bye ends the phone's dormant tunnel.
    wait_until("the old Mac's bye ends the phone's dormant tunnel", Duration::from_secs(2), || {
        dormant::ticket(&old_mac.mac_id).is_none()
    })
    .await;
    assert!(!dormant::keeps(&old_mac.phone_id));
    let ticket = dormant::ticket(&old_mac.mac_id);
    let full_options = options();
    let full = dial::connect(
        &old_mac.phone,
        &old_mac.mac_id,
        TransportKind::WireGuard,
        &full_options,
        LinkConfig::default(),
    );
    let won = dormant::hedged(ticket, LinkConfig::default(), &Timeline::new(), full).await.expect("redial");
    let Hedged::Full(connected) = won else { panic!("resumed on an old Mac") };
    echo(&connected.link).await;
    connected.link.close("done");
    drop(connected);
    dormant::act_old_for_tests(false, false);

    // Old phone, new Mac.
    dormant::act_old_for_tests(true, true);
    let pair = pair().await;
    let connected =
        dial::connect(&pair.phone, &pair.mac_id, TransportKind::WireGuard, &options(), LinkConfig::default())
            .await
            .expect("an old phone dials");
    echo(&connected.link).await;
    connected.link.close("keepalive timed out");
    drop(connected);
    assert!(dormant::ticket(&pair.mac_id).is_none(), "an old phone keeps no ticket");
    wait_until("the old phone's bye ends the Mac's dormant tunnel", Duration::from_secs(2), || {
        !dormant::keeps(&pair.phone_id)
    })
    .await;
    let connected =
        dial::connect(&pair.phone, &pair.mac_id, TransportKind::WireGuard, &options(), LinkConfig::default())
            .await
            .expect("an old phone redials");
    echo(&connected.link).await;
    assert_eq!(pair.resumed.load(Ordering::Relaxed), 0);
    connected.link.close("done");
    dormant::act_old_for_tests(true, false);
}

/// Send `keys` on a fresh input-lane echo channel at once (the lane may
/// still be opening) and read them back: each exactly once, in order, and
/// nothing after them.
async fn type_keys(link: &cmux_mobile_link::Link, keys: std::ops::Range<u32>) {
    let mut channel = link.open_on("echo", serde_json::json!({}), Lane::Input).await.expect("input channel");
    for key in keys.clone() {
        channel.send(Bytes::from(key.to_be_bytes().to_vec())).await.expect("send a key");
    }
    let mut got = Vec::new();
    let mut pending = Vec::new();
    while got.len() < keys.len() {
        let event = tokio::time::timeout(Duration::from_secs(10), channel.recv()).await;
        match event.expect("every key echoed in time") {
            Some(ChannelEvent::Data(bytes)) => {
                pending.extend_from_slice(&bytes);
                while pending.len() >= 4 {
                    let key: Vec<u8> = pending.drain(..4).collect();
                    got.push(u32::from_be_bytes(key.try_into().unwrap()));
                }
            }
            other => panic!("the input channel ended: {other:?}"),
        }
    }
    assert_eq!(got, keys.clone().collect::<Vec<_>>(), "each key once, in order");
    let extra = tokio::time::timeout(Duration::from_millis(300), channel.recv()).await;
    assert!(extra.is_err(), "nothing after the keys: {extra:?}");
}

/// Leo's phone on weak LTE, 2026-11-25 ("I also just can't seem to send
/// messages into terminal from iOS to Mac right now in the terminal"): a
/// fresh dial raced a dormant resume, and the Mac paired the input lane by
/// order with whatever came next on the tunnel, ending links and stalling
/// resumes. Now input typed during and after each reconnect arrives once
/// and in order, the winner's lane pairs, and the loser never ends it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn input_across_a_fresh_dial_racing_a_dormant_resume_arrives_once_in_order() {
    let _serial = SERIAL.lock().await;
    dormant::set_hold_for_tests(None);
    let pair = pair().await;
    linked_then_lost(&pair).await;
    let mut next = 0u32;
    for round in 0..3 {
        let ticket = dormant::ticket(&pair.mac_id);
        assert!(ticket.is_some(), "round {round}: a dormant tunnel to resume");
        // No head start: the full dial and the resume race.
        let dial_options = options();
        let full = dial::connect(
            &pair.phone,
            &pair.mac_id,
            TransportKind::WireGuard,
            &dial_options,
            LinkConfig::default(),
        );
        let won =
            dormant::hedged(ticket, LinkConfig::default(), &Timeline::new(), full).await.expect("redial");
        let link = match won {
            Hedged::Resumed(connected) => connected.link,
            Hedged::Full(dialed) => dialed.link,
        };
        // During: typed the moment the link is back, its lane still opening.
        type_keys(&link, next..next + 20).await;
        next += 20;
        // After: once the loser's lane wait is long over the winner still
        // carries input, on its own lane.
        tokio::time::sleep(Duration::from_secs(3)).await;
        assert!(!link.is_closed(), "round {round}: the race's loser ended the winner");
        assert_eq!(link.input_lane(), LaneState::Ready, "round {round}: the winner's lane paired");
        type_keys(&link, next..next + 20).await;
        next += 20;
        link.close("keepalive timed out");
        drop(link);
        wait_until("dormant again", Duration::from_secs(5), || {
            dormant::ticket(&pair.mac_id).is_some() && dormant::keeps(&pair.phone_id)
        })
        .await;
    }
}
