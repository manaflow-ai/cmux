//! Catch-up time over a shaped link: today's separate calls (a `daemon` channel for
//! `set-client-info` + `list-workspaces`, an `acpmux` channel for `_acpmux/watch` and one
//! `_acpmux/attach` per chat, both channels at once: the old path's best case) against one
//! `catch-up` request. Each sample is a fresh phone link through a `cmux-fault` shaper to a
//! real `services::serve`, with a fake daemon socket and a fake acpmux behind it.
//!
//! `#[ignore]`: a bench. Run it with
//! `cargo test -p cmux-mobile-host --test catch_up_conditions -- --ignored --nocapture`.
//! Env: `CATCHUP_PROFILES` (default `lte`), `CATCHUP_RUNS` (default 5), `CATCHUP_CHATS`
//! (default 6), `CATCHUP_DURESS_THREADS` (busy threads spinning while it runs; default 0).
//! Prints one `CATCHUP-ROW` JSON line per profile, load labelled.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_fault::Trace;
use cmux_fault::shaper::{ProfileFile, Shaper};
use cmux_mobile_host::config::{AcpmuxTarget, ServiceConfig};
use cmux_mobile_host::control::SessionExposure;
use cmux_mobile_host::pairing::LinkAuth;
use cmux_mobile_host::services::{Peer, serve};
use cmux_mobile_link::{ChannelEvent, Link, LinkConfig, Role};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream, UnixListener};
use tokio::sync::watch;
use tokio_tungstenite::tungstenite::Message;

fn chat_id(i: usize) -> String {
    format!("00000000-0000-7000-8000-{i:012}")
}

/// A daemon answering `list-workspaces` with `tabs` tabs, and `ok` to anything else.
fn fake_daemon(dir: &Path, tabs: usize) {
    let listener = UnixListener::bind(dir.join("main.sock")).unwrap();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            tokio::spawn(async move {
                let (read, mut write) = stream.into_split();
                let mut lines = BufReader::new(read).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    let request: Value = serde_json::from_str(&line).unwrap();
                    let reply = match request["cmd"].as_str().unwrap_or("") {
                        "list-workspaces" => {
                            let tabs: Vec<Value> = (0..tabs)
                                .map(|i| json!({"id": i, "title": format!("tab {i} ~/src/project-{i}"), "cwd": format!("/Users/me/src/project-{i}")}))
                                .collect();
                            json!({"id": request["id"], "ok": true, "data": {"revision": "r2",
                                "workspaces": [{"id": "w1", "screens": [{"panes": [{"tabs": tabs}]}]}]}})
                        }
                        _ => json!({"id": request["id"], "ok": true}),
                    };
                    let _ = write.write_all(format!("{reply}\n").as_bytes()).await;
                }
            });
        }
    });
}

/// An acpmux with `chats` sessions; each attach answers `events` records of ~300 bytes.
async fn fake_acpmux(chats: usize, events: u64) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("ws://{}/", listener.local_addr().unwrap());
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            // As acpmux's own listener (`server/mod.rs`): without it the burst of replies
            // waits on delayed ACKs, ~40 ms that the real server never adds.
            stream.set_nodelay(true).unwrap();
            tokio::spawn(async move {
                let Ok(socket) = tokio_tungstenite::accept_async(stream).await else { return };
                let (mut sink, mut source) = socket.split();
                while let Some(Ok(Message::Text(text))) = source.next().await {
                    let request: Value = serde_json::from_str(&text).unwrap();
                    let params = &request["params"];
                    let result = match request["method"].as_str().unwrap_or("") {
                        "_acpmux/info" => json!({"sessionId": params["sessionId"]}),
                        "_acpmux/watch" => {
                            let sessions: Vec<Value> = (0..chats)
                                .map(|i| json!({"sessionId": chat_id(i), "title": format!("chat {i}"), "status": "idle"}))
                                .collect();
                            json!({"listEpoch": "E", "listSeq": 91, "follow": true, "sessions": sessions})
                        }
                        "_acpmux/attach" => {
                            let session = params["sessionId"].as_str().unwrap_or("");
                            let last = 10 + events;
                            let records: Vec<Value> = (11..=last)
                                .map(|seq| {
                                    json!({"seq": seq, "kind": "transcript", "sessionId": session,
                                    "msg": {"text": "a".repeat(240)}})
                                })
                                .collect();
                            json!({"session": {"sessionId": session}, "events": records, "hasMore": false,
                                "lastSeq": last, "pageThrough": last})
                        }
                        _ => json!({}),
                    };
                    let reply = json!({"jsonrpc": "2.0", "id": request["id"], "result": result});
                    let _ = sink.send(Message::Text(reply.to_string().into())).await;
                }
            });
        }
    });
    url
}

