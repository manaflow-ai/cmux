//! Attachment upload over the real Rust link under a degraded network, one matrix cell per run.
//! Driver: `cmux-next-ios/scripts/upload-netem-bench.sh` (it builds the namespaces; read its header).
//!
//! The phone half (this test) runs in the root namespace; the real hostd (`serve_signaling` with
//! the real `upload` service) runs as a child of this same test binary inside a network namespace,
//! reached over a veth pair carrying `tc netem` (delay, jitter, loss, rate) on both ends. Nothing
//! touches `lo` or the VM's NIC. The phone's side is `tests/upload.rs`'s, exactly: the `upload`
//! channel, 192 KiB writes read from disk, wait for the Mac's reply.
//!
//! All `#[ignore]`d: CI skips them. Config is by env (set by the script): NETEM_NS, NETEM_HOST_IF
//! (root side veth), NETEM_NS_IF (namespace side), NETEM_HOST_IP (root side address),
//! NETEM_SIZE_MB, NETEM_PROFILE (none|lte|lossy-3|link-drop), NETEM_LOAD (idle|duress),
//! NETEM_TRANSPORT (wireguard|webrtc), NETEM_ENGINE (current|new), NETEM_RUN, NETEM_CAP_SECS,
//! NETEM_CSV (appended), NETEM_WORKDIR.

use std::future::Future;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use cmux_mobile_host::config::{AcpmuxTarget, ServiceConfig};
use cmux_mobile_host::host::{AnswerContext, IceSource, serve_signaling};
use cmux_mobile_link::SignalingClient;
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling, LinkProfile};
use cmux_mobile_link_ffi::{AttachmentUploads, UploadObserver, UploadProgress, UploadSpec, UploadStage};
use cmux_mobile_link_ffi::{ChannelMessage, ConnectRequest, LinkHandle, Transport, connect_inner};

/// `LinkUpload.chunkBytes`.
const CHUNK: usize = 192 << 10;
const READY: &str = "NETEM_HOST_READY";
/// link-drop: a full blackout this long, starting when this share of the bytes is through.
const DROP_AT_PERCENT: u64 = 40;
const DROP_SECS: u64 = 20;
/// A run with no progress this long and no failure is reported as a hang.
const HANG_SECS: u64 = 60;

fn env(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_owned())
}

// ---------------------------------------------------------------- the Mac half, in the namespace

/// Started by the phone half inside the namespace: a real hostd until its stdin closes.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "child of upload_netem_cell"]
async fn netem_host_child() {
    if std::env::var("NETEM_ROLE").as_deref() != Ok("host") {
        return;
    }
    let (url, mac_id, root) =
        (env("NETEM_SIGNALING", ""), env("NETEM_MAC_ID", ""), PathBuf::from(env("NETEM_ROOT", "")));
    let services = ServiceConfig {
        tui_socket_dir: root.parent().unwrap().to_path_buf(),
        default_session: "main".into(),
        default_socket: None,
        file_roots: vec![root.clone()],
        acpmux: AcpmuxTarget::Fixed { url: "ws://127.0.0.1:1/".into(), token: None },
        browser: Default::default(),
        surface: Default::default(),
        chief_socket: None,
        agent_tab_host: None,
        uploads_dir: root.parent().unwrap().join("uploads"),
        pairing: None,
        viewport_sync: None,
    };
    let mac = SignalingClient::connect(&url, "user:alice", "team", &mac_id).await.unwrap();
    let services = Arc::new(services);
    let context = move || AnswerContext {
        owner_user_id: "alice".into(),
        services: Arc::clone(&services),
        ice: IceSource::Fixed(Vec::new()),
        include_loopback: true,
        exclude_cgnat: false,
        mailbox: None,
        session_exposure: None,
    };
    // As the real hostd (`host.rs`): when signaling drops (a long blackout), connect again,
    // move live WireGuard sessions onto the new socket, and serve on.
    tokio::spawn(async move {
        let mut mac = mac;
        loop {
            let reason = serve_signaling(mac, context()).await;
            eprintln!("host: signaling closed ({reason}); reconnecting");
            mac = loop {
                match SignalingClient::connect(&url, "user:alice", "team", &mac_id).await {
                    Ok(mac) => break mac,
                    Err(_) => tokio::time::sleep(Duration::from_secs(1)).await,
                }
            };
            cmux_mobile_link::dial::wireguard::rehome(&mac);
        }
    });
    println!("{READY}");
    let _ = std::io::stdout().flush();
    // The phone half holds our stdin; its exit (or kill) closes it.
    let _ = tokio::task::spawn_blocking(|| std::io::stdin().read_to_end(&mut Vec::new())).await;
}

