//! The pair matrix's Mac-asleep rows (ask-bb9c69b84e, offline under duress): what the phone sees when the Mac is
//! asleep, over each path, idle and under load, with no real Mac, phone or network.
//!
//! The Mac (signaling, the answer, its services) runs on its own single-threaded runtime on its own thread. Asleep
//! is that runtime blocked for the wake delay: nothing on the Mac runs, while the kernel keeps its sockets and
//! buffers what arrives, as on a suspended process. The phone is the test's runtime, its inbound datagrams shaped
//! by the `lte` link profile.
//!
//! Conditions (`PAIRMATRIX_CONDITIONS`, comma separated, all by default):
//! - `mac-asleep`: the Mac is asleep when the phone opens it cold. `ttfc_ms`: from the first dial to the first
//!   bytes of the Mac's page; the phone redials every 250 ms while dials fail, as the app does (`attempts`).
//! - `mac-asleep-resume`: the link is up and parked; the phone is away `PAIRMATRIX_SLEEP_S`, the Mac sleeps that
//!   plus the wake delay. `resume_ms`: from resume to the first bytes of a fresh page, redialing if the link is
//!   gone (`redialed`).
//! - `mac-asleep-send`: the Mac falls asleep as the phone sends 128 bytes. `send_ms`: until the Mac's ack.
//!
//! Paths (`PAIRMATRIX_PATHS`): `direct` (UDP on loopback, the fake backend), `relay` (the fake backend's
//! WebSocket relay), `relay-worker` (the real Worker's TeamHub and LinkRelay in miniflare, started by
//! `backend/scripts/pair-matrix-worker.mjs`; needs `npm ci` in backend; `LINK_RELAY_CACHE=on` passes through),
//! `relay-cache` (the same Worker with `LINK_RELAY_CACHE=on` forced; the phone reads the relay cache, not the Mac:
//! see below). The default stays `direct,relay,relay-worker`.
//! Loads (`PAIRMATRIX_LOADS`): `idle` (a 64 KB page), `duress` (a 512 KB page beside a 2 Mbit/s stream from
//! the Mac). `PAIRMATRIX_N` runs per cell (5), `PAIRMATRIX_SEED_BASE` (1), `PAIRMATRIX_MAC_WAKE_MS` (1500).
//!
//! The `relay-cache` path (RFD 0142 R2 and R9): before the Mac falls asleep it publishes the page it would serve
//! through its real publisher (`cmux_mobile_host::relay_publish::RelayPublisher`), sealed to the phone's key, to the
//! Worker's `/v1/relay-cache/<mac>/...`: the page in snapshots of at most `MAX_PLAINTEXT` (the 64 KB page in one,
//! the 512 KB page in two) plus a first screen of the first. Under duress the Mac's 2 Mbit/s stream (16 KB every
//! 64 ms) runs as deltas on its own stream through the run (a snapshot every 16), and the phone drains it through
//! the same shaped link as it reads the page. The phone is the real client (`cmux_mobile_link::relay_cache`) over
//! plain HTTP through cmux-fault's TCP shaper with the same `lte` profile and seed (a new client per run, so each
//! run pays its own TCP handshakes; a real open adds TLS). Its signaling and link are not used.
//! - `mac-asleep`: `ttfc_ms` from the first request to the first screen opened (`cold_open_first_screen`), and
//!   `snapshot_ms` to the whole page opened (its snapshots fetched at once after the first screen).
//! - `mac-asleep-resume`: the phone holds the page's position, the Mac publishes a fresh page as 16 KB deltas and
//!   sleeps; after `PAIRMATRIX_SLEEP_S` the phone calls `resume_or_snapshot` (256 KiB budget). `resume_ms` to the
//!   fresh bytes opened (the deltas, or the newest snapshot when the relay cut them).
//! - `mac-asleep-send`: no row. The cache holds what the Mac published; nothing on it takes or acks a send, so it
//!   prints `PAIRCELL-NA` with the reason.
//!
//! One `PAIRCELL {json}` line per run and metric, as `pair_matrix_ios_mac.rs` prints them:
//!
//! cargo test --release -p cmux-mobile-link --features testing --test pair_matrix_mac_asleep -- --ignored --nocapture --test-threads 1

use std::io::BufRead;
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_fault::Trace;
use cmux_fault::shaper::{ProfileFile, Shaper};
use cmux_mobile_host::relay_publish::{RelayPublishConfig, RelayPublisher, Viewer};
use cmux_mobile_link::api::ApiClient;
use cmux_mobile_link::dial::relay::RelayEndpoint;
use cmux_mobile_link::dial::{self, Connected, SessionEvents};
use cmux_mobile_link::relay_cache::{FIRST_SCREEN_BYTES, MAX_BUDGET_BYTES, RelayCache, RelayCacheConfig};
use cmux_mobile_link::testing::{
    FakeOptions, FakeSignaling, LinkProfile, set_link_profile, shape_by_profile,
};
use cmux_mobile_link::{Channel, ChannelEvent, DialOptions, LinkConfig, SignalingClient, TransportKind};
use cmux_relay_snapshot::{Floor, MAX_PLAINTEXT};
use p256::SecretKey;
use p256::ecdsa::SigningKey;

