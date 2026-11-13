//! iOS connectivity and reliability matrix, protocol level (runs on Linux).
//!
//! Each `#[tokio::test]` here is one cell of the matrix in
//! `cmux-next-ios/reliability-matrix/cells.json`; the workflow
//! `.github/workflows/ios-reliability-matrix.yml` runs it with the Swift cells
//! (CmuxMobileLiveTests/ConnectivityMatrixTests.swift) and the existing link
//! suites, and `scripts/ci/ios_reliability_matrix.py` turns the results into
//! one table. The cells are `#[ignore]`d so a plain `cargo test` (the rust
//! workspaces job, in debug and in parallel) skips them: they time
//! themselves, so they run alone, in release, with `--ignored`:
//! `cargo test --release -p cmux-mobile-host --test reliability_matrix -- --ignored --nocapture --test-threads=1`.
//!
//! The rig is the real phone `Link`, the real `cmux-mobile-host` services and
//! a fake cmux-tui daemon on a Unix socket. Between phone and Mac sits a
//! "toxic" pipe that adds one-way latency, random stalls (what loss does to an
//! ordered stream: a retransmit holds everything behind it) and can go
//! offline (pause) and come back without losing bytes, like a TCP or tunnel
//! stream across a short outage. It holds about 4 MB in flight, as a socket
//! buffer does; past that the sender waits.
//!
//! Degenerate axis: every cell runs a small variant and a god variant (a
//! session list of thousands, MB-sized tool output, a backlog of tens of
//! thousands of deltas after a long offline period) and asserts the god
//! result is within 1.2x of the small one ([`within_god_bound`]), not only that
//! it eventually works.
//!
//! Every cell prints one `MATRIX {json}` line per variant with its numbers.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use bytes::Bytes;
use cmux_mobile_host::config::{AcpmuxTarget, ServiceConfig};
use cmux_mobile_host::pairing::LinkAuth;
use cmux_mobile_host::services::{Peer, serve};
use cmux_mobile_link::{Channel, ChannelEvent, Lane, Link, LinkConfig, Role};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader, DuplexStream};
use tokio::sync::{mpsc, watch};
use tokio::time::Instant;

/// The degenerate bound: the god variant may take at most this times the
/// small one.
const GOD_RATIO: f64 = 1.2;
/// Below this many milliseconds a difference is scheduler noise, not cost
/// that grows with the session (a 0.4 ms vs 0.6 ms reply is "the same").
const NOISE_FLOOR_MS: f64 = 5.0;

fn within_god_bound(small_ms: f64, god_ms: f64) -> bool {
    god_ms <= small_ms * GOD_RATIO + NOISE_FLOOR_MS
}

fn report(cell: &str, variant: &str, fields: Value) {
    let mut line = json!({"cell": cell, "variant": variant});
    if let (Some(line), Some(fields)) = (line.as_object_mut(), fields.as_object()) {
        line.extend(fields.clone());
    }
    println!("MATRIX {line}");
}

fn ms(duration: Duration) -> f64 {
    duration.as_secs_f64() * 1000.0
}

// ---------------------------------------------------------------------------
// Toxic pipe
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Default)]
struct Toxics {
    /// Added to every chunk, each way.
    latency: Duration,
    /// Chance per chunk that it (and everything behind it) stalls.
    stall_chance: f64,
    stall: Duration,
}

/// Controls a toxic pipe: offline (nothing moves, nothing is lost) and back.
#[derive(Clone)]
struct ToxicControl {
    offline: watch::Sender<bool>,
}

impl ToxicControl {
    fn go_offline(&self) {
        let _ = self.offline.send(true);
    }

    fn come_back(&self) {
        let _ = self.offline.send(false);
    }
}

/// Two stream ends (phone, Mac) joined through the toxics.
fn toxic_pipe(toxics: Toxics, seed: u64) -> (DuplexStream, DuplexStream, ToxicControl) {
    let (phone, phone_inner) = tokio::io::duplex(256 * 1024);
    let (mac_inner, mac) = tokio::io::duplex(256 * 1024);
    let (offline, offline_rx) = watch::channel(false);
    let (phone_read, phone_write) = tokio::io::split(phone_inner);
    let (mac_read, mac_write) = tokio::io::split(mac_inner);
    tokio::spawn(pump(phone_read, mac_write, toxics, offline_rx.clone(), seed));
    tokio::spawn(pump(mac_read, phone_write, toxics, offline_rx, seed.wrapping_mul(31).wrapping_add(7)));
    (phone, mac, ToxicControl { offline })
}

