//! cmux-mobile-applike: a phone that dials like the app and does what the app does on
//! the `daemon` channel, against a real cmux-tui daemon behind a Mac's cmux-mobile-host.
//! The oracle of the phone-link gates (plink-bisect's `mobile-pair-e2e`, the version skew
//! matrix `scripts/ci/mobile-pair-skew.sh`), so it must build at older phone commits too:
//! the skew gate copies this file and `skew_impair.rs` into such a tree. Keep to API both
//! had (2026-11-20 on): `ApiClient`, `SignalingClient`, `dial::connect`, `DialOptions`.
//!
//! Steps, each bounded, one JSON line each, `{"result":"PASS"}` or `{"result":"FAIL","at"}`
//! last (exit 1 on FAIL):
//!   link             dial the Mac
//!   <setup batch>    set-client-info, identify, subscribe, list-agents, list-workspaces,
//!                    list-personal in one go (WorkspaceSync.prepare)
//!   new-workspace    a terminal to drive
//!   attach-surface, resize-surface, send, output   on a second daemon channel
//!   hold             (CMUX_SKEW_HOLD_S > 0) the link kept that long under steady
//!                    traffic, a typed line every 500 ms whose output must come back
//!                    within 3 s: FAIL on any miss, a dead link, or more than one path
//!                    switch (Leo's NIGHTLY: WireGuard dying every 2-43 s, paths
//!                    flapping Direct<->Turn every 2-5 s, while connect looked fine)
//!   stall            (CMUX_SKEW_STALL_MS > 0) every datagram to the phone dropped that
//!                    long, then the terminal must answer again: on the same link, or
//!                    after one redial and re-attach, as the app reconnects
//!
//!   others           (CMUX_SKEW_OTHER_MACS=mac2,mac3) Macs paired but unreachable,
//!                    dialed meanwhile as the app keeps trying them: one dial in flight
//!                    per Mac, backoff 1 s doubling to 30 s with +-25% jitter; their dial
//!                    counts are reported and bounded, and the hold above must not suffer
//!
//!   cmux-mobile-applike BASE_URL TOKEN_FILE TEAM MAC [CARRIER]
//! CARRIER: `webrtc` (default) or `wireguard`, plus `+relay-only` (TURN only) or
//! `+block-udp` (no UDP: the WSS relay). Env: `CMUX_APPLIKE_DEVICE` (a fixed phone
//! device id, so a second run is the same paired phone; default a fresh one),
//! `CMUX_SKEW_IMPAIR` (see `skew_impair.rs`), `CMUX_SKEW_HOLD_S`, `CMUX_SKEW_STALL_MS`,
//! `CMUX_SKEW_OTHER_MACS`, `CMUX_SKEW_MAX_SWITCHES` (1), `CMUX_SKEW_MAX_RTT_MS` (3000).

#[path = "../skew_impair.rs"]
mod skew_impair;

use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use base64::Engine;
use bytes::Bytes;
use cmux_mobile_link::api::ApiClient;
use cmux_mobile_link::{ChannelEvent, DialOptions, LinkConfig, SignalingClient, TransportKind};
use serde_json::{Value, json};

struct Chan {
    ch: cmux_mobile_link::Channel,
    buf: Vec<u8>,
    events: Vec<Value>,
    next: u64,
}

impl Chan {
    async fn line(&mut self, deadline: Instant) -> Result<Value> {
        loop {
            if let Some(n) = self.buf.iter().position(|&b| b == b'\n') {
                let line: Vec<u8> = self.buf.drain(..=n).collect();
                if let Ok(value) = serde_json::from_slice::<Value>(&line) {
                    return Ok(value);
                }
                continue;
            }
            let left = deadline.saturating_duration_since(Instant::now());
            match tokio::time::timeout(left, self.ch.recv()).await.context("timed out")? {
                Some(ChannelEvent::Data(bytes)) => self.buf.extend_from_slice(&bytes),
                other => bail!("channel ended: {other:?}"),
            }
        }
    }

