//! A 60 s hold of one phone-to-Mac WireGuard link on the network Leo's
//! phone had (2026-11-27, "so between mac and ios connections something
//! broke"): Wi-Fi quality "moderate" the whole time and iOS falling back to
//! cellular 2,891 times in 15 minutes. Here the direct path answers for 1 s
//! and drops everything for the next 1.5 s, both ways, with a 300 ms round
//! trip and 2% loss while up; TURN carries everything with a 300 to 600 ms
//! round trip and 1% loss. The link must hold: no close, no redial, every
//! echoed frame back, and no WireGuard handshake given up (each one a 5 s
//! REKEY_TIMEOUT restart).
//!
//! `IMPAIRED_HOLD_SECS` (default 60) sets the hold. Each run prints one
//! `IMPAIRED_HOLD` line with the counts, for before/after comparisons.

use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_mobile_link::dial::{self, SessionEvents};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling, TestTurn, is_test_relay};
use cmux_mobile_link::{ChannelEvent, DialOptions, LinkConfig, LinkPath, SignalingClient, TransportKind};
use tracing_subscriber::layer::SubscriberExt;

/// When the flap started; every impair call reads it.
static FLAP_START: OnceLock<Instant> = OnceLock::new();
/// A counter-driven loss pattern (deterministic, no RNG crate).
static TICKS: AtomicU64 = AtomicU64::new(0);

/// One in `every` datagrams, spread by a multiplicative hash of a counter.
fn lose(every: u64) -> bool {
    let n = TICKS.fetch_add(1, Ordering::Relaxed);
    n.wrapping_mul(0x9E37_79B9_7F4A_7C15) % every == 0
}

/// Both ends' inbound datagrams. A relayed datagram (through this side's TURN
/// allocation, or from the peer's relayed address) takes 150 to 300 ms one way
/// with 1% loss. A direct one takes 150 ms with 2% loss while the path is up
/// (1 s of every 2.5 s) and is dropped while it is down.
fn impair(through_turn: bool, from: &std::net::SocketAddr, _len: usize) -> Option<Duration> {
    let start = *FLAP_START.get_or_init(Instant::now);
    let elapsed = start.elapsed().as_millis() as u64;
    if through_turn || is_test_relay(from) {
        if lose(100) {
            return None;
        }
        // 150 ms one way, plus a 0 to 150 ms swing every 4 s.
        let swing = (elapsed / 4000) % 2 * 150;
        return Some(Duration::from_millis(150 + swing));
    }
    let up = elapsed % 2500 < 1000;
    if !up || lose(50) {
        return None;
    }
    Some(Duration::from_millis(150))
}

fn options() -> DialOptions {
    DialOptions {
        include_loopback: true,
        impair_inbound: Some(impair),
        timeout: Duration::from_secs(40),
        ..DialOptions::default()
    }
}

/// Counts the tracing events that mean a WireGuard handshake was given up or
/// restarted: boringtun's `HANDSHAKE(REKEY_TIMEOUT)` and `CONNECTION_EXPIRED`.
#[derive(Clone, Default)]
struct HandshakeCounter {
    rekey_timeouts: Arc<AtomicUsize>,
    expired: Arc<AtomicUsize>,
}

struct Message(String);

impl tracing::field::Visit for Message {
    fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
        if field.name() == "message" {
            self.0 = format!("{value:?}");
        }
    }
    fn record_str(&mut self, field: &tracing::field::Field, value: &str) {
        if field.name() == "message" {
            self.0 = value.to_string();
        }
    }
}

impl<S: tracing::Subscriber> tracing_subscriber::Layer<S> for HandshakeCounter {
    fn on_event(&self, event: &tracing::Event<'_>, _: tracing_subscriber::layer::Context<'_, S>) {
        let mut message = Message(String::new());
        event.record(&mut message);
        if message.0.contains("REKEY_TIMEOUT") {
            self.rekey_timeouts.fetch_add(1, Ordering::Relaxed);
        }
        if message.0.contains("CONNECTION_EXPIRED") {
            self.expired.fetch_add(1, Ordering::Relaxed);
        }
    }
}

#[derive(Debug)]
struct Hold {
    secs: u64,
    sessions: usize,
    phone_closed: Option<String>,
    mac_closed: Option<String>,
    sent: usize,
    echoed: usize,
    /// The longest time with no echoed frame arriving.
    longest_gap: Duration,
    /// Gaps of 2 s or more (a user sees the terminal freeze).
    stalls: usize,
    rekey_timeouts: usize,
    expired: usize,
    /// Changes of the phone's path label (Direct, Turn, ...).
    path_flips: usize,
}