const PROFILE: &str = "lte";
const IDLE_PAGE: usize = 64 * 1024;
const DURESS_PAGE: usize = 512 * 1024;
const CHUNK: usize = 16 * 1024;
const WAIT: Duration = Duration::from_secs(20);

fn env_list(name: &str, default: &str) -> Vec<String> {
    std::env::var(name)
        .unwrap_or_else(|_| default.into())
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

fn env_u64(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// Where both sides sign in and how they reach each other.
#[derive(Clone)]
struct Base {
    url: String,
    team: String,
    mac_id: String,
    mac_token: String,
    phone_id: String,
    phone_token: String,
    relay: bool,
}

impl Base {
    fn options(&self, device: &str, token: &str, phone: bool) -> DialOptions {
        DialOptions {
            include_loopback: true,
            timeout: Duration::from_secs(10),
            relay: self.relay.then(|| RelayEndpoint::with_token(self.url.clone(), None, device, token)),
            force_relay: self.relay,
            impair_inbound: phone.then_some(shape_by_profile as dial::ImpairInbound),
            ..DialOptions::default()
        }
    }
}

/// The miniflare Worker, stopped when dropped (its stdin closes).
struct Worker {
    child: std::process::Child,
}

impl Drop for Worker {
    fn drop(&mut self) {
        drop(self.child.stdin.take());
        let _ = self.child.wait();
    }
}

/// `cache`: the Worker's relay cache on (`LINK_RELAY_CACHE=on`) whatever the environment says; otherwise the
/// environment's value passes through.
fn start_worker(cache: bool) -> Result<(Worker, Base), String> {
    let script = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../backend/scripts/pair-matrix-worker.mjs");
    let mut command = std::process::Command::new("node");
    if cache {
        command.env("LINK_RELAY_CACHE", "on");
    }
    let mut child = command
        .arg(script)
        .current_dir(concat!(env!("CARGO_MANIFEST_DIR"), "/../../../backend"))
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| format!("node: {e}"))?;
    let stdout = child.stdout.take().ok_or("no stdout")?;
    let worker = Worker { child };
    for line in std::io::BufReader::new(stdout).lines() {
        let line = line.map_err(|e| e.to_string())?;
        if let Some(json) = line.strip_prefix("PAIRWORKER ") {
            let v: serde_json::Value = serde_json::from_str(json).map_err(|e| e.to_string())?;
            let s = |p: &str| v.pointer(p).and_then(|x| x.as_str()).unwrap_or_default().to_string();
            let base = Base {
                url: s("/url"),
                team: s("/team"),
                mac_id: s("/mac/id"),
                mac_token: s("/mac/token"),
                phone_id: s("/phone/id"),
                phone_token: s("/phone/token"),
                relay: true,
            };
            return Ok((worker, base));
        }
    }
    Err("the Worker exited before PAIRWORKER".into())
}

/// The Mac on its own runtime: `sleep` blocks that runtime for a while.
struct Mac {
    sleep: tokio::sync::mpsc::UnboundedSender<Duration>,
}

impl Mac {
    fn fall_asleep(&self, d: Duration) {
        self.sleep.send(d).expect("the Mac runs");
        // Asleep before the caller's clock starts.
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn spawn_mac(base: Base) -> Mac {
    let (sleep, mut sleeps) = tokio::sync::mpsc::unbounded_channel::<Duration>();
    let (ready_tx, ready) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        rt.block_on(async move {
            tokio::spawn(async move {
                while let Some(d) = sleeps.recv().await {
                    // The whole Mac stops: this is its only thread.
                    std::thread::sleep(d);
                }
            });
            let mac = SignalingClient::connect(&base.url, &base.mac_token, &base.team, &base.mac_id)
                .await
                .expect("Mac signs in");
            ready_tx.send(()).unwrap();
            let options = base.options(&base.mac_id, &base.mac_token, false);
            while let Some(session) = mac.next_session().await {
                let events = SessionEvents {
                    backend: mac.events(),
                    session_id: session.first.session_id.clone(),
                    session: session.events,
                };
                let (mac, options) = (mac.clone(), options.clone());
                tokio::spawn(async move {
                    let Ok(connected) =
                        dial::answer(&mac, session.first, events, &options, LinkConfig::default()).await
                    else {
                        return;
                    };
                    while let Some(incoming) = connected.link.accept().await {
                        tokio::spawn(serve(incoming.service, incoming.args, incoming.channel));
                    }
                });
            }
        });
    });
    ready.recv_timeout(Duration::from_secs(20)).expect("the Mac signed in");
    Mac { sleep }
}

async fn send_page(channel: &Channel, size: usize) -> bool {
    let mut sent = 0;
    while sent < size {
        let n = CHUNK.min(size - sent);
        if channel.send(Bytes::from(vec![b'p'; n])).await.is_err() {
            return false;
        }
        sent += n;
    }
    true
}

/// The Mac's services: `content` sends a page on open and on each `get`, and acks anything else; `bulk` streams
/// 2 Mbit/s until the phone goes.
async fn serve(service: String, args: serde_json::Value, mut channel: Channel) {
    let page = args.get("page").and_then(|v| v.as_u64()).unwrap_or(IDLE_PAGE as u64) as usize;
    match service.as_str() {
        "content" => {
            if !send_page(&channel, page).await {
                return;
            }
            while let Some(ChannelEvent::Data(bytes)) = channel.recv().await {
                let ok = if bytes.starts_with(b"get") {
                    send_page(&channel, page).await
                } else {
                    channel.send(Bytes::from_static(b"ack")).await.is_ok()
                };
                if !ok {
                    return;
                }
            }
        }
        "bulk" => loop {
            if channel.send(Bytes::from(vec![b'b'; CHUNK])).await.is_err() {
                return;
            }
            tokio::time::sleep(Duration::from_millis(64)).await;
        },
        _ => {}
    }
}

/// The first bytes on `channel` within `WAIT`, then (with `rest`) the rest of a page of `size`.
async fn first_bytes(channel: &mut Channel, size: usize, rest: bool) -> Result<(), String> {
    let mut got = 0;
    while got < size {
        match tokio::time::timeout(WAIT, channel.recv()).await {
            Err(_) => return Err("no page in time".into()),
            Ok(Some(ChannelEvent::Data(bytes))) => got += bytes.len(),
            Ok(other) => return Err(format!("page: {other:?}")),
        }
        if !rest {
            return Ok(());
        }
    }
    Ok(())
}

struct Open {
    connected: Connected,
    content: Channel,
    attempts: u32,
}

/// Dial until a dial works (every 250 ms after a failure, within `WAIT`), open the page and, under duress, the
/// stream beside it; drain the stream on its own task.
async fn open(base: &Base, phone: &SignalingClient, page: usize, duress: bool) -> Result<Open, String> {
    let options = base.options(&base.phone_id, &base.phone_token, true);
    let deadline = Instant::now() + WAIT;
    let mut attempts = 0;
    let connected = loop {
        attempts += 1;
        match dial::connect(phone, &base.mac_id, TransportKind::WireGuard, &options, LinkConfig::default())
            .await
        {
            Ok(connected) => break connected,
            Err(error) if Instant::now() >= deadline => return Err(format!("dial: {error}")),
            Err(_) => tokio::time::sleep(Duration::from_millis(250)).await,
        }
    };
    let content = connected
        .link
        .open("content", serde_json::json!({ "page": page }))
        .await
        .map_err(|e| format!("open: {e}"))?;
    if duress {
        let mut bulk =
            connected.link.open("bulk", serde_json::json!({})).await.map_err(|e| format!("bulk: {e}"))?;
        tokio::spawn(async move { while let Some(ChannelEvent::Data(_)) = bulk.recv().await {} });
    }
    Ok(Open { connected, content, attempts })
}

struct Row<'a> {
    path: &'a str,
    condition: &'a str,
    load: &'a str,
    run: u64,
    seed: u64,
    wake_ms: u64,
}