// ---------------------------------------------------------------- shaping

struct Shape {
    profile: Option<LinkProfile>,
    /// Seconds of 100% loss once DROP_AT_PERCENT of the bytes are through (0: none).
    blackout: u64,
}

fn shape_for(name: &str) -> Shape {
    match name {
        "none" => Shape { profile: None, blackout: 0 },
        // Not in cmux-fault's link-profiles.json (it has elevator-30s, a different blackout): the
        // lte row, then 100% loss for DROP_SECS once DROP_AT_PERCENT of the bytes are through.
        "link-drop" => Shape { profile: Some(LinkProfile::named("lte")), blackout: DROP_SECS },
        // Past the link's 45 s keepalive: the link itself dies, not just the bytes.
        "link-drop-60" => Shape { profile: Some(LinkProfile::named("lte")), blackout: 60 },
        other => Shape { profile: Some(LinkProfile::named(other)), blackout: 0 },
    }
}

fn run_ok(cmd: &mut Command) {
    let out = cmd.output().expect("spawn");
    assert!(out.status.success(), "{cmd:?}: {}", String::from_utf8_lossy(&out.stderr));
}

/// netem on both veth ends: each direction gets half the round trip. cmux-fault's jitter is
/// `0..=jitter_ms` extra; netem's is symmetric uniform, so the delay mean carries half of it.
fn apply_netem(profile: &LinkProfile, loss_percent: f64) {
    let (ns, host_if, ns_if) = (env("NETEM_NS", ""), env("NETEM_HOST_IF", ""), env("NETEM_NS_IF", ""));
    let jitter = profile.jitter_ms as f64;
    let delay = profile.rtt_ms as f64 / 2.0 + jitter / 2.0;
    let rate = profile.up_kbit.min(if profile.down_kbit == 0 { u64::MAX } else { profile.down_kbit }).max(1);
    let mut args: Vec<String> = vec!["qdisc".into(), "replace".into(), "dev".into(), String::new()];
    args.extend(["root".into(), "netem".into(), "delay".into(), format!("{delay}ms")]);
    if jitter > 0.0 {
        args.push(format!("{}ms", jitter / 2.0));
    }
    args.extend(["loss".into(), format!("{loss_percent}%"), "rate".into(), format!("{rate}kbit")]);
    // cmux-fault's bearer buffer: 256 segments.
    args.extend(["limit".into(), "256".into()]);
    args[3] = host_if;
    run_ok(Command::new("sudo").args(["-n", "tc"]).args(&args));
    args[3] = ns_if;
    run_ok(Command::new("sudo").args(["-n", "ip", "netns", "exec", &ns, "tc"]).args(&args));
}

// ---------------------------------------------------------------- the upload under test

/// What an engine reports as it goes; the harness reads it for the stall watch, the link-drop
/// trigger and the cap, so a run cut off at the cap still has its numbers.
#[derive(Default)]
struct Progress {
    /// Bytes whose `send` has returned (the link's buffer took them; the closest the FFI shows to acked).
    acked: AtomicU64,
    open_ms: AtomicU64,
    /// Time the last byte went in, from the start of the upload (0: not yet).
    last_byte_ms: AtomicU64,
    reply_ms: AtomicU64,
    max_stall_ms: AtomicU64,
    done: AtomicBool,
}

struct UploadJob {
    handle: Arc<LinkHandle>,
    source: PathBuf,
    size: u64,
    root: PathBuf,
    started: Instant,
    progress: Arc<Progress>,
    /// Dials the Mac again, as `MacSession` does when the served link dies.
    relink: Relink,
}

