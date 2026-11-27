//! The phone node's Linux proof, on a throwaway headscale (testing/phone-node-e2e.sh). The same
//! Rust path the app links (`TsnetNode`, `connect`, the route rules), built for Linux.
//!
//! `phone_probe echo --state DIR --hostname mac --control-url URL --authkey-file F --port P`
//!     A tailnet node (the stand-in for the Mac's carrier listener) that echoes on tailnet port P.
//! `phone_probe relay ADDR`
//!     A plain TCP echo: the stand-in for the existing relay path.
//! `phone_probe probe --state DIR --control-url URL --authkey-file F --peer HOST --port P
//!     --dead-port Q --relay ADDR [--rounds N]`
//!     Joins as the phone, then prints one JSON row per check: join time, time until the peer's
//!     path is direct, the link and its RTT with the carrier on, the fallback when the tailnet dial
//!     fails, the relay with the carrier off, and Forget.

use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use cmux_mobile_tailnet::Mode;
use cmux_mobile_tailnet::connect::{PhoneNode, RelayDial, Stream, TAILNET_DIAL_TIMEOUT, connect};
use cmux_mobile_tailnet::key::PhoneTailnet;
use cmux_mobile_tailnet::route::RouteTracker;
use cmux_mobile_tailnet::tsnet::TsnetNode;
use cmux_tailnet_join::{Secret, embedded_options};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

fn fail(why: &str) -> ! {
    eprintln!("phone_probe: {why}");
    std::process::exit(2)
}

#[derive(Default)]
struct Args {
    state: Option<PathBuf>,
    hostname: Option<String>,
    control_url: Option<String>,
    key: Option<Secret>,
    peer: Option<String>,
    port: u16,
    dead_port: u16,
    relay: Option<String>,
    rounds: usize,
}

fn parse(mut it: impl Iterator<Item = String>) -> Args {
    let mut a = Args { rounds: 50, ..Args::default() };
    while let Some(flag) = it.next() {
        let value = it.next().unwrap_or_else(|| fail(&format!("{flag} needs a value")));
        match flag.as_str() {
            "--state" => a.state = Some(value.into()),
            "--hostname" => a.hostname = Some(value),
            "--control-url" => a.control_url = Some(value),
            "--authkey-file" => {
                let text = std::fs::read_to_string(&value).unwrap_or_else(|e| fail(&format!("authkey: {e}")));
                a.key = Some(Secret::new(text.trim()));
            }
            "--peer" => a.peer = Some(value),
            "--port" => a.port = value.parse().unwrap_or_else(|_| fail("--port")),
            "--dead-port" => a.dead_port = value.parse().unwrap_or_else(|_| fail("--dead-port")),
            "--relay" => a.relay = Some(value),
            "--rounds" => a.rounds = value.parse().unwrap_or_else(|_| fail("--rounds")),
            _ => fail(&format!("unknown flag {flag}")),
        }
    }
    a
}

fn join(a: &Args, hostname: &str) -> (TsnetNode, Duration) {
    // A throwaway headscale on a private docker network: plain http chosen for this server only.
    let tailnet = PhoneTailnet {
        control_url: a.control_url.clone(),
        hostname: Some(hostname.to_owned()),
        ephemeral: true,
        allow_http: a.control_url.as_deref().is_some_and(|u| u.starts_with("http://")),
    };
    let key = a.key.clone().unwrap_or_else(|| fail("--authkey-file"));
    let checked = tailnet.request(key).unwrap_or_else(|e| fail(&e.0));
    let state = a.state.clone().unwrap_or_else(|| fail("--state"));
    let started = Instant::now();
    let node = TsnetNode::join(&embedded_options(&checked), &state, hostname, Duration::from_secs(60))
        .unwrap_or_else(|e| fail(&format!("join: {e}")));
    (node, started.elapsed())
}

fn row(value: serde_json::Value) {
    println!("{value}");
}

fn echo(a: Args) {
    let hostname = a.hostname.clone().unwrap_or_else(|| "mac".into());
    let (node, took) = join(&a, &hostname);
    let listener = node.listener(a.port).unwrap_or_else(|e| fail(&e));
    row(serde_json::json!({"event": "echo-up", "joinMs": took.as_millis(), "port": a.port}));
    loop {
        let Ok((mut stream, _peer)) = listener.accept() else { continue };
        std::thread::spawn(move || {
            let mut buf = [0u8; 4096];
            while let Ok(n) = stream.read(&mut buf) {
                if n == 0 || stream.write_all(&buf[..n]).is_err() {
                    break;
                }
            }
        });
    }
}

