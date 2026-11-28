//! Catch-up time over a shaped link: today's separate calls (a `daemon` channel for
//! `set-client-info` + `list-workspaces`, an `acpmux` channel for `_acpmux/watch` and one
//! `_acpmux/attach` per chat, both channels at once: the old path's best case) against one
//! `catch-up` request, against the same catch-up from the relay cache with the Mac asleep
//! (RFD 0142 R9: sealed deltas, `POST /v1/relay-cache/<src>/catch-up`, read by the phone's
//! `cmux_mobile_core::catch_up::relay`, unsealing included). Each sample is a fresh phone link
//! through a `cmux-fault` shaper to a real `services::serve`, with a fake daemon socket and a fake
//! acpmux behind it; the relay is a plain HTTP/1.1 server over the relay's own `DeltaLog`, through
//! a shaper of the same profile. No TLS on either: the relay rows leave out the TLS handshake a
//! cold HTTPS connection adds (`relay_cold_ms` is TCP connect + one request).
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

/// When the Mac last accepted a shaped link's connection (the shaped TCP handshake landed).
static ACCEPTED: Mutex<Option<Instant>> = Mutex::new(None);

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
        *ACCEPTED.lock().unwrap() = Some(Instant::now());
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

/// The Mac's relay deltas for the same state the fakes answer: one for the workspaces, one for
/// the chat list, one per transcript event of each chat (the Mac seals one per change).
struct RelayFixture {
    mac: p256::ecdsa::SigningKey,
    phone: p256::SecretKey,
    logs: Arc<Mutex<std::collections::BTreeMap<String, cmux_relay_snapshot::delta::DeltaLog>>>,
    surfaces: Vec<String>,
    deltas: usize,
}

const RELAY_EPOCH: u64 = 7;

fn relay_fixture(chats: usize, tabs: usize, events: u64) -> RelayFixture {
    use cmux_mobile_core::catch_up::relay::chat_surface;
    use cmux_relay_snapshot::{Position, delta};
    let mac = p256::ecdsa::SigningKey::random(&mut rand_core::OsRng);
    let phone = p256::SecretKey::random(&mut rand_core::OsRng);
    let mut plain: Vec<(String, Vec<Value>)> = Vec::new();
    let tabs: Vec<Value> = (0..tabs)
        .map(|i| json!({"id": i, "title": format!("tab {i} ~/src/project-{i}"), "cwd": format!("/Users/me/src/project-{i}")}))
        .collect();
    plain.push((
        "workspaces".into(),
        vec![json!({"tree_revision": "r2",
        "workspaces": [{"id": "w1", "screens": [{"panes": [{"tabs": tabs}]}]}]})],
    ));
    let sessions: Vec<Value> = (0..chats)
        .map(|i| json!({"sessionId": chat_id(i), "title": format!("chat {i}"), "status": "idle"}))
        .collect();
    plain.push((
        "chat-list".into(),
        vec![json!({"listEpoch": "E", "listSeq": 91, "follow": true, "sessions": sessions})],
    ));
    for i in 0..chats {
        let session = chat_id(i);
        let pages = (11..=10 + events)
            .map(|seq| {
                json!({"sessionId": session, "events": [{"seq": seq, "kind": "transcript",
                "sessionId": session, "msg": {"text": "a".repeat(240)}}], "hasMore": false,
                "lastSeq": seq, "pageThrough": seq})
            })
            .collect();
        plain.push((chat_surface(&session), pages));
    }
    let mut logs = std::collections::BTreeMap::new();
    let mut deltas = 0;
    for (surface, pages) in &plain {
        let mut log = delta::DeltaLog::new();
        for (k, page) in pages.iter().enumerate() {
            let position = Position { epoch: RELAY_EPOCH, seq: 11 + k as u64 };
            let sealed = cmux_relay_snapshot::seal(
                &mac,
                &phone.public_key(),
                &delta::delta_stream(surface),
                position,
                page.to_string().as_bytes(),
            )
            .unwrap();
            log.append(sealed, 0).unwrap();
            deltas += 1;
        }
        logs.insert(surface.clone(), log);
    }
    RelayFixture {
        mac,
        phone,
        logs: Arc::new(Mutex::new(logs)),
        surfaces: plain.into_iter().map(|(surface, _)| surface).collect(),
        deltas,
    }
}