async fn pump<R, W>(mut read: R, mut write: W, toxics: Toxics, mut offline: watch::Receiver<bool>, seed: u64)
where
    R: tokio::io::AsyncRead + Unpin + Send + 'static,
    W: tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    // What the network holds in flight while it is down or slow: a sender's
    // socket buffer and the path, about 4 MB (128 reads of up to 32 KB).
    // Past it the writer waits, as a real socket's does.
    let (tx, mut rx) = mpsc::channel::<(Instant, Vec<u8>)>(128);
    let reader = tokio::spawn(async move {
        let mut rng = seed | 1;
        let mut buffer = vec![0u8; 32 * 1024];
        loop {
            let n = match read.read(&mut buffer).await {
                Ok(0) | Err(_) => return,
                Ok(n) => n,
            };
            // xorshift64: deterministic per seed, no extra dependency.
            rng ^= rng << 13;
            rng ^= rng >> 7;
            rng ^= rng << 17;
            let roll = (rng % 10_000) as f64 / 10_000.0;
            let mut due = Instant::now() + toxics.latency;
            if roll < toxics.stall_chance {
                due += toxics.stall;
            }
            if tx.send((due, buffer[..n].to_vec())).await.is_err() {
                return;
            }
        }
    });
    let mut last_due = Instant::now();
    while let Some((due, chunk)) = rx.recv().await {
        // Ordered stream: a stalled chunk holds everything behind it.
        let due = due.max(last_due);
        last_due = due;
        tokio::time::sleep_until(due).await;
        while *offline.borrow() {
            if offline.changed().await.is_err() {
                break;
            }
        }
        if write.write_all(&chunk).await.is_err() {
            break;
        }
    }
    reader.abort();
}

// ---------------------------------------------------------------------------
// Fake cmux-tui daemon
// ---------------------------------------------------------------------------

/// The fake daemon's knobs, shared with its connections.
#[derive(Default)]
struct DaemonState {
    workspaces: AtomicUsize,
}

struct FakeDaemon {
    socket: PathBuf,
    state: Arc<DaemonState>,
    task: Option<tokio::task::JoinHandle<()>>,
}

impl FakeDaemon {
    fn start(dir: &Path, workspaces: usize) -> Self {
        let state = Arc::new(DaemonState { workspaces: AtomicUsize::new(workspaces) });
        let mut daemon = Self { socket: dir.join("main.sock"), state, task: None };
        daemon.listen();
        daemon
    }

    fn listen(&mut self) {
        let _ = std::fs::remove_file(&self.socket);
        let listener = tokio::net::UnixListener::bind(&self.socket).expect("bind fake daemon");
        let state = Arc::clone(&self.state);
        self.task = Some(tokio::spawn(async move {
            let mut clients = tokio::task::JoinSet::new();
            loop {
                tokio::select! {
                    accepted = listener.accept() => {
                        let Ok((stream, _)) = accepted else { return };
                        clients.spawn(daemon_client(stream, Arc::clone(&state)));
                    }
                    _ = clients.join_next(), if !clients.is_empty() => {}
                }
            }
        }));
    }

    /// The daemon process dies: every socket closes, the path refuses.
    fn kill(&mut self) {
        if let Some(task) = self.task.take() {
            task.abort();
        }
        let _ = std::fs::remove_file(&self.socket);
    }

    fn restart(&mut self) {
        self.kill();
        self.listen();
    }
}

impl Drop for FakeDaemon {
    fn drop(&mut self) {
        self.kill();
    }
}

fn workspace_tree(count: usize) -> Value {
    let workspaces: Vec<Value> = (0..count)
        .map(|i| {
            let base = 10 + i as u64 * 10;
            json!({
                "id": base, "key": format!("workspace-{i}"), "title": format!("Workspace {i}"),
                "screens": [{"id": base + 1, "panes": [{"id": base + 2, "active_tab": 0, "tabs": [
                    {"surface": base + 3, "kind": "terminal", "cwd": "/", "title": format!("agent {i}")},
                    {"surface": base + 4, "kind": "terminal", "cwd": "/", "title": "shell"}
                ]}]}]
            })
        })
        .collect();
    json!({"registry_id": "matrix-registry", "workspaces": workspaces})
}