type Relink = Arc<dyn Fn() -> Pin<Box<dyn Future<Output = Option<Arc<LinkHandle>>> + Send>> + Send + Sync>;

/// The engine's verdict: `Ok` when the Mac stored `size` bytes, else a failure code.
type UploadFuture = Pin<Box<dyn Future<Output = Result<(), String>>>>;
type Engine = fn(UploadJob) -> UploadFuture;

fn engine(name: &str) -> Engine {
    match name {
        "current" => |job| Box::pin(upload_current(job)),
        "new" => |job| Box::pin(upload_new(job)),
        other => panic!("unknown NETEM_ENGINE {other}"),
    }
}

fn ms(since: Instant) -> u64 {
    since.elapsed().as_millis() as u64
}

/// `LinkUpload.swift` as `tests/upload.rs` ports it: one `upload` channel, `CHUNK` writes read from
/// disk, a failed send means the Mac answered early, then wait for the reply.
async fn upload_current(job: UploadJob) -> Result<(), String> {
    let UploadJob { handle, source, size, root, started, progress, relink: _ } = job;
    let args =
        serde_json::json!({"name": "big.bin", "size": size.to_string(), "cwd": root.to_str().unwrap()});
    let channel = handle
        .open_channel("upload".into(), args.to_string())
        .await
        .map_err(|error| format!("open: {error}"))?;
    progress.open_ms.store(ms(started), Ordering::Relaxed);
    let mut file = std::fs::File::open(&source).unwrap();
    let (mut buffer, mut sent) = (vec![0_u8; CHUNK], 0_u64);
    while sent < size {
        let read = file.read(&mut buffer).unwrap();
        if read == 0 {
            return Err("source ended early".into());
        }
        if channel.send(buffer[..read].to_vec()).await.is_err() {
            break;
        }
        sent += read as u64;
        progress.acked.store(sent, Ordering::Relaxed);
    }
    progress.last_byte_ms.store(ms(started), Ordering::Relaxed);
    let mut reply = Vec::new();
    let code = loop {
        match channel.recv().await {
            ChannelMessage::Data { bytes } => reply.extend(bytes),
            ChannelMessage::Closed { code, .. } => break code,
        }
    };
    progress.reply_ms.store(ms(started), Ordering::Relaxed);
    let reply: serde_json::Value = serde_json::from_slice(&reply).unwrap_or_default();
    if code == "eof" && sent == size && reply["size"].as_u64() == Some(size) {
        Ok(())
    } else {
        Err(format!("{code}: sent {sent} of {size}; reply {reply}"))
    }
}

/// The resumable engine (`AttachmentUploads`, src/attachment_upload.rs) as the app drives it:
/// one link set for the Mac, one upload started, `wait` for the path. `acked` is the Mac's own
/// ack here, not a returned `send`.
struct BenchObserver {
    started: Instant,
    progress: Arc<Progress>,
    last: std::sync::Mutex<(Option<UploadStage>, u32)>,
}

impl UploadObserver for BenchObserver {
    fn on_progress(&self, update: UploadProgress) {
        let p = &self.progress;
        {
            let mut last = self.last.lock().unwrap();
            if *last != (Some(update.stage), update.attempt) {
                *last = (Some(update.stage), update.attempt);
                eprintln!(
                    "stage {:?} attempt {} acked {} at {} ms {}",
                    update.stage,
                    update.attempt,
                    update.acked_bytes,
                    ms(self.started),
                    update.error_code.clone().unwrap_or_default()
                );
            }
        }
        if update.stage == UploadStage::Uploading && p.open_ms.load(Ordering::Relaxed) == 0 {
            p.open_ms.store(ms(self.started), Ordering::Relaxed);
        }
        if update.stage != UploadStage::Compressing {
            p.acked.fetch_max(update.acked_bytes, Ordering::Relaxed);
        }
        if update.total_bytes > 0
            && update.sent_bytes >= update.total_bytes
            && p.last_byte_ms.load(Ordering::Relaxed) == 0
        {
            p.last_byte_ms.store(ms(self.started), Ordering::Relaxed);
        }
    }
}

