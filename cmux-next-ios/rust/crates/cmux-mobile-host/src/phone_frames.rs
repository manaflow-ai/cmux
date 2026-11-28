//! `phone-frames` (`phone-frames-v1`): how smoothly the phone drew each terminal scroll.
//!
//! The phone times every display frame of one pan of a terminal (the finger's drag and its
//! fling) and sends the intervals here when the pan ends, one JSON line per pan:
//! `{"kind":"tui"|"scrollback","program"?,"app"?,"expected_ms","intervals_ms":[...],"rows"?,"bytes_in"?,"rtt_ms"?,"painted"?}`.
//! This host turns them into a summary (frames, p50/p95/max frame time, hitches, frames
//! dropped, hitch time per second, and the load it ran under: the page's rows, output bytes per
//! second during the pan, the link's round trip) and appends it, one JSON line, to `phone-frames.jsonl` in
//! hostd's state folder (`~/Library/Application Support/cmux-mobile-host/` unless
//! `CMUX_MOBILE_STATE_DIR` says otherwise), rotating at [`ROTATE_AT`] with one previous file
//! kept, and logs the same summary to hostd's log. An agent on the Mac reads the phone's
//! numbers from there; nothing on the phone is touched.
//!
//! `painted` (ask-0e9bbe35bb), per presented frame `[output bytes parsed, ms before the
//! report]`, adds the Mac output to iPhone paint of the pan's output, on this Mac's clock only
//! (`output_paint.rs`): `output_to_paint_ms` (sent to painted, the report's way back included)
//! and `output_to_paint_less_half_rtt_ms` (less half the round trip), each `{events, p50_ms,
//! p95_ms, max_ms}`, so the link's share and the phone's are separable.
//!
//! Bounded: a channel carries at most [`MAX_PANS`] pans of at most [`MAX_FRAME_BYTES`] each,
//! a pan at most [`MAX_INTERVALS`] intervals. A line that does not parse or is out of range
//! is dropped and logged; the channel goes on. Phones only (`peer.rs`: not offered to machines).

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use cmux_mobile_link::ChannelEvent;
use cmux_mobile_link::link::{ChannelReceiver, ChannelSender};
use serde::{Deserialize, Serialize};

use crate::services::Refusal;

/// The service's name on the link.
pub const SERVICE: &str = "phone-frames";
/// The `version` capability that says this host takes [`SERVICE`].
pub const CAPABILITY: &str = "phone-frames-v1";
/// Most pans one channel may carry.
pub const MAX_PANS: usize = 16;
/// Largest pan line.
pub const MAX_FRAME_BYTES: usize = 64 * 1024;
/// Most frame intervals in one pan (the phone stops recording at 1800).
pub const MAX_INTERVALS: usize = 4096;
/// The log's size bound before it rotates (two files, so twice this on disk).
pub const ROTATE_AT: u64 = 1024 * 1024;

/// One pan as the phone sends it.
#[derive(Debug, Clone, Deserialize)]
pub struct Pan {
    /// `tui` (a full-screen app scrolled by wheel events) or `scrollback` (the page itself).
    pub kind: String,
    /// The program the terminal runs (`claude`, `zsh`).
    #[serde(default)]
    pub program: Option<String>,
    /// The phone app's version and build.
    #[serde(default)]
    pub app: Option<String>,
    /// The display's nominal frame interval (ms): 8.33 at 120 Hz, 16.67 at 60 Hz.
    pub expected_ms: f64,
    /// Every interval between consecutive frames of the pan (ms, in order).
    pub intervals_ms: Vec<f64>,
    /// The load it ran under: rows the page held when the pan began,
    #[serde(default)]
    pub rows: Option<u64>,
    /// terminal output bytes that arrived during the pan,
    #[serde(default)]
    pub bytes_in: Option<u64>,
    /// and the link's last measured round trip (ms).
    #[serde(default)]
    pub rtt_ms: Option<u64>,
    /// Each presented frame of the pan: `[output bytes its terminal had parsed, ms before the
    /// phone sent this line]` (at most [`MAX_INTERVALS`]).
    #[serde(default)]
    pub painted: Option<Vec<[f64; 2]>>,
}

