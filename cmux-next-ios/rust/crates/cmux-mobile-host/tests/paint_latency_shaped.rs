//! Mac redraw to iPhone receive over a shaped link (cmux-fault's `good-wifi`, `lte`, `lossy-3`, `lossy-10`):
//! the Mac side stamps a streaming agent CLI's redraws as hostd's splice does
//! (`paint_latency::stamp_line`, then `send_marked`), a phone link reads them through the shaper,
//! probes the clock and sends its paint report on `phone-frames`, and hostd's own join prints
//! (a) Mac read to socket, (b) the wire, p50/p95. The phone's paint (c) comes from the simulator.
//!
//! `cargo test -p cmux-mobile-host --test paint_latency_shaped -- --ignored --nocapture`

use std::time::Duration;

use base64::Engine as _;
use bytes::Bytes;
use cmux_fault::Trace;
use cmux_fault::shaper::{ProfileFile, Shaper};
use cmux_mobile_host::paint_latency;
use cmux_mobile_host::phone_frames;
use cmux_mobile_link::ChannelEvent;
use cmux_mobile_link::frame::epoch_us;
use cmux_mobile_link::link::{Link, LinkConfig, Role};
use tokio::net::{TcpListener, TcpStream};

/// A redraw of a Claude Code screen streaming a reply: a few rows of styled text, 1 to 6 KB.
fn redraw(i: u64) -> Vec<u8> {
    let rows = 4 + (i % 24) as usize;
    let mut raw = Vec::new();
    for r in 0..rows {
        raw.extend_from_slice(format!("\x1b[{};1H\x1b[2K\x1b[38;5;{}m", 10 + r, 100 + r).as_bytes());
        raw.extend_from_slice(
            "  ⏺ streaming the reply, word by word, the way Claude Code redraws ".as_bytes(),
        );
        raw.extend_from_slice(format!("{i}:{r}\x1b[0m").as_bytes());
    }
    let data = base64::engine::general_purpose::STANDARD.encode(raw);
    format!("{{\"data\":\"{data}\",\"event\":\"output\",\"surface\":1}}\n").into_bytes()
}

async fn run(profile: &str, lines: u64, every: Duration) -> (paint_latency::Summary, paint_latency::Summary) {
    let link_profile = ProfileFile::builtin().get(profile).cloned().expect("profile");
    run_link(profile, link_profile, None, lines, every).await
}

/// `resets`: every `.0`, nothing gets through for `.1` (a path reset: the link at NoPath, then
/// back on its relay, as Leo's Mac logs about every 1 to 2 min).
async fn run_link(
    profile: &str,
    link_profile: cmux_fault::shaper::LinkProfile,
    resets: Option<(Duration, Duration)>,
    lines: u64,
    every: Duration,
) -> (paint_latency::Summary, paint_latency::Summary) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let shaper = std::sync::Arc::new(
        Shaper::start(listener.local_addr().unwrap(), link_profile, 7, &Trace::new()).await.unwrap(),
    );
    let resetter = resets.map(|(period, dark)| {
        let shaper = std::sync::Arc::clone(&shaper);
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
        async move {
            let (stream, _) = listener.accept().await.unwrap();
            stream.set_nodelay(true).unwrap();
            let mac = Link::new(stream, Role::Mac, LinkConfig::default(), None);
            let terminal = mac.accept().await.expect("terminal channel");
            let (sender, _receiver) = terminal.channel.split();
            let producer = tokio::spawn(async move {
                let mut tick = tokio::time::interval(every);
                for i in 0..lines {
                    tick.tick().await;
                    let (line, mark) = paint_latency::stamp_line(redraw(i));
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
    (measured, paint_latency::summarize(truth, "phone-1", 0, paint_latency::lookup))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "a measurement (about a minute): --ignored --nocapture prints the table"]
async fn mac_redraw_to_phone_receive_under_wifi_lte_and_lossy_3() {
    let mut rows = Vec::new();
    for profile in ["good-wifi", "lte", "lossy-3", "lossy-10"] {
        let (summary, truth) = run(profile, 500, Duration::from_millis(16)).await;
        let mac = summary.mac.expect("mac part");
        let estimated = summary.wire.expect("wire part");
        let wire = truth.wire.expect("wire part");
        println!(
            "PAINT-ROW {profile}: a mac p50 {} p95 {} | b wire p50 {} p95 {} (offset estimated {:?} from a {:?} ms probe: p50 {} p95 {}) | n {}",
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
        rows.push((profile, mac, wire));
    }
    for (profile, _mac, wire) in &rows {
        let nominal = match *profile {
            "good-wifi" => 1.0,
            _ => 35.0,
        };
        assert!(wire.p50_ms + 2.0 >= nominal, "{profile}: the wire is at least the one-way delay");
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
    for (name, relay_rtt) in [("relay-30", 30), ("relay-80", 80)] {
        for resets in [None, Some((Duration::from_secs(90), Duration::from_secs(2)))] {
            let mut profile = wifi.clone();
            profile.rtt_ms += relay_rtt;
            profile.jitter_ms = 10;
            let label = if resets.is_some() { format!("{name}+reset-90s") } else { name.to_string() };
            // 200 s at 40 redraws a second, two resets inside the run; under hostd's stamp ring
            // (paint_latency::RING), since this bench reports once at the end.
            let (summary, truth) = run_link(&label, profile, resets, 8_000, Duration::from_millis(25)).await;
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