impl Row<'_> {
    fn emit(&self, metric: &str, value: Result<f64, String>, extra: serde_json::Value) {
        // Every metric waits out the Mac's wake (or, for resume, the wake past the phone's own time away): the
        // part above it is what the path and the load cost.
        let over = value.as_ref().ok().map(|v| ((v - self.wake_ms as f64) * 10.0).round() / 10.0);
        let (value, error) = match value {
            Ok(v) => (serde_json::json!((v * 10.0).round() / 10.0), serde_json::Value::Null),
            Err(e) => (serde_json::Value::Null, serde_json::json!(e)),
        };
        let mut row = serde_json::json!({
            "pair": "ios-mac", "path": self.path, "condition": self.condition, "load": self.load,
            "profile": PROFILE, "run": self.run, "seed": self.seed, "metric": metric, "value": value,
            "error": error, "mac_wake_ms": self.wake_ms, "over_wake_ms": over,
        });
        if let (Some(row), Some(extra)) = (row.as_object_mut(), extra.as_object()) {
            row.extend(extra.clone());
        }
        println!("PAIRCELL {row}");
    }
}

fn ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1000.0
}

async fn mac_asleep(
    base: &Base,
    mac: &Mac,
    phone: &SignalingClient,
    page: usize,
    duress: bool,
    wake: Duration,
    row: &Row<'_>,
) {
    mac.fall_asleep(wake);
    let started = Instant::now();
    let result = match open(base, phone, page, duress).await {
        Ok(mut o) => {
            let r =
                first_bytes(&mut o.content, page, false).await.map(|()| (ms(started.elapsed()), o.attempts));
            o.connected.link.close("done");
            r
        }
        Err(e) => Err(e),
    };
    let attempts = result.as_ref().map(|(_, a)| *a).unwrap_or(0);
    row.emit("ttfc_ms", result.map(|(v, _)| v), serde_json::json!({ "attempts": attempts }));
}