/// One column of `output_to_paint_*` in `phone-frames.jsonl`.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct OutputToPaint {
    /// Output events timed.
    pub events: usize,
    pub p50_ms: f64,
    pub p95_ms: f64,
    pub max_ms: f64,
}

impl From<crate::output_paint::Column> for OutputToPaint {
    fn from(c: crate::output_paint::Column) -> Self {
        Self { events: c.events, p50_ms: c.p50_ms, p95_ms: c.p95_ms, max_ms: c.max_ms }
    }
}

/// What one pan came to: one line of `phone-frames.jsonl`.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Summary {
    /// Epoch milliseconds when this host received it.
    pub at_ms: i64,
    /// The phone's device id (backend-stamped).
    pub phone: String,
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub program: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app: Option<String>,
    /// Intervals counted.
    pub frames: usize,
    pub expected_ms: f64,
    pub p50_ms: f64,
    pub p95_ms: f64,
    pub max_ms: f64,
    /// Intervals longer than 1.5 display frames: at least one frame missed.
    pub hitches: usize,
    /// Frames the display skipped in all (an interval of n frames skips n - 1).
    pub dropped: usize,
    /// The pan's length (ms).
    pub duration_ms: f64,
    /// Time spent late per second of motion (ms/s), Apple's hitch time ratio.
    pub hitch_ms_per_s: f64,
    /// The load the pan ran under (absent from a phone that does not say): the page's rows,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rows: Option<u64>,
    /// the output bytes during the pan and their rate,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bytes_in: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bytes_per_s: Option<u64>,
    /// and the link's round trip (ms),
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rtt_ms: Option<u64>,
    /// on the link's route (`direct-lan`, `direct-wan`, `direct`, `relay`, `none`: hostd's own
    /// [`cmux_mobile_link::dial::route_name`], never the phone's word).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<&'static str>,
    /// Mac output to iPhone paint of the pan's output (`output_paint.rs`): sent to painted,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub output_to_paint_ms: Option<OutputToPaint>,
    /// and the same less half the link's round trip (the phone's share).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub output_to_paint_less_half_rtt_ms: Option<OutputToPaint>,
}

/// Why a pan line was dropped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Invalid {
    Json,
    Kind,
    Expected,
    Intervals,
}

/// The summary of `pan` from phone `phone` at `at_ms`, or why it is not one.
pub fn summarize(pan: Pan, phone: &str, at_ms: i64) -> Result<Summary, Invalid> {
    summarize_painted(pan, phone, at_ms).map(|(summary, _)| summary)
}

/// [`summarize`], and the pan's `painted` frames, checked.
fn summarize_painted(pan: Pan, phone: &str, at_ms: i64) -> Result<(Summary, Vec<[f64; 2]>), Invalid> {
    if !matches!(pan.kind.as_str(), "tui" | "scrollback") {
        return Err(Invalid::Kind);
    }
    let expected = pan.expected_ms;
    if !expected.is_finite() || !(1.0..=50.0).contains(&expected) {
        return Err(Invalid::Expected);
    }
    let painted = pan.painted.unwrap_or_default();
    if painted.len() > MAX_INTERVALS || painted.iter().flatten().any(|v| !v.is_finite() || *v < 0.0) {
        return Err(Invalid::Intervals);
    }
    let mut sorted = pan.intervals_ms;
    if sorted.is_empty()
        || sorted.len() > MAX_INTERVALS
        || sorted.iter().any(|v| !v.is_finite() || *v <= 0.0 || *v > 10_000.0)
    {
        return Err(Invalid::Intervals);
    }
    let budget = expected * 1.5;
    let (mut hitches, mut dropped, mut late, mut duration) = (0usize, 0usize, 0.0f64, 0.0f64);
    for &interval in &sorted {
        duration += interval;
        if interval > budget {
            hitches += 1;
            dropped += ((interval / expected).round() as usize).saturating_sub(1);
            late += interval - expected;
        }
    }
    sorted.sort_by(f64::total_cmp);
    let round = |v: f64| (v * 100.0).round() / 100.0;
    Ok::<_, Invalid>(Summary {
        at_ms,
        phone: phone.to_owned(),
        kind: pan.kind,
        program: pan.program.map(|p| label(&p)).filter(|p| !p.is_empty()),
        app: pan.app.map(|a| label(&a)).filter(|a| !a.is_empty()),
        frames: sorted.len(),
        expected_ms: round(expected),
        p50_ms: round(percentile(&sorted, 0.5)),
        p95_ms: round(percentile(&sorted, 0.95)),
        max_ms: round(*sorted.last().unwrap_or(&0.0)),
        hitches,
        dropped,
        duration_ms: round(duration),
        hitch_ms_per_s: if duration > 0.0 { round(late / (duration / 1000.0)) } else { 0.0 },
        rows: pan.rows,
        bytes_in: pan.bytes_in,
        bytes_per_s: pan
            .bytes_in
            .filter(|_| duration > 0.0)
            .map(|b| (b as f64 / (duration / 1000.0)).round() as u64),
        rtt_ms: pan.rtt_ms,
        path: None,
        output_to_paint_ms: None,
        output_to_paint_less_half_rtt_ms: None,
    })
    .map(|summary| (summary, painted))
}

