//! cmux-mobile-netprobe: echo through a Wi-Fi to cell handoff (netlab `wificell.sh`).
//!
//!   cmux-mobile-netprobe --base-url URL --token-file PATH --team TEAM --mac MAC_DEVICE_ID
//!            [--seconds 20] [--interval-ms 20] [--exclude-cgnat] [--no-turn]
//!            [--watch-ifaces] [--no-roam-call]
//!
//! Dials a Mac running cmux-mobile-host over WireGuard, opens its `echo` service and sends one
//! 16-byte frame every `--interval-ms` for `--seconds`, whether or not the earlier ones came back.
//! Prints JSON lines: `ready` (wall clock of the dial), one `probe` per answered frame (`sent`
//! and `recv` as epoch seconds, `rtt_ms`), `iface` and `roam` events from `--watch-ifaces`, and a
//! last `summary` (frames sent, answered). It records; wificell.sh turns the lines into
//! percentiles, the longest stall and `recovered`.
//!
//! `--watch-ifaces` is what the iOS app's path monitor does, on Linux: every 100 ms it reads
//! /sys/class/net, and when the set of up interfaces changes it calls
//! `wireguard::set_interfaces` (only in a tree that has it) and `wireguard::network_changed()`
//! (the roam; `--no-roam-call` leaves it out when set_interfaces is present). An interface counts
//! as Wi-Fi when its name starts with `wifi`, `wlan` or `en`, as cellular for `cell`, `wwan`,
//! `rmnet` and `pdp_ip`; others are ignored. It is up when IFF_UP is set and the kernel
//! reports a carrier.

use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, bail};
use bytes::Bytes;
use cmux_mobile_link::api::ApiClient;
use cmux_mobile_link::{ChannelEvent, DialOptions, LinkConfig, SignalingClient, TransportKind};
use serde_json::json;

struct Args {
    base_url: String,
    token: String,
    team: String,
    mac: String,
    seconds: f64,
    interval_ms: u64,
    exclude_cgnat: bool,
    no_turn: bool,
    watch_ifaces: bool,
    no_roam_call: bool,
}

fn parse() -> Result<Args> {
    let mut args = std::env::args().skip(1);
    let (mut base_url, mut token_file, mut team, mut mac) = (None, None, None, None);
    let (mut seconds, mut interval_ms) = (20.0, 20);
    let (mut exclude_cgnat, mut no_turn, mut watch_ifaces, mut no_roam_call) = (false, false, false, false);
    while let Some(arg) = args.next() {
        let mut value = || args.next().with_context(|| format!("{arg} needs a value"));
        match arg.as_str() {
            "--base-url" => base_url = Some(value()?),
            "--token-file" => token_file = Some(value()?),
            "--team" => team = Some(value()?),
            "--mac" => mac = Some(value()?),
            "--seconds" => seconds = value()?.parse()?,
            "--interval-ms" => interval_ms = value()?.parse()?,
            "--exclude-cgnat" => exclude_cgnat = true,
            "--no-turn" => no_turn = true,
            "--watch-ifaces" => watch_ifaces = true,
            "--no-roam-call" => no_roam_call = true,
            other => bail!("unknown argument {other}"),
        }
    }
    let token_file = token_file.context("--token-file is required")?;
    let token = std::fs::read_to_string(&token_file).with_context(|| format!("reading {token_file}"))?;
    Ok(Args {
        base_url: base_url.context("--base-url is required")?,
        token: token.trim().to_owned(),
        team: team.context("--team is required")?,
        mac: mac.context("--mac is required")?,
        seconds,
        interval_ms: interval_ms.max(1),
        exclude_cgnat,
        no_turn,
        watch_ifaces,
        no_roam_call,
    })
}

fn epoch() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or_default()
}

fn emit(value: serde_json::Value) {
    println!("{value}");
}

/// One interface this watcher cares about, as the kernel shows it now.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Iface {
    name: String,
    cellular: bool,
}

