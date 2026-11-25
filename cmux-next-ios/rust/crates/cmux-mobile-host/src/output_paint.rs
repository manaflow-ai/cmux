//! Mac output to phone paint (ask-0e9bbe35bb), on this Mac's clock only.
//!
//! Every phone terminal is its own `daemon` channel (`services.rs` `splice`). While one is open,
//! a [`Tracker`] stamps each attach line it forwards to the phone with this host's clock and the
//! output bytes the phone's terminal will parse from it ([`output_bytes`]: an `output` event's
//! data, a `vt-state` or a new-grid `resized` replay and its pending sequence), into a bounded
//! [`SendStamps`] ring. The phone's pan report (`phone_frames.rs`) says, for every frame it
//! presented, the output bytes its terminal had parsed and how long before the report that was;
//! [`window_for`] places those frames on this clock and times each output event to the first
//! frame that showed it ([`cmux_output_paint::window`]).
//!
//! Bounded: one ring of [`cmux_output_paint::RING`] events per open channel, at most
//! [`MAX_VIEWERS`] channels per phone (the oldest falls off); a closed channel's ring goes.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

pub use cmux_output_paint::{Column, Paint, SendStamps, Window};
use serde_json::Value;

/// Most open terminal channels one phone's stamps are kept for.
pub const MAX_VIEWERS: usize = 32;

/// This host's monotonic clock (µs since its first use).
pub fn now_us() -> u64 {
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_micros() as u64
}

#[derive(Default)]
struct Viewer {
    stamps: SendStamps,
    /// The grid the phone's mirror holds: a `resized` at it is not replayed (the phone keeps
    /// its screen, `DaemonTerminalEvents.swift` `sameGridResize`).
    grid: Option<(u64, u64)>,
    last_us: u64,
}

type Viewers = HashMap<String, Vec<(u64, Arc<Mutex<Viewer>>)>>;

fn viewers() -> &'static Mutex<Viewers> {
    static VIEWERS: OnceLock<Mutex<Viewers>> = OnceLock::new();
    VIEWERS.get_or_init(Mutex::default)
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// One open terminal channel's stamps; dropping it forgets them.
pub struct Tracker {
    phone: String,
    id: u64,
    viewer: Arc<Mutex<Viewer>>,
}

impl Tracker {
    /// Starts stamping a channel of `phone`.
    pub fn start(phone: &str) -> Self {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
        let id = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let viewer = Arc::new(Mutex::new(Viewer::default()));
        let mut all = lock(viewers());
        let list = all.entry(phone.to_owned()).or_default();
        if list.len() >= MAX_VIEWERS {
            list.remove(0);
        }
        list.push((id, Arc::clone(&viewer)));
        Self { phone: phone.to_owned(), id, viewer }
    }

    /// The phone is sent `line` now.
    pub fn line(&self, line: &[u8]) {
        self.line_at(line, now_us());
    }

    fn line_at(&self, line: &[u8], at_us: u64) {
        let mut viewer = lock(&self.viewer);
        let bytes = output_bytes(line, &mut viewer.grid);
        if bytes > 0 {
            viewer.stamps.sent(bytes, at_us);
            viewer.last_us = at_us;
        }
    }
}

impl Drop for Tracker {
    fn drop(&mut self) {
        let mut all = lock(viewers());
        if let Some(list) = all.get_mut(&self.phone) {
            list.retain(|(id, _)| *id != self.id);
            if list.is_empty() {
                all.remove(&self.phone);
            }
        }
    }
}

/// The output bytes the phone's terminal parses from one attach line (0 for any other line).
/// Only lines that start like the daemon writes these events are read as JSON.
pub fn output_bytes(line: &[u8], grid: &mut Option<(u64, u64)>) -> u64 {
    const OUTPUT: &[u8] = b"{\"event\":\"output\"";
    const VT_STATE: &[u8] = b"{\"event\":\"vt-state\"";
    const RESIZED: &[u8] = b"{\"event\":\"resized\"";
    if !(line.starts_with(OUTPUT) || line.starts_with(VT_STATE) || line.starts_with(RESIZED)) {
        return 0;
    }
    let Ok(value) = serde_json::from_slice::<Value>(line) else { return 0 };
    let len = |key: &str| {
        value.get(key).and_then(Value::as_str).map_or(0, |text| {
            let padding = text.bytes().rev().take_while(|b| *b == b'=').count();
            cmux_output_paint::base64_decoded_len(text.len(), padding)
        })
    };
    let size = || Some((value.get("cols")?.as_u64()?, value.get("rows")?.as_u64()?));
    match value.get("event").and_then(Value::as_str) {
        Some("output") => len("data"),
        Some("vt-state") => {
            *grid = size().or(*grid);
            len("data") + len("pending")
        }
        Some("resized") => {
            if let Some(at) = size()
                && *grid == Some(at)
            {
                return 0;
            }
            *grid = size().or(*grid);
            let replay = if value.get("replay").is_some() { len("replay") } else { len("data") };
            replay + len("pending")
        }
        _ => 0,
    }
}