fn relay(addr: &str) {
    let listener = TcpListener::bind(addr).unwrap_or_else(|e| fail(&format!("relay bind: {e}")));
    row(serde_json::json!({"event": "relay-up", "addr": addr}));
    for stream in listener.incoming().flatten() {
        std::thread::spawn(move || {
            let mut stream = stream;
            let mut buf = [0u8; 4096];
            while let Ok(n) = stream.read(&mut buf) {
                if n == 0 || stream.write_all(&buf[..n]).is_err() {
                    break;
                }
            }
        });
    }
}

struct TcpRelay(String);

impl RelayDial for TcpRelay {
    async fn dial(&self) -> Result<Stream, String> {
        let stream = tokio::net::TcpStream::connect(&self.0).await.map_err(|e| e.to_string())?;
        stream.set_nodelay(true).map_err(|e| e.to_string())?;
        Ok(Box::new(stream))
    }
}

/// `rounds` 64-byte ping-pongs; returns (p50, p95, max) in ms.
async fn rtt(stream: &mut Stream, rounds: usize) -> Result<(f64, f64, f64), String> {
    let ping = [7u8; 64];
    let mut pong = [0u8; 64];
    let mut ms = Vec::with_capacity(rounds);
    for _ in 0..rounds {
        let t = Instant::now();
        stream.write_all(&ping).await.map_err(|e| e.to_string())?;
        stream.read_exact(&mut pong).await.map_err(|e| e.to_string())?;
        ms.push(t.elapsed().as_secs_f64() * 1000.0);
    }
    ms.sort_by(f64::total_cmp);
    let at = |p: f64| ms[((ms.len() - 1) as f64 * p) as usize];
    Ok((at(0.5), at(0.95), *ms.last().unwrap_or(&0.0)))
}

async fn link(check: &str, mode: Mode, node: &TsnetNode, a: &Args, port: u16, tracker: &mut RouteTracker) {
    let peer = a.peer.as_deref().unwrap_or_else(|| fail("--peer"));
    let relay = TcpRelay(a.relay.clone().unwrap_or_else(|| fail("--relay")));
    match connect(mode, Some(node), peer, port, &relay, tracker, TAILNET_DIAL_TIMEOUT).await {
        Ok(mut c) => {
            let stats = rtt(&mut c.stream, a.rounds).await;
            row(serde_json::json!({
                "check": check,
                "mode": mode.as_setting(),
                "route": c.route,
                "change": c.change.map(|ch| ch.to_string()),
                "dialMs": (c.took.as_secs_f64() * 1000.0 * 100.0).round() / 100.0,
                "rttMs": stats.as_ref().map(|(p50, p95, max)| serde_json::json!({"p50": p50, "p95": p95, "max": max})).ok(),
                "error": stats.err(),
            }));
        }
        Err(e) => row(serde_json::json!({"check": check, "mode": mode.as_setting(), "error": e})),
    }
}

async fn probe(a: Args) {
    let (node, join_took) = join(&a, "iphone");
    row(serde_json::json!({"check": "join", "joinMs": join_took.as_millis(), "state": node.state()}));
    let peer = a.peer.clone().unwrap_or_else(|| fail("--peer"));
    let started = Instant::now();
    let mut seen = None;
    while started.elapsed() < Duration::from_secs(30) {
        seen = node.peer(&peer);
        if seen.as_ref().is_some_and(|p| p.online && p.direct) {
            break;
        }
        // The first packet makes the path go direct (disco); a failed dial is fine here.
        if let Some(p) = &seen {
            let _ = node.dial(&p.addr, a.port).await;
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    row(serde_json::json!({"check": "peer-path", "peer": seen, "afterMs": started.elapsed().as_millis()}));

    let mut tracker = RouteTracker::default();
    link("carrier-on", Mode::On, &node, &a, a.port, &mut tracker).await;
    link("carrier-direct-only", Mode::DirectOnly, &node, &a, a.port, &mut tracker).await;
    link("tailnet-dial-fails", Mode::On, &node, &a, a.dead_port, &mut tracker).await;
    link("carrier-off", Mode::Off, &node, &a, a.port, &mut tracker).await;
    link("carrier-on-again", Mode::On, &node, &a, a.port, &mut tracker).await;

    let leave =
        tokio::task::spawn_blocking(move || node.leave()).await.unwrap_or_else(|e| Err(e.to_string()));
    row(serde_json::json!({"check": "forget", "ok": leave.is_ok(), "error": leave.err()}));
}

fn main() {
    let mut args = std::env::args().skip(1);
    let cmd = args.next().unwrap_or_default();
    match cmd.as_str() {
        "echo" => echo(parse(args)),
        "relay" => relay(&args.next().unwrap_or_else(|| fail("relay ADDR"))),
        "probe" => {
            let rt = tokio::runtime::Runtime::new().unwrap_or_else(|e| fail(&e.to_string()));
            rt.block_on(probe(parse(args)));
        }
        _ => fail("usage: phone_probe echo|relay|probe ..."),
    }
}