/// The pan's [`Summary`] with its output-to-paint, timed against what this host sent `phone`
/// (`painted` as the phone sent it, the line received at `received_us`, this host's clock).
pub fn with_output_to_paint(mut summary: Summary, painted: &[[f64; 2]], received_us: u64) -> Summary {
    let painted: Vec<(u64, f64)> = painted.iter().map(|[bytes, age]| (*bytes as u64, *age)).collect();
    let half_rtt = summary.rtt_ms.map(|rtt| rtt as f64 / 2.0);
    if let Some(window) = crate::output_paint::window_for(&summary.phone, &painted, received_us, half_rtt) {
        summary.output_to_paint_ms = Some(window.raw.into());
        summary.output_to_paint_less_half_rtt_ms = window.less_half_rtt.map(Into::into);
    }
    summary
}

/// Nearest-rank percentile of sorted values (the phone's `TerminalFrameStats.percentile`).
pub fn percentile(sorted: &[f64], p: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let rank = (p * sorted.len() as f64).ceil() as usize;
    sorted[rank.clamp(1, sorted.len()) - 1]
}

/// A name from the phone, safe for a log line: control characters become spaces, at most 64.
pub(crate) fn label(text: &str) -> String {
    text.chars().map(|c| if c.is_control() { ' ' } else { c }).take(64).collect::<String>().trim().to_owned()
}

/// Where summaries go: `phone-frames.jsonl` in hostd's state folder.
pub fn default_path() -> PathBuf {
    crate::config::default_state_dir().join("phone-frames.jsonl")
}

/// One writer at a time, so two phones' pans never rotate the file under each other.
static WRITE: Mutex<()> = Mutex::new(());

/// Records one pan line from `phone`: the summary to `path` and to hostd's log.
pub fn record(line: &[u8], phone: &str, path: &Path) -> Result<Summary, Invalid> {
    record_on(line, phone, path, None)
}

/// [`record`], on the link route `route` ([`Summary::path`]).
pub fn record_on(
    line: &[u8],
    phone: &str,
    path: &Path,
    route: Option<&'static str>,
) -> Result<Summary, Invalid> {
    let received_us = crate::output_paint::now_us();
    let pan: Pan = serde_json::from_slice(line).map_err(|_| Invalid::Json)?;
    let (summary, painted) = summarize_painted(pan, phone, crate::activity::now_ms())?;
    let mut summary = with_output_to_paint(summary, &painted, received_us);
    summary.path = route;
    tracing::info!(
        phone,
        kind = summary.kind.as_str(),
        program = summary.program.as_deref().unwrap_or("-"),
        frames = summary.frames,
        p50_ms = summary.p50_ms,
        p95_ms = summary.p95_ms,
        max_ms = summary.max_ms,
        hitches = summary.hitches,
        hitch_ms_per_s = summary.hitch_ms_per_s,
        rows = summary.rows,
        bytes_per_s = summary.bytes_per_s,
        rtt_ms = summary.rtt_ms,
        route = summary.path.unwrap_or("-"),
        output_to_paint_p95_ms = summary.output_to_paint_ms.map(|c| c.p95_ms),
        output_to_paint_less_half_rtt_p95_ms = summary.output_to_paint_less_half_rtt_ms.map(|c| c.p95_ms),
        "phone frames"
    );
    let _guard = WRITE.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Err(error) = crate::activity::append(path, &summary, ROTATE_AT) {
        tracing::warn!(path = %path.display(), %error, "could not write phone frames");
    }
    Ok(summary)
}

