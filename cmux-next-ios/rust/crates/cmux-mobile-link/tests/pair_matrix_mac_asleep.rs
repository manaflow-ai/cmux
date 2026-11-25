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
//! `backend/scripts/pair-matrix-worker.mjs`; needs `npm ci` in backend; `LINK_RELAY_CACHE=on` passes through).
//! Loads (`PAIRMATRIX_LOADS`): `idle` (a 64 KB page), `duress` (a 512 KB page beside a 2 Mbit/s stream from
//! the Mac). `PAIRMATRIX_N` runs per cell (5), `PAIRMATRIX_SEED_BASE` (1), `PAIRMATRIX_MAC_WAKE_MS` (1500).
//!
//! One `PAIRCELL {json}` line per run and metric, as `pair_matrix_ios_mac.rs` prints them:
//!
//! cargo test --release -p cmux-mobile-link --features testing --test pair_matrix_mac_asleep -- --ignored --nocapture --test-threads 1

use std::io::BufRead;
use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_mobile_link::dial::relay::RelayEndpoint;
use cmux_mobile_link::dial::{self, Connected, SessionEvents};
use cmux_mobile_link::testing::{
    FakeOptions, FakeSignaling, LinkProfile, set_link_profile, shape_by_profile,
};
use cmux_mobile_link::{Channel, ChannelEvent, DialOptions, LinkConfig, SignalingClient, TransportKind};

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

fn start_worker() -> Result<(Worker, Base), String> {
    let script = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../backend/scripts/pair-matrix-worker.mjs");
    let mut child = std::process::Command::new("node")
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
            "relay-worker" => match tokio::task::spawn_blocking(start_worker).await.unwrap() {
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
            },
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
        for condition in &conditions {
            for load in &loads {
                let duress = load == "duress";
                let page = if duress { DURESS_PAGE } else { IDLE_PAGE };
                for run in 0..n {
                    let seed = seed_base + run;
                    set_link_profile(Some(LinkProfile::named(PROFILE)), seed);
                    let row = Row { path: &path, condition, load, run, seed, wake_ms };
                    match condition.as_str() {
                        "mac-asleep" => mac_asleep(&base, &mac, &phone, page, duress, wake, &row).await,
                        "mac-asleep-resume" => {
                            mac_asleep_resume(&base, &mac, &phone, page, duress, wake, away, &row).await
                        }
                        "mac-asleep-send" => {
                            mac_asleep_send(&base, &mac, &phone, page, duress, wake, &row).await
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