/// A relay serving `catch-up` from the fixture's logs over keep-alive HTTP/1.1, as the Worker's
/// route answers it (PROTOCOL.md "Relay cache routes").
async fn fake_relay(
    logs: Arc<Mutex<std::collections::BTreeMap<String, cmux_relay_snapshot::delta::DeltaLog>>>,
) -> std::net::SocketAddr {
    use base64::Engine as _;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            stream.set_nodelay(true).unwrap();
            let logs = Arc::clone(&logs);
            tokio::spawn(async move {
                let (read, mut write) = stream.into_split();
                let mut read = BufReader::new(read);
                while let Some(body) = read_http(&mut read, "POST /v1/relay-cache/").await {
                    let ask: Value = serde_json::from_slice(&body).unwrap();
                    let reply = {
                        let (mut surfaces, mut cut) = (Vec::new(), Vec::new());
                        let mut logs = logs.lock().unwrap();
                        for entry in ask["surfaces"].as_array().unwrap() {
                            let stream = entry["surface"].as_str().unwrap().to_string();
                            let after = cmux_relay_snapshot::Position {
                                epoch: entry["after"]["epoch"].as_u64().unwrap(),
                                seq: entry["after"]["seq"].as_u64().unwrap(),
                            };
                            match logs.get_mut(&stream).map(|log| (log.catch_up(after, 0), log.head())) {
                                Some((cmux_relay_snapshot::delta::CatchUp::Deltas(sealed), Some(head))) => {
                                    let sealed: Vec<String> = sealed
                                        .iter()
                                        .map(|e| base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(e))
                                        .collect();
                                    surfaces.push(json!({"surface": stream, "sealed": sealed,
                                    "head": {"epoch": head.epoch, "seq": head.seq}}));
                                }
                                _ => cut.push(stream),
                            }
                        }
                        json!({"fromRelay": true, "surfaces": surfaces, "cut": cut}).to_string()
                    };
                    let head = format!(
                        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\r\n",
                        reply.len()
                    );
                    if write.write_all(format!("{head}{reply}").as_bytes()).await.is_err() {
                        return;
                    }
                }
            });
        }
    });
    addr
}

/// One HTTP/1.1 message's body (by `content-length`), after a start line beginning `start`
/// (empty: any). None at EOF.
async fn read_http<R: tokio::io::AsyncBufRead + Unpin>(read: &mut R, start: &str) -> Option<Vec<u8>> {
    use tokio::io::AsyncReadExt;
    let mut line = String::new();
    if read.read_line(&mut line).await.ok()? == 0 {
        return None;
    }
    assert!(line.starts_with(start), "{line:?}");
    let mut length = 0;
    loop {
        line.clear();
        read.read_line(&mut line).await.ok()?;
        if line == "\r\n" {
            break;
        }
        if let Some((name, value)) = line.split_once(':')
            && name.eq_ignore_ascii_case("content-length")
        {
            length = value.trim().parse().unwrap();
        }
    }
    let mut body = vec![0; length];
    read.read_exact(&mut body).await.ok()?;
    Some(body)
}

