//! A network change returns before its new signaling socket is open, and a dial that starts
//! meanwhile (the app's redial, `send(.networkChanged)`) joins that open: it gets the new socket,
//! never the old pooled one, and no second socket opens. When the new open fails, the old socket
//! is probed as before and the dial gets it back if it still answers.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use cmux_mobile_link::dial::{self, SessionEvents};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_mobile_link::{DialOptions, LinkConfig, SignalingClient};
use cmux_mobile_link_ffi::{ConnectRequest, LinkEvent, LinkObserver, Transport, WarmPool};
use tokio::io::copy;
use tokio::net::{TcpListener, TcpStream};

/// The phone's path to the fake service: every new connection waits `delay_ms` before it is
/// forwarded (a slow handshake on the new network), or is dropped while `refuse` holds.
struct Path {
    url: String,
    accepts: Arc<AtomicU64>,
    delay_ms: Arc<AtomicU64>,
    refuse: Arc<AtomicBool>,
}

impl Path {
    async fn start(upstream: &str) -> Self {
        let target = upstream.trim_start_matches("http://").trim_end_matches('/').to_owned();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let accepts = Arc::new(AtomicU64::new(0));
        let delay_ms = Arc::new(AtomicU64::new(0));
        let refuse = Arc::new(AtomicBool::new(false));
        let (counted, delayed, refused) = (Arc::clone(&accepts), Arc::clone(&delay_ms), Arc::clone(&refuse));
        tokio::spawn(async move {
            while let Ok((mut phone, _)) = listener.accept().await {
                counted.fetch_add(1, Ordering::SeqCst);
                if refused.load(Ordering::SeqCst) {
                    drop(phone);
                    continue;
                }
                let delay = Duration::from_millis(delayed.load(Ordering::SeqCst));
                let target = target.clone();
                tokio::spawn(async move {
                    tokio::time::sleep(delay).await;
                    let Ok(mut service) = TcpStream::connect(&target).await else { return };
                    let (mut phone_read, mut phone_write) = phone.split();
                    let (mut service_read, mut service_write) = service.split();
                    let _ = tokio::join!(
                        copy(&mut phone_read, &mut service_write),
                        copy(&mut service_read, &mut phone_write)
                    );
                });
            }
        });
        Self { url, accepts, delay_ms, refuse }
    }
}

const OPEN_DELAY: Duration = Duration::from_millis(600);

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_dial_during_the_network_changes_open_joins_it() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let path = Path::start(&server.base_url).await;
    let pool = WarmPool::new();
    let device = uuid::Uuid::new_v4().to_string();
    let args = || (path.url.clone(), "user:alice".to_owned(), "team".to_owned(), device.clone());

    let (a, b, c, d) = args();
    pool.prewarm(a, b, c, d).await;
    let (a, b, c, d) = args();
    let (_, reused, old) = pool.dial_socket(a, b, c, d).await.unwrap();
    assert!(reused, "prewarm pooled the socket");

    // The new network's handshake is slow; the old socket still looks fresh (no missed pong yet).
    path.delay_ms.store(OPEN_DELAY.as_millis() as u64, Ordering::SeqCst);
    let before = path.accepts.load(Ordering::SeqCst);
    let started = Instant::now();
    let (a, b, c, d) = args();
    let marks = pool.network_changed(a, b, c, d).await;
    let returned = started.elapsed();
    assert!(returned < OPEN_DELAY, "network_changed waited for the new socket: {returned:?}");
    assert!(
        marks.iter().any(|mark| mark.name == "signaling:pending"),
        "the call says the open is still running: {marks:?}"
    );

    let (a, b, c, d) = args();
    let (redial, reused, socket) = pool.dial_socket(a, b, c, d).await.unwrap();
    let ready = started.elapsed();
    assert_ne!(socket, old, "the redial got the old socket");
    assert!(reused, "the redial opened a socket of its own: {redial:?}");
    assert!(redial.iter().any(|mark| mark.name == "signaling_awaited"), "{redial:?}");
    assert!(ready >= OPEN_DELAY, "the redial did not wait for the open: {ready:?}");
    assert_eq!(path.accepts.load(Ordering::SeqCst) - before, 1, "exactly one new socket opened");

    // A steady link afterwards: dials reuse the socket, nothing opens.
    let (a, b, c, d) = args();
    let (_, reused, again) = pool.dial_socket(a, b, c, d).await.unwrap();
    assert!(reused);
    assert_eq!(again, socket);
    assert_eq!(path.accepts.load(Ordering::SeqCst) - before, 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn when_the_new_open_fails_a_dial_gets_the_old_socket_that_still_answers() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let path = Path::start(&server.base_url).await;
    let pool = WarmPool::new();
    let device = uuid::Uuid::new_v4().to_string();
    let args = || (path.url.clone(), "user:alice".to_owned(), "team".to_owned(), device.clone());

    let (a, b, c, d) = args();
    pool.prewarm(a, b, c, d).await;
    let (a, b, c, d) = args();
    let (_, _, old) = pool.dial_socket(a, b, c, d).await.unwrap();

    path.refuse.store(true, Ordering::SeqCst);
    let (a, b, c, d) = args();
    pool.network_changed(a, b, c, d).await;
    let (a, b, c, d) = args();
    let (redial, reused, socket) = pool.dial_socket(a, b, c, d).await.unwrap();
    assert_eq!(socket, old, "the old socket answered the probe, so it stays: {redial:?}");
    assert!(reused);
}