/// Clock probes one `phone-frames` channel answers (the phone sends a handful per report).
pub const MAX_CLOCK_PROBES: usize = 32;

pub use crate::paint_latency::Line;

/// Records one paint report from `phone`, joined with hostd's stamps, to `path`.
pub fn record_paint(
    line: &[u8],
    phone: &str,
    path: &Path,
    route: Option<&'static str>,
) -> Result<crate::paint_latency::Summary, Invalid> {
    let mut report: crate::paint_latency::Report = serde_json::from_slice(line).map_err(|_| Invalid::Json)?;
    report.samples.truncate(crate::paint_latency::MAX_SAMPLES);
    let mut summary = crate::paint_latency::summarize(
        report,
        phone,
        crate::activity::now_ms(),
        crate::paint_latency::lookup,
    );
    summary.path = route;
    let part = |p: &Option<crate::paint_latency::Part>| p.map(|p| format!("{}/{}", p.p50_ms, p.p95_ms));
    tracing::info!(
        phone,
        samples = summary.samples,
        joined = summary.joined,
        offset_ms = summary.offset_ms,
        route = summary.path.unwrap_or("-"),
        rtt_ms = summary.rtt_ms,
        agent_cli_hybrid = summary.agent_cli_hybrid,
        mac_p50_p95 = part(&summary.mac).as_deref().unwrap_or("-"),
        wire_p50_p95 = part(&summary.wire).as_deref().unwrap_or("-"),
        phone_p50_p95 = part(&summary.phone_paint).as_deref().unwrap_or("-"),
        total_p50_p95 = part(&summary.total).as_deref().unwrap_or("-"),
        transports = ?summary.transports,
        "phone paint"
    );
    let _guard = WRITE.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Err(error) = crate::activity::append(path, &summary, ROTATE_AT) {
        tracing::warn!(path = %path.display(), %error, "could not write phone paint");
    }
    Ok(summary)
}

/// How long a paint summary waits for room in the phone's channel queue before it is dropped.
pub const PAINT_ANSWER_WAIT: std::time::Duration = std::time::Duration::from_millis(250);

/// The `phone-frames` service: reads pan lines until the phone closes or [`MAX_PANS`] came.
pub async fn serve(
    phone: &str,
    path: &Path,
    sender: &ChannelSender,
    receiver: ChannelReceiver,
) -> Result<(), Refusal> {
    serve_on(phone, path, &|| None, sender, receiver).await
}