async fn upload_new(job: UploadJob) -> Result<(), String> {
    let UploadJob { handle, source, size, root, started, progress, relink } = job;
    let uploads = AttachmentUploads::new(Arc::new(BenchObserver {
        started,
        progress: progress.clone(),
        last: Default::default(),
    }));
    uploads.set_link("bench".into(), Some(Arc::clone(&handle)));
    // MacSession's part: when the served link dies, dial again and hand the engine the new one.
    let relinker = {
        let uploads = Arc::clone(&uploads);
        tokio::spawn(async move {
            let mut current = handle;
            loop {
                tokio::time::sleep(Duration::from_millis(250)).await;
                if !current.is_closed() {
                    continue;
                }
                eprintln!("relink: link closed, dialing again");
                let next = relink().await;
                eprintln!("relink: {}", if next.is_some() { "linked" } else { "dial failed" });
                if let Some(next) = next {
                    uploads.set_link("bench".into(), Some(Arc::clone(&next)));
                    current = next;
                }
            }
        })
    };
    let spec = UploadSpec {
        upload_id: None,
        mac_id: "bench".into(),
        name: "big.bin".into(),
        cwd: Some(root.to_str().unwrap().into()),
    };
    let id = uploads.start(spec, source.to_str().unwrap().into());
    let result = uploads.wait(id.clone()).await;
    relinker.abort();
    progress.reply_ms.store(ms(started), Ordering::Relaxed);
    if progress.last_byte_ms.load(Ordering::Relaxed) == 0 {
        progress.last_byte_ms.store(ms(started), Ordering::Relaxed);
    }
    let attempts = uploads.progress(id).map(|p| p.attempt).unwrap_or(0);
    match result {
        Ok(path) => match std::fs::metadata(&path) {
            Ok(meta) if meta.len() == size => Ok(()),
            Ok(meta) => Err(format!("short: {} of {size} at {path}", meta.len())),
            Err(error) => Err(format!("missing {path}: {error}")),
        },
        Err(error) => Err(format!("{error} (attempts {attempts})")),
    }
}

/// The phone's dial: redials preserve the authenticated device that owns the staged bytes.
fn request(base_url: &str, mac_id: &str, phone_id: &str, transport: Transport) -> ConnectRequest {
    ConnectRequest {
        base_url: base_url.to_owned(),
        token: "user:alice".into(),
        team_id: "team".into(),
        device_id: phone_id.into(),
        mac_device_id: mac_id.to_owned(),
        transport,
        // The veth address is the path under test; loopback only misleads (the phone's own).
        include_loopback: false,
        relay_only: false,
        block_udp: false,
        video_lane: false,
        webrtc_media: false,
        ultra: cmux_mobile_link::UltraSetting::Off,
        proxy_only: false,
        drop_wireguard: false,
        force_relay: false,
    }
}

/// Duress: a second bulk channel (an `upload` to the same Mac) sending until told to stop.
async fn background_bulk(handle: Arc<LinkHandle>, root: PathBuf, stop: Arc<AtomicBool>) {
    let args = serde_json::json!({"name": "bulk2.bin", "size": (64_u64 << 30).to_string(), "cwd": root.to_str().unwrap()});
    let Ok(channel) = handle.open_channel("upload".into(), args.to_string()).await else { return };
    let chunk = vec![0x5a_u8; CHUNK];
    while !stop.load(Ordering::Relaxed) {
        if channel.send(chunk.clone()).await.is_err() {
            break;
        }
    }
}

// ---------------------------------------------------------------- the cell