#[allow(clippy::too_many_arguments, reason = "one matrix cell's facts, each read once")]
async fn mac_asleep_resume(
    base: &Base,
    mac: &Mac,
    phone: &SignalingClient,
    page: usize,
    duress: bool,
    wake: Duration,
    away: Duration,
    row: &Row<'_>,
) {
    let mut o = match open(base, phone, page, duress).await {
        Ok(o) => o,
        Err(e) => return row.emit("resume_ms", Err(e), serde_json::json!({})),
    };
    if let Err(e) = first_bytes(&mut o.content, page, true).await {
        o.connected.link.close("done");
        return row.emit("resume_ms", Err(e), serde_json::json!({}));
    }
    let parked = o
        .connected
        .link
        .park(away + wake + Duration::from_secs(30), Duration::from_secs(3))
        .await
        .unwrap_or(false);
    mac.fall_asleep(away + wake);
    tokio::time::sleep(away).await;
    let started = Instant::now();
    o.connected.link.resume();
    dial::wireguard::resume_session(&o.connected.session_id);
    let _ = o.connected.link.probe(Duration::from_millis(1500)).await;
    let mut redialed = false;
    let fresh = match o.content.send(Bytes::from_static(b"get")).await {
        Ok(()) => first_bytes(&mut o.content, page, false).await,
        Err(e) => Err(format!("get: {e}")),
    };
    let result = match fresh {
        Ok(()) => Ok(ms(started.elapsed())),
        Err(_) => {
            redialed = true;
            o.connected.link.close("redial");
            match open(base, phone, page, duress).await {
                Ok(mut again) => {
                    let r =
                        first_bytes(&mut again.content, page, false).await.map(|()| ms(started.elapsed()));
                    again.connected.link.close("done");
                    r
                }
                Err(e) => Err(e),
            }
        }
    };
    o.connected.link.close("done");
    row.emit(
        "resume_ms",
        result,
        serde_json::json!({ "parked": parked, "redialed": redialed, "away_ms": away.as_millis() as u64 }),
    );
}

async fn mac_asleep_send(
    base: &Base,
    mac: &Mac,
    phone: &SignalingClient,
    page: usize,
    duress: bool,
    wake: Duration,
    row: &Row<'_>,
) {
    let mut o = match open(base, phone, page, duress).await {
        Ok(o) => o,
        Err(e) => return row.emit("send_ms", Err(e), serde_json::json!({})),
    };
    if let Err(e) = first_bytes(&mut o.content, page, true).await {
        o.connected.link.close("done");
        return row.emit("send_ms", Err(e), serde_json::json!({}));
    }
    mac.fall_asleep(wake);
    let started = Instant::now();
    let result = async {
        o.content.send(Bytes::from(vec![b's'; 128])).await.map_err(|e| format!("send: {e}"))?;
        loop {
            match tokio::time::timeout(WAIT, o.content.recv()).await {
                Err(_) => return Err("no ack in time".to_string()),
                Ok(Some(ChannelEvent::Data(bytes))) if bytes.as_ref() == b"ack" => {
                    return Ok(ms(started.elapsed()));
                }
                Ok(Some(ChannelEvent::Data(_))) => {}
                Ok(other) => return Err(format!("ack: {other:?}")),
            }
        }
    }
    .await;
    o.connected.link.close("done");
    row.emit("send_ms", result, serde_json::json!({}));
}

// The `relay-cache` path.

/// Why `mac-asleep-send` has no `relay-cache` row.
const SEND_NA: &str = "the relay cache holds only what the Mac published (sealed snapshots and deltas); nothing on it \
                       takes or acks a phone's send, so a send still waits for the Mac's wake over a link path";
/// The most of the page one snapshot holds: whole chunks within the seal's plaintext bound.
const PART: usize = (MAX_PLAINTEXT / CHUNK) * CHUNK;
/// The Mac's stream under duress: a chunk every 64 ms (2 Mbit/s), as `serve`'s `bulk` sends it.
const BULK_EVERY: Duration = Duration::from_millis(64);
/// A snapshot of the stream every this many deltas, so a reader whose deltas the relay dropped can jump.
const BULK_SNAPSHOT_EVERY: u64 = 16;

