//! A Mac stays listed online on a host under full load (cmux#52200, cmuxterm-hq#21260).
//!
//! A Mac at load 89-92 on 15 cores with 21.5 of 22.5 GB of swap used showed offline on the
//! iPhone for about 50 min while it was up. The service lists a Mac online while its signaling
//! socket is open and fresh while its application pings keep coming at most `FRESH_WITHIN`
//! (18 s) apart (PROTOCOL.md "Mac freshness").
//!
//! Here the process that holds the socket is loaded the way that host was: every worker of the
//! runtime that opened it is held by blocking work, and twice as many busy threads as the machine
//! has cores spin beside it. The service (on its own thread, standing in for the hub) must keep
//! hearing the pings no more than `FRESH_WITHIN` apart, and the socket must stay open.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_mobile_link::SignalingClient;
use cmux_mobile_link::signaling::{APP_PING, APP_PONG, FRESH_WITHIN};
use futures_util::{SinkExt, StreamExt};
use tokio_tungstenite::tungstenite::Message;

/// How long the load lasts: past two keepalive intervals (15 s) and the 18 s freshness bound.
const LOAD: Duration = Duration::from_secs(35);

/// What the stand-in service heard.
#[derive(Default)]
struct Heard {
    opened: Option<Instant>,
    pings: Vec<Instant>,
    closed: Option<Instant>,
}

/// A WebSocket service on its own thread and runtime: answers each application ping with a pong
/// (as the hub's auto-response does) and records when each came.
fn start_service() -> (String, Arc<Mutex<Heard>>) {
    let heard = Arc::new(Mutex::new(Heard::default()));
    let (address_tx, address_rx) = std::sync::mpsc::channel();
    let record = Arc::clone(&heard);
    std::thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        runtime.block_on(async move {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            address_tx.send(listener.local_addr().unwrap()).unwrap();
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
            record.lock().unwrap().opened = Some(Instant::now());
            while let Some(Ok(message)) = socket.next().await {
                if let Message::Text(text) = &message
                    && text.as_str() == APP_PING
                {
                    record.lock().unwrap().pings.push(Instant::now());
                    let _ = socket.send(Message::Text(APP_PONG.into())).await;
                }
                if matches!(message, Message::Close(_)) {
                    break;
                }
            }
            record.lock().unwrap().closed = Some(Instant::now());
        });
    });
    let address = address_rx.recv().unwrap();
    (format!("http://{address}"), heard)
}

#[test]
fn a_loaded_host_keeps_its_signaling_socket_fresh() {
    let (base_url, heard) = start_service();
    // The host's shared runtime: the one the socket is opened from.
    let shared = tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap();
    let client = shared
        .block_on(SignalingClient::connect(&base_url, "token", "team", "mac-under-load"))
        .expect("signaling connects");

    // Full load: every shared worker blocked, and 2x cores busy threads beside them.
    let stop = Arc::new(AtomicBool::new(false));
    let cores = std::thread::available_parallelism().map_or(4, |n| n.get());
    let spinners: Vec<_> = (0..cores * 2)
        .map(|_| {
            let stop = Arc::clone(&stop);
            std::thread::spawn(move || {
                let mut x = 0u64;
                while !stop.load(Ordering::Relaxed) {
                    x = std::hint::black_box(x.wrapping_mul(6364136223846793005).wrapping_add(1));
                }
            })
        })
        .collect();
    let began = Instant::now();
    for _ in 0..2 {
        shared.spawn(async { std::thread::sleep(LOAD) });
    }
    std::thread::sleep(LOAD);
    stop.store(true, Ordering::Relaxed);
    for spinner in spinners {
        spinner.join().unwrap();
    }

    let (opened, pings, closed) = {
        let heard = heard.lock().unwrap();
        (heard.opened, heard.pings.clone(), heard.closed)
    };
    let opened = opened.expect("the service saw the socket open");
    assert!(closed.is_none(), "the socket closed under load: {:?}", client.closed_reason());
    let mut marks = vec![opened.max(began)];
    marks.extend(pings.iter().copied().filter(|at| *at > began));
    marks.push(Instant::now());
    let gaps: Vec<Duration> = marks.windows(2).map(|w| w[1] - w[0]).collect();
    let longest = gaps.iter().copied().max().unwrap_or_default();
    eprintln!(
        "duress: {} busy threads on {cores} cores + shared runtime blocked {}s; {} app pings; longest gap {}ms",
        cores * 2,
        LOAD.as_secs(),
        pings.len(),
        longest.as_millis()
    );
    assert!(
        longest < FRESH_WITHIN,
        "the service heard no application ping for {}ms under load (fresh within {}ms): the phone shows this Mac asleep or offline",
        longest.as_millis(),
        FRESH_WITHIN.as_millis()
    );
    drop(client);
    shared.shutdown_background();
}