fn config(dir: &Path, acpmux_url: String) -> Arc<ServiceConfig> {
    Arc::new(ServiceConfig {
        tui_socket_dir: dir.to_owned(),
        default_session: "main".into(),
        default_socket: None,
        file_roots: vec![],
        acpmux: AcpmuxTarget::Fixed { url: acpmux_url, token: None },
        pairing: None,
        agent_tab_host: None,
        uploads_dir: dir.join("uploads"),
        chief_socket: None,
        browser: cmux_mobile_host::browser::BrowserConfig::new(None, 1),
        surface: cmux_mobile_host::surface::SurfaceConfig::new(None, 1),
        viewport_sync: None,
    })
}

fn exposure() -> SessionExposure {
    SessionExposure {
        available: true,
        configured: true,
        allowed: Default::default(),
        blocked: Default::default(),
    }
}

/// A phone link through a shaper to a Mac link serving every channel it accepts.
async fn shaped_link(config: Arc<ServiceConfig>, profile: &str, seed: u64) -> (Link, Arc<Shaper>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let link_profile =
        ProfileFile::builtin().get(profile).cloned().unwrap_or_else(|| panic!("profile {profile}"));
    let shaper = Arc::new(
        Shaper::start(listener.local_addr().unwrap(), link_profile, seed, &Trace::new()).await.unwrap(),
    );
    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        stream.set_nodelay(true).unwrap();
        let mac = Link::new(stream, Role::Mac, LinkConfig::default(), None);
        let (_tx, rx) = watch::channel(exposure());
        while let Some(incoming) = mac.accept().await {
            let peer = Peer {
                device_id: "phone-1".into(),
                session_id: "s".into(),
                video: None,
                session_exposure: Some(rx.clone()),
                path: None,
                viewport: None,
                route: None,
            };
            tokio::spawn(serve(Arc::clone(&config), peer, Arc::new(LinkAuth::default()), incoming));
        }
        drop(_tx);
    });
    let stream = TcpStream::connect(shaper.addr()).await.unwrap();
    stream.set_nodelay(true).unwrap();
    (Link::new(stream, Role::Phone, LinkConfig::default(), None), shaper)
}

/// Today: a `daemon` channel and an `acpmux` channel at once, every request pipelined.
/// Returns (ms until every reply arrived, bytes received).
async fn separate_calls(link: &Link, chats: usize) -> (f64, usize) {
    let start = Instant::now();
    let daemon = async {
        let mut channel = link.open("daemon", json!({})).await.unwrap();
        channel
            .send(Bytes::from(
                "{\"cmd\":\"set-client-info\",\"id\":\"h1\",\"name\":\"phone\"}\n{\"cmd\":\"list-workspaces\",\"id\":\"l1\",\"known\":\"r1\"}\n",
            ))
            .await
            .unwrap();
        let mut got = Vec::new();
        while got.iter().filter(|b| **b == b'\n').count() < 2 {
            match channel.recv().await {
                Some(ChannelEvent::Data(data)) => got.extend_from_slice(&data),
                other => panic!("daemon ended: {other:?}"),
            }
        }
        got.len()
    };
    let acpmux = async {
        let mut channel = link.open("acpmux", json!({})).await.unwrap();
        let watch = json!({"jsonrpc": "2.0", "id": 1, "method": "_acpmux/watch", "params": {"listEpoch": "E", "afterSeq": 88}});
        channel.send(Bytes::from(watch.to_string())).await.unwrap();
        for i in 0..chats {
            let attach = json!({"jsonrpc": "2.0", "id": 2 + i, "method": "_acpmux/attach",
                "params": {"sessionId": chat_id(i), "afterSeq": 10, "visible": false}});
            channel.send(Bytes::from(attach.to_string())).await.unwrap();
        }
        let (mut replies, mut bytes, mut pending) = (0, 0, Vec::new());
        while replies < 1 + chats {
            match channel.recv().await {
                Some(ChannelEvent::Data(data)) => {
                    bytes += data.len();
                    pending.extend_from_slice(&data);
                    if serde_json::from_slice::<serde::de::IgnoredAny>(&pending).is_ok() {
                        pending.clear();
                        replies += 1;
                    }
                }
                other => panic!("acpmux ended: {other:?}"),
            }
        }
        bytes
    };
    let (a, b) = tokio::join!(daemon, acpmux);
    (start.elapsed().as_secs_f64() * 1000.0, a + b)
}