/// Aborts its task when dropped.
struct AbortOnDrop(tokio::task::JoinHandle<()>);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

fn random_secret() -> SecretKey {
    loop {
        let mut bytes = [0u8; 32];
        getrandom::fill(&mut bytes).expect("operating system randomness");
        if let Ok(key) = SecretKey::from_slice(&bytes) {
            return key;
        }
    }
}

/// The Mac's publisher (its own device, token and identity key, unshaped to the Worker) and the phone's key.
struct Cache {
    publisher: Arc<RelayPublisher>,
    viewers: Arc<Vec<Viewer>>,
    phone_key: SecretKey,
    source_key: p256::PublicKey,
    /// The Worker's address, behind the phone's shaper.
    worker: SocketAddr,
    mac_id: String,
    phone_id: String,
    phone_token: String,
}

impl Cache {
    fn new(base: &Base) -> Self {
        let mac = RelayCache::new(
            ApiClient::new(&base.url, &base.mac_token),
            &base.mac_id,
            RelayCacheConfig { enabled: true },
        );
        let epoch = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(1);
        let publisher = RelayPublisher::new(
            mac,
            SigningKey::from(random_secret()),
            epoch,
            RelayPublishConfig { enabled: true },
        );
        let phone_key = random_secret();
        let viewers = vec![Viewer { device: base.phone_id.clone(), key: phone_key.public_key() }];
        let worker = base
            .url
            .trim_start_matches("http://")
            .trim_end_matches('/')
            .parse()
            .unwrap_or_else(|e| panic!("the Worker's address {}: {e}", base.url));
        Self {
            source_key: publisher.source_key(),
            publisher: Arc::new(publisher),
            viewers: Arc::new(viewers),
            phone_key,
            worker,
            mac_id: base.mac_id.clone(),
            phone_id: base.phone_id.clone(),
            phone_token: base.phone_token.clone(),
        }
    }

    /// The page's snapshot streams for `load`, each with its part of the page.
    fn parts(load: &str, page: usize) -> Vec<(String, Vec<u8>)> {
        (0..page.div_ceil(PART))
            .map(|i| (format!("{load}/page/{i}"), vec![b'p'; PART.min(page - i * PART)]))
            .collect()
    }

    /// The Mac publishes the page it would serve: each part's snapshot, then the first part's first screen.
    async fn publish_page(&self, load: &str, page: usize) -> Result<(), String> {
        let parts = Self::parts(load, page);
        for (stream, part) in &parts {
            let sent = self.publisher.publish_snapshot(&self.viewers, stream, part).await;
            if sent.sent != 1 {
                return Err(format!("publish {stream}: {}", sent.first_error.unwrap_or_default()));
            }
        }
        let (stream, part) = &parts[0];
        let screen = &part[..FIRST_SCREEN_BYTES.min(part.len())];
        let sent = self.publisher.publish_first_screen(&self.viewers, stream, screen).await;
        if sent.sent != 1 {
            return Err(format!("first screen {stream}: {}", sent.first_error.unwrap_or_default()));
        }
        Ok(())
    }

    /// The Mac's 2 Mbit/s stream as deltas on `<load>/bulk` until dropped; the counter is the bytes it published
    /// since the instant returned.
    async fn spawn_bulk(&self, load: &str) -> Result<(AbortOnDrop, Arc<AtomicU64>, Instant), String> {
        let stream = format!("{load}/bulk");
        let chunk = vec![b'b'; CHUNK];
        let sent = self.publisher.publish_snapshot(&self.viewers, &stream, &chunk).await;
        if sent.sent != 1 {
            return Err(format!("publish {stream}: {}", sent.first_error.unwrap_or_default()));
        }
        let bytes = Arc::new(AtomicU64::new(0));
        let (publisher, viewers, counted) = (self.publisher.clone(), self.viewers.clone(), bytes.clone());
        let task = tokio::spawn(async move {
            let mut tick = tokio::time::interval(BULK_EVERY);
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            let mut n = 0u64;
            loop {
                tick.tick().await;
                n += 1;
                if publisher.publish_delta(&viewers, &stream, &chunk).await.sent == 1 {
                    counted.fetch_add(CHUNK as u64, Ordering::Relaxed);
                }
                if n.is_multiple_of(BULK_SNAPSHOT_EVERY) {
                    publisher.publish_snapshot(&viewers, &stream, &chunk).await;
                }
            }
        });
        Ok((AbortOnDrop(task), bytes, Instant::now()))
    }