    async fn send_req(&mut self, cmd: &str, mut params: Value) -> Result<String> {
        self.next += 1;
        let id = format!("p{}", self.next);
        if !params.is_object() {
            params = json!({});
        }
        params["id"] = json!(id);
        params["cmd"] = json!(cmd);
        let mut line = serde_json::to_vec(&params)?;
        line.push(b'\n');
        self.ch.send(Bytes::from(line)).await?;
        Ok(id)
    }

    async fn wait(&mut self, id: &str, secs: u64) -> Result<Value> {
        let deadline = Instant::now() + Duration::from_secs(secs);
        loop {
            let value = self.line(deadline).await?;
            if value.get("id").and_then(Value::as_str) == Some(id) {
                return Ok(value);
            }
            self.events.push(value);
        }
    }

    /// Until the surface's output stream carries `marker`.
    async fn output(&mut self, marker: &str, secs: u64) -> Result<()> {
        let deadline = Instant::now() + Duration::from_secs(secs);
        let mut seen = String::new();
        let mut events: Vec<Value> = std::mem::take(&mut self.events);
        loop {
            for value in events.drain(..) {
                if let Some(data) = value.get("data").and_then(Value::as_str)
                    && value.get("surface").is_some()
                    && let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(data)
                {
                    seen.push_str(&String::from_utf8_lossy(&bytes));
                }
            }
            if seen.contains(marker) {
                return Ok(());
            }
            if Instant::now() > deadline {
                let tail: String =
                    seen.chars().rev().take(200).collect::<Vec<_>>().into_iter().rev().collect();
                bail!("no {marker:?} in output; tail {tail:?}");
            }
            events.push(self.line(deadline).await?);
        }
    }
}

fn step(name: &str, value: &Value) {
    println!("{}", json!({"step": name, "reply": value}));
}

fn fail(at: impl std::fmt::Display) -> ! {
    println!("{}", json!({"result": "FAIL", "at": at.to_string()}));
    std::process::exit(1);
}

/// A command line whose output (`<tag>ink`) is not its own echo.
fn typed(tag: &str) -> String {
    base64::engine::general_purpose::STANDARD.encode(format!("printf '{tag}%s\\n' ink\r"))
}

struct Dialer {
    signaling: SignalingClient,
    mac: String,
    transport: TransportKind,
    options: DialOptions,
}

impl Dialer {
    async fn dial(
        &self,
    ) -> Result<(cmux_mobile_link::Link, tokio::sync::watch::Receiver<cmux_mobile_link::LinkPath>)> {
        self.dial_mac(&self.mac).await
    }

    async fn dial_mac(
        &self,
        mac: &str,
    ) -> Result<(cmux_mobile_link::Link, tokio::sync::watch::Receiver<cmux_mobile_link::LinkPath>)> {
        let conn = cmux_mobile_link::dial::connect(
            &self.signaling,
            mac,
            self.transport,
            &self.options,
            LinkConfig::default(),
        )
        .await
        .context("dial")?;
        Ok((conn.link.clone(), conn.path.clone()))
    }
}

async fn attach(link: &cmux_mobile_link::Link, surface: u64, next: u64) -> Result<Chan> {
    let mut chan = Chan {
        ch: link.open("daemon", json!({})).await.context("open daemon")?,
        buf: vec![],
        events: vec![],
        next,
    };
    let id = chan.send_req("attach-surface", json!({"surface": surface})).await?;
    let reply = chan.wait(&id, 20).await?;
    if reply.get("ok") == Some(&json!(false)) {
        bail!("attach-surface refused: {reply}");
    }
    Ok(chan)
}

