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
use cmux_mobile_host::viewport_sync::{self, Config, UDP_MAX_DATAGRAM, ViewportSync};
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
    let lines = load.reads.len() as u64;
    let link_profile = ProfileFile::builtin().get(profile).cloned().expect("profile");
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let shaper = Shaper::start(listener.local_addr().unwrap(), link_profile, 7, &Trace::new()).await.unwrap();
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
            // No screen here: painted when received, so (c) reads 0 and the sim gives it.
            samples.push([seq as f64, rx, rx]);
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
    /// After quiescence the phone acked the last state and its screen is the host's capture.
    converged: bool,
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
    let phone_task = tokio::spawn(async move {
        let mut receiver = SyncReceiver::new();
        let mut held: Vec<(u64, Instant)> = Vec::new();
        let mut buffer = vec![0_u8; 64 * 1024];
        let mut stopped = stopped;
        loop {
            tokio::select! {
                received = phone.recv(&mut buffer) => {
                    let Ok(n) = received else { continue };
                    let before = receiver.seq();
                    let ack = receiver.on_datagram(&buffer[..n]);
                    if receiver.seq() > before {
                        held.push((receiver.seq(), Instant::now()));
                    }
                    if let Some(ack) = ack {
                        let _ = phone.send(&ack).await;
                    }
                }
                _ = &mut stopped => return (receiver, held),
            }
        }
    });

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
    let mut latencies = Vec::with_capacity(lines as usize);
    let mut superseded = 0;
    let mut coalesced = 0;
    let mut previous_seq = None;
    for (i, wrote) in written.iter().enumerate() {
        let batch = i as u64 + 1;
        let capture = captures.iter().find(|capture| capture.batches >= batch).expect("a capture covers it");
        if previous_seq == Some(capture.seq) {
            coalesced += 1;
        }
        previous_seq = Some(capture.seq);
        let Some((seq, at)) = held.iter().find(|(seq, _)| *seq >= capture.seq).copied() else {
            // Never held: counted at the end of the run.
            latencies.push((started + elapsed).saturating_duration_since(*wrote).as_secs_f64() * 1000.0);
            continue;
        };
        if seq != capture.seq {
            superseded += 1;
        }
        latencies.push(at.saturating_duration_since(*wrote).as_secs_f64() * 1000.0);
    }
    latencies.sort_by(f64::total_cmp);
    DatagramRow {
        p50_ms: percentile(&latencies, 0.50),
        p95_ms: percentile(&latencies, 0.95),
        down_per_min: per_min(counters.down_bytes, elapsed),
        up_per_min: per_min(counters.up_bytes, elapsed),
        superseded,
        coalesced,
        rate: sync.rate(),
        converged,
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
            println!(
                "PAINT-ROW {name}{profile}: a mac p50 {} p95 {} | b wire p50 {} p95 {} (offset estimated {:?} from a {:?} ms probe: p50 {} p95 {}) | n {}",
                mac.p50_ms,
                mac.p95_ms,
                wire.p50_ms,
                wire.p95_ms,
                summary.offset_ms,
                summary.clock_rtt_ms,
                estimated.p50_ms,
                estimated.p95_ms,
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
                "STATESYNC-ROW {name}{profile}: stream p50 {:.1} p95 {:.1} bytes/min {:.0} down / {:.0} up | datagram p50 {:.1} p95 {:.1} bytes/min {:.0} down / {:.0} up | one-way {one_way} | superseded {} coalesced {} of {n} | pacer {:.0} B/s | datagram p95 <= 2x one-way: {}",
                wire.p50_ms,
                wire.p95_ms,
                per_min(counters.down_bytes, elapsed),
                per_min(counters.up_bytes, elapsed),
                datagram.p50_ms,
                datagram.p95_ms,
                datagram.down_per_min,
                datagram.up_per_min,
                datagram.superseded,
                datagram.coalesced,
                datagram.rate,
                if datagram.p95_ms <= 2.0 * one_way { "yes" } else { "no" },
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