fn sparse_file(path: &Path, size: u64) {
    let mut file = std::fs::File::create(path).unwrap();
    file.set_len(size).unwrap();
    for (mark, at) in [(0x11_u8, 0), (0x22, size / 2), (0x33, size - 4096)] {
        file.seek(SeekFrom::Start(at)).unwrap();
        file.write_all(&[mark; 4096]).unwrap();
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "needs the netns the driver builds: cmux-next-ios/scripts/upload-netem-bench.sh"]
async fn upload_netem_cell() {
    let size_mb: u64 = env("NETEM_SIZE_MB", "10").parse().unwrap();
    let size = (size_mb << 20) + 12_345;
    let (profile_name, load) = (env("NETEM_PROFILE", "lte"), env("NETEM_LOAD", "idle"));
    let transport_name = env("NETEM_TRANSPORT", "wireguard");
    let engine_name = env("NETEM_ENGINE", "current");
    let cap = Duration::from_secs(env("NETEM_CAP_SECS", "1200").parse().unwrap());
    let shape = shape_for(&profile_name);
    let transport = match transport_name.as_str() {
        "wireguard" => Transport::WireGuard,
        "webrtc" => Transport::WebRtc,
        other => panic!("NETEM_TRANSPORT {other}"),
    };

    let workdir = tempfile::Builder::new()
        .prefix("netem-")
        .tempdir_in(env("NETEM_WORKDIR", &std::env::temp_dir().to_string_lossy()))
        .unwrap();
    let root = std::fs::canonicalize(workdir.path()).unwrap().join("mac").join("work");
    std::fs::create_dir_all(&root).unwrap();
    let source = workdir.path().join("big.bin");
    sparse_file(&source, size);

    // Shape before anything dials: the handshake and the upload both live on this link.
    if let Some(profile) = &shape.profile {
        apply_netem(profile, profile.loss_percent);
    }

    // Signaling is the phone half's; the Mac child reaches it over the veth.
    let server = FakeSignaling::start_on("0.0.0.0:0", FakeOptions::default()).await;
    let port = server.base_url.rsplit(':').next().unwrap().to_owned();
    let local_url = format!("http://127.0.0.1:{port}");
    let mac_id = uuid::Uuid::new_v4().to_string();
    let exe = std::env::current_exe().unwrap();
    let mut child = Command::new("sudo")
        .args([
            "-n",
            "ip",
            "netns",
            "exec",
            &env("NETEM_NS", ""),
            "sudo",
            "-n",
            "-u",
            &env("USER", "cmux"),
            "env",
        ])
        .arg("NETEM_ROLE=host")
        .arg(format!("NETEM_SIGNALING=http://{}:{port}", env("NETEM_HOST_IP", "")))
        .arg(format!("NETEM_MAC_ID={mac_id}"))
        .arg(format!("NETEM_ROOT={}", root.display()))
        .arg(&exe)
        .args(["--exact", "netem_host_child", "--ignored", "--nocapture", "--test-threads=1"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn hostd in the namespace");
    let stdout = child.stdout.take().unwrap();
    let ready = tokio::task::spawn_blocking(move || {
        BufReader::new(stdout).lines().map_while(Result::ok).any(|line| line.contains(READY))
    });
    assert!(
        tokio::time::timeout(Duration::from_secs(60), ready).await.expect("hostd start timed out").unwrap(),
        "hostd child exited before ready"
    );

    let phone_id = uuid::Uuid::new_v4().to_string();
    let connect_started = Instant::now();
    let connected = tokio::time::timeout(
        Duration::from_secs(120),
        connect_inner(request(&local_url, &mac_id, &phone_id, transport), None),
    )
    .await;
    let connect_ms = ms(connect_started);
    let (mut yes_workers, stop) = (Vec::new(), Arc::new(AtomicBool::new(false)));
    let progress = Arc::new(Progress::default());
    let (mut finished, mut code, mut capped) = (false, String::new(), false);
    let mut total_ms = 0;
    let started = Instant::now();
    match connected {
        Ok(Ok(handle)) => {
            if load == "duress" {
                for _ in 0..4 {
                    yes_workers
                        .push(Command::new("sh").args(["-c", "exec yes > /dev/null"]).spawn().expect("yes"));
                }
                tokio::spawn(background_bulk(Arc::clone(&handle), root.clone(), Arc::clone(&stop)));
                tokio::time::sleep(Duration::from_millis(500)).await;
            }
            // Watchers: stall detection and the link-drop trigger.
            let watch = Arc::clone(&progress);
            let blackout = shape.blackout;
            let lte = shape.profile.clone();
            tokio::spawn(async move {
                let (mut last, mut since, mut dropped) = (0_u64, Instant::now(), false);
                let mut hang_reported = false;
                while !watch.done.load(Ordering::Relaxed) {
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    let acked = watch.acked.load(Ordering::Relaxed);
                    if acked != last {
                        (last, since, hang_reported) = (acked, Instant::now(), false);
                    }
                    let stall = ms(since);
                    watch.max_stall_ms.fetch_max(stall, Ordering::Relaxed);
                    if stall > HANG_SECS * 1000 && !hang_reported {
                        hang_reported = true;
                        let phase = if watch.last_byte_ms.load(Ordering::Relaxed) > 0 {
                            "waiting for the Mac's reply, all bytes sent"
                        } else if watch.open_ms.load(Ordering::Relaxed) > 0 {
                            "in send()"
                        } else {
                            "in open_channel"
                        };
                        eprintln!("HANG? no progress {stall} ms, acked {acked} B, {phase}");
                    }
                    if blackout > 0 && !dropped && acked * 100 >= size * DROP_AT_PERCENT {
                        dropped = true;
                        let lte = lte.clone().unwrap();
                        eprintln!("link-drop: 100% loss for {blackout} s at {acked} B");
                        apply_netem(&lte, 100.0);
                        tokio::time::sleep(Duration::from_secs(blackout)).await;
                        apply_netem(&lte, lte.loss_percent);
                    }
                }
            });
            let job = UploadJob {
                handle: Arc::clone(&handle),
                source: source.clone(),
                size,
                root: root.clone(),
                started: Instant::now(),
                progress: Arc::clone(&progress),
                relink: {
                    let (url, mac, phone) = (local_url.clone(), mac_id.clone(), phone_id.clone());
                    Arc::new(move || {
                        let (url, mac, phone) = (url.clone(), mac.clone(), phone.clone());
                        Box::pin(async move {
                            let dial = connect_inner(request(&url, &mac, &phone, transport), None);
                            tokio::time::timeout(Duration::from_secs(30), dial).await.ok()?.ok()
                        })
                    })
                },
            };
            match tokio::time::timeout(cap, engine(&engine_name)(job)).await {
                Ok(Ok(())) => (finished, code) = (true, "ok".into()),
                Ok(Err(error)) => {
                    code = error.split(':').next().unwrap_or("error").to_owned() + &format!(" [{error}]")
                }
                Err(_) => (capped, code) = (true, format!("cap {} s", cap.as_secs())),
            }
            total_ms = ms(started);
            progress.done.store(true, Ordering::Relaxed);
            stop.store(true, Ordering::Relaxed);
        }
        Ok(Err(error)) => code = format!("connect: {error}"),
        Err(_) => code = "connect: timeout 120 s".into(),
    }
    let csv_line = format!(
        "{engine_name},{transport_name},{profile_name},{load},{size_mb},{run},{connect_ms},{open},{last},{reply},{total_ms},{acked},{fin},{code:?},{stall},{capped}\n",
        run = env("NETEM_RUN", "0"),
        open = progress.open_ms.load(Ordering::Relaxed),
        last = progress.last_byte_ms.load(Ordering::Relaxed),
        reply = progress.reply_ms.load(Ordering::Relaxed),
        acked = progress.acked.load(Ordering::Relaxed),
        fin = if finished { "y" } else { "n" },
        stall = progress.max_stall_ms.load(Ordering::Relaxed),
    );
    print!("NETEM-ROW {csv_line}");
    if let Ok(path) = std::env::var("NETEM_CSV") {
        std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .unwrap()
            .write_all(csv_line.as_bytes())
            .unwrap();
    }
    for worker in &mut yes_workers {
        let _ = worker.kill();
        let _ = worker.wait();
    }
    drop(child.stdin.take());
    let _ = child.wait();
    drop(server);
    // `exit` skips destructors: remove the workdir (the source and the Mac's copy) first, or
    // every run leaves its file behind in the temp dir.
    drop(workdir);
    // A capped run leaves tasks mid-send; leave without waiting for them.
    std::process::exit(0);
}