    /// The phone's client through its own `lte` shaper (seeded), so every request crosses the shaped link.
    async fn phone(&self, seed: u64) -> Result<(Shaper, RelayCache), String> {
        let profile = ProfileFile::builtin().get(PROFILE).cloned().ok_or("no lte profile in cmux-fault")?;
        let shaper = Shaper::start(self.worker, profile, seed, &Trace::new())
            .await
            .map_err(|e| format!("shaper: {e}"))?;
        let base = format!("http://{}", shaper.addr());
        let phone = RelayCache::new(
            ApiClient::new(&base, &self.phone_token),
            &self.phone_id,
            RelayCacheConfig { enabled: true },
        );
        Ok((shaper, phone))
    }

    /// The phone drains the Mac's stream on its own task through `phone` (the same shaped link) until dropped:
    /// it opens the stream's snapshot unless it holds `floor`, then catches up every 64 ms, jumping to the newest
    /// snapshot when the relay dropped the deltas it needed. The counter is the sealed bytes it read.
    fn spawn_drain(&self, phone: RelayCache, load: &str, mut floor: Floor) -> (AbortOnDrop, Arc<AtomicU64>) {
        let stream = format!("{load}/bulk");
        let bytes = Arc::new(AtomicU64::new(0));
        let counted = bytes.clone();
        let (mac, source, key) = (self.mac_id.clone(), self.source_key, self.phone_key.clone());
        let task = tokio::spawn(async move {
            loop {
                if floor.position().is_none() {
                    if let Ok(Some(open)) = phone.cold_open(&mac, &source, &key, &stream, &mut floor).await {
                        counted.fetch_add(open.bytes as u64, Ordering::Relaxed);
                    }
                } else {
                    let mut floors = [(stream.clone(), floor)];
                    if let Ok(resume) =
                        phone.resume_or_snapshot(&mac, &source, &key, &mut floors, MAX_BUDGET_BYTES).await
                    {
                        counted.fetch_add(resume.bytes as u64, Ordering::Relaxed);
                    }
                    floor = floors[0].1;
                }
                tokio::time::sleep(BULK_EVERY).await;
            }
        });
        (AbortOnDrop(task), bytes)
    }
}

fn kbit(bytes: &AtomicU64, over: Duration) -> f64 {
    let secs = over.as_secs_f64().max(0.001);
    (bytes.load(Ordering::Relaxed) as f64 * 8.0 / 1000.0 / secs).round()
}

/// Waits until the Mac, asleep since `asleep_at` for `d`, is awake again, so the next run starts as the others do.
async fn until_awake(asleep_at: Instant, d: Duration) {
    tokio::time::sleep_until((asleep_at + d).into()).await;
}

async fn cache_mac_asleep(
    cache: &Cache,
    mac: &Mac,
    load: &str,
    page: usize,
    duress: bool,
    wake: Duration,
    row: &Row<'_>,
) {
    let fail = |e: String| {
        row.emit("ttfc_ms", Err(e.clone()), serde_json::json!({}));
        row.emit("snapshot_ms", Err(e), serde_json::json!({}));
    };
    if let Err(e) = cache.publish_page(load, page).await {
        return fail(e);
    }
    let bulk = if duress {
        match cache.spawn_bulk(load).await {
            Ok(bulk) => Some(bulk),
            Err(e) => return fail(e),
        }
    } else {
        None
    };
    let (_shaper, phone) = match cache.phone(row.seed).await {
        Ok(phone) => phone,
        Err(e) => return fail(e),
    };
    let asleep_at = Instant::now();
    mac.fall_asleep(wake);
    let started = Instant::now();
    let drain = duress.then(|| cache.spawn_drain(phone.clone(), load, Floor::default()));
    let parts = Cache::parts(load, page);
    let (source, key) = (&cache.source_key, &cache.phone_key);
    let mut floor = Floor::default();
    let first = match phone.cold_open_first_screen(&cache.mac_id, source, key, &parts[0].0, &mut floor).await
    {
        Ok(Some(open)) if !open.opened.plaintext.is_empty() => Ok((ms(started.elapsed()), open.bytes)),
        Ok(_) => Err("the relay holds no first screen".to_string()),
        Err(e) => Err(format!("first screen: {e}")),
    };
    let whole = futures_util::future::join_all(parts.iter().map(|(stream, _)| {
        let phone = phone.clone();
        async move {
            let mut floor = Floor::default();
            match phone.cold_open(&cache.mac_id, source, key, stream, &mut floor).await {
                Ok(Some(open)) => Ok((open.opened.plaintext.len(), open.bytes)),
                Ok(None) => Err(format!("the relay holds no {stream}")),
                Err(e) => Err(format!("{stream}: {e}")),
            }
        }
    }))
    .await;
    let elapsed = started.elapsed();
    let whole: Result<Vec<(usize, usize)>, String> = whole.into_iter().collect();
    let whole = whole.and_then(|got| {
        let plain: usize = got.iter().map(|g| g.0).sum();
        if plain == page {
            Ok((ms(elapsed), got.iter().map(|g| g.1).sum::<usize>()))
        } else {
            Err(format!("{plain} of {page} bytes"))
        }
    });
    let mut extra = serde_json::json!({ "snapshots": parts.len() });
    if let (Some((_, published, since)), Some((_, drained))) = (&bulk, &drain) {
        extra["mac_stream_kbit"] = serde_json::json!(kbit(published, since.elapsed()));
        extra["phone_drain_kbit"] = serde_json::json!(kbit(drained, elapsed));
    }
    drop((drain, bulk));
    let first_bytes = first.as_ref().map(|f| f.1).unwrap_or(0);
    let mut first_extra = extra.clone();
    first_extra["first_screen_sealed_bytes"] = serde_json::json!(first_bytes);
    row.emit("ttfc_ms", first.map(|f| f.0), first_extra);
    let sealed = whole.as_ref().map(|w| w.1).unwrap_or(0);
    extra["sealed_bytes"] = serde_json::json!(sealed);
    row.emit("snapshot_ms", whole.map(|w| w.0), extra);
    until_awake(asleep_at, wake).await;
}