async fn hold() -> Hold {
    let counter = HandshakeCounter::default();
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("warn,boringtun=debug"));
    let _ = tracing::subscriber::set_global_default(
        tracing_subscriber::registry()
            .with(filter)
            .with(counter.clone())
            .with(tracing_subscriber::fmt::layer().with_test_writer()),
    );
    let secs: u64 = std::env::var("IMPAIRED_HOLD_SECS").ok().and_then(|s| s.parse().ok()).unwrap_or(60);
    let turn = TestTurn::start().await;
    let options = DialOptions { ice_servers: vec![turn.udp_only()], ..options() };
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let sessions = Arc::new(AtomicUsize::new(0));
    let mac_link = Arc::new(Mutex::new(None::<cmux_mobile_link::Link>));
    {
        let (sessions, mac_link, options) = (Arc::clone(&sessions), Arc::clone(&mac_link), options.clone());
        tokio::spawn(async move {
            while let Some(session) = mac.next_session().await {
                sessions.fetch_add(1, Ordering::SeqCst);
                let events = SessionEvents {
                    backend: mac.events(),
                    session_id: session.first.session_id.clone(),
                    session: session.events,
                };
                let (mac, mac_link, options) = (mac.clone(), Arc::clone(&mac_link), options.clone());
                tokio::spawn(async move {
                    let Ok(connected) =
                        dial::answer(&mac, session.first, events, &options, LinkConfig::default()).await
                    else {
                        return;
                    };
                    *mac_link.lock().unwrap() = Some(connected.link.clone());
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
    let connected = dial::connect(&phone, &mac_id, TransportKind::WireGuard, &options, LinkConfig::default())
        .await
        .expect("dial");
    let path_flips = Arc::new(AtomicUsize::new(0));
    let flips = {
        let (mut path, path_flips) = (connected.path.clone(), Arc::clone(&path_flips));
        tokio::spawn(async move {
            let mut last = *path.borrow_and_update();
            while path.changed().await.is_ok() {
                let now = *path.borrow_and_update();
                if now != last && last != LinkPath::NoPath {
                    path_flips.fetch_add(1, Ordering::Relaxed);
                }
                last = now;
            }
        })
    };
    let channel = connected.link.open("echo", serde_json::json!({})).await.unwrap();
    let (sender, mut receiver) = channel.split();
    let arrivals = Arc::new(Mutex::new(Vec::<Instant>::new()));
    let reader = {
        let arrivals = Arc::clone(&arrivals);
        tokio::spawn(async move {
            while let Some(ChannelEvent::Data(_)) = receiver.recv().await {
                arrivals.lock().unwrap().push(Instant::now());
            }
        })
    };
    // The counts start with the hold, not the dial.
    counter.rekey_timeouts.store(0, Ordering::Relaxed);
    counter.expired.store(0, Ordering::Relaxed);
    let started = Instant::now();
    let mut sent = 0usize;
    let mut tick = tokio::time::interval(Duration::from_millis(100));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    while started.elapsed() < Duration::from_secs(secs) && connected.link.closed_state().borrow().is_none() {
        tick.tick().await;
        if sender.send(Bytes::from(format!("frame {sent:08}"))).await.is_err() {
            break;
        }
        sent += 1;
    }
    let _ = tokio::time::timeout(Duration::from_secs(10), async {
        while arrivals.lock().unwrap().len() < sent && connected.link.closed_state().borrow().is_none() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await;
    let (echoed, longest_gap, stalls) = {
        let arrivals = arrivals.lock().unwrap();
        let mut times = vec![started];
        times.extend(arrivals.iter().copied());
        let gaps: Vec<Duration> = times.windows(2).map(|w| w[1].duration_since(w[0])).collect();
        (
            arrivals.len(),
            gaps.iter().copied().max().unwrap_or_default(),
            gaps.iter().filter(|gap| **gap >= Duration::from_secs(2)).count(),
        )
    };
    let phone_closed = connected.link.closed_state().borrow().clone();
    let mac_closed = mac_link.lock().unwrap().as_ref().and_then(|link| link.closed_state().borrow().clone());
    connected.link.close("done");
    reader.abort();
    flips.abort();
    Hold {
        secs,
        sessions: sessions.load(Ordering::SeqCst),
        phone_closed,
        mac_closed,
        sent,
        echoed,
        longest_gap,
        stalls,
        rekey_timeouts: counter.rekey_timeouts.load(Ordering::Relaxed),
        expired: counter.expired.load(Ordering::Relaxed),
        path_flips: path_flips.load(Ordering::Relaxed),
    }
}

/// The gate: the link holds through the flap.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_phone_link_holds_60s_on_a_flapping_direct_path_with_slow_turn() {
    let run = hold().await;
    eprintln!(
        "IMPAIRED_HOLD secs={} sessions={} phone_closed={:?} mac_closed={:?} sent={} echoed={} longest_gap_ms={} stalls_2s={} rekey_timeouts={} expired={} path_flips={}",
        run.secs,
        run.sessions,
        run.phone_closed,
        run.mac_closed,
        run.sent,
        run.echoed,
        run.longest_gap.as_millis(),
        run.stalls,
        run.rekey_timeouts,
        run.expired,
        run.path_flips,
    );
    assert_eq!(run.phone_closed, None, "the phone's link closed: {run:?}");
    assert_eq!(run.mac_closed, None, "the Mac's link closed: {run:?}");
    assert_eq!(run.sessions, 1, "the phone redialed: {run:?}");
    assert_eq!(run.echoed, run.sent, "frames lost: {run:?}");
    assert_eq!(run.expired, 0, "WireGuard gave the session up: {run:?}");
    assert_eq!(run.rekey_timeouts, 0, "a handshake waited out REKEY_TIMEOUT (5 s): {run:?}");
}

/// The path label settles and the echo never stalls 2 s: a direct path that is down 1.5 s of every 2.5 s
/// is not a better route than TURN, so the phone's label must not flip
/// Direct/Turn with each flap (Leo's phone showed the label flipping while
/// the link dropped). Run it alone: it shares the flap clock and the
/// handshake counter with the gate above.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "waits on lane/plink-cloud-flip (plink-cloud's helper): with #63296 the label still flips 3 times and the echo stalls 2.3 s twice in 60 s; a fresh TURN allocation's 200 ms server-silence bound declares the cellular TURN leg dead and forget_carrier(Turn) flips the label"]
async fn the_path_label_settles_on_a_flapping_direct_path_with_slow_turn() {
    let run = hold().await;
    eprintln!("IMPAIRED_HOLD_FLIPS secs={} path_flips={} {run:?}", run.secs, run.path_flips);
    assert!(run.path_flips <= 2, "the path label flipped {} times in {} s: {run:?}", run.path_flips, run.secs);
    assert_eq!(run.stalls, 0, "the echo stalled 2 s or more (each label flip moves the stream): {run:?}");
}
