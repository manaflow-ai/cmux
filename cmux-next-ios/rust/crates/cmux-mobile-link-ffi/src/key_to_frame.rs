//! Phone key-to-frame: the time from this phone sending a key (or tap) to the frame that shows
//! its effect presented on this phone's screen, p50 / p95 over many samples, for the
//! screen-share-fast goal (key to presented frame at most 60 ms p50, 100 ms p95).
//!
//! The host shows the glass-to-glass marker (`cmux-tui/crates/cmux-rd-host/scripts/mac-marker`:
//! 20 cells, a 16-bit counter LSB first then guards 1,0,1,0; every key press or click on it
//! bumps the counter), the same marker `cmux-rd bench`, `screen-share-vs.py` and
//! `RdMarkerClickLatencyTests` time. A sample is one input sent here while the marker shows
//! `v`, ended by the first presented frame whose marker reads `v + 1` (1 s = lost), then a
//! random 40 to 160 ms gap, as the rd bench.
//!
//! Everything but the pixels and the present time is here, so the rd/1 and WebRTC viewers share
//! it: the marker's sample points, the counter read, the input loop and its matching, the
//! percentiles and probe.json. Swift reads 20 luma bytes from each decoded picture at
//! `marker_points` and says when that picture reaches the glass (`frame`).
//!
//! One clock for every time: `key_to_frame_clock_us` (CLOCK_UPTIME_RAW on Apple, the clock of
//! `CACurrentMediaTime` and `CADisplayLink`; CLOCK_MONOTONIC elsewhere).

use std::fs;
use std::path::Path;
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::time::Duration;

use crate::CmuxMobileError;

/// The marker's cells: 16 counter bits then the guards.
const CELLS: usize = 20;
const GUARD: [bool; 4] = [true, false, true, false];
/// Luma above this is a lit cell (video-range 4:2:0, as RdMarkerClickLatencyTests reads it).
const LIT: u8 = 125;
/// An input whose frame never came within this is lost (the rd bench's deadline).
const LOST_AFTER: Duration = Duration::from_secs(1);
/// The first marker must show within this (the rd bench's bound).
const FIRST_MARKER: Duration = Duration::from_secs(15);
/// The goal's targets, carried in probe.json beside the numbers.
const TARGET_P50_MS: f64 = 60.0;
const TARGET_P95_MS: f64 = 100.0;
pub const PROBE_SCHEMA: &str = "cmux.screen-share-fast/1";
/// screen-share-vs.py's budget schema, so screen_share_fast_receipt.py extract reads the run.
const BUDGET_SCHEMA: &str = "cmux.screen-share-budget/1";
/// The Total row's source: this probe, ending at the presented frame.
pub const SOURCE: &str = "phone marker";

/// Where the marker sits in the stream: one cell's width as a fraction of the frame width, and
/// the marker's top as a fraction of the frame height (the rig prints both from the marker's
/// `marker-origin` and the stream size; RdMarkerClickLatencyTests takes the same two numbers).
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct MarkerGeometry {
    pub cell_fraction: f64,
    pub origin_y: f64,
}

/// A pixel in the decoded picture.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct MarkerPoint {
    pub x: u32,
    pub y: u32,
}

/// What the probe asks the viewer to send (the viewer's own input path, so the time includes it).
#[uniffi::export(with_foreign)]
pub trait KeyToFrameInput: Send + Sync {
    /// Press and release "a" (HID usage 4), as `cmux-rd bench --input key`.
    fn key(&self);
    /// Click at `(x, y)` in the decoded picture's pixels.
    fn click(&self, x: u32, y: u32);
}

/// Now on the probe's clock, microseconds.
#[uniffi::export]
pub fn key_to_frame_clock_us() -> u64 {
    clock_us()
}

fn clock_us() -> u64 {
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    let id = libc::CLOCK_UPTIME_RAW;
    #[cfg(not(any(target_os = "macos", target_os = "ios")))]
    let id = libc::CLOCK_MONOTONIC;
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: `ts` is a live timespec for the call's duration.
    unsafe {
        libc::clock_gettime(id, &raw mut ts);
    }
    u64::try_from(ts.tv_sec).unwrap_or(0) * 1_000_000 + u64::try_from(ts.tv_nsec).unwrap_or(0) / 1000
}