#[allow(clippy::too_many_arguments, reason = "one matrix cell's facts, each read once")]
async fn cache_mac_asleep_resume(
    cache: &Cache,
    mac: &Mac,
    load: &str,
    page: usize,
    duress: bool,
    wake: Duration,
    away: Duration,
    row: &Row<'_>,
) {
    let fail = |e: String| row.emit("resume_ms", Err(e), serde_json::json!({}));
    if let Err(e) = cache.publish_page(load, page).await {
        return fail(e);
    }
    let bulk = if duress {
        match cache.spawn_bulk(load).await {
            Ok(bulk) => Some(bulk),
            Err(e) => return fail(e),
        }
    } else {
        None
    };
    let (_shaper, phone) = match cache.phone(row.seed).await {
        Ok(phone) => phone,
        Err(e) => return fail(e),
    };
    let (source, key) = (&cache.source_key, &cache.phone_key);
    let parts = Cache::parts(load, page);
    let stream = parts[0].0.clone();
    // Before: the phone holds the page (and, under duress, the Mac's stream) at the positions it opened.
    let mut floor = Floor::default();
    match phone.cold_open(&cache.mac_id, source, key, &stream, &mut floor).await {
        Ok(Some(_)) => {}
        Ok(None) => return fail(format!("the relay holds no {stream}")),
        Err(e) => return fail(format!("{stream}: {e}")),
    }
    let mut bulk_floor = Floor::default();
    if duress {
        let bulk_stream = format!("{load}/bulk");
        if let Err(e) = phone.cold_open(&cache.mac_id, source, key, &bulk_stream, &mut bulk_floor).await {
            return fail(format!("{bulk_stream}: {e}"));
        }
    }
    // The Mac's fresh page as chunked deltas, then its newest snapshot, before it sleeps.
    let mut published = 0;
    while published < page {
        let n = CHUNK.min(page - published);
        let sent = cache.publisher.publish_delta(&cache.viewers, &stream, &vec![b'f'; n]).await;
        if sent.sent != 1 {
            return fail(format!("delta: {}", sent.first_error.unwrap_or_default()));
        }
        published += n;
    }
    cache.publisher.publish_snapshot(&cache.viewers, &stream, &parts[0].1).await;
    let asleep_at = Instant::now();
    mac.fall_asleep(away + wake);
    tokio::time::sleep(away).await;
    let started = Instant::now();
    let drain = duress.then(|| cache.spawn_drain(phone.clone(), load, bulk_floor));
    let mut floors = [(stream.clone(), floor)];
    let result = phone.resume_or_snapshot(&cache.mac_id, source, key, &mut floors, MAX_BUDGET_BYTES).await;
    let elapsed = started.elapsed();
    let mut extra =
        serde_json::json!({ "away_ms": away.as_millis() as u64, "budget_bytes": MAX_BUDGET_BYTES });
    let value = match result {
        Ok(resume) => {
            let applied: usize = resume.surfaces.iter().map(|s| s.applied.len()).sum();
            let fresh: usize =
                resume.surfaces.iter().flat_map(|s| &s.applied).map(|o| o.plaintext.len()).sum::<usize>()
                    + resume.snapshots.iter().map(|o| o.plaintext.len()).sum::<usize>();
            extra["deltas_applied"] = serde_json::json!(applied);
            extra["from_snapshot"] = serde_json::json!(!resume.snapshots.is_empty());
            extra["cut"] = serde_json::json!(resume.cut);
            extra["sealed_bytes"] = serde_json::json!(resume.bytes);
            extra["fresh_bytes"] = serde_json::json!(fresh);
            if fresh > 0 { Ok(ms(elapsed)) } else { Err("no fresh bytes from the relay".to_string()) }
        }
        Err(e) => Err(format!("resume: {e}")),
    };
    if let (Some((_, published, since)), Some((_, drained))) = (&bulk, &drain) {
        extra["mac_stream_kbit"] = serde_json::json!(kbit(published, since.elapsed()));
        extra["phone_drain_kbit"] = serde_json::json!(kbit(drained, elapsed));
    }
    drop((drain, bulk));
    row.emit("resume_ms", value, extra);
    until_awake(asleep_at, away + wake).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "the pair matrix's Mac-asleep rows: run with --ignored --nocapture"]