/// The interfaces that are up (IFF_UP and a carrier), sorted by name.
fn up_interfaces() -> Vec<Iface> {
    let mut found = Vec::new();
    let Ok(entries) = std::fs::read_dir("/sys/class/net") else { return found };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let cellular = ["cell", "wwan", "rmnet", "pdp_ip"].iter().any(|p| name.starts_with(p));
        let wifi = ["wifi", "wlan", "en"].iter().any(|p| name.starts_with(p));
        if !cellular && !wifi {
            continue;
        }
        let read = |file: &str| std::fs::read_to_string(entry.path().join(file)).ok();
        let flags = read("flags")
            .and_then(|text| u32::from_str_radix(text.trim().trim_start_matches("0x"), 16).ok())
            .unwrap_or(0);
        let carrier = read("carrier").is_some_and(|text| text.trim() == "1");
        if flags & 1 != 0 && carrier {
            found.push(Iface { name, cellular });
        }
    }
    found.sort_by(|a, b| a.name.cmp(&b.name));
    found
}

// MULTIPATH-BEGIN
fn to_net_interfaces(up: &[Iface]) -> Vec<cmux_mobile_link::dial::wireguard::NetInterface> {
    use cmux_mobile_link::dial::wireguard::{InterfaceKind, NetInterface};
    // As iOS: Wi-Fi is the primary while it is up, cell otherwise.
    let primary_is_wifi = up.iter().any(|i| !i.cellular);
    up.iter()
        .map(|i| NetInterface {
            name: i.name.clone(),
            kind: if i.cellular { InterfaceKind::Cellular } else { InterfaceKind::Wifi },
            expensive: i.cellular,
            constrained: false,
            primary: i.cellular != primary_is_wifi,
        })
        .collect()
}
// MULTIPATH-END

/// Poll the interface table every 100 ms; on a change, tell the link the way the app does.
async fn watch(no_roam_call: bool, t0: Instant) {
    let mut last = up_interfaces();
    #[allow(unused_variables)]
    let initial = last.clone();
    // MULTIPATH-BEGIN
    cmux_mobile_link::dial::wireguard::set_interfaces(to_net_interfaces(&initial));
    // MULTIPATH-END
    emit(
        json!({"ev": "iface", "t": epoch(), "up": last.iter().map(|i| i.name.clone()).collect::<Vec<_>>(), "initial": true}),
    );
    loop {
        tokio::time::sleep(Duration::from_millis(100)).await;
        let now = up_interfaces();
        if now == last {
            continue;
        }
        last = now.clone();
        let seen = epoch();
        emit(json!({"ev": "iface", "t": seen, "up": now.iter().map(|i| i.name.clone()).collect::<Vec<_>>()}));
        #[allow(unused_mut)]
        let mut roam = !no_roam_call;
        // MULTIPATH-BEGIN
        cmux_mobile_link::dial::wireguard::set_interfaces(to_net_interfaces(&now));
        emit(json!({"ev": "set_interfaces", "t": epoch()}));
        // MULTIPATH-END
        if roam {
            let started = Instant::now();
            let marks = cmux_mobile_link::dial::wireguard::network_changed().await;
            roam = marks.is_empty();
            emit(json!({"ev": "roam", "t": epoch(), "took_ms": started.elapsed().as_secs_f64() * 1000.0,
                        "sessions": marks.len(), "since_start_s": t0.elapsed().as_secs_f64()}));
        }
        let _ = roam;
    }
}