#[derive(Default)]
struct Recorder(std::sync::Mutex<Vec<LinkEvent>>);

impl LinkObserver for Recorder {
    fn on_event(&self, event: LinkEvent) {
        self.0.lock().unwrap().push(event);
    }
}

/// A Mac that answers every session and counts them.
async fn counting_mac(server: &FakeSignaling) -> (String, Arc<AtomicU64>) {
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let sessions = Arc::new(AtomicU64::new(0));
    let counted = Arc::clone(&sessions);
    tokio::spawn(async move {
        while let Some(session) = mac.next_session().await {
            counted.fetch_add(1, Ordering::SeqCst);
            let first = session.first;
            let events = SessionEvents {
                backend: mac.events(),
                session_id: first.session_id.clone(),
                session: session.events,
            };
            let mac = mac.clone();
            tokio::spawn(async move {
                let options = DialOptions { include_loopback: true, ..DialOptions::default() };
                if let Ok(connected) =
                    dial::answer(&mac, first, events, &options, LinkConfig::default()).await
                {
                    while connected.link.accept().await.is_some() {}
                }
            });
        }
    });
    (mac_id, sessions)
}

fn request(url: &str, device: &str, mac: &str) -> ConnectRequest {
    ConnectRequest {
        base_url: url.to_owned(),
        token: "user:alice".into(),
        team_id: "team".into(),
        device_id: device.to_owned(),
        mac_device_id: mac.to_owned(),
        transport: Transport::WireGuard,
        include_loopback: true,
        relay_only: false,
        block_udp: false,
        video_lane: false,
        webrtc_media: false,
        ultra: cmux_mobile_link::UltraSetting::Off,
    }
}

/// The app's redial for change 2 arrives while change 1's redial is still connecting (it waits
/// for the new socket): it joins that dial. One session reaches the Mac, both callers get the
/// one link, and each caller's observer hears it connect.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_redial_for_a_second_change_joins_the_one_still_connecting() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let path = Path::start(&server.base_url).await;
    let (mac, sessions) = counting_mac(&server).await;
    let pool = WarmPool::new();
    let device = uuid::Uuid::new_v4().to_string();
    let args = || (path.url.clone(), "user:alice".to_owned(), "team".to_owned(), device.clone());
    let (a, b, c, d) = args();
    pool.prewarm(a, b, c, d).await;

    path.delay_ms.store(OPEN_DELAY.as_millis() as u64, Ordering::SeqCst);
    let before = path.accepts.load(Ordering::SeqCst);
    let (a, b, c, d) = args();
    pool.network_changed(a, b, c, d).await;
    let (first_events, second_events) = (Arc::new(Recorder::default()), Arc::new(Recorder::default()));
    let first = tokio::spawn({
        let (pool, request, events) = (pool.clone(), request(&path.url, &device, &mac), first_events.clone());
        async move { pool.connect(request, Some(events as Arc<dyn LinkObserver>)).await }
    });
    tokio::time::sleep(Duration::from_millis(200)).await;
    // Change 2, then its redial: the first is still waiting for the socket.
    let (a, b, c, d) = args();
    pool.network_changed(a, b, c, d).await;
    let second = pool
        .connect(request(&path.url, &device, &mac), Some(second_events.clone() as Arc<dyn LinkObserver>))
        .await
        .expect("the joined dial connects");
    let first = first.await.unwrap().expect("the first caller gets the link too");
    assert!(std::ptr::eq(Arc::as_ptr(&first), Arc::as_ptr(&second)), "one link for both callers");
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(sessions.load(Ordering::SeqCst), 1, "one Mac session");
    assert!(
        path.accepts.load(Ordering::SeqCst) - before <= 3,
        "at most one socket per change (and the service's ICE call)"
    );
    for events in [&first_events, &second_events] {
        let seen = events.0.lock().unwrap().clone();
        assert!(seen.iter().any(|event| matches!(event, LinkEvent::Connected { .. })), "{seen:?}");
    }
    second.close();
}

/// A dial that took its socket before the last change is on the old path: the redial replaces it
/// (the old one is cancelled, not kept beside the new).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_redial_after_a_change_replaces_a_dial_on_the_old_socket() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let path = Path::start(&server.base_url).await;
    // A Mac that never answers: the first dial stays connecting on its (pooled) socket.
    let mac_id = uuid::Uuid::new_v4().to_string();
    let _silent = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let pool = WarmPool::new();
    let device = uuid::Uuid::new_v4().to_string();
    let args = || (path.url.clone(), "user:alice".to_owned(), "team".to_owned(), device.clone());
    let (a, b, c, d) = args();
    pool.prewarm(a, b, c, d).await;
    let stuck = tokio::spawn({
        let (pool, request) = (pool.clone(), request(&path.url, &device, &mac_id));
        async move { pool.connect(request, None).await }
    });
    tokio::time::sleep(Duration::from_millis(300)).await;
    let (a, b, c, d) = args();
    pool.network_changed(a, b, c, d).await;
    let started = Instant::now();
    let replaced = tokio::spawn({
        let (pool, request) = (pool.clone(), request(&path.url, &device, &mac_id));
        async move { pool.connect(request, None).await }
    });
    let outcome =
        tokio::time::timeout(Duration::from_secs(3), stuck).await.expect("the old dial is cancelled");
    assert!(outcome.unwrap().is_err(), "the old dial ends with an error, not a link");
    assert!(started.elapsed() < Duration::from_secs(3));
    replaced.abort();
}