/// The 20 cell centers in a `width` by `height` picture.
pub fn points(geometry: MarkerGeometry, width: u32, height: u32) -> Vec<MarkerPoint> {
    let cell = geometry.cell_fraction * f64::from(width);
    let y = geometry.origin_y * f64::from(height) + cell / 2.0;
    (0..CELLS)
        .map(|i| MarkerPoint { x: clamp_px((i as f64 + 0.5) * cell, width), y: clamp_px(y, height) })
        .collect()
}

fn clamp_px(v: f64, limit: u32) -> u32 {
    (v.max(0.0) as u32).min(limit.saturating_sub(1))
}

/// The counter in 20 luma samples, or None when the guards do not read 1,0,1,0.
pub fn read_marker(lumas: &[u8]) -> Option<u16> {
    if lumas.len() != CELLS {
        return None;
    }
    let bits: Vec<bool> = lumas.iter().map(|&l| l > LIT).collect();
    if bits.get(16..)? != GUARD {
        return None;
    }
    Some(bits.iter().take(16).enumerate().fold(0u16, |acc, (i, &b)| acc | (u16::from(b) << i)))
}

/// One matched input.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Sample {
    pub sent_us: u64,
    pub decoded_us: u64,
    pub presented_us: u64,
}

#[derive(Default)]
struct State {
    size: (u32, u32),
    current: Option<u16>,
    /// The input in flight: when it was sent and the counter it should bring.
    pending: Option<(u64, u16)>,
    /// The frame that closed the pending input (decoded, presented).
    closed: Option<(u64, u64)>,
}

/// One probe run. Feed it every decoded picture (`frame`), and `run` it on a thread of its own.
#[derive(uniffi::Object)]
pub struct KeyToFrameProbe {
    geometry: MarkerGeometry,
    state: Mutex<State>,
    changed: Condvar,
}

#[uniffi::export]
impl KeyToFrameProbe {
    #[uniffi::constructor]
    pub fn new(geometry: MarkerGeometry) -> Arc<Self> {
        Arc::new(Self { geometry, state: Mutex::new(State::default()), changed: Condvar::new() })
    }

    /// Where to read the 20 luma bytes in a `width` by `height` picture.
    pub fn marker_points(&self, width: u32, height: u32) -> Vec<MarkerPoint> {
        points(self.geometry, width, height)
    }

    /// One decoded picture: its luma at `marker_points`, when it was decoded and when it is (or
    /// will be) presented, on `key_to_frame_clock_us`. Returns the counter it shows.
    pub fn frame(
        &self,
        width: u32,
        height: u32,
        lumas: Vec<u8>,
        decoded_us: u64,
        presented_us: u64,
    ) -> Option<u16> {
        let value = read_marker(&lumas)?;
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        state.size = (width, height);
        if state.current != Some(value) {
            state.current = Some(value);
            if let Some((_, expected)) = state.pending
                && expected == value
                && state.closed.is_none()
            {
                state.closed = Some((decoded_us, presented_us));
            }
            self.changed.notify_all();
        }
        Some(value)
    }

    /// Runs `samples` inputs (`mode` `key` or `click`) through `input`, then writes probe.json and
    /// samples.jsonl into `out_dir` and returns probe.json's text. Blocks: call it off the main
    /// thread. `meta` (a JSON object: viewer, path, host, rev, ...) is copied into probe.json.
    pub fn run(
        &self,
        input: Arc<dyn KeyToFrameInput>,
        mode: String,
        samples: u32,
        out_dir: String,
        meta_json: String,
    ) -> Result<String, CmuxMobileError> {
        if mode != "key" && mode != "click" {
            return Err(CmuxMobileError::InvalidArgument { message: format!("mode {mode} is key or click") });
        }
        let first = self.wait_value(None, FIRST_MARKER);
        if first.is_none() {
            return Err(CmuxMobileError::Transport {
                message: "no marker in the picture within 15 s".into(),
            });
        }
        let pad = self.pad();
        // The marker window is not key when the rig starts it: one click on its pad first (it
        // bumps the counter too), as screen-share-vs.py does before timing keys.
        if mode == "key" {
            let _ = self.once(&*input, "click", pad);
        }
        let mut got = Vec::new();
        let mut lost = 0u32;
        let mut rng = clock_us() | 1;
        while got.len() as u32 + lost < samples {
            let before = self.state.lock().unwrap_or_else(PoisonError::into_inner).current;
            match self.once(&*input, &mode, pad) {
                Some(sample) => got.push(sample),
                None => {
                    lost += 1;
                    // A late frame of the lost input must not close the next one: let it land.
                    let _ = self.wait_value(before, LOST_AFTER);
                }
            }
            rng ^= rng << 13;
            rng ^= rng >> 7;
            rng ^= rng << 17;
            std::thread::sleep(Duration::from_millis(40 + rng % 121));
        }
        let meta: serde_json::Value =
            serde_json::from_str(&meta_json).unwrap_or_else(|_| serde_json::json!({}));
        let probe = report(&got, lost, &mode, &meta);
        let text = probe.to_string();
        let dir = Path::new(&out_dir);
        let io = |e: std::io::Error| CmuxMobileError::Transport { message: format!("{out_dir}: {e}") };
        fs::create_dir_all(dir).map_err(io)?;
        fs::write(dir.join("probe.json"), &text).map_err(io)?;
        let lines: String = got
            .iter()
            .map(|s| {
                format!(
                    "{}\n",
                    serde_json::json!({"sent_us": s.sent_us, "decoded_us": s.decoded_us, "presented_us": s.presented_us})
                )
            })
            .collect();
        fs::write(dir.join("samples.jsonl"), lines).map_err(io)?;
        Ok(text)
    }
}