/// The phone's relay catch-up: request every surface after the Mac's last relay head, read and
/// unseal the reply into `catch-up` answers. Returns (ms, bytes received).
async fn relay_catch_up<S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin>(
    stream: &mut BufReader<S>,
    fixture: &RelayFixture,
    start: Instant,
) -> (f64, usize) {
    use cmux_mobile_core::catch_up::relay;
    let mut floors = relay::Floors::default();
    floors.set_from_mac(&fixture.surfaces.iter().map(|s| (s.clone(), (RELAY_EPOCH, 10))).collect());
    // The phone's steps (cmux-mobile-link-ffi `relay_request` / `relay_apply`): core picks the
    // streams, the one relay cache client builds the call and opens the reply.
    use cmux_mobile_link::relay_cache;
    let mut wanted = relay::wanted(&floors, &fixture.surfaces);
    let asks = relay_cache::resume_asks(&wanted);
    let body = relay_cache::catch_up_body(&asks, relay_cache::MAX_BUDGET_BYTES).unwrap().to_string();
    let path = relay_cache::path("phone-1", "mac-1", "catch-up", &[]);
    let request = format!(
        "POST {path} HTTP/1.1\r\nhost: relay\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\r\n{body}",
        body.len()
    );
    stream.get_mut().write_all(request.as_bytes()).await.unwrap();
    let reply = read_http(stream, "HTTP/1.1 200").await.unwrap();
    let source = p256::PublicKey::from(fixture.mac.verifying_key());
    let reply_json = relay_cache::read_catch_up(&reply).unwrap();
    let resume = relay_cache::apply_catch_up(reply_json, &source, &fixture.phone, &mut wanted).unwrap();
    let opened: Vec<relay::Opened<'_>> = resume
        .surfaces
        .iter()
        .map(|s| relay::Opened {
            surface: &s.surface,
            applied: &s.applied,
            stopped: s.stopped.as_ref(),
            head: s.head,
        })
        .collect();
    let got = relay::take(&mut floors, &resume.cut, &opened);
    assert!(got.cut.is_empty(), "{:?}", got.cut_why);
    assert_eq!(got.answers.len(), fixture.deltas);
    (start.elapsed().as_secs_f64() * 1000.0, reply.len())
}

fn stats(mut samples: Vec<f64>) -> Value {
    samples.sort_by(f64::total_cmp);
    let pick = |q: f64| samples[((samples.len() - 1) as f64 * q).round() as usize];
    let mut row = json!({"n": samples.len(), "p50": (pick(0.5) * 10.0).round() / 10.0,
        "p95": (pick(0.95) * 10.0).round() / 10.0, "max": (pick(1.0) * 10.0).round() / 10.0});
    // A long run's samples are its percentiles; a short one's are worth reading whole.
    if samples.len() <= 20 {
        row["samples"] = samples.iter().map(|s| (s * 10.0).round() / 10.0).collect::<Vec<_>>().into();
    }
    row
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
    let fixture = relay_fixture(chats, 24, 8);
    let relay = fake_relay(Arc::clone(&fixture.logs)).await;
    let loads = Mutex::new(Vec::new());
    for profile in profiles.split(',') {
        let (mut before, mut after) = (Vec::new(), Vec::new());
        let (mut before_bytes, mut after_bytes) = (0, 0);
        let (mut warm, mut cold, mut relay_bytes) = (Vec::new(), Vec::new(), 0);
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
            // The relay, through its own shaper of the same profile: a cold connection (TCP
            // connect + the request), then the same request on the kept-alive connection.
            let relay_profile = ProfileFile::builtin().get(profile).cloned().unwrap();
            let relay_shaper =
                Shaper::start(relay, relay_profile, 11 + run as u64, &Trace::new()).await.unwrap();
            let start = Instant::now();
            let tcp = TcpStream::connect(relay_shaper.addr()).await.unwrap();
            tcp.set_nodelay(true).unwrap();
            let mut tcp = BufReader::new(tcp);
            let (c, _) = relay_catch_up(&mut tcp, &fixture, start).await;
            let (w, rb) = relay_catch_up(&mut tcp, &fixture, Instant::now()).await;
            cold.push(c);
            warm.push(w);
            relay_bytes = rb;
            loads.lock().unwrap().push(loadavg());
        }
        let row = json!({"row": "catch-up", "profile": profile, "chats": chats,
            "load": if duress > 0 { format!("duress: {duress} busy threads + host") } else { "idle: no added load".into() },
            "loadavg": loads.lock().unwrap().last().cloned(), "nproc": std::thread::available_parallelism().map(|n| n.get()).unwrap_or(0),
            "separate_ms": stats(before), "one_request_ms": stats(after),
            "separate_bytes": before_bytes, "one_request_bytes": after_bytes,
            "relay_warm_ms": stats(warm), "relay_cold_ms": stats(cold), "relay_bytes": relay_bytes,
            "relay_deltas": fixture.deltas, "relay_tls": false});
        println!("CATCHUP-ROW {row}");
    }
    stop.store(true, Ordering::Relaxed);
    for spinner in spinners {
        let _ = spinner.join();
    }
}