/// One daemon connection. `send` with text `FLOOD:<lines>:<bytes>:<delay ms>`
/// makes the daemon push that many event lines of that size (a tool's output,
/// or the deltas a long-offline phone missed) before it answers.
async fn daemon_client(stream: tokio::net::UnixStream, state: Arc<DaemonState>) {
    let (read, write) = stream.into_split();
    let write = Arc::new(tokio::sync::Mutex::new(write));
    let mut lines = BufReader::new(read).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let Ok(request) = serde_json::from_str::<Value>(&line) else { continue };
        let mut answer = json!({"id": request["id"], "ok": true, "data": request});
        match request["cmd"].as_str() {
            Some("list-workspaces") => answer["data"] = workspace_tree(state.workspaces.load(Ordering::Relaxed)),
            Some("list-personal") => answer["data"] = json!({"groups": [], "workspaces": []}),
            Some("send") => {
                let text = request["text"].as_str().unwrap_or_default();
                if let Some(spec) = text.strip_prefix("FLOOD:") {
                    let parts: Vec<u64> = spec.split(':').filter_map(|p| p.parse().ok()).collect();
                    let (count, size, delay) = (parts[0], parts[1] as usize, parts.get(2).copied().unwrap_or(0));
                    let write = Arc::clone(&write);
                    let id = request["id"].clone();
                    // The flood runs beside this reader, so the daemon keeps
                    // answering other requests while it pushes.
                    tokio::spawn(async move {
                        tokio::time::sleep(Duration::from_millis(delay)).await;
                        let pad = "x".repeat(size.saturating_sub(64));
                        let mut guard = write.lock().await;
                        for seq in 0..count {
                            let event = json!({"event": "output", "seq": seq, "data": pad});
                            if guard.write_all(format!("{event}\n").as_bytes()).await.is_err() {
                                return;
                            }
                        }
                        let done = json!({"id": id, "ok": true, "data": {"flooded": count}});
                        let _ = guard.write_all(format!("{done}\n").as_bytes()).await;
                    });
                    continue;
                }
            }
            _ if request["operation"] == "sidebar_layout.get" => answer["result"] = json!({"sections": []}),
            _ => {}
        }
        let mut guard = write.lock().await;
        if guard.write_all(format!("{answer}\n").as_bytes()).await.is_err() {
            return;
        }
    }
}

// ---------------------------------------------------------------------------
// Rig: phone link + host services + fake daemon
// ---------------------------------------------------------------------------

struct Rig {
    _dir: tempfile::TempDir,
    daemon: FakeDaemon,
    phone: Link,
    toxic: ToxicControl,
    host: tokio::task::JoinHandle<()>,
}

impl Rig {
    async fn start(workspaces: usize, toxics: Toxics) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let daemon = FakeDaemon::start(dir.path(), workspaces);
        let config = Arc::new(ServiceConfig {
            tui_socket_dir: dir.path().to_owned(),
            default_session: "main".into(),
            default_socket: None,
            file_roots: vec![],
            acpmux: AcpmuxTarget::Fixed { url: "ws://127.0.0.1:1/".into(), token: None },
            pairing: None,
            agent_tab_host: None,
            uploads_dir: dir.path().join("uploads"),
            chief_socket: None,
            browser: cmux_mobile_host::browser::BrowserConfig::new(None, 1),
            surface: cmux_mobile_host::surface::SurfaceConfig::new(None, 1),
        });
        let (phone_stream, mac_stream, toxic) = toxic_pipe(toxics, 0x5eed);
        let phone = Link::new(phone_stream, Role::Phone, LinkConfig::default(), None);
        let mac = Link::new(mac_stream, Role::Mac, LinkConfig::default(), None);
        let host = tokio::spawn(async move {
            let mut services = tokio::task::JoinSet::new();
            while let Some(incoming) = mac.accept().await {
                let config = Arc::clone(&config);
                services.spawn(serve(
                    config,
                    Peer {
                        device_id: "matrix-phone".into(),
                        session_id: "matrix-session".into(),
                        video: None,
                        session_exposure: None,
                    },
                    Arc::new(LinkAuth::default()),
                    incoming,
                ));
            }
            services.shutdown().await;
        });
        Self { _dir: dir, daemon, phone, toxic, host }
    }

    async fn daemon_channel(&self, lane: Lane) -> Channel {
        self.phone.open_on("daemon", json!({}), lane).await.expect("open daemon channel")
    }

    async fn finish(self) {
        self.phone.close("matrix done");
        self.host.abort();
        let _ = self.host.await;
    }
}

