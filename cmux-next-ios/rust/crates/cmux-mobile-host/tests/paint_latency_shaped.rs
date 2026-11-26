//! Mac redraw to iPhone receive over a shaped link (cmux-fault's `good-wifi`, `lte`, `lossy-3`, `lossy-10`):
//! the Mac side stamps a streaming agent CLI's redraws as hostd's splice does
//! (`paint_latency::stamp_line`, then `send_marked`), a phone link reads them through the shaper,
//! probes the clock and sends its paint report on `phone-frames`, and hostd's own join prints
//! (a) Mac read to socket, (b) the wire, p50/p95. The phone's paint (c) comes from the simulator.
//!
//! Beside each, the same redraws over viewport state sync (`viewport_sync.rs`): datagrams through
//! cmux-fault's `UdpShaper` (loss is loss), the phone a `SyncReceiver` acking back; one
//! `STATESYNC-ROW` per profile sets the two paths' wire p50/p95 and bytes side by side.
//!
//! `cargo test -p cmux-mobile-host --test paint_latency_shaped -- --ignored --nocapture`

use std::sync::Arc;
use std::time::{Duration, Instant};

use base64::Engine as _;
use bytes::Bytes;
use cmux_fault::Trace;
use cmux_fault::shaper::{Counters, ProfileFile, Shaper, UdpShaper};
use cmux_mobile_host::paint_latency;
use cmux_mobile_host::phone_frames;
use cmux_mobile_host::viewport_sync::{
    self, Config, Path, SelectorConfig, StreamOut, UDP_MAX_DATAGRAM, ViewportSync,
};
use cmux_mobile_link::ChannelEvent;
use cmux_mobile_link::frame::epoch_us;
use cmux_mobile_link::link::{Link, LinkConfig, Role};
use cmux_terminal_projection::sync::SyncReceiver;
use tokio::net::{TcpListener, TcpStream, UdpSocket};
use tokio::sync::{mpsc, oneshot};

/// PTY bytes as the daemon's output line.
fn output_line(vt: &[u8]) -> Vec<u8> {
    let data = base64::engine::general_purpose::STANDARD.encode(vt);
    format!("{{\"data\":\"{data}\",\"event\":\"output\",\"surface\":1}}\n").into_bytes()
}

/// The phone's model of the screen, headless: the projection the phone's terminal is painted
/// from, at the host grid. Fed a stream line, it is the grid ready to paint.
struct PhoneGrid {
    projection: cmux_terminal_projection::Projection,
}

impl PhoneGrid {
    fn new(load: &Load) -> Self {
        let mut projection = cmux_terminal_projection::Projection::new(
            usize::from(load.cols),
            usize::from(load.rows),
            cmux_terminal_projection::DEFAULT_HISTORY_LIMIT,
        );
        projection.set_viewport(usize::from(load.cols), usize::from(load.rows));
        Self { projection }
    }

    /// An output (or history) line: its PTY bytes into the projection, painted.
    fn feed_line(&mut self, line: &[u8]) {
        let value: serde_json::Value = serde_json::from_slice(line).expect("a JSON line");
        let data = value["data"].as_str().expect("its data");
        let vt = base64::engine::general_purpose::STANDARD.decode(data).expect("base64");
        std::hint::black_box(self.projection.feed(&vt, true));
    }
}

/// A load: the PTY reads, one every 16 ms, at a host grid.
#[derive(Clone)]
struct Load {
    name: &'static str,
    reads: Arc<Vec<Vec<u8>>>,
    cols: u16,
    rows: u16,
}

/// The synthetic streaming reply: 500 redraws at 100x40 (every row it writes is on screen).
fn synthetic() -> Load {
    Load { name: "", reads: Arc::new((0..500).map(redraw_vt).collect()), cols: 100, rows: 40 }
}

/// A real Claude Code scroll, recorded at 120x40 (the projection crate's parity corpus): one
/// read per `.steps` line (`t_ms offset len phase`).
fn claude_code_scroll() -> Load {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../../cmux-tui/crates/cmux-terminal-projection/tests/parity/real");
    let vt = std::fs::read(dir.join("claude_code_scroll.vt")).expect("the scroll recording");
    let steps = std::fs::read_to_string(dir.join("claude_code_scroll.steps")).expect("its steps");
    let grid = std::fs::read_to_string(dir.join("claude_code_scroll.grid")).expect("its grid");
    let (cols, rows) = grid.trim().split_once('x').expect("COLSxROWS");
    let reads = steps
        .lines()
        .filter(|line| !line.starts_with('#') && !line.trim().is_empty())
        .map(|line| {
            let fields: Vec<&str> = line.split_whitespace().collect();
            let offset: usize = fields[1].parse().unwrap();
            let len: usize = fields[2].parse().unwrap();
            vt[offset..offset + len].to_vec()
        })
        .collect();
    Load { name: "scroll ", reads: Arc::new(reads), cols: cols.parse().unwrap(), rows: rows.parse().unwrap() }
}