// ---------------------------------------------------------------------------------------------
// Staleness rows: time away × Mac load × link, before (no background sips: the phone catches
// up only when it comes forward) and after (sips at the cadence iOS allows, bounded per wake and
// per background hour by `cmux_mobile_core::catch_up::hour`). One harness for both: the same
// shaped link, the same real `services::serve`, the same phone code (`cmux_mobile_core::catch_up`
// `service::request` / `read` / `Cursors::apply_catch_up`, as `cmux-mobile-link-ffi` calls them).
// The Mac's clock is modelled (an 8 h row does not take 8 h): each wake sets the fakes' heads to
// what the Mac had by then, then runs over the shaped link in real time.
//
// Run: `cargo test -p cmux-mobile-host --test catch_up_conditions staleness -- --ignored --nocapture`.
// Env: `STALENESS_PROFILES` (default `good-wifi,lte,lossy-3`), `STALENESS_AWAYS` (seconds,
// default `60,600,3600,28800`), `STALENESS_RUNS` (foreground samples per row, default 10),
// `CATCHUP_DURESS_THREADS`. Prints one `STALENESS-ROW` JSON line per row.

use cmux_mobile_core::catch_up::service as phone;
use cmux_mobile_core::catch_up::{ChatCursor, Cursors, Wake};

const STALE_CHATS: usize = 6;
/// The iOS floor this models for `BGAppRefreshTask` (`earliestBeginDate`; iOS runs it later or
/// not at all as it sees fit, so this is the sips' best case).
const REFRESH_EVERY: u64 = 15 * 60;
/// A busy Mac's agent turns ending, each a push the notification service extension wakes for.
const PUSH_EVERY: u64 = 10 * 60;

/// Where the Mac's surfaces reached: the tree's revision number, the chat list's row log
/// position, each chat's newest event (events are `1..=head`).
#[derive(Debug, Clone, Default)]
struct MacHeads {
    tree: u64,
    list: u64,
    chats: Vec<u64>,
}

/// The Mac's heads `t` seconds after the phone left. Busy: a long live agent session in chat 0
/// (an event every 2 s), two others ticking (one every 20 s), the chat list and the workspace
/// tree changing once a minute. Idle: one chat and the list changing every 10 min.
fn heads_at(busy: bool, t: u64) -> MacHeads {
    let mut chats = vec![0; STALE_CHATS];
    if busy {
        chats[0] = t / 2;
        chats[1] = t / 20;
        chats[2] = t / 20;
        MacHeads { tree: t / 60, list: t / 60, chats }
    } else {
        chats[1] = t / 600;
        MacHeads { tree: 0, list: t / 600, chats }
    }
}