/// [`serve`], each record tagged with the link's route as `route` reads it then.
pub async fn serve_on(
    phone: &str,
    path: &Path,
    route: &(dyn Fn() -> Option<&'static str> + Send + Sync),
    sender: &ChannelSender,
    mut receiver: ChannelReceiver,
) -> Result<(), Refusal> {
    let mut clocks = 0;
    for _ in 0..MAX_PANS + MAX_CLOCK_PROBES {
        match receiver.recv().await {
            Some(ChannelEvent::Data(bytes)) => {
                if bytes.len() > MAX_FRAME_BYTES {
                    return Err(Refusal::new(
                        "too_large",
                        format!("a pan line is at most {MAX_FRAME_BYTES} bytes"),
                    ));
                }
                match crate::paint_latency::kind_of(&bytes) {
                    Some(Line::Clock(t0)) if clocks < MAX_CLOCK_PROBES => {
                        clocks += 1;
                        let t1 = cmux_mobile_link::frame::epoch_us() as f64 / 1000.0;
                        let answer = crate::paint_latency::clock_answer(t0, t1);
                        if sender.send(bytes::Bytes::from(answer)).await.is_err() {
                            return Ok(());
                        }
                    }
                    Some(Line::Clock(_)) => {}
                    Some(Line::Paint) => match record_paint(&bytes, phone, path, route()) {
                        // The join goes back to the phone (its DEBUG overlay); a phone that
                        // closed after its report never reads it, and that is not an error.
                        // A phone whose queue is full (a stalled link) gets no answer after
                        // [`PAINT_ANSWER_WAIT`]: the overlay is advisory, and this loop must
                        // keep reading the next probe or pan line, not wait on the phone.
                        Ok(summary) => {
                            let answer = sender.send(bytes::Bytes::from(summary.answer()));
                            if tokio::time::timeout(PAINT_ANSWER_WAIT, answer).await.is_err() {
                                tracing::info!(phone, "paint summary not sent: phone queue full");
                            }
                        }
                        Err(why) => tracing::info!(phone, ?why, "phone paint dropped"),
                    },
                    None => {
                        if let Err(why) = record_on(&bytes, phone, path, route()) {
                            tracing::info!(phone, ?why, "phone frames dropped");
                        }
                    }
                }
            }
            Some(ChannelEvent::Closed(_)) | None => return Ok(()),
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pan(intervals: Vec<f64>) -> Pan {
        Pan {
            kind: "tui".into(),
            program: Some("claude\n".into()),
            app: Some("1.0 (7)".into()),
            expected_ms: 8.33,
            intervals_ms: intervals,
            rows: None,
            bytes_in: None,
            rtt_ms: None,
            painted: None,
        }
    }

    #[test]
    fn a_smooth_pan_has_no_hitches() {
        let s = summarize(pan(vec![8.33; 120]), "phone-1", 5).unwrap();
        assert_eq!((s.frames, s.hitches, s.dropped), (120, 0, 0));
        assert_eq!((s.p50_ms, s.p95_ms, s.max_ms), (8.33, 8.33, 8.33));
        assert_eq!(s.hitch_ms_per_s, 0.0);
        assert_eq!(s.program.as_deref(), Some("claude"), "control characters go");
        assert_eq!(s.duration_ms, 999.6);
        assert_eq!((s.rows, s.bytes_per_s, s.rtt_ms), (None, None, None), "an older phone says no load");
    }

    #[test]
    fn late_frames_count_as_hitches_and_drops() {
        // 96 on time, then a 2-frame and a 4-frame interval, then two on time.
        let mut intervals = vec![8.33; 96];
        intervals.extend([16.67, 33.33, 8.33, 8.33]);
        let s = summarize(pan(intervals), "phone-1", 5).unwrap();
        assert_eq!(s.frames, 100);
        assert_eq!(s.hitches, 2);
        assert_eq!(s.dropped, 1 + 3);
        assert_eq!(s.max_ms, 33.33);
        assert_eq!(s.p50_ms, 8.33);
        assert_eq!(s.p95_ms, 8.33);
        assert!(s.hitch_ms_per_s > 30.0 && s.hitch_ms_per_s < 40.0, "{}", s.hitch_ms_per_s);
    }

    #[test]
    fn percentiles_are_nearest_rank_like_the_phone() {
        assert_eq!(percentile(&[1.0, 2.0, 3.0, 4.0], 0.5), 2.0);
        assert_eq!(percentile(&[1.0, 2.0, 3.0, 4.0], 0.95), 4.0);
        assert_eq!(percentile(&[], 0.5), 0.0);
    }

    #[test]
    fn out_of_range_pans_are_refused() {
        let mut bad = pan(vec![8.0]);
        bad.kind = "feed".into();
        assert_eq!(summarize(bad, "p", 0), Err(Invalid::Kind));
        let mut bad = pan(vec![8.0]);
        bad.expected_ms = 0.0;
        assert_eq!(summarize(bad, "p", 0), Err(Invalid::Expected));
        assert_eq!(summarize(pan(vec![]), "p", 0), Err(Invalid::Intervals));
        assert_eq!(summarize(pan(vec![8.0, -1.0]), "p", 0), Err(Invalid::Intervals));
        assert_eq!(summarize(pan(vec![8.0, f64::NAN]), "p", 0), Err(Invalid::Intervals));
        assert_eq!(summarize(pan(vec![8.0; MAX_INTERVALS + 1]), "p", 0), Err(Invalid::Intervals));
    }

    #[test]
    fn a_pan_line_lands_as_one_json_line() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("phone-frames.jsonl");
        let line = br#"{"kind":"scrollback","program":"zsh","expected_ms":16.67,"intervals_ms":[16.6,16.7,50.1],"rows":12000,"bytes_in":8340,"rtt_ms":41}"#;
        record(line, "phone-1", &path).unwrap();
        assert_eq!(record(b"not json", "phone-1", &path), Err(Invalid::Json));
        let text = std::fs::read_to_string(&path).unwrap();
        let rows: Vec<serde_json::Value> = text.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["phone"], "phone-1");
        assert_eq!(rows[0]["kind"], "scrollback");
        assert_eq!(rows[0]["frames"], 3);
        assert_eq!(rows[0]["hitches"], 1);
        assert_eq!(rows[0]["dropped"], 2);
        assert_eq!(rows[0]["max_ms"], 50.1);
        assert!(rows[0].get("app").is_none());
        // The load it ran under: 8340 bytes over 83.4 ms is 100 000 bytes/s.
        assert_eq!(rows[0]["rows"], 12000);
        assert_eq!(rows[0]["bytes_in"], 8340);
        assert_eq!(rows[0]["bytes_per_s"], 100_000);
        assert_eq!(rows[0]["rtt_ms"], 41);
        assert!(rows[0].get("path").is_none(), "off a dialed link no route is claimed");
        assert!(rows[0].get("output_to_paint_ms").is_none(), "no painted frames, no column");
    }

    #[test]
    fn a_record_carries_the_route_hostd_read_not_one_the_phone_sent() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("phone-frames.jsonl");
        let pan = br#"{"kind":"tui","expected_ms":16.67,"intervals_ms":[16.6],"rtt_ms":3,"path":"relay"}"#;
        record_on(pan, "phone-1", &path, Some("direct-lan")).unwrap();
        let paint = br#"{"kind":"paint","samples":[],"clock":[],"path":"relay"}"#;
        record_paint(paint, "phone-1", &path, Some("direct-wan")).unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        let rows: Vec<serde_json::Value> = text.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
        assert_eq!(rows[0]["path"], "direct-lan");
        assert_eq!(rows[0]["rtt_ms"], 3);
        assert_eq!(rows[1]["path"], "direct-wan");
    }

    #[test]
    fn painted_frames_add_output_to_paint_and_its_link_free_column() {
        use base64::Engine as _;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("phone-frames.jsonl");
        let phone = "phone-frames-output-paint";
        let stamps = crate::output_paint::Tracker::start(phone);
        // Two output events of 100 bytes each, sent now.
        let data = base64::engine::general_purpose::STANDARD.encode([b'x'; 100]);
        let line = format!(r#"{{"event":"output","surface":1,"data":"{data}"}}"#);
        stamps.line(line.as_bytes());
        stamps.line(line.as_bytes());
        // Painted through 0, then 100, then 200 bytes, the last frame 0 ms before the report.
        let pan = br#"{"kind":"scrollback","expected_ms":16.67,"intervals_ms":[16.6,16.7,16.7,16.6],"rtt_ms":40,"painted":[[0,0],[100,0],[200,0]]}"#;
        let summary = record(pan, phone, &path).unwrap();
        let raw = summary.output_to_paint_ms.expect("timed");
        assert_eq!(raw.events, 2);
        assert!(raw.max_ms >= 0.0 && raw.max_ms < 5_000.0, "{raw:?}");
        let less = summary.output_to_paint_less_half_rtt_ms.expect("rtt known");
        assert!(less.max_ms <= raw.max_ms);
        let text = std::fs::read_to_string(&path).unwrap();
        let row: serde_json::Value = serde_json::from_str(text.lines().next().unwrap()).unwrap();
        assert_eq!(row["output_to_paint_ms"]["events"], 2);
        assert!(row["output_to_paint_less_half_rtt_ms"]["p95_ms"].is_number());
        let bad = br#"{"kind":"tui","expected_ms":8.33,"intervals_ms":[8.3],"painted":[[1,-1]]}"#;
        assert_eq!(record(bad, phone, &path), Err(Invalid::Intervals));
    }
}