/// A redraw of a Claude Code screen streaming a reply: a few rows of styled text, 1 to 6 KB.
fn redraw_vt(i: u64) -> Vec<u8> {
    let rows = 4 + (i % 24) as usize;
    let mut raw = Vec::new();
    for r in 0..rows {
        raw.extend_from_slice(format!("\x1b[{};1H\x1b[2K\x1b[38;5;{}m", 10 + r, 100 + r).as_bytes());
        raw.extend_from_slice(
            "  ⏺ streaming the reply, word by word, the way Claude Code redraws ".as_bytes(),
        );
        raw.extend_from_slice(format!("{i}:{r}\x1b[0m").as_bytes());
    }
    raw
}

/// What crossed the stream run's link while the redraws flowed, and for how long.
struct StreamBytes {
    counters: Counters,
    elapsed: Duration,
}

async fn run(
    profile: &str,
    load: &Load,
    every: Duration,
) -> (paint_latency::Summary, paint_latency::Summary, StreamBytes) {
    let link_profile = ProfileFile::builtin().get(profile).cloned().expect("profile");
    run_link(profile, link_profile, None, load, every).await
}

/// `resets`: every `.0`, nothing gets through for `.1` (a path reset: the link at NoPath, then
/// back on its relay, as Leo's Mac logs about every 1 to 2 min).
async fn run_link(
    profile: &str,
    link_profile: cmux_fault::shaper::LinkProfile,
    resets: Option<(Duration, Duration)>,
    load: &Load,
    every: Duration,
) -> (paint_latency::Summary, paint_latency::Summary, StreamBytes) {
    let lines = load.reads.len() as u64;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let shaper = Arc::new(
        Shaper::start(listener.local_addr().unwrap(), link_profile, 7, &Trace::new()).await.unwrap(),
    );
    let resetter = resets.map(|(period, dark)| {
        let shaper = Arc::clone(&shaper);
        tokio::spawn(async move {
            let mut tick = tokio::time::interval_at(tokio::time::Instant::now() + period, period);
            loop {
                tick.tick().await;
                shaper.blackout(dark);
            }
        })
    });
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("phone-frames.jsonl");

    let mac = tokio::spawn({
        let path = path.clone();
        let reads = load.reads.clone();
        async move {
            let (stream, _) = listener.accept().await.unwrap();
            stream.set_nodelay(true).unwrap();
            let mac = Link::new(stream, Role::Mac, LinkConfig::default(), None);
            let terminal = mac.accept().await.expect("terminal channel");
            let (sender, _receiver) = terminal.channel.split();
            let producer = tokio::spawn(async move {
                let mut tick = tokio::time::interval(every);
                for read in reads.iter() {
                    tick.tick().await;
                    let (line, mark) = paint_latency::stamp_line(output_line(read));
                    assert!(mark.is_some());
                    sender.send_marked(Bytes::from(line), mark).await.unwrap();
                }
                sender
            });
            let frames = mac.accept().await.expect("phone-frames channel");
            assert_eq!(frames.service, "phone-frames");
            let (frames_sender, frames_receiver) = frames.channel.split();
            phone_frames::serve("phone-1", &path, &frames_sender, frames_receiver).await.unwrap();
            let _sender = producer.await.unwrap();
            mac
        }
    });

    let started = Instant::now();
    let stream = TcpStream::connect(shaper.addr()).await.unwrap();
    stream.set_nodelay(true).unwrap();
    let phone = Link::new(stream, Role::Phone, LinkConfig::default(), None);
    let mut terminal = phone.open("terminal", serde_json::json!({})).await.unwrap();
    let mut samples = Vec::new();
    let mut pending = Vec::new();
    let mut grid = PhoneGrid::new(load);
    while samples.len() < lines as usize {
        let Some(ChannelEvent::Data(bytes)) =
            tokio::time::timeout(Duration::from_secs(60), terminal.recv()).await.unwrap()
        else {
            panic!("terminal closed")
        };
        let rx = epoch_us() as f64 / 1000.0;
        pending.extend_from_slice(&bytes);
        while let Some(end) = pending.iter().position(|b| *b == b'\n') {
            let line: Vec<u8> = pending.drain(..=end).collect();
            let seq = paint_latency::trailing_seq(&line).expect("a stamped line");
            // No screen here: (c) is the receive to the phone's grid ready (the projection
            // fed, headless); the simulator's present comes after it.
            grid.feed_line(&line);
            samples.push([seq as f64, rx, epoch_us() as f64 / 1000.0]);
        }
    }
    // The redraws' bytes, before the paint reports go up.
    let bytes = StreamBytes { counters: shaper.counters(), elapsed: started.elapsed() };
    let mut frames = phone.open("phone-frames", serde_json::json!({})).await.unwrap();
    let mut clock = Vec::new();
    for _ in 0..8 {
        let t0 = epoch_us() as f64 / 1000.0;
        frames.send(Bytes::from(serde_json::json!({"kind": "clock", "t0": t0}).to_string())).await.unwrap();
        let Some(ChannelEvent::Data(answer)) = frames.recv().await else { panic!("no clock answer") };
        let t3 = epoch_us() as f64 / 1000.0;
        let answer: serde_json::Value = serde_json::from_slice(&answer).unwrap();
        clock.push([t0, answer["t1"].as_f64().unwrap(), answer["t2"].as_f64().unwrap(), t3]);
    }
    for chunk in samples.chunks(200) {
        let report = serde_json::json!({"v": 1, "kind": "paint", "program": "claude", "load": profile,
            "samples": chunk, "clock": clock});
        frames.send(Bytes::from(report.to_string())).await.unwrap();
    }
    frames.close("done", "").await;
    let _mac = tokio::time::timeout(Duration::from_secs(60), mac).await.unwrap().unwrap();
    if let Some(resetter) = resetter {
        resetter.abort();
    }

    // hostd's own lines in phone-frames.jsonl, one per report.
    let text = std::fs::read_to_string(&path).unwrap();
    let mut joined = 0;
    for line in text.lines() {
        let value: serde_json::Value = serde_json::from_str(line).unwrap();
        assert_eq!(value["kind"], "paint");
        joined += value["joined"].as_u64().unwrap();
        println!("PAINT-JSONL {line}");
    }
    assert_eq!(joined, lines, "every stamp joined");
    // The run as one row.
    let report =
        serde_json::json!({"program": "claude", "load": profile, "samples": samples, "clock": clock});
    let report: paint_latency::Report = serde_json::from_value(report).unwrap();
    let measured = paint_latency::summarize(report.clone(), "phone-1", 0, paint_latency::lookup);
    // Both ends share this machine's clock, so the true offset is 0: the wire without the
    // estimate's error (at most half the probe's round trip).
    let truth = paint_latency::Report { clock: vec![[0.0, 0.0, 0.0, 0.0]], ..report };
    (measured, paint_latency::summarize(truth, "phone-1", 0, paint_latency::lookup), bytes)
}

