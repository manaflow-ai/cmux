//! The iPhone's Screen Sharing link (`ScreenLink`) against a real Linux host: `cmux-rd serve`
//! on an X display, the process `cmux-rd linux-host` starts for every hub session. The hub's
//! part (request, approval, the signed signaling) is replaced by passing the offer, answer and
//! candidates straight between the two, so this measures the link and the stream alone:
//! time from `start` to the handshake and to the first whole frame, and frame age.
//!
//!   CMUX_RD_BIN=$(command -v cmux-rd) CMUX_RD_DISPLAY=:99 CMUX_RD_TAKES=5 \
//!     cargo test -p cmux-mobile-link-ffi --test screen_rd -- --ignored --nocapture
//!
//! Ignored by default: it needs a cmux-rd build and an X display.

use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_mobile_link_ffi::{BrowserFrame, ScreenAnswer, ScreenLink, ScreenObserver};
use serde_json::{Value, json};

enum Seen {
    Frame(BrowserFrame),
    Candidate(String),
    Message(String),
    Closed(String),
}

struct Observer(Mutex<mpsc::Sender<Seen>>);

impl ScreenObserver for Observer {
    fn on_frame(&self, frame: BrowserFrame) {
        let _ = self.0.lock().unwrap().send(Seen::Frame(frame));
    }
    fn on_candidate(&self, candidate: String) {
        let _ = self.0.lock().unwrap().send(Seen::Candidate(candidate));
    }
    fn on_message(&self, json: String) {
        let _ = self.0.lock().unwrap().send(Seen::Message(json));
    }
    fn on_closed(&self, reason: String) {
        let _ = self.0.lock().unwrap().send(Seen::Closed(reason));
    }
}

struct Take {
    connected_ms: f64,
    first_frame_ms: f64,
    age_ms: Option<f64>,
    frames_in_2s: u64,
    path: Option<String>,
    rtt_ms: Option<f64>,
}

fn take(bin: &str, display: &str) -> Take {
    let link = ScreenLink::new().unwrap();
    let mut host = Command::new(bin)
        .args(["serve", "--display", display, "--capture", "x11"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("cmux-rd serve");
    let mut stdin = host.stdin.take().unwrap();
    let (lines_tx, lines) = mpsc::channel::<Value>();
    let stdout = host.stdout.take().unwrap();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if let Ok(v) = serde_json::from_str(&line) {
                let _ = lines_tx.send(v);
            }
        }
    });
    // The setup first (the viewer's key, from its offer), then the host says its displays and key.
    let setup = json!({
        "session": "screen-rd-test", "peer_key": link.session_key(),
        "viewer": {"user": "ios-test", "install": "ios-test"}, "scope": "control",
        "stun": [], "display": "main", "max_fps": 60, "max_width": null,
    });
    writeln!(stdin, "{setup}").unwrap();
    let host_key = loop {
        let line = lines.recv_timeout(Duration::from_secs(10)).expect("the host's key");
        if let Some(key) = line["key"].as_str() {
            break key.to_owned();
        }
    };
    // The host's routes as its answer would list them.
    let mut candidates = Vec::new();
    while let Ok(v) = lines.recv_timeout(Duration::from_secs(5)) {
        if let Some(c) = v["candidate"].as_str() {
            candidates.push(c.to_owned());
        }
        if v["candidates_done"].as_bool() == Some(true) {
            break;
        }
    }
    let mut answer = format!("cmux.rd/1\r\na=fingerprint:cmux-rd-key {host_key}\r\n");
    for c in &candidates {
        answer += &format!("a=cmux-rd-candidate:{c}\r\n");
    }
    let (tx, seen) = mpsc::channel();
    let started = Instant::now();
    link.start(
        ScreenAnswer {
            session: "screen-rd-test".into(),
            answer,
            ice_json: "[]".into(),
            control: true,
            relay_only: false,
        },
        Arc::new(Observer(Mutex::new(tx))),
    )
    .unwrap();
    let mut connected_ms = None;
    let mut first: Option<(f64, Option<f64>)> = None;
    let mut frames = 0u64;
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() || first.is_some_and(|_| started.elapsed() > Duration::from_secs(2)) {
            break;
        }
        match seen.recv_timeout(left.min(Duration::from_millis(100))) {
            Ok(Seen::Candidate(c)) => writeln!(stdin, "{}", json!({ "candidate": c })).unwrap(),
            Ok(Seen::Message(m)) if m.contains("\"connected\"") => {
                connected_ms.get_or_insert(started.elapsed().as_secs_f64() * 1000.0);
            }
            Ok(Seen::Frame(f)) => {
                frames += 1;
                if first.is_none() {
                    assert!(f.keyframe, "the first frame is a keyframe");
                    assert!(f.access_unit.windows(4).any(|w| w == [0, 0, 0, 1]), "Annex-B");
                    first = Some((started.elapsed().as_secs_f64() * 1000.0, None));
                }
                if let (Some(first), Some(age)) = (first.as_mut(), f.age_us) {
                    first.1.get_or_insert(age as f64 / 1000.0);
                }
            }
            Ok(Seen::Closed(reason)) => panic!("closed before the first frame: {reason}"),
            _ => {}
        }
    }
    let stats = link.stats();
    link.close();
    let _ = writeln!(stdin, "{}", json!({"stop": true}));
    let _ = host.wait();
    let (first_frame_ms, age_ms) = first.expect("a frame within 20 s");
    Take {
        connected_ms: connected_ms.unwrap_or(f64::NAN),
        first_frame_ms,
        age_ms,
        frames_in_2s: frames,
        path: stats.path,
        rtt_ms: stats.path_rtt_us.map(|us| us as f64 / 1000.0),
    }
}

fn median(mut v: Vec<f64>) -> f64 {
    v.sort_by(f64::total_cmp);
    v[v.len() / 2]
}

#[test]
#[ignore = "needs CMUX_RD_BIN and an X display"]
fn the_iphone_link_streams_a_linux_host() {
    let bin = std::env::var("CMUX_RD_BIN").expect("CMUX_RD_BIN");
    let display = std::env::var("CMUX_RD_DISPLAY").unwrap_or_else(|_| ":99".into());
    let takes: usize = std::env::var("CMUX_RD_TAKES").ok().and_then(|t| t.parse().ok()).unwrap_or(3);
    let all: Vec<Take> = (0..takes).map(|_| take(&bin, &display)).collect();
    for (i, t) in all.iter().enumerate() {
        println!(
            "take {i}: connected {:.1} ms, first frame {:.1} ms, frame age {:?} ms, {} frames by 2 s, path {:?} rtt {:?} ms",
            t.connected_ms, t.first_frame_ms, t.age_ms, t.frames_in_2s, t.path, t.rtt_ms
        );
    }
    println!(
        "median of {takes}: connected {:.1} ms, first frame {:.1} ms",
        median(all.iter().map(|t| t.connected_ms).collect()),
        median(all.iter().map(|t| t.first_frame_ms).collect()),
    );
}