/// After: one `catch-up` request, one reply.
async fn one_catch_up(link: &Link, chats: usize) -> (f64, usize) {
    let start = Instant::now();
    let request = json!({"v": 1, "wake": "foreground", "budgetBytes": 256 * 1024,
        "workspaces": {"known": "r1"},
        "chatList": {"listEpoch": "E", "afterSeq": 88},
        "chats": (0..chats).map(|i| json!({"sessionId": chat_id(i), "lastSeq": 10})).collect::<Vec<_>>()});
    let mut channel = link.open("catch-up", request).await.unwrap();
    let (mut bytes, mut pending) = (0, Vec::new());
    loop {
        match channel.recv().await {
            Some(ChannelEvent::Data(data)) => {
                bytes += data.len();
                pending.extend_from_slice(&data);
            }
            Some(ChannelEvent::Closed(info)) => {
                assert_eq!(info.code, "eof");
                let reply: Value = serde_json::from_slice(&pending).unwrap();
                assert_eq!(reply["chats"].as_array().map(Vec::len), Some(chats), "{reply}");
                break;
            }
            None => panic!("catch-up ended"),
        }
    }
    (start.elapsed().as_secs_f64() * 1000.0, bytes)
}

fn stats(mut samples: Vec<f64>) -> Value {
    samples.sort_by(f64::total_cmp);
    let pick = |q: f64| samples[((samples.len() - 1) as f64 * q).round() as usize];
    json!({"n": samples.len(), "p50": (pick(0.5) * 10.0).round() / 10.0, "p95": (pick(0.95) * 10.0).round() / 10.0,
        "samples": samples.iter().map(|s| (s * 10.0).round() / 10.0).collect::<Vec<_>>()})
}

fn loadavg() -> String {
    std::fs::read_to_string("/proc/loadavg")
        .unwrap_or_default()
        .split_whitespace()
        .take(3)
        .collect::<Vec<_>>()
        .join(" ")
}

fn env_or<T: std::str::FromStr>(name: &str, default: T) -> T {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "bench: shaped catch-up rows"]
async fn catch_up_rows_under_conditions() {
    let profiles = std::env::var("CATCHUP_PROFILES").unwrap_or_else(|_| "lte".into());
    let runs: usize = env_or("CATCHUP_RUNS", 5);
    let chats: usize = env_or("CATCHUP_CHATS", 6);
    let duress: usize = env_or("CATCHUP_DURESS_THREADS", 0);
    let stop = Arc::new(AtomicBool::new(false));
    let spinners: Vec<_> = (0..duress)
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
    tokio::time::sleep(Duration::from_secs(if duress > 0 { 5 } else { 0 })).await;

    let dir = tempfile::tempdir().unwrap();
    fake_daemon(dir.path(), 24);
    let url = fake_acpmux(chats, 8).await;
    let config = config(dir.path(), url);
    let loads = Mutex::new(Vec::new());
    for profile in profiles.split(',') {
        let (mut before, mut after) = (Vec::new(), Vec::new());
        let (mut before_bytes, mut after_bytes) = (0, 0);
        for run in 0..runs {
            // Alternate the order so neither path always goes first on a fresh link.
            let (link, _shaper) = shaped_link(Arc::clone(&config), profile, 7 + run as u64).await;
            let one = |first: bool| {
                let link = &link;
                async move {
                    if first { separate_calls(link, chats).await } else { one_catch_up(link, chats).await }
                }
            };
            let order = run % 2 == 0;
            let x = one(order).await;
            let y = one(!order).await;
            let ((b, bb), (a, ab)) = if order { (x, y) } else { (y, x) };
            before.push(b);
            after.push(a);
            before_bytes = bb;
            after_bytes = ab;
            loads.lock().unwrap().push(loadavg());
        }
        let row = json!({"row": "catch-up", "profile": profile, "chats": chats,
            "load": if duress > 0 { format!("duress: {duress} busy threads + host") } else { "idle: no added load".into() },
            "loadavg": loads.lock().unwrap().last().cloned(), "nproc": std::thread::available_parallelism().map(|n| n.get()).unwrap_or(0),
            "separate_ms": stats(before), "one_request_ms": stats(after),
            "separate_bytes": before_bytes, "one_request_bytes": after_bytes});
        println!("CATCHUP-ROW {row}");
    }
    stop.store(true, Ordering::Relaxed);
    for spinner in spinners {
        let _ = spinner.join();
    }
}