/// Lines from a channel, with the bytes left over between reads.
struct Lines {
    buffered: Vec<u8>,
}

impl Lines {
    fn new() -> Self {
        Self { buffered: Vec::new() }
    }

    /// The next whole line, or the close (as `Err`).
    async fn next(&mut self, channel: &mut Channel) -> Result<Value, String> {
        loop {
            if let Some(end) = self.buffered.iter().position(|b| *b == b'\n') {
                let line: Vec<u8> = self.buffered.drain(..=end).collect();
                return serde_json::from_slice(&line).map_err(|e| format!("bad line: {e}"));
            }
            match channel.recv().await {
                Some(ChannelEvent::Data(data)) => self.buffered.extend_from_slice(&data),
                Some(ChannelEvent::Closed(info)) => return Err(format!("closed {}: {}", info.code, info.reason)),
                None => return Err("channel ended".into()),
            }
        }
    }

    /// Lines until the reply with `id`; the events seen before it.
    async fn until_reply(&mut self, channel: &mut Channel, id: &str) -> Result<(Value, Vec<Value>), String> {
        let mut events = Vec::new();
        loop {
            let line = self.next(channel).await?;
            if line["id"] == id {
                return Ok((line, events));
            }
            events.push(line);
        }
    }
}

async fn send_line(channel: &Channel, value: &Value) {
    channel.send(Bytes::from(format!("{value}\n"))).await.expect("send line");
}

/// Opens a daemon channel and times one `list-workspaces` to its last byte.
async fn time_list(rig: &Rig, expect: usize) -> Duration {
    let began = Instant::now();
    let mut channel = rig.daemon_channel(Lane::Bulk).await;
    let mut lines = Lines::new();
    send_line(&channel, &json!({"id": "list", "cmd": "list-workspaces"})).await;
    let (reply, _) = tokio::time::timeout(Duration::from_secs(30), lines.until_reply(&mut channel, "list"))
        .await
        .expect("list-workspaces answered within 30 s")
        .expect("list-workspaces reply");
    let elapsed = began.elapsed();
    let got = reply["data"]["workspaces"].as_array().map(Vec::len).unwrap_or_default();
    assert_eq!(got, expect, "list-workspaces returned {got} workspaces, expected {expect}");
    channel.close("eof", "matrix").await;
    elapsed
}

fn median(mut samples: Vec<f64>) -> f64 {
    samples.sort_by(f64::total_cmp);
    samples[samples.len() / 2]
}

/// Median of `rounds` timed lists (the first warms the host's cache).
async fn list_median(rig: &Rig, expect: usize, rounds: usize) -> f64 {
    let _ = time_list(rig, expect).await;
    let mut samples = Vec::new();
    for _ in 0..rounds {
        samples.push(ms(time_list(rig, expect).await));
    }
    median(samples)
}

// ---------------------------------------------------------------------------
// Cells
// ---------------------------------------------------------------------------

/// Scale: the session list with 1, 100, 1,000 and 5,000 (god) workspaces,
/// on a clean link. The list reaches the phone whole and correct each time,
/// and 1,000+ is within 1.2x of 1.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "iOS reliability matrix cell: timed, run alone in release by ios-reliability-matrix.yml (--ignored)"]
async fn cell_scale_session_list() {
    let mut results = Vec::new();
    for (variant, count) in [("1", 1usize), ("100", 100), ("1000", 1000), ("god-5000", 5000)] {
        let rig = Rig::start(count, Toxics::default()).await;
        let median_ms = list_median(&rig, count, 5).await;
        report("scale_session_list", variant, json!({"workspaces": count, "list_ms": median_ms}));
        results.push((variant, median_ms));
        rig.finish().await;
    }
    let small = results[0].1;
    for (variant, value) in &results[1..] {
        assert!(
            within_god_bound(small, *value),
            "session list of {variant}: {value:.1} ms vs {small:.1} ms for 1 (bound {GOD_RATIO}x)"
        );
    }
}