impl KeyToFrameProbe {
    /// The marker's click pad (cells 20 to 23, never read) in picture pixels.
    fn pad(&self) -> (u32, u32) {
        let (w, h) = self.state.lock().unwrap_or_else(PoisonError::into_inner).size;
        let cell = self.geometry.cell_fraction * f64::from(w);
        (clamp_px(22.0 * cell, w), clamp_px(self.geometry.origin_y * f64::from(h) + cell / 2.0, h))
    }

    /// Waits until the marker shows something other than `not`; the value, or None at `limit`.
    fn wait_value(&self, not: Option<u16>, limit: Duration) -> Option<u16> {
        let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let (state, _) = self
            .changed
            .wait_timeout_while(state, limit, |s| s.current.is_none() || s.current == not)
            .unwrap_or_else(PoisonError::into_inner);
        state.current.filter(|v| Some(*v) != not)
    }

    /// One input and the frame that shows it, or None when it never came within LOST_AFTER.
    fn once(&self, input: &dyn KeyToFrameInput, mode: &str, pad: (u32, u32)) -> Option<Sample> {
        let sent_us = {
            let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            let expected = state.current?.wrapping_add(1);
            let sent = clock_us();
            state.pending = Some((sent, expected));
            state.closed = None;
            sent
        };
        if mode == "key" {
            input.key();
        } else {
            input.click(pad.0, pad.1);
        }
        let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let (mut state, _) = self
            .changed
            .wait_timeout_while(state, LOST_AFTER, |s| s.closed.is_none())
            .unwrap_or_else(PoisonError::into_inner);
        state.pending = None;
        let (decoded_us, presented_us) = state.closed.take()?;
        Some(Sample { sent_us, decoded_us, presented_us })
    }
}

/// Nearest-rank percentiles of milliseconds, as RdMarkerClickLatencyTests and screen-share-vs.py.
fn cell(mut ms: Vec<f64>) -> serde_json::Value {
    if ms.is_empty() {
        return serde_json::json!({"null": "no samples"});
    }
    ms.sort_by(f64::total_cmp);
    let q = |p: f64| ms.get(((p * (ms.len() - 1) as f64).round()) as usize).copied().unwrap_or(f64::NAN);
    let r = |v: f64| (v * 100.0).round() / 100.0;
    serde_json::json!({
        "n": ms.len(), "min": r(q(0.0)), "p50": r(q(0.5)), "p95": r(q(0.95)), "max": r(q(1.0)),
    })
}

fn ms(from: u64, to: u64) -> f64 {
    to.saturating_sub(from) as f64 / 1000.0
}