fn mac_daemon(dir: &Path, heads: Arc<Mutex<MacHeads>>) {
    let listener = UnixListener::bind(dir.join("main.sock")).unwrap();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            let heads = Arc::clone(&heads);
            tokio::spawn(async move {
                let (read, mut write) = stream.into_split();
                let mut lines = BufReader::new(read).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    let request: Value = serde_json::from_str(&line).unwrap();
                    let revision = format!("r{}", heads.lock().unwrap().tree);
                    let reply = match request["cmd"].as_str().unwrap_or("") {
                        "list-workspaces" if request["known"]["tree_revision"] == json!(revision) => {
                            json!({"id": request["id"], "ok": true, "data": {"unchanged": true, "tree_revision": revision}})
                        }
                        "list-workspaces" => {
                            let tabs: Vec<Value> = (0..24)
                                .map(|i| json!({"id": i, "title": format!("tab {i} ~/src/project-{i}"), "cwd": format!("/Users/me/src/project-{i}")}))
                                .collect();
                            json!({"id": request["id"], "ok": true, "data": {"tree_revision": revision,
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

/// acpmux over the heads: `_acpmux/watch {afterSeq}` answers the rows changed since, and
/// `_acpmux/attach {afterSeq, maxBytes, limit, beforeSeq}` the newest events after `afterSeq`
/// that fit `maxBytes` (a tail-first page: `hasMore` when older ones stayed behind).
async fn mac_acpmux(heads: Arc<Mutex<MacHeads>>) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("ws://{}/", listener.local_addr().unwrap());
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            stream.set_nodelay(true).unwrap();
            let heads = Arc::clone(&heads);
            tokio::spawn(async move {
                let Ok(socket) = tokio_tungstenite::accept_async(stream).await else { return };
                let (mut sink, mut source) = socket.split();
                while let Some(Ok(Message::Text(text))) = source.next().await {
                    let request: Value = serde_json::from_str(&text).unwrap();
                    let params = &request["params"];
                    let heads = heads.lock().unwrap().clone();
                    let result = match request["method"].as_str().unwrap_or("") {
                        "_acpmux/info" => json!({"sessionId": params["sessionId"]}),
                        "_acpmux/watch" => {
                            let after = params["afterSeq"].as_u64().unwrap_or(0);
                            let changed = (heads.list.saturating_sub(after) as usize).min(STALE_CHATS);
                            let sessions: Vec<Value> = (0..changed)
                                .map(|i| json!({"sessionId": chat_id(i), "title": format!("chat {i}"), "status": "running"}))
                                .collect();
                            json!({"listEpoch": "E", "listSeq": heads.list, "follow": true, "sessions": sessions})
                        }
                        "_acpmux/attach" => {
                            let session = params["sessionId"].as_str().unwrap_or("").to_string();
                            let index = (0..STALE_CHATS).find(|i| chat_id(*i) == session).unwrap();
                            let head = heads.chats[index];
                            let after = params["afterSeq"].as_u64().unwrap_or(0).min(head);
                            let max_bytes =
                                params["maxBytes"].as_u64().unwrap_or(u64::MAX).saturating_sub(512);
                            let limit = params["limit"].as_u64().unwrap_or(u64::MAX);
                            let (mut records, mut used) = (Vec::new(), 0u64);
                            for seq in (after + 1..=head).rev() {
                                let record = json!({"seq": seq, "kind": "transcript", "sessionId": session,
                                    "msg": {"text": "a".repeat(240)}});
                                let size = record.to_string().len() as u64 + 1;
                                if used + size > max_bytes || records.len() as u64 >= limit {
                                    break;
                                }
                                used += size;
                                records.push(record);
                            }
                            let has_more = (records.len() as u64) < head - after;
                            records.reverse();
                            json!({"session": {"sessionId": session}, "events": records, "hasMore": has_more,
                                "lastSeq": head, "pageThrough": head})
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

/// The phone as it left: caught up to the Mac at t = 0, chat 0 opened last.
fn left_phone() -> Cursors {
    let mut cursors = Cursors::default();
    cursors.list.tree_revision = Some("r0".into());
    cursors.list.list_seq = Some(0);
    cursors.list.list_epoch = Some("E".into());
    for i in 0..STALE_CHATS {
        cursors.chats.insert(chat_id(i), ChatCursor { last_seq: 0, opened_at: 100 - i as u64 });
    }
    cursors
}

/// Changes the phone does not hold: tree revisions, list rows, chat events.
fn behind(cursors: &Cursors, heads: &MacHeads) -> u64 {
    let tree =
        cursors.list.tree_revision.as_deref().and_then(|r| r.strip_prefix('r')?.parse().ok()).unwrap_or(0);
    let mut behind =
        heads.tree.saturating_sub(tree) + heads.list.saturating_sub(cursors.list.list_seq.unwrap_or(0));
    for (i, head) in heads.chats.iter().enumerate() {
        behind += head.saturating_sub(cursors.chats.get(&chat_id(i)).map_or(0, |c| c.last_seq));
    }
    behind
}

/// One foreground catch-up's time, split: the shaped TCP handshake (until the Mac accepted; zero
/// on a link already open), the request up plus the Mac's service plus the first reply byte down,
/// the rest of the reply, and the phone applying it. Milliseconds.
#[derive(Clone, Copy, Debug, Default)]
struct Phases {
    connect: f64,
    first_byte: f64,
    transfer: f64,
    apply: f64,
}

/// One wake over `link`: the request the phone's code builds, the reply, the cursors moved.
/// Returns (ms, reply bytes, events a tail-first page left behind for scroll-back).
async fn stale_wake(link: &Link, cursors: &mut Cursors, ask: &phone::Ask, at: u64) -> (f64, u64, u64) {
    let (ms, bytes, skipped, _) = stale_wake_phased(link, cursors, ask, at, None).await;
    (ms, bytes, skipped)
}

/// [`stale_wake`], with its [`Phases`]; `opened` is when the link's connect started (a fresh
/// link), or `None` for a link already open.
async fn stale_wake_phased(
    link: &Link,
    cursors: &mut Cursors,
    ask: &phone::Ask,
    at: u64,
    opened: Option<Instant>,
) -> (f64, u64, u64, Phases) {
    let args = phone::request(cursors, ask);
    let held: Vec<(String, u64)> = cursors.chats.iter().map(|(id, c)| (id.clone(), c.last_seq)).collect();
    let start = opened.unwrap_or_else(Instant::now);
    let mut channel = link.open("catch-up", args).await.unwrap();
    let mut reply = Vec::new();
    let mut first = None;
    loop {
        match channel.recv().await {
            Some(ChannelEvent::Data(data)) => {
                first.get_or_insert_with(Instant::now);
                reply.extend_from_slice(&data);
            }
            Some(ChannelEvent::Closed(info)) => {
                assert_eq!(info.code, "eof");
                break;
            }
            None => panic!("catch-up ended"),
        }
    }
    let done = Instant::now();
    let since = |a: Instant, b: Instant| b.saturating_duration_since(a).as_secs_f64() * 1000.0;
    let accepted = opened.and_then(|_| *ACCEPTED.lock().unwrap()).unwrap_or(start);
    let first = first.unwrap_or(done);
    let wire = reply.len();
    let reply = match cmux_mobile_link::zstd_stream::open_one_envelope(&reply) {
        Some(text) => text.unwrap(),
        None => reply,
    };
    let answer = phone::read(&reply).unwrap();
    let skipped = answer
        .chats
        .iter()
        .filter_map(|chat| {
            let older = chat.older_before?;
            let had = held.iter().find(|(id, _)| *id == chat.session_id).map_or(0, |(_, seq)| *seq);
            Some(older.saturating_sub(had + 1))
        })
        .sum();
    if ask.hour_now.is_some() {
        cursors.spend_background(at, wire as u64);
    }
    cursors.apply_catch_up(&answer, at);
    let applied = Instant::now();
    let phases = Phases {
        connect: since(start, accepted),
        first_byte: since(accepted.max(start), first),
        transfer: since(first, done),
        apply: since(done, applied),
    };
    (since(start, applied), wire as u64, skipped, phases)
}

/// `runs` foreground catch-ups from `cursors`, each on a fresh shaped link (seed `31 + run`, so
/// the two arms draw the same losses), with the zstd reply when `zstd`; then the same request
/// again on the open link. Times include the phone applying the reply.
#[allow(clippy::too_many_arguments, reason = "one arm of one row")]
async fn foreground_arm(
    config: &Arc<ServiceConfig>,
    profile: &str,
    runs: usize,
    cursors: &Cursors,
    at_fg: &MacHeads,
    away: u64,
    busy: bool,
    zstd: bool,
) -> Value {
    let (mut fg_ms, mut warm_ms, mut behind_after) = (Vec::new(), Vec::new(), Vec::new());
    let mut phases: [Vec<f64>; 4] = Default::default();
    let (mut wire_bytes, mut skipped, mut turns, mut down_segments, mut worst) = (0, 0, 0, 0, Value::Null);
    for run in 0..runs {
        let mut fg = cursors.clone();
        let (link, shaper) = shaped_link(Arc::clone(config), profile, 31 + run as u64).await;
        let opened = Instant::now();
        let mut ask = phone::Ask::new(Wake::Foreground { chat: Some(chat_id(0)), terminal: None });
        ask.chats = (0..4).map(|i| (chat_id(i), None)).collect();
        if zstd {
            ask.compressions = vec![cmux_mobile_link::zstd_stream::NAME.to_string()];
        }
        let (ms, bytes, s, split) =
            stale_wake_phased(&link, &mut fg, &ask, 1_000_000 + away, Some(opened)).await;
        let counters = shaper.counters();
        turns = counters.up_turns;
        down_segments = counters.down_bytes.div_ceil(cmux_fault::shaper::SEGMENT as u64);
        for (list, value) in phases.iter_mut().zip([split.connect, split.first_byte, split.transfer, split.apply]) {
            list.push(value);
        }
        fg_ms.push(ms);
        wire_bytes = bytes;
        skipped = s;
        // What the busy session added while the catch-up ran (an event every 2 s).
        let arrived = if busy { (ms / 2000.0) as u64 } else { 0 };
        let left = behind(&fg, at_fg) + arrived;
        if ms >= fg_ms.iter().copied().fold(0.0, f64::max) {
            worst = json!({"run": run, "ms": (ms * 10.0).round() / 10.0, "behind_after": left,
                "behind_cursor": behind(&fg, at_fg), "connect": split.connect.round(),
                "first_byte": split.first_byte.round(), "transfer": split.transfer.round(),
                "apply": split.apply.round()});
        }
        behind_after.push(left);
        let mut again = cursors.clone();
        let (ms, ..) = stale_wake(&link, &mut again, &ask, 1_000_000 + away).await;
        warm_ms.push(ms);
    }
    let [connect, first_byte, transfer, apply] = phases;
    json!({"zstd": zstd, "ms": stats(fg_ms), "warm_ms": stats(warm_ms), "wire_bytes": wire_bytes,
        "skipped": skipped, "up_turns": turns, "down_segments": down_segments,
        "behind_after_max": behind_after.iter().max(),
        "behind_after_runs": behind_after.iter().filter(|b| **b > 0).count(),
        "phases": {"connect": stats(connect), "first_byte": stats(first_byte),
            "transfer": stats(transfer), "apply": stats(apply)}, "worst": worst})
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "bench: staleness rows"]
async fn staleness_rows_under_conditions() {
    let profiles = std::env::var("STALENESS_PROFILES").unwrap_or_else(|_| "good-wifi,lte,lossy-3".into());
    let aways: Vec<u64> = std::env::var("STALENESS_AWAYS")
        .unwrap_or_else(|_| "60,600,3600,28800".into())
        .split(',')
        .map(|s| s.parse().unwrap())
        .collect();
    let runs: usize = env_or("STALENESS_RUNS", 10);
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
    let heads = Arc::new(Mutex::new(MacHeads { chats: vec![0; STALE_CHATS], ..Default::default() }));
    mac_daemon(dir.path(), Arc::clone(&heads));
    let config = config(dir.path(), mac_acpmux(Arc::clone(&heads)).await);
    let set = |t: u64, busy: bool| *heads.lock().unwrap() = heads_at(busy, t);
    let load = if duress > 0 { format!("duress: {duress} busy threads") } else { "idle machine".into() };
    for profile in profiles.split(',') {
        for &away in &aways {
            for busy in [false, true] {
                // before: no sips; wake: sips bounded per wake only; hour: per wake and per hour.
                for variant in ["before", "after-wake-bound", "after"] {
                    let mut cursors = left_phone();
                    let (mut bg_bytes, mut bg_wakes, mut skipped) = (0u64, 0u64, 0u64);
                    let mut spends: Vec<(u64, u64)> = Vec::new();
                    if variant != "before" {
                        let mut wakes: Vec<(u64, bool)> = (1..)
                            .map(|k| (k * REFRESH_EVERY, false))
                            .take_while(|(t, _)| *t < away)
                            .collect();
                        if busy {
                            wakes
                                .extend((1..).map(|k| (k * PUSH_EVERY, true)).take_while(|(t, _)| *t < away));
                        }
                        wakes.sort();
                        let (link, _shaper) = shaped_link(Arc::clone(&config), profile, 21).await;
                        for (t, push) in wakes {
                            set(t, busy);
                            let wake =
                                if push { Wake::Push { chat: Some(chat_id(0)) } } else { Wake::Refresh };
                            let mut ask = phone::Ask::new(wake);
                            // The wall clock: the phone left at 1_000_000 s.
                            ask.hour_now = (variant == "after").then_some(1_000_000 + t);
                            let (_, bytes, s) = stale_wake(&link, &mut cursors, &ask, 1_000_000 + t).await;
                            bg_bytes += bytes;
                            bg_wakes += 1;
                            skipped += s;
                            spends.push((t, bytes));
                        }
                    }
                    set(away, busy);
                    let at_fg = heads.lock().unwrap().clone();
                    let behind_at_fg = behind(&cursors, &at_fg);
                    let max_hour = spends
                        .iter()
                        .map(|(end, _)| {
                            spends
                                .iter()
                                .filter(|(t, _)| *t <= *end && t + 3600 > *end)
                                .map(|(_, b)| b)
                                .sum::<u64>()
                        })
                        .max()
                        .unwrap_or(0);
                    let fg = foreground_arm(&config, profile, runs, &cursors, &at_fg, away, busy, false).await;
                    let fg_zstd = foreground_arm(&config, profile, runs, &cursors, &at_fg, away, busy, true).await;
                    let hours = away as f64 / 3600.0;
                    let row = json!({"row": "staleness", "profile": profile, "away_s": away,
                        "mac": if busy { "busy" } else { "idle" }, "variant": variant, "load": load,
                        "loadavg": loadavg(), "nproc": std::thread::available_parallelism().map(|n| n.get()).unwrap_or(0),
                        "link": "cmux-fault shaper (link-profiles.json)",
                        "bg_wakes": bg_wakes, "bg_bytes": bg_bytes,
                        "bg_bytes_per_hour": if hours >= 1.0 { (bg_bytes as f64 / hours).round() as u64 } else { bg_bytes },
                        "bg_max_hour_bytes": max_hour, "hour_bound": cmux_mobile_core::catch_up::hour::HOUR_BUDGET_BYTES,
                        "behind_at_fg": behind_at_fg, "behind_after_fg_max": fg["behind_after_max"],
                        "fg_ms": fg["ms"], "fg_bytes": fg["wire_bytes"], "fg": fg, "fg_zstd": fg_zstd,
                        "skipped_bg": skipped, "skipped_fg": fg_zstd["skipped"]});
                    println!("STALENESS-ROW {row}");
                }
            }
        }
    }
    stop.store(true, Ordering::Relaxed);
    for spinner in spinners {
        let _ = spinner.join();
    }
}