/// Scale on a far network: 80 ms each way, 3% of chunks stall 250 ms.
/// The list arrives within 5 s, and 1,000 within 1.2x of 1.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "iOS reliability matrix cell: timed, run alone in release by ios-reliability-matrix.yml (--ignored)"]
async fn cell_network_high_latency_and_loss() {
    let toxics = Toxics { latency: Duration::from_millis(80), stall_chance: 0.03, stall: Duration::from_millis(250) };
    let mut results = Vec::new();
    for (variant, count) in [("small-1", 1usize), ("god-1000", 1000)] {
        let rig = Rig::start(count, toxics).await;
        let median_ms = list_median(&rig, count, 3).await;
        report("network_high_latency_and_loss", variant, json!({"workspaces": count, "list_ms": median_ms}));
        assert!(median_ms < 5000.0, "list of {count} took {median_ms:.0} ms over a lossy 160 ms RTT link");
        results.push(median_ms);
        rig.finish().await;
    }
    assert!(
        within_god_bound(results[0], results[1]),
        "lossy link: 1,000 workspaces {:.0} ms vs 1 workspace {:.0} ms",
        results[1],
        results[0]
    );
}

/// Keystroke round trip on the input lane while a tool's output streams on
/// another channel: 1 KB (small) vs 8 MB (god). Keystrokes must not wait
/// behind the output.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "iOS reliability matrix cell: timed, run alone in release by ios-reliability-matrix.yml (--ignored)"]
async fn cell_degenerate_keystroke_behind_mb_tool_output() {
    head_of_line("degenerate_keystroke_behind_mb_tool_output", Lane::Input).await;
}

/// Opening another session (a new bulk channel's first reply) while a tool's
/// output streams: 1 KB vs 8 MB. Switching sessions must not wait behind it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "iOS reliability matrix cell: timed, run alone in release by ios-reliability-matrix.yml (--ignored)"]
async fn cell_degenerate_open_session_behind_mb_tool_output() {
    head_of_line("degenerate_open_session_behind_mb_tool_output", Lane::Bulk).await;
}

async fn head_of_line(cell: &str, lane: Lane) {
    let toxics = Toxics { latency: Duration::from_millis(20), ..Toxics::default() };
    let mut results = Vec::new();
    for (variant, lines, size) in [("small-1KB", 1u64, 1024usize), ("god-8MB", 8u64, 1024 * 1024)] {
        let rig = Rig::start(1, toxics).await;
        let mut output = rig.daemon_channel(Lane::Bulk).await;
        let mut output_lines = Lines::new();
        send_line(&output, &json!({"id": "flood", "cmd": "send", "surface": 13, "text": format!("FLOOD:{lines}:{size}:0")}))
            .await;
        // Let the flood get under way first.
        tokio::time::sleep(Duration::from_millis(30)).await;
        let mut samples = Vec::new();
        for round in 0..8 {
            let began = Instant::now();
            let mut channel = rig.daemon_channel(lane).await;
            let mut reader = Lines::new();
            let id = format!("probe-{round}");
            send_line(&channel, &json!({"id": id, "cmd": "send", "surface": 14, "text": "x"})).await;
            tokio::time::timeout(Duration::from_secs(30), reader.until_reply(&mut channel, &id))
                .await
                .expect("probe answered within 30 s")
                .expect("probe reply");
            samples.push(ms(began.elapsed()));
            channel.close("eof", "matrix").await;
        }
        // The output arrives whole: every line once, in order.
        let (_, events) = tokio::time::timeout(Duration::from_secs(60), output_lines.until_reply(&mut output, "flood"))
            .await
            .expect("tool output delivered within 60 s")
            .expect("tool output");
        let seqs: Vec<u64> = events.iter().filter_map(|e| e["seq"].as_u64()).collect();
        assert_eq!(seqs, (0..lines).collect::<Vec<_>>(), "tool output lost, duplicated or reordered lines");
        let p50 = median(samples);
        report(cell, variant, json!({"output_bytes": lines as usize * size, "probe_p50_ms": p50}));
        results.push(p50);
        rig.finish().await;
    }
    assert!(
        within_god_bound(results[0], results[1]),
        "{cell}: {:.1} ms behind 8 MB of output vs {:.1} ms behind 1 KB (bound {GOD_RATIO}x)",
        results[1],
        results[0]
    );
}