async fn pair_matrix_mac_asleep() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_test_writer()
        .try_init();
    let n = env_u64("PAIRMATRIX_N", 5);
    let seed_base = env_u64("PAIRMATRIX_SEED_BASE", 1);
    let wake_ms = env_u64("PAIRMATRIX_MAC_WAKE_MS", 1500);
    let wake = Duration::from_millis(wake_ms);
    let away = Duration::from_secs(env_u64("PAIRMATRIX_SLEEP_S", 5));
    let conditions = env_list("PAIRMATRIX_CONDITIONS", "mac-asleep,mac-asleep-resume,mac-asleep-send");
    let loads = env_list("PAIRMATRIX_LOADS", "idle,duress");
    for path in env_list("PAIRMATRIX_PATHS", "direct,relay,relay-worker") {
        let mut _server = None;
        let mut _worker = None;
        let base = match path.as_str() {
            "direct" | "relay" => {
                let server = FakeSignaling::start(FakeOptions::default()).await;
                let base = Base {
                    url: server.base_url.clone(),
                    team: "team".into(),
                    mac_id: uuid::Uuid::new_v4().to_string(),
                    mac_token: "user:alice".into(),
                    phone_id: uuid::Uuid::new_v4().to_string(),
                    phone_token: "user:alice".into(),
                    relay: path == "relay",
                };
                _server = Some(server);
                base
            }
            "relay-worker" | "relay-cache" => {
                match tokio::task::spawn_blocking({
                    let cache = path == "relay-cache";
                    move || start_worker(cache)
                })
                .await
                .unwrap()
                {
                    Ok((worker, base)) => {
                        _worker = Some(worker);
                        base
                    }
                    Err(e) => {
                        println!(
                            "PAIRCELL-NA {}",
                            serde_json::json!({ "pair": "ios-mac", "path": path, "reason": e })
                        );
                        continue;
                    }
                }
            }
            other => panic!("unknown path {other}"),
        };
        let mac = tokio::task::spawn_blocking({
            let base = base.clone();
            move || spawn_mac(base)
        })
        .await
        .unwrap();
        let phone = SignalingClient::connect(&base.url, &base.phone_token, &base.team, &base.phone_id)
            .await
            .expect("phone signs in");
        let cache = (path == "relay-cache").then(|| Cache::new(&base));
        for condition in &conditions {
            for load in &loads {
                let duress = load == "duress";
                let page = if duress { DURESS_PAGE } else { IDLE_PAGE };
                for run in 0..n {
                    let seed = seed_base + run;
                    set_link_profile(Some(LinkProfile::named(PROFILE)), seed);
                    let row = Row { path: &path, condition, load, run, seed, wake_ms };
                    if let Some(cache) = &cache {
                        match condition.as_str() {
                            "mac-asleep" => {
                                cache_mac_asleep(cache, &mac, load, page, duress, wake, &row).await;
                            }
                            "mac-asleep-resume" => {
                                cache_mac_asleep_resume(cache, &mac, load, page, duress, wake, away, &row)
                                    .await;
                            }
                            "mac-asleep-send" => {
                                if run == 0 {
                                    println!(
                                        "PAIRCELL-NA {}",
                                        serde_json::json!({
                                            "pair": "ios-mac", "path": path, "condition": condition, "load": load,
                                            "profile": PROFILE, "reason": SEND_NA,
                                        })
                                    );
                                }
                            }
                            other => panic!("unknown condition {other}"),
                        }
                        continue;
                    }
                    match condition.as_str() {
                        "mac-asleep" => mac_asleep(&base, &mac, &phone, page, duress, wake, &row).await,
                        "mac-asleep-resume" => {
                            mac_asleep_resume(&base, &mac, &phone, page, duress, wake, away, &row).await;
                        }
                        "mac-asleep-send" => {
                            mac_asleep_send(&base, &mac, &phone, page, duress, wake, &row).await;
                        }
                        other => panic!("unknown condition {other}"),
                    }
                }
            }
        }
        set_link_profile(None, 0);
        phone.close();
    }
}