/// The output-to-paint of a pan `phone` reported at `received_us`: `painted` is each
/// presented frame's `(parsed output bytes, ms before the report)`. The channel it is timed
/// against: the phone's most recently sent-to one that sent at least the bytes the pan last
/// painted, else its most recent one (a count that ran ahead is clamped, [`Window::ahead`]).
pub fn window_for(
    phone: &str,
    painted: &[(u64, f64)],
    received_us: u64,
    half_rtt_ms: Option<f64>,
) -> Option<Window> {
    let last = painted.iter().map(|(through, _)| *through).max()?;
    let candidates: Vec<Arc<Mutex<Viewer>>> =
        lock(viewers()).get(phone)?.iter().map(|(_, viewer)| Arc::clone(viewer)).collect();
    let mut best: Option<(bool, u64, Arc<Mutex<Viewer>>)> = None;
    for viewer in candidates {
        let (covers, last_us) = {
            let v = lock(&viewer);
            (v.stamps.offset() >= last, v.last_us)
        };
        if best.as_ref().is_none_or(|(c, at, _)| (covers, last_us) > (*c, *at)) {
            best = Some((covers, last_us, viewer));
        }
    }
    let (_, _, viewer) = best?;
    let paints: Vec<Paint> =
        painted.iter().map(|&(through, age)| Paint::reported(through, age, received_us)).collect();
    let viewer = lock(&viewer);
    cmux_output_paint::window(&viewer.stamps, &paints, half_rtt_ms)
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine as _;

    fn b64(bytes: &[u8]) -> String {
        base64::engine::general_purpose::STANDARD.encode(bytes)
    }

    #[test]
    fn only_what_the_phone_parses_is_counted() {
        let mut grid = None;
        let vt = format!(
            r#"{{"event":"vt-state","surface":1,"cols":80,"rows":24,"data":"{}","pending":"{}"}}"#,
            b64(b"hello"),
            b64(b"\x1b[")
        );
        assert_eq!(output_bytes(vt.as_bytes(), &mut grid), 7);
        assert_eq!(grid, Some((80, 24)));
        let out = format!(r#"{{"event":"output","surface":1,"data":"{}"}}"#, b64(b"abcd"));
        assert_eq!(output_bytes(out.as_bytes(), &mut grid), 4);
        // A resize at the grid the mirror holds is not replayed; at another it is.
        let same =
            format!(r#"{{"event":"resized","surface":1,"cols":80,"rows":24,"replay":"{}"}}"#, b64(b"xyz"));
        assert_eq!(output_bytes(same.as_bytes(), &mut grid), 0);
        let other =
            format!(r#"{{"event":"resized","surface":1,"cols":100,"rows":24,"replay":"{}"}}"#, b64(b"xyz"));
        assert_eq!(output_bytes(other.as_bytes(), &mut grid), 3);
        assert_eq!(output_bytes(br#"{"id":1,"ok":true}"#, &mut grid), 0);
        assert_eq!(output_bytes(br#"{"event":"agent-cli-lean","f":"AAAA"}"#, &mut grid), 0);
    }

    #[test]
    fn a_pan_is_timed_against_the_channel_that_sent_its_bytes() {
        let phone = "phone-output-paint-test";
        let quiet = Tracker::start(phone);
        let busy = Tracker::start(phone);
        let out = |bytes: &[u8]| format!(r#"{{"event":"output","surface":1,"data":"{}"}}"#, b64(bytes));
        quiet.line_at(out(b"ab").as_bytes(), 1_000);
        // 10 bytes at 100 ms, 10 more at 110 ms.
        busy.line_at(out(&[b'x'; 10]).as_bytes(), 100_000);
        busy.line_at(out(&[b'y'; 10]).as_bytes(), 110_000);
        // The report came at 200 ms: frames 95, 80 and 70 ms before it (105, 120, 130 ms).
        let painted = [(0, 95.0), (10, 80.0), (20, 70.0)];
        let w = window_for(phone, &painted, 200_000, Some(10.0)).unwrap();
        assert_eq!((w.raw.events, w.raw.p50_ms, w.raw.max_ms), (2, 20.0, 20.0));
        assert_eq!(w.less_half_rtt.unwrap().max_ms, 10.0);
        drop(busy);
        drop(quiet);
        assert!(window_for(phone, &painted, 200_000, None).is_none(), "closed channels are forgotten");
    }
}