/// Offline, then back: the link goes silent for 3 s (a tunnel, elevator or
/// Wi-Fi to cellular handoff that keeps the session) while the Mac keeps
/// producing deltas: 10 (small) vs 20,000 (god, hours of agent output). The
/// phone drains the feed as fast as it can, as the app does. Asserts every
/// delta arrives once and in order, the link stays up, and a fresh request
/// after the network is back (the session list) answers within 1.2x of the
/// small backlog.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "iOS reliability matrix cell: timed, run alone in release by ios-reliability-matrix.yml (--ignored)"]
async fn cell_network_offline_then_back_with_backlog() {
    backlog_after_outage("network_offline_then_back_with_backlog", Duration::ZERO).await;
}

/// The same outage, with a phone that applies each delta slower than they
/// arrive (a busy main actor applying a god session's deltas: 1 ms each).
/// One slow channel must not hold the session list, or lose its own deltas.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "iOS reliability matrix cell: timed, run alone in release by ios-reliability-matrix.yml (--ignored)"]
async fn cell_degenerate_slow_consumer_after_outage() {
    backlog_after_outage("degenerate_slow_consumer_after_outage", Duration::from_millis(1)).await;
}

async fn backlog_after_outage(cell: &str, per_delta: Duration) {
    let mut results = Vec::new();
    for (variant, deltas) in [("small-10", 10u64), ("god-20000", 20_000u64)] {
        let rig = Rig::start(100, Toxics::default()).await;
        let mut feed = rig.daemon_channel(Lane::Bulk).await;
        // Warm the list once while online.
        let _ = time_list(&rig, 100).await;
        send_line(&feed, &json!({"id": "backlog", "cmd": "send", "surface": 13, "text": format!("FLOOD:{deltas}:1024:200")}))
            .await;
        let drain = tokio::spawn(async move {
            let mut lines = Lines::new();
            let mut seqs = Vec::new();
            let result = tokio::time::timeout(Duration::from_secs(120), async {
                loop {
                    let line = lines.next(&mut feed).await?;
                    if line["id"] == "backlog" {
                        return Ok::<(), String>(());
                    }
                    if let Some(seq) = line["seq"].as_u64() {
                        seqs.push(seq);
                        if !per_delta.is_zero() {
                            tokio::time::sleep(per_delta).await;
                        }
                    }
                }
            })
            .await;
            (result, seqs)
        });
        tokio::time::sleep(Duration::from_millis(50)).await;
        rig.toxic.go_offline();
        tokio::time::sleep(Duration::from_secs(3)).await;
        rig.toxic.come_back();
        let back = Instant::now();
        // The link's own ping while the backlog drains: the phone's probe
        // (2 s budget) redials a link whose pong is this late.
        let ping_began = Instant::now();
        let ping = tokio::time::timeout(Duration::from_secs(10), rig.phone.ping()).await;
        let ping_ms = match ping {
            Ok(Ok(_)) => ms(ping_began.elapsed()),
            _ => 10_000.0,
        };
        // Under time_list's own 30 s bound, so a stuck list is reported, not a panic.
        let fresh = tokio::time::timeout(Duration::from_secs(25), time_list(&rig, 100)).await;
        let fresh_ms = fresh.map(ms).unwrap_or(25_000.0);
        let (drained, seqs) = drain.await.expect("drain task");
        let drained_ms = ms(back.elapsed());
        let link_up = rig.phone.closed_state().borrow().is_none();
        let in_order = seqs.windows(2).all(|w| w[1] == w[0] + 1);
        report(
            cell,
            variant,
            json!({
                "deltas": deltas, "received": seqs.len(), "fresh_list_ms": fresh_ms, "ping_ms": ping_ms,
                "backlog_drained_ms": drained_ms, "feed": format!("{drained:?}"), "link_up": link_up,
            }),
        );
        rig.finish().await;
        assert!(link_up, "{cell} {variant}: the link closed during a 3 s outage");
        assert!(ping_ms < 2000.0, "{cell} {variant}: a ping took {ping_ms:.0} ms behind the backlog (the phone's probe gives up at 2 s and redials)");
        assert!(
            matches!(drained, Ok(Ok(()))),
            "{cell} {variant}: the feed ended before its backlog: {drained:?} after {} of {deltas} deltas",
            seqs.len()
        );
        assert_eq!(seqs.len() as u64, deltas, "{cell} {variant}: deltas lost or duplicated across the outage");
        assert!(in_order, "{cell} {variant}: deltas reordered across the outage");
        results.push(fresh_ms);
    }
    assert!(
        within_god_bound(results[0], results[1]),
        "{cell}: after an outage the session list took {:.0} ms behind 20,000 deltas vs {:.0} ms behind 10",
        results[1],
        results[0]
    );
}