/// The datagram run's row.
struct DatagramRow {
    p50_ms: f64,
    p95_ms: f64,
    down_per_min: f64,
    up_per_min: f64,
    /// Redraws whose state the phone never held: a newer one landed first.
    superseded: usize,
    /// Redraws that shared a capture with a later one (the pacer held the screen).
    coalesced: usize,
    rate: f64,
    /// Of `down_per_min`, the bytes/min that were copies of a diff already sent.
    copies_per_min: f64,
    /// After quiescence the phone acked the last state and its screen is the host's capture.
    converged: bool,
    /// Where a redraw's time goes, p50/p95 ms per stage.
    stages: Vec<(&'static str, f64, f64)>,
}

/// The phone side of the datagram path: a `SyncReceiver` acking every datagram, and each state
/// it took: (seq, when held, how long the apply took, held epoch ms).
fn spawn_sync_phone(
    phone: UdpSocket,
    stopped: oneshot::Receiver<()>,
) -> tokio::task::JoinHandle<(SyncReceiver, Vec<Held>)> {
    tokio::spawn(async move {
        let mut receiver = SyncReceiver::new();
        let mut held: Vec<Held> = Vec::new();
        let mut buffer = vec![0_u8; 64 * 1024];
        let mut stopped = stopped;
        loop {
            tokio::select! {
                received = phone.recv(&mut buffer) => {
                    let Ok(n) = received else { continue };
                    let before = receiver.seq();
                    let started = Instant::now();
                    let ack = receiver.on_datagram(&buffer[..n]);
                    if receiver.seq() > before {
                        let at = Instant::now();
                        held.push(Held { seq: receiver.seq(), at, apply: at - started, epoch_ms: epoch_us() as f64 / 1000.0 });
                    }
                    if let Some(ack) = ack {
                        let _ = phone.send(&ack).await;
                    }
                }
                _ = &mut stopped => return (receiver, held),
            }
        }
    })
}

/// A state the phone took.
#[derive(Clone, Copy)]
struct Held {
    seq: u64,
    at: Instant,
    apply: Duration,
    epoch_ms: f64,
}

fn ms(duration: Duration) -> f64 {
    duration.as_secs_f64() * 1000.0
}

/// p50 and p95 of `values` (ms), sorted here.
fn p50_p95(mut values: Vec<f64>) -> (f64, f64) {
    if values.is_empty() {
        return (f64::NAN, f64::NAN);
    }
    values.sort_by(f64::total_cmp);
    (percentile(&values, 0.50), percentile(&values, 0.95))
}

/// Nearest rank.
fn percentile(sorted: &[f64], p: f64) -> f64 {
    let rank = ((p * sorted.len() as f64).ceil() as usize).clamp(1, sorted.len());
    sorted[rank - 1]
}

fn per_min(bytes: u64, elapsed: Duration) -> f64 {
    bytes as f64 * 60.0 / elapsed.as_secs_f64()
}

/// The same redraws over viewport state sync: the host is `viewport_sync::run` on a UDP port
/// behind a `UdpShaper`, the phone a `SyncReceiver` that acks every datagram it judges. Wire
/// latency of redraw i: from its write to the host until the phone first holds a state with a
/// seq at least the one of the first capture covering it (newest wins: a newer state covers it).
async fn run_datagram(profile: &str, load: &Load, every: Duration) -> DatagramRow {
    let lines = load.reads.len() as u64;
    let link_profile = ProfileFile::builtin().get(profile).cloned().expect("profile");
    let host = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let shaper = UdpShaper::start(host.local_addr().unwrap(), link_profile, 7, &Trace::new()).await.unwrap();
    let phone = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    phone.connect(shaper.addr()).await.unwrap();
    // The phone speaks first so the relay knows where it is (its knock on the overlay port).
    phone.send(b"hello").await.unwrap();
    tokio::time::sleep(Duration::from_millis(20)).await;

    let (stop, stopped) = oneshot::channel::<()>();
    let phone_task = spawn_sync_phone(phone, stopped);

    let peer = shaper.phone_addr_at_host().unwrap();
    let mut sync =
        ViewportSync::new(load.cols, load.rows, UDP_MAX_DATAGRAM, Config::default(), Instant::now());
    sync.record_captures();
    let (output, batches) = mpsc::channel(1024);
    shaper.reset_counters();
    let started = Instant::now();
    let host_task =
        tokio::spawn(viewport_sync::run(sync, host, Some(peer), batches, None, Duration::from_secs(60)));
    let mut written = Vec::with_capacity(lines as usize);
    let mut tick = tokio::time::interval(every);
    for read in load.reads.iter() {
        tick.tick().await;
        written.push(Instant::now());
        output.send(read.clone()).await.unwrap();
    }
    drop(output);
    let sync = host_task.await.unwrap().unwrap();
    let elapsed = started.elapsed();
    let counters = shaper.counters();
    stop.send(()).unwrap();
    let (receiver, held) = phone_task.await.unwrap();
    // Checked after the table prints, so a miss still shows the numbers.
    let converged =
        sync.settled() && receiver.seq() == sync.latest_seq() && receiver.screen() == Some(&sync.capture());

    let captures = sync.captures();
    let feeds = sync.feeds();
    let mut latencies = Vec::with_capacity(lines as usize);
    let mut superseded = 0;
    let mut coalesced = 0;
    let mut previous_seq = None;
    let names =
        ["write to feed", "feed to capture", "capture cpu", "encode cpu", "send to held", "phone apply"];
    let mut stages: Vec<Vec<f64>> = vec![Vec::new(); names.len()];
    for (i, wrote) in written.iter().enumerate() {
        let batch = i as u64 + 1;
        let capture = captures.iter().find(|capture| capture.batches >= batch).expect("a capture covers it");
        if previous_seq == Some(capture.seq) {
            coalesced += 1;
        }
        previous_seq = Some(capture.seq);
        let fed = feeds[i].0;
        stages[0].push(ms(fed.saturating_duration_since(*wrote)));
        stages[1].push(ms(capture.at.saturating_duration_since(fed)));
        stages[2].push(ms(capture.capture));
        stages[3].push(ms(capture.encode));
        let Some(held) = held.iter().find(|held| held.seq >= capture.seq).copied() else {
            // Never held: counted at the end of the run.
            latencies.push(ms((started + elapsed).saturating_duration_since(*wrote)));
            continue;
        };
        stages[4].push(ms(held.at.saturating_duration_since(capture.at)));
        stages[5].push(ms(held.apply));
        if held.seq != capture.seq {
            superseded += 1;
        }
        latencies.push(ms(held.at.saturating_duration_since(*wrote)));
    }
    let stages = names
        .iter()
        .zip(stages)
        .map(|(name, values)| {
            let (p50, p95) = p50_p95(values);
            (*name, p50, p95)
        })
        .collect();
    let (p50_ms, p95_ms) = p50_p95(latencies);
    DatagramRow {
        p50_ms,
        p95_ms,
        down_per_min: per_min(counters.down_bytes, elapsed),
        up_per_min: per_min(counters.up_bytes, elapsed),
        superseded,
        coalesced,
        rate: sync.rate(),
        copies_per_min: per_min(sync.copies_sent().1, elapsed),
        converged,
        stages,
    }
}

/// The selected run's row: each redraw went by the path the selector was on when it came.
struct SelectedRow {
    p50_ms: f64,
    p95_ms: f64,
    stream_frames: usize,
    datagram_frames: usize,
    /// The path at the end, and each switch (ms after the run started, to which path).
    path: &'static str,
    switches: Vec<(f64, &'static str)>,
    warmup: Duration,
    /// The phone's receive to its grid ready (stream: the projection fed; datagram: the state
    /// applied), p50/p95 ms.
    grid_ready: (f64, f64),
    /// hostd's line in phone-frames.jsonl for this run's report.
    jsonl: String,
}

/// A frame the phone's stream took: its stamp, received and grid ready (instants, epoch ms).
struct StreamFrame {
    pseq: u64,
    rx: Instant,
    rx_ms: f64,
    ready_ms: f64,
}

/// The path selector on a link: today's stream (a link channel through cmux-fault's `Shaper`)
/// and the datagrams (through its `UdpShaper`) side by side, the same profile on both. The
/// driver is `viewport_sync::run_selected`: probes while idle for a 1 s warmup (the selector
/// must have judged even lossy-10's link within it), then the redraws, each on the path it is on. A redraw's latency is
/// its write to the phone's receive (stream) or to the phone holding its state (datagram), as
/// in the two runs above. The phone's paint report carries the path of each frame.
async fn run_selected(profile: &str, load: &Load, every: Duration) -> SelectedRow {
    let link_profile = ProfileFile::builtin().get(profile).cloned().expect("profile");
    let warmup = Duration::from_secs(1);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let tcp_shaper =
        Shaper::start(listener.local_addr().unwrap(), link_profile.clone(), 7, &Trace::new()).await.unwrap();
    let host = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let udp_shaper =
        UdpShaper::start(host.local_addr().unwrap(), link_profile, 7, &Trace::new()).await.unwrap();
    let phone_udp = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    phone_udp.connect(udp_shaper.addr()).await.unwrap();
    phone_udp.send(b"hello").await.unwrap();
    tokio::time::sleep(Duration::from_millis(20)).await;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("phone-frames.jsonl");

    // The Mac: the stream's writer takes what the driver hands it.
    let (stream_out, mut stream_in) = mpsc::channel::<StreamOut>(4096);
    let stamped: Arc<std::sync::Mutex<Vec<(u64, u64)>>> = Arc::default();
    let mac = tokio::spawn({
        let path = path.clone();
        let stamped = stamped.clone();
        async move {
            let (stream, _) = listener.accept().await.unwrap();
            stream.set_nodelay(true).unwrap();
            let mac = Link::new(stream, Role::Mac, LinkConfig::default(), None);
            let terminal = mac.accept().await.expect("terminal channel");
            let (sender, _receiver) = terminal.channel.split();
            let writer = tokio::spawn(async move {
                while let Some(out) = stream_in.recv().await {
                    match out {
                        StreamOut::Output { batch, bytes } => {
                            let (line, mark) = paint_latency::stamp_line(output_line(&bytes));
                            let pseq = paint_latency::trailing_seq(&line).expect("a stamped line");
                            stamped.lock().unwrap().push((pseq, batch));
                            sender.send_marked(Bytes::from(line), mark).await.unwrap();
                        }
                        StreamOut::History(rows) => {
                            let data = base64::engine::general_purpose::STANDARD.encode(&rows);
                            let line =
                                format!("{{\"data\":\"{data}\",\"event\":\"history\",\"surface\":1}}\n");
                            sender.send_marked(Bytes::from(line), None).await.unwrap();
                        }
                        // The measured runs' writer: switches and the repaint after one say nothing.
                        StreamOut::Switched(_) | StreamOut::Repaint(_) => {}
                    }
                }
                sender
            });
            let frames = mac.accept().await.expect("phone-frames channel");
            let (frames_sender, frames_receiver) = frames.channel.split();
            phone_frames::serve("phone-1", &path, &frames_sender, frames_receiver).await.unwrap();
            let _sender = writer.await.unwrap();
            mac
        }
    });

    // The phone: its stream into the grid, its datagrams into a `SyncReceiver`.
    let stream = TcpStream::connect(tcp_shaper.addr()).await.unwrap();
    stream.set_nodelay(true).unwrap();
    let phone = Link::new(stream, Role::Phone, LinkConfig::default(), None);
    let mut terminal = phone.open("terminal", serde_json::json!({})).await.unwrap();
    let expected = Arc::new(std::sync::atomic::AtomicUsize::new(usize::MAX));
    let stream_phone = tokio::spawn({
        let expected = expected.clone();
        let mut grid = PhoneGrid::new(load);
        async move {
            let mut frames = Vec::new();
            let mut pending = Vec::new();
            let deadline = Instant::now() + Duration::from_secs(300);
            while frames.len() < expected.load(std::sync::atomic::Ordering::SeqCst)
                && Instant::now() < deadline
            {
                let Ok(event) = tokio::time::timeout(Duration::from_millis(20), terminal.recv()).await else {
                    continue;
                };
                let Some(ChannelEvent::Data(bytes)) = event else { break };
                let rx = Instant::now();
                let rx_ms = epoch_us() as f64 / 1000.0;
                pending.extend_from_slice(&bytes);
                while let Some(end) = pending.iter().position(|b| *b == b'\n') {
                    let line: Vec<u8> = pending.drain(..=end).collect();
                    grid.feed_line(&line);
                    if let Some(pseq) = paint_latency::trailing_seq(&line) {
                        frames.push(StreamFrame { pseq, rx, rx_ms, ready_ms: epoch_us() as f64 / 1000.0 });
                    }
                }
            }
            (terminal, frames)
        }
    });
    let (stop, stopped) = oneshot::channel::<()>();
    let sync_phone = spawn_sync_phone(phone_udp, stopped);

    let peer = udp_shaper.phone_addr_at_host().unwrap();
    let mut sync =
        ViewportSync::new(load.cols, load.rows, UDP_MAX_DATAGRAM, Config::default(), Instant::now());
    sync.select_path(SelectorConfig::default());
    sync.record_captures();
    let (output, batches) = mpsc::channel(1024);
    let started = Instant::now();
    let host_task = tokio::spawn(viewport_sync::run_selected(
        sync,
        host,
        Some(peer),
        batches,
        stream_out,
        Duration::from_secs(60),
    ));
    tokio::time::sleep(warmup).await;
    let mut written = Vec::with_capacity(load.reads.len());
    let mut tick = tokio::time::interval(every);
    for read in load.reads.iter() {
        tick.tick().await;
        written.push(Instant::now());
        output.send(read.clone()).await.unwrap();
    }
    drop(output);
    let sync = host_task.await.unwrap().unwrap();
    let ended = Instant::now();
    let feeds = sync.feeds().to_vec();
    let on_stream = feeds.iter().filter(|(_, path)| *path == Path::Stream).count();
    expected.store(on_stream, std::sync::atomic::Ordering::SeqCst);
    let (terminal, frames) = stream_phone.await.unwrap();
    // Late datagram acks are not waited for: the driver returned once settled or on the stream.
    tokio::time::sleep(Duration::from_millis(50)).await;
    stop.send(()).unwrap();
    let (_receiver, held) = sync_phone.await.unwrap();
    drop(terminal);

    let stamped = stamped.lock().unwrap().clone();
    let captures = sync.captures();
    let mut latencies = Vec::with_capacity(written.len());
    let mut samples = Vec::with_capacity(written.len());
    let mut transports = Vec::with_capacity(written.len());
    let mut grid_ready = Vec::new();
    for (i, wrote) in written.iter().enumerate() {
        let batch = i as u64 + 1;
        match feeds[i].1 {
            Path::Stream => {
                let frame = stamped
                    .iter()
                    .find(|(_, b)| *b == batch)
                    .and_then(|(pseq, _)| frames.iter().find(|frame| frame.pseq == *pseq));
                let Some(frame) = frame else {
                    latencies.push(ms(ended.saturating_duration_since(*wrote)));
                    continue;
                };
                latencies.push(ms(frame.rx.saturating_duration_since(*wrote)));
                grid_ready.push(frame.ready_ms - frame.rx_ms);
                samples.push([frame.pseq as f64, frame.rx_ms, frame.ready_ms]);
                transports.push(Path::Stream.name());
            }
            Path::Datagram => {
                let held = captures
                    .iter()
                    .find(|capture| capture.batches >= batch)
                    .and_then(|capture| held.iter().find(|held| held.seq >= capture.seq));
                let Some(held) = held else {
                    latencies.push(ms(ended.saturating_duration_since(*wrote)));
                    continue;
                };
                latencies.push(ms(held.at.saturating_duration_since(*wrote)));
                grid_ready.push(ms(held.apply));
                // No hostd stamp on a datagram: seq 0 joins nothing, its phone part still counts.
                samples.push([0.0, held.epoch_ms - ms(held.apply), held.epoch_ms]);
                transports.push(Path::Datagram.name());
            }
        }
    }

    // The paint report, as the phone sends it: each frame with the path that painted it.
    let mut report = phone.open("phone-frames", serde_json::json!({})).await.unwrap();
    let mut clock = Vec::new();
    for _ in 0..8 {
        let t0 = epoch_us() as f64 / 1000.0;
        report.send(Bytes::from(serde_json::json!({"kind": "clock", "t0": t0}).to_string())).await.unwrap();
        let Some(ChannelEvent::Data(answer)) = report.recv().await else { panic!("no clock answer") };
        let t3 = epoch_us() as f64 / 1000.0;
        let answer: serde_json::Value = serde_json::from_slice(&answer).unwrap();
        clock.push([t0, answer["t1"].as_f64().unwrap(), answer["t2"].as_f64().unwrap(), t3]);
    }
    for (chunk, kinds) in samples.chunks(200).zip(transports.chunks(200)) {
        let line = serde_json::json!({"v": 1, "kind": "paint", "program": "claude", "load": profile,
            "samples": chunk, "clock": clock, "transports": kinds});
        report.send(Bytes::from(line.to_string())).await.unwrap();
    }
    report.close("done", "").await;
    let _mac = tokio::time::timeout(Duration::from_secs(60), mac).await.unwrap().unwrap();
    let jsonl = std::fs::read_to_string(&path).unwrap();

    let (p50_ms, p95_ms) = p50_p95(latencies);
    let switches = sync
        .switches()
        .iter()
        .map(|switch| (ms(switch.at.saturating_duration_since(started)), switch.to.name()))
        .collect();
    SelectedRow {
        p50_ms,
        p95_ms,
        stream_frames: on_stream,
        datagram_frames: feeds.len() - on_stream,
        path: sync.path().name(),
        switches,
        warmup,
        grid_ready: p50_p95(grid_ready),
        jsonl,
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "a measurement (about a minute): --ignored --nocapture prints the table"]
async fn mac_redraw_to_phone_receive_under_wifi_lte_and_lossy_3() {
    let mut rows = Vec::new();
    let mut converged = Vec::new();
    // The synthetic load's rows first; the recording loads after them, so a missing file
    // still leaves the first table printed.
    let loads: [fn() -> Load; 2] = [synthetic, claude_code_scroll];
    for make in loads {
        let load = make();
        let name = load.name;
        let n = load.reads.len();
        for profile in ["good-wifi", "lte", "lossy-3", "lossy-10"] {
            let (summary, truth, stream_bytes) = run(profile, &load, Duration::from_millis(16)).await;
            let mac = summary.mac.expect("mac part");
            let estimated = summary.wire.expect("wire part");
            let wire = truth.wire.expect("wire part");
            let grid = truth.phone_paint.expect("phone part");
            println!(
                "PAINT-ROW {name}{profile}: a mac p50 {} p95 {} | b wire p50 {} p95 {} (offset estimated {:?} from a {:?} ms probe: p50 {} p95 {}) | c receive to grid ready (headless) p50 {} p95 {} | n {}",
                mac.p50_ms,
                mac.p95_ms,
                wire.p50_ms,
                wire.p95_ms,
                summary.offset_ms,
                summary.clock_rtt_ms,
                estimated.p50_ms,
                estimated.p95_ms,
                grid.p50_ms,
                grid.p95_ms,
                wire.n
            );
            assert!(
                (estimated.p50_ms - wire.p50_ms).abs() <= summary.clock_rtt_ms.unwrap() / 2.0 + 1.0,
                "{profile}: the offset's error is bounded by half its probe"
            );
            let datagram = run_datagram(profile, &load, Duration::from_millis(16)).await;
            let one_way = ProfileFile::builtin().get(profile).unwrap().rtt_ms as f64 / 2.0;
            let StreamBytes { counters, elapsed } = stream_bytes;
            println!(
                "STATESYNC-ROW {name}{profile}: stream p50 {:.1} p95 {:.1} bytes/min {:.0} down / {:.0} up | datagram p50 {:.1} p95 {:.1} bytes/min {:.0} down (copies {:.0}) / {:.0} up | one-way {one_way} | superseded {} coalesced {} of {n} | pacer {:.0} B/s | datagram p95 <= 2x one-way: {}",
                wire.p50_ms,
                wire.p95_ms,
                per_min(counters.down_bytes, elapsed),
                per_min(counters.up_bytes, elapsed),
                datagram.p50_ms,
                datagram.p95_ms,
                datagram.down_per_min,
                datagram.copies_per_min,
                datagram.up_per_min,
                datagram.superseded,
                datagram.coalesced,
                datagram.rate,
                if datagram.p95_ms <= 2.0 * one_way { "yes" } else { "no" },
            );
            let stages: Vec<String> = datagram
                .stages
                .iter()
                .map(|(stage, p50, p95)| format!("{stage} {p50:.2}/{p95:.2}"))
                .collect();
            println!("STAGES {name}{profile}: datagram p50/p95 ms: {}", stages.join(" | "));
            let selected = run_selected(profile, &load, Duration::from_millis(16)).await;
            for line in selected.jsonl.lines() {
                println!("SELECTED-JSONL {name}{profile}: {line}");
            }
            let switches: Vec<String> =
                selected.switches.iter().map(|(at, to)| format!("{to} at {at:.0} ms")).collect();
            // Slower than today's stream: its p95 above the stream run's by more than 1 ms
            // (two runs of the same path differ by about that).
            let slower = selected.p95_ms > wire.p95_ms + 1.0;
            // The first switch to the datagrams, ms after the driver started (none: never).
            let first_switch = selected.switches.iter().find(|(_, to)| *to == "datagram").map(|(at, _)| *at);
            println!(
                "SELECTED-ROW {name}{profile}: selected p50 {:.1} p95 {:.1} | path {} (switches: {}; warmup {} ms) | frames {} stream / {} datagram | phone receive to grid ready p50 {:.2} p95 {:.2} | stream p95 {:.1} datagram p95 {:.1} | one-way {one_way} | slower than stream: {} | p95 <= 2x one-way: {} | switched within 1 s: {}",
                selected.p50_ms,
                selected.p95_ms,
                selected.path,
                if switches.is_empty() { "none".to_owned() } else { switches.join(", ") },
                selected.warmup.as_millis(),
                selected.stream_frames,
                selected.datagram_frames,
                selected.grid_ready.0,
                selected.grid_ready.1,
                wire.p95_ms,
                datagram.p95_ms,
                if slower { "yes" } else { "no" },
                if selected.p95_ms <= 2.0 * one_way { "yes" } else { "no" },
                match first_switch {
                    Some(at) if at <= 1000.0 => "yes",
                    Some(_) => "no",
                    None => "never switched",
                },
            );
            assert!(
                selected.jsonl.contains("\"transports\""),
                "{profile}: the report says which path painted"
            );
            rows.push((profile, mac, wire));
            converged.push((name, profile, datagram.converged));
        }
    }
    for (name, profile, converged) in &converged {
        assert!(converged, "{name}{profile}: after quiescence the phone's screen is the host's capture");
    }
    for (profile, _mac, wire) in &rows {
        let nominal = match *profile {
            "good-wifi" => 1.0,
            _ => 35.0,
        };
        assert!(wire.p50_ms + 2.0 >= nominal, "{profile}: the wire is at least the one-way delay");
    }
}

/// Host CPU per redraw by grid, the screen's capture and the diff's encode into datagrams, under
/// duress: every core but one spinning (a busy machine) while a load replays as fast as it
/// comes (high-rate streaming), the phone's acks four redraws behind (a round trip on lte), so
/// each diff spans what a real one does. One `ENCODE-ROW` per grid and load.
#[test]
#[ignore = "a measurement: --ignored --nocapture prints ENCODE-ROW"]
fn host_capture_and_encode_per_redraw_by_grid_on_a_busy_machine() {
    use std::sync::atomic::{AtomicBool, Ordering};
    let stop = Arc::new(AtomicBool::new(false));
    let cores = std::thread::available_parallelism().map_or(2, |n| n.get());
    let spinners: Vec<_> = (0..cores.saturating_sub(1).max(1))
        .map(|_| {
            let stop = stop.clone();
            std::thread::spawn(move || {
                let mut x = 1_u64;
                while !stop.load(Ordering::Relaxed) {
                    x = x.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1);
                    std::hint::black_box(x);
                }
            })
        })
        .collect();
    let config = Config { initial_rate: 8_000_000.0, ..Config::default() };
    for (cols, rows) in [(44_u16, 40_u16), (120, 40)] {
        let loads: [fn() -> Load; 2] = [synthetic, claude_code_scroll];
        for make in loads {
            let load = make();
            let name = if load.name.is_empty() { "synthetic" } else { load.name.trim() };
            let mut sync = ViewportSync::new(cols, rows, UDP_MAX_DATAGRAM, config.clone(), Instant::now());
            sync.record_captures();
            let mut phone = SyncReceiver::new();
            let mut acks: std::collections::VecDeque<(usize, Vec<u8>)> = Default::default();
            let start = Instant::now();
            for (i, read) in load.reads.iter().enumerate() {
                let now = start + Duration::from_millis(16 * i as u64);
                sync.feed(read);
                for datagram in sync.poll(now) {
                    if let Some(ack) = phone.on_datagram(&datagram) {
                        acks.push_back((i + 4, ack));
                    }
                }
                while acks.front().is_some_and(|(due, _)| *due <= i) {
                    let (_, ack) = acks.pop_front().unwrap();
                    sync.on_datagram(&ack, now);
                }
            }
            let captures = sync.captures();
            let sent: Vec<_> = captures.iter().filter(|capture| !capture.encode.is_zero()).collect();
            let (capture_p50, capture_p95) = p50_p95(captures.iter().map(|c| ms(c.capture)).collect());
            let (encode_p50, encode_p95) = p50_p95(sent.iter().map(|c| ms(c.encode)).collect());
            let (total_p50, total_p95) = p50_p95(sent.iter().map(|c| ms(c.capture + c.encode)).collect());
            println!(
                "ENCODE-ROW {cols}x{rows} {name}: capture p50 {capture_p50:.3} p95 {capture_p95:.3} | encode p50 {encode_p50:.3} p95 {encode_p95:.3} | total p50 {total_p50:.3} p95 {total_p95:.3} ms | redraws {} captures {} sent {} | {} cores spinning | total p95 under 1 ms: {}",
                load.reads.len(),
                captures.len(),
                sent.len(),
                cores.saturating_sub(1).max(1),
                if total_p95 < 1.0 { "yes" } else { "no" },
            );
        }
    }
    stop.store(true, Ordering::Relaxed);
    for spinner in spinners {
        spinner.join().unwrap();
    }
}

/// Leo's real link (his NIGHTLY's host log, 2026-11-22): the phone on wifi reaches the wired Mac
/// through a TURN relay, never direct, and the path resets (NoPath, then the relay again) about
/// every 1 to 2 min. Modelled: good-wifi's rates, plus a relay hop of 30 ms or 80 ms round trip
/// with 10 ms jitter, and a reset every 90 s that carries nothing for 2 s. The relay's round trip
/// is a guess until the rtt lines (path_report.rs) read his.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "a measurement (about 14 min): --ignored --nocapture prints the table"]
async fn mac_redraw_to_phone_receive_over_a_relay_with_a_path_reset_every_90_s() {
    let wifi = ProfileFile::builtin().get("good-wifi").cloned().expect("profile");
    // 200 s at 40 redraws a second, two resets inside the run; under hostd's stamp ring
    // (paint_latency::RING), since this bench reports once at the end.
    let load = Load { name: "", reads: Arc::new((0..8_000).map(redraw_vt).collect()), cols: 100, rows: 40 };
    for (name, relay_rtt) in [("relay-30", 30), ("relay-80", 80)] {
        for resets in [None, Some((Duration::from_secs(90), Duration::from_secs(2)))] {
            let mut profile = wifi.clone();
            profile.rtt_ms += relay_rtt;
            profile.jitter_ms = 10;
            let label = if resets.is_some() { format!("{name}+reset-90s") } else { name.to_string() };
            let (summary, truth, _bytes) =
                run_link(&label, profile, resets, &load, Duration::from_millis(25)).await;
            let mac = summary.mac.expect("mac part");
            let wire = truth.wire.expect("wire part");
            println!(
                "PAINT-ROW {label}: a mac p50 {} p95 {} | b wire p50 {} p95 {} max {} | n {}",
                mac.p50_ms, mac.p95_ms, wire.p50_ms, wire.p95_ms, wire.max_ms, wire.n
            );
            assert!(
                wire.p50_ms + 2.0 >= relay_rtt as f64 / 2.0,
                "{label}: the wire is at least the relay's one-way delay"
            );
        }
    }
}