async fn run(args: &Args) -> Result<()> {
    let api = ApiClient::new(&args.base_url, &args.token);
    let mut ice_servers = api.ice().await.map(|c| c.ice_servers).unwrap_or_default();
    if args.no_turn {
        for server in &mut ice_servers {
            server.urls.retain(|url| !url.starts_with("turn:") && !url.starts_with("turns:"));
        }
        ice_servers.retain(|server| !server.urls.is_empty());
    }
    let device = uuid::Uuid::new_v4().to_string();
    api.register_device(&cmux_mobile_link::api::DeviceRegistration {
        device_id: device.clone(),
        kind: "phone".into(),
        name: "cmux-mobile-netprobe".into(),
        team_id: args.team.clone(),
        wg_public_key: None,
        machine_id: None,
        sibling_device_ids: Vec::new(),
    })
    .await
    .context("POST /v1/devices")?;
    let started = Instant::now();
    let signaling = SignalingClient::connect(&args.base_url, &args.token, &args.team, &device).await?;
    let options = DialOptions {
        ice_servers,
        exclude_cgnat: args.exclude_cgnat,
        input_lane: true,
        timeline: cmux_mobile_link::Timeline::starting_at(started),
        ..DialOptions::default()
    };
    let connected = cmux_mobile_link::dial::connect(
        &signaling,
        &args.mac,
        TransportKind::WireGuard,
        &options,
        LinkConfig::default(),
    )
    .await?;
    let link = &connected.link;
    let echo = link.open("echo", json!({})).await?;
    let (sender, mut receiver) = echo.split();
    // Ready: the first round trip is answered, the watcher starts, t0 is now.
    sender.send(Bytes::from_static(b"x")).await?;
    let _ = tokio::time::timeout(Duration::from_secs(10), receiver.recv()).await?;
    let path = format!("{:?}", *connected.path.borrow()).to_lowercase();
    emit(
        json!({"ev": "ready", "t": epoch(), "connect_ms": started.elapsed().as_secs_f64() * 1000.0, "path": path}),
    );

    if args.watch_ifaces {
        tokio::spawn(watch(args.no_roam_call, Instant::now()));
    }

    let total = ((args.seconds * 1000.0) / args.interval_ms as f64) as u64;
    let interval = Duration::from_millis(args.interval_ms);
    let begin = Instant::now();
    let writer = tokio::spawn(async move {
        let mut tick = tokio::time::interval(interval);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let mut sent = 0u64;
        for seq in 0..total {
            tick.tick().await;
            let mut frame = [0u8; 16];
            frame[..8].copy_from_slice(&seq.to_be_bytes());
            frame[8..].copy_from_slice(&epoch().to_be_bytes());
            if sender.send(Bytes::copy_from_slice(&frame)).await.is_err() {
                break;
            }
            sent += 1;
        }
        // The sender goes back to the reader: dropping it would close the channel and cut off the
        // last answers still on their way.
        (sent, sender)
    });
    // Read until the writer is done and 5 s have passed since (late answers still count).
    let mut buffer: Vec<u8> = Vec::new();
    let mut answered = 0u64;
    let mut writer = Some(writer);
    let mut sent_total = None;
    let mut writer_done_at: Option<Instant> = None;
    let mut held_sender = None;
    loop {
        if writer_done_at.is_some_and(|at| at.elapsed() > Duration::from_secs(5)) {
            break;
        }
        match tokio::time::timeout(Duration::from_millis(250), receiver.recv()).await {
            Ok(Some(ChannelEvent::Data(bytes))) => {
                buffer.extend_from_slice(&bytes);
                while buffer.len() >= 16 {
                    let frame: Vec<u8> = buffer.drain(..16).collect();
                    let seq = u64::from_be_bytes(frame[..8].try_into().unwrap());
                    let sent = f64::from_be_bytes(frame[8..].try_into().unwrap());
                    let recv = epoch();
                    answered += 1;
                    emit(
                        json!({"ev": "probe", "seq": seq, "sent": sent, "recv": recv, "rtt_ms": (recv - sent) * 1000.0}),
                    );
                }
            }
            Ok(Some(_)) => {}
            Ok(None) => {
                emit(json!({"ev": "channel_closed", "t": epoch()}));
                break;
            }
            Err(_) => {}
        }
        if writer.as_ref().is_some_and(|w| w.is_finished()) {
            if let Ok((sent, sender)) = writer.take().unwrap().await {
                sent_total = Some(sent);
                held_sender = Some(sender);
            }
            writer_done_at = Some(Instant::now());
        }
    }
    if let Some(w) = writer.take() {
        w.abort();
    }
    drop(held_sender);
    emit(
        json!({"ev": "summary", "sent": sent_total, "answered": answered, "seconds": begin.elapsed().as_secs_f64()}),
    );
    link.close("done");
    signaling.close();
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_env("CMUX_MOBILE_LOG")
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("warn")),
        )
        .with_writer(std::io::stderr)
        .init();
    let args = parse()?;
    if let Err(error) = run(&args).await {
        emit(json!({"ev": "error", "error": format!("{error:#}")}));
        std::process::exit(1);
    }
    Ok(())
}