/// The daemon restarts under a live phone (cmux-tui crash or update). The
/// open channel ends with a clear close, not a hang; a request while it is
/// down gets a clear refusal; once it is back a new channel answers within
/// 1 s. Small: 1 workspace; god: 5,000.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "iOS reliability matrix cell: timed, run alone in release by ios-reliability-matrix.yml (--ignored)"]
async fn cell_host_daemon_restart() {
    let mut results = Vec::new();
    for (variant, count) in [("small-1", 1usize), ("god-5000", 5000usize)] {
        let mut rig = Rig::start(count, Toxics::default()).await;
        let mut open = rig.daemon_channel(Lane::Bulk).await;
        let mut lines = Lines::new();
        send_line(&open, &json!({"id": "before", "cmd": "list-workspaces"})).await;
        lines.until_reply(&mut open, "before").await.expect("answer before the restart");
        rig.daemon.kill();
        let ended = tokio::time::timeout(Duration::from_secs(3), lines.next(&mut open)).await;
        let close = match ended {
            Ok(Err(close)) => close,
            Ok(Ok(line)) => panic!("expected the channel to close with the daemon, got {line}"),
            Err(_) => panic!("the open channel hung for 3 s after the daemon died"),
        };
        // While it is down: a clear refusal, quickly.
        let mut down = rig.daemon_channel(Lane::Bulk).await;
        let mut down_lines = Lines::new();
        send_line(&down, &json!({"id": "down", "cmd": "list-workspaces"})).await;
        let refusal = tokio::time::timeout(Duration::from_secs(3), down_lines.next(&mut down))
            .await
            .expect("a request to a dead daemon was answered or refused within 3 s");
        assert!(refusal.is_err(), "a dead daemon answered: {refusal:?}");
        rig.daemon.restart();
        let back = time_list(&rig, count).await;
        report(
            "host_daemon_restart",
            variant,
            json!({"workspaces": count, "close": close, "refusal": refusal.err(), "back_list_ms": ms(back)}),
        );
        assert!(back < Duration::from_secs(1), "first list after the restart took {back:?}");
        results.push(ms(back));
        rig.finish().await;
    }
    assert!(
        within_god_bound(results[0], results[1]),
        "after a daemon restart 5,000 workspaces took {:.0} ms vs {:.0} ms for 1",
        results[1],
        results[0]
    );
}

/// The Mac sleeps under a live link (the stream goes silent and stays
/// silent). The phone's link must notice and say so: closed within the
/// keepalive bound, so the app redials instead of showing a frozen session.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "iOS reliability matrix cell: timed, run alone in release by ios-reliability-matrix.yml (--ignored)"]
async fn cell_host_mac_asleep_link_notices() {
    let rig = Rig::start(1, Toxics::default()).await;
    let _ = time_list(&rig, 1).await;
    rig.toxic.go_offline();
    let began = Instant::now();
    let mut closed = rig.phone.closed_state();
    let config = LinkConfig::default();
    let bound = config.keepalive.unwrap_or_default() + config.keepalive_timeout + Duration::from_secs(2);
    let noticed = tokio::time::timeout(bound, closed.wait_for(Option::is_some)).await.is_ok();
    let elapsed = began.elapsed();
    let reason = closed.borrow().clone();
    report("host_mac_asleep_link_notices", "small", json!({"noticed_ms": ms(elapsed), "reason": reason}));
    assert!(noticed, "a silent link stayed open for {elapsed:?}");
    rig.finish().await;
}