#[tokio::main]
async fn main() -> Result<()> {
    cmux_mobile_link::install_crypto_provider();
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 5 {
        bail!("usage: cmux-mobile-applike BASE_URL TOKEN_FILE TEAM MAC [CARRIER]");
    }
    let (base, token_file, team, mac) = (&args[1], &args[2], &args[3], &args[4]);
    let carrier = args.get(5).map(String::as_str).unwrap_or("webrtc");
    let mut parts = carrier.split('+');
    let transport = match parts.next() {
        Some("wireguard") => TransportKind::WireGuard,
        _ => TransportKind::WebRtc,
    };
    let flags: Vec<&str> = parts.collect();
    let token = std::fs::read_to_string(token_file)?.trim().to_owned();
    let api = ApiClient::new(base, &token);
    let ice = api.ice().await.map(|c| c.ice_servers).unwrap_or_default();
    let device = std::env::var("CMUX_APPLIKE_DEVICE").unwrap_or_else(|_| uuid::Uuid::new_v4().to_string());
    api.register_device(&cmux_mobile_link::api::DeviceRegistration {
        device_id: device.clone(),
        kind: "phone".into(),
        name: "plink-applike".into(),
        team_id: team.clone(),
        wg_public_key: None,
        machine_id: None,
        sibling_device_ids: Vec::new(),
    })
    .await
    .context("register")?;
    let signaling = SignalingClient::connect(base, &token, team, &device).await?;
    let impaired = std::env::var_os("CMUX_SKEW_IMPAIR").is_some();
    let hops = impaired && skew_impair::impair().flip_s > 0;
    let options = DialOptions {
        ice_servers: ice,
        relay_only: flags.contains(&"relay-only"),
        block_udp: flags.contains(&"block-udp"),
        // The gate rewrites `impair3` to `impair2` for a tree whose hook takes two arguments.
        impair_inbound: if impaired { Some(skew_impair::impair3) } else { None },
        // The hop moves the tunnel between the Mac's loopback and its other addresses.
        include_loopback: hops,
        drop_udp_to: if hops { Some(skew_impair::drop_out) } else { None },
        ..DialOptions::default()
    };
    let others: Vec<String> = std::env::var("CMUX_SKEW_OTHER_MACS")
        .unwrap_or_default()
        .split(',')
        .filter(|m| !m.is_empty())
        .map(str::to_owned)
        .collect();
    let dialer = std::sync::Arc::new(Dialer { signaling, mac: mac.clone(), transport, options });
    let other_dials: Vec<std::sync::Arc<std::sync::atomic::AtomicU64>> =
        others.iter().map(|_| std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0))).collect();
    for (other, count) in others.iter().zip(&other_dials) {
        // A Mac the phone has paired but cannot reach: dialed as the app keeps trying it.
        let (dialer, other, count) =
            (std::sync::Arc::clone(&dialer), other.clone(), std::sync::Arc::clone(count));
        tokio::spawn(async move {
            let mut backoff = Duration::from_secs(1);
            let mut seed = other.bytes().fold(7u64, |h, b| h.wrapping_mul(31).wrapping_add(b as u64));
            loop {
                count.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                if let Ok(Ok((link, _))) =
                    tokio::time::timeout(Duration::from_secs(20), dialer.dial_mac(&other)).await
                {
                    link.close("unexpected");
                }
                seed ^= seed << 13;
                seed ^= seed >> 7;
                seed ^= seed << 17;
                let spread = backoff.as_millis() as u64 / 2;
                let wait = backoff.as_millis() as u64 * 3 / 4 + if spread > 0 { seed % spread } else { 0 };
                tokio::time::sleep(Duration::from_millis(wait)).await;
                backoff = (backoff * 2).min(Duration::from_secs(30));
            }
        });
    }
    let started = Instant::now();
    let (link, path) = match dialer.dial().await {
        Ok(dialed) => dialed,
        Err(error) => fail(format!("link: {error:#}")),
    };
    let first_path = format!("{:?}", *path.borrow()).to_lowercase();
    println!(
        "{}",
        json!({"step": "link", "ms": started.elapsed().as_millis() as u64, "carrier": carrier, "device": device, "path": first_path})
    );
    let switches = std::sync::Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
    {
        let (switches, mut path) = (std::sync::Arc::clone(&switches), path.clone());
        tokio::spawn(async move {
            while path.changed().await.is_ok() {
                let now = format!("{:?}", *path.borrow()).to_lowercase();
                switches.lock().unwrap().push(now);
            }
        });
    }
    let mut control = Chan {
        ch: link.open("daemon", json!({})).await.context("open daemon")?,
        buf: vec![],
        events: vec![],
        next: 0,
    };
    // The app's setup batch, in order (WorkspaceSync.prepare).
    let batch = [
        (
            "set-client-info",
            json!({"name": "plink", "kind": "ios", "device_kind": "iphone", "device_name": "plink", "device_id": device,
                "capabilities": ["conversation-tabs-v1", "agent-session-tabs-v1", "page-tabs-v1"]}),
        ),
        ("identify", json!({})),
        ("subscribe", json!({"tree_events": "deltas"})),
        ("list-agents", json!({})),
        ("list-workspaces", json!({"known": {}})),
        ("list-personal", json!({})),
    ];
    let mut ids = vec![];
    for (cmd, params) in batch.iter() {
        ids.push((cmd.to_string(), control.send_req(cmd, params.clone()).await?));
    }
    let mut fatal = None;
    for (cmd, id) in ids {
        match control.wait(&id, 20).await {
            Ok(reply) => {
                let short = if reply.to_string().len() > 600 {
                    json!({"ok": reply.get("ok"), "len": reply.to_string().len(), "error": reply.get("error")})
                } else {
                    reply.clone()
                };
                step(&cmd, &short);
                // The app shows a workspace list without agents or personal items.
                if reply.get("ok") == Some(&json!(false))
                    && fatal.is_none()
                    && cmd != "list-personal"
                    && cmd != "list-agents"
                {
                    fatal = Some(format!("{cmd}: {reply}"));
                }
            }
            Err(error) => {
                step(&cmd, &json!({"error": error.to_string()}));
                fatal.get_or_insert(format!("{cmd}: {error}"));
            }
        }
    }
    if let Some(at) = fatal {
        fail(at);
    }
    let id = control.send_req("new-workspace", json!({"name": "plink", "cols": 80, "rows": 24})).await?;
    let reply = control.wait(&id, 20).await?;
    step("new-workspace", &reply);
    let Some(surface) = reply["data"]["surface"].as_u64() else {
        fail(format!("new-workspace: no surface: {reply}"))
    };
    let mut term = match attach(&link, surface, 100).await {
        Ok(chan) => chan,
        Err(error) => fail(format!("attach-surface: {error:#}")),
    };
    step("attach-surface", &json!({"ok": true}));
    let id = term.send_req("resize-surface", json!({"surface": surface, "cols": 60, "rows": 20})).await?;
    let reply = term.wait(&id, 20).await?;
    step("resize-surface", &json!({"ok": reply.get("ok"), "error": reply.get("error")}));
    if reply.get("ok") == Some(&json!(false)) {
        fail(format!("resize-surface: {reply}"));
    }
    let id = term.send_req("send", json!({"surface": surface, "bytes": typed("pl")})).await?;
    let reply = term.wait(&id, 20).await?;
    step("send", &json!({"ok": reply.get("ok"), "error": reply.get("error")}));
    if reply.get("ok") == Some(&json!(false)) {
        fail(format!("send: {reply}"));
    }
    if let Err(error) = term.output("plink", 20).await {
        fail(format!("output: {error:#}"));
    }
    println!("{}", json!({"step": "output", "ok": true}));

    let hold = std::env::var("CMUX_SKEW_HOLD_S").ok().and_then(|v| v.parse::<u64>().ok()).unwrap_or(0);
    if hold > 0 {
        let started = Instant::now();
        let before = switches.lock().unwrap().len();
        let (mut sent, mut worst_ms, mut misses) = (0u64, 0u64, Vec::<String>::new());
        let (mut rtts, mut ping_fails) = (Vec::<u64>::new(), 0u64);
        while started.elapsed() < Duration::from_secs(hold) {
            let tick = Instant::now();
            match tokio::time::timeout(Duration::from_secs(3), link.ping()).await {
                Ok(Ok(rtt)) => rtts.push(rtt.as_millis() as u64),
                _ => ping_fails += 1,
            }
            sent += 1;
            let tag = format!("h{sent}x");
            let echoed = async {
                let id = term.send_req("send", json!({"surface": surface, "bytes": typed(&tag)})).await?;
                term.wait(&id, 3).await?;
                term.output(&format!("{tag}ink"), 3).await
            };
            match echoed.await {
                Ok(()) => worst_ms = worst_ms.max(tick.elapsed().as_millis() as u64),
                Err(error) => {
                    misses.push(format!("{}ms: {error:#}", started.elapsed().as_millis()));
                    if error.to_string().contains("channel ended") || misses.len() >= 3 {
                        break;
                    }
                }
            }
            tokio::time::sleep(Duration::from_millis(500).saturating_sub(tick.elapsed())).await;
        }
        let switched: Vec<String> = switches.lock().unwrap()[before..].to_vec();
        let envn = |key: &str, default: u64| {
            std::env::var(key).ok().and_then(|v| v.parse::<u64>().ok()).unwrap_or(default)
        };
        rtts.sort_unstable();
        let rtt_max = rtts.last().copied().unwrap_or(0);
        let dials: Vec<u64> =
            other_dials.iter().map(|c| c.load(std::sync::atomic::Ordering::Relaxed)).collect();
        // Backoff from 1 s to 30 s: at most ~6 dials in the first minute, then 2 a minute.
        let dial_bound = 8 + 3 * hold / 60;
        let (datagrams, dropped) = skew_impair::counts();
        let ok = misses.is_empty()
            && ping_fails == 0
            && rtt_max <= envn("CMUX_SKEW_MAX_RTT_MS", 3000)
            && switched.len() as u64 <= envn("CMUX_SKEW_MAX_SWITCHES", 1)
            && !link.is_closed()
            && dials.iter().all(|d| *d <= dial_bound);
        let report = json!({"step": "hold", "ok": ok, "hold_s": hold, "held_ms": started.elapsed().as_millis() as u64,
            "echoes": sent, "worst_echo_ms": worst_ms, "misses": misses, "path_switches": switched,
            "pings_failed": ping_fails, "rtt_p50_ms": rtts.get(rtts.len() / 2), "rtt_max_ms": rtt_max,
            "other_macs": others, "other_dials": dials, "other_dial_bound": dial_bound,
            "wg_in": datagrams, "wg_in_dropped": dropped});
        println!("{report}");
        if !ok {
            fail(format!("hold: {report}"));
        }
    }

    let stall = std::env::var("CMUX_SKEW_STALL_MS").ok().and_then(|v| v.parse::<u64>().ok()).unwrap_or(0);
    if stall > 0 {
        if !impaired {
            fail("stall: needs CMUX_SKEW_IMPAIR (the hook that drops datagrams), say `delay_ms=0`");
        }
        let started = Instant::now();
        skew_impair::blackout(Duration::from_millis(stall));
        tokio::time::sleep(Duration::from_millis(stall)).await;
        // The same link first: WireGuard rides out a gap shorter than its handshake.
        let same = async {
            let id = term.send_req("send", json!({"surface": surface, "bytes": typed("st")})).await?;
            term.wait(&id, 20).await?;
            term.output("stink", 25).await
        };
        let how = match same.await {
            Ok(()) => "same-link",
            Err(first) => {
                // As the app does: dial again and re-attach.
                eprintln!("stall: same link failed ({first:#}); redialing");
                let (link, _) = match dialer.dial().await {
                    Ok(dialed) => dialed,
                    Err(error) => fail(format!("stall: redial after {first:#}: {error:#}")),
                };
                let mut again = match attach(&link, surface, 200).await {
                    Ok(chan) => chan,
                    Err(error) => fail(format!("stall: re-attach: {error:#}")),
                };
                let id = again.send_req("send", json!({"surface": surface, "bytes": typed("rd")})).await?;
                again.wait(&id, 20).await?;
                if let Err(error) = again.output("rdink", 25).await {
                    fail(format!("stall: output after redial: {error:#}"));
                }
                link.close("done");
                "redial"
            }
        };
        println!(
            "{}",
            json!({"step": "stall", "ok": true, "stall_ms": stall, "how": how, "ms": started.elapsed().as_millis() as u64})
        );
    }
    println!("{}", json!({"result": "PASS"}));
    link.close("done");
    Ok(())
}