/// probe.json: the numbers, the goal's targets, and a budget record screen_share_fast_receipt.py
/// extract reads (its Total row ends at the presented frame).
pub fn report(samples: &[Sample], lost: u32, mode: &str, meta: &serde_json::Value) -> serde_json::Value {
    let presented = cell(samples.iter().map(|s| ms(s.sent_us, s.presented_us)).collect());
    let decoded = cell(samples.iter().map(|s| ms(s.sent_us, s.decoded_us)).collect());
    let present = cell(samples.iter().map(|s| ms(s.decoded_us, s.presented_us)).collect());
    let mut total = presented.clone();
    let mut stage = present.clone();
    if let Some(row) = total.as_object_mut() {
        row.insert("source".into(), SOURCE.into());
        row.insert("to".into(), "presented".into());
    }
    if let Some(row) = stage.as_object_mut() {
        row.insert("source".into(), SOURCE.into());
    }
    let pass = presented.get("p50").and_then(serde_json::Value::as_f64).is_some_and(|v| v <= TARGET_P50_MS)
        && presented.get("p95").and_then(serde_json::Value::as_f64).is_some_and(|v| v <= TARGET_P95_MS);
    serde_json::json!({
        "schema": PROBE_SCHEMA,
        "measure": "phone key to presented frame",
        "input": mode,
        "meta": meta,
        "presented_ms": presented,
        "decoded_ms": decoded,
        "present_stage_ms": present,
        "lost": lost,
        "target": {"p50_ms": TARGET_P50_MS, "p95_ms": TARGET_P95_MS, "met": pass},
        "budget": {
            "schema": BUDGET_SCHEMA,
            "source": SOURCE,
            "rows": [
                {"row": "Total", "cmux": total},
                {"row": "Present", "cmux": stage},
            ],
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lumas(value: u16) -> Vec<u8> {
        (0..16).map(|i| if value >> i & 1 == 1 { 235 } else { 16 }).chain([235, 16, 235, 16]).collect()
    }

    #[test]
    fn the_marker_reads_its_counter_and_refuses_without_guards() {
        assert_eq!(read_marker(&lumas(0x1234)), Some(0x1234));
        let mut bad = lumas(7);
        bad[17] = 235;
        assert_eq!(read_marker(&bad), None);
        assert_eq!(read_marker(&[0; 3]), None);
    }

    #[test]
    fn points_sit_on_cell_centers_inside_the_picture() {
        let p = points(MarkerGeometry { cell_fraction: 32.0 / 1280.0, origin_y: 0.0 }, 1280, 800);
        assert_eq!(p.len(), 20);
        assert_eq!(p[0], MarkerPoint { x: 16, y: 16 });
        assert_eq!(p[19], MarkerPoint { x: 624, y: 16 });
    }

    struct Echo(Arc<KeyToFrameProbe>, Mutex<u16>);
    impl KeyToFrameInput for Echo {
        fn key(&self) {
            let mut v = self.1.lock().unwrap();
            *v = v.wrapping_add(1);
            let now = clock_us();
            let (probe, value) = (Arc::clone(&self.0), *v);
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(5));
                probe.frame(640, 400, lumas(value), now + 4000, now + 8000);
            });
        }
        fn click(&self, _x: u32, _y: u32) {
            self.key();
        }
    }

    #[test]
    fn a_run_matches_each_input_to_its_frame_and_writes_probe_json() {
        let probe = KeyToFrameProbe::new(MarkerGeometry { cell_fraction: 0.05, origin_y: 0.0 });
        probe.frame(640, 400, lumas(41), 1, 1);
        let input = Arc::new(Echo(Arc::clone(&probe), Mutex::new(41)));
        let dir = tempfile::tempdir().unwrap();
        let text = probe
            .run(input, "key".into(), 5, dir.path().to_string_lossy().into_owned(), r#"{"path":"rd"}"#.into())
            .unwrap();
        let v: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(v["schema"], PROBE_SCHEMA);
        assert_eq!(v["presented_ms"]["n"], 5);
        assert_eq!(v["lost"], 0);
        assert_eq!(v["budget"]["rows"][0]["cmux"]["to"], "presented");
        assert!(v["presented_ms"]["p50"].as_f64().unwrap() >= 8.0);
        assert_eq!(fs::read_to_string(dir.path().join("samples.jsonl")).unwrap().lines().count(), 5);
    }

    #[test]
    fn report_takes_nearest_rank_percentiles() {
        let s: Vec<Sample> = (1..=20)
            .map(|i| Sample { sent_us: 0, decoded_us: i * 1000, presented_us: i * 1000 + 500 })
            .collect();
        let v = report(&s, 2, "key", &serde_json::json!({}));
        assert_eq!(v["presented_ms"]["p50"], 11.5);
        assert_eq!(v["presented_ms"]["p95"], 19.5);
        assert_eq!(v["present_stage_ms"]["p95"], 0.5);
        assert_eq!(v["target"]["met"], true);
    }
}
