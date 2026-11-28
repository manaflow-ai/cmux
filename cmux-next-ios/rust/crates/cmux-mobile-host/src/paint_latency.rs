//! Mac terminal redraw to iPhone paint, in three parts (Leo, 2026-11-22: "the scroll occurs or
//! whatever on f***ing mac / then it delays on my actual iphone display").
//!
//! - **Stamp** ([`stamp_line`]): every terminal redraw line the daemon sends a phone
//!   (`output`, `agent-cli-frame`, `agent-cli-lean`) gets a sequence id, hostd-wide and
//!   increasing, at the moment hostd reads it from the daemon (`produced`). The id rides the
//!   line as an optional `"pseq": N` (phones that do not know it ignore it), and the line goes
//!   out with a [`FlushMark`] the link writer sets when its last byte is handed to the
//!   transport (`flushed`). Both stamps stay here, in a bounded ring ([`RING`] lines).
//! - **Clock** ([`Clock`]): the phone asks the `phone-frames` channel for the Mac's time
//!   (`{"kind":"clock","t0"}`, answered `{"t0","t1","t2"}`), NTP style; the sample with the
//!   shortest round trip gives the offset (`offset = ((t1 - t0) + (t2 - t3)) / 2`, Mac minus
//!   phone).
//! - **Report** ([`summarize`]): the phone sends `{"kind":"paint","samples":[[seq, rx, paint],
//!   ...],"clock":[[t0,t1,t2,t3],...]}`, its receive time of each stamped line and the present
//!   of the first frame that showed it (its own clock, epoch ms), and this joins them with the
//!   ring: (a) Mac read to handed to the socket, (b) the wire (phone receive minus Mac flush,
//!   offset applied), (c) phone receive to paint, and the total, each p50/p95/max.
//!
//! Costs per redraw line: one atomic id, one clock read, one ring slot (a mutex held for a push)
//! and `,"pseq":N` (at most 21 bytes) on the wire.

use std::collections::VecDeque;
use std::sync::Mutex;

use cmux_mobile_link::frame::{FlushMark, epoch_us};
use serde::{Deserialize, Serialize};

/// Lines whose stamps are kept (about 30 s of a 60 Hz redraw on several terminals).
pub const RING: usize = 8192;
/// Most samples one paint report carries: its line stays in one link frame (16 KiB), since
/// `phone-frames` reads a line per frame.
pub const MAX_SAMPLES: usize = 256;
/// Most clock samples one paint report carries.
pub const MAX_CLOCK: usize = 16;

/// What hostd knows about one stamped line.
#[derive(Debug, Clone)]
pub struct Stamp {
    pub seq: u64,
    /// When hostd read the line from the daemon (epoch µs).
    pub produced_us: i64,
    /// Set when the link handed its last byte to the transport.
    pub flushed: FlushMark,
}

/// The ring of the last [`RING`] stamps, in id order.
#[derive(Debug, Default)]
pub struct Stamps {
    ring: VecDeque<Stamp>,
    next: u64,
}

impl Stamps {
    /// A new stamp at `produced_us`; the oldest goes when the ring is full.
    pub fn push(&mut self, produced_us: i64) -> Stamp {
        self.next += 1;
        let stamp = Stamp { seq: self.next, produced_us, flushed: FlushMark::new() };
        if self.ring.len() == RING {
            self.ring.pop_front();
        }
        self.ring.push_back(stamp.clone());
        stamp
    }

    fn find(&self, seq: u64) -> Option<&Stamp> {
        let first = self.ring.front()?.seq;
        let stamp = self.ring.get(usize::try_from(seq.checked_sub(first)?).ok()?)?;
        (stamp.seq == seq).then_some(stamp)
    }

    /// `(produced, flushed)` of `seq` (epoch µs), while the ring holds it.
    pub fn get(&self, seq: u64) -> Option<(i64, Option<i64>)> {
        self.find(seq).map(|stamp| (stamp.produced_us, stamp.flushed.flushed_us()))
    }

    /// The flush mark of `seq`, for the link writer.
    pub fn mark(&self, seq: u64) -> Option<FlushMark> {
        self.find(seq).map(|stamp| stamp.flushed.clone())
    }
}

static STAMPS: Mutex<Stamps> = Mutex::new(Stamps { ring: VecDeque::new(), next: 0 });

fn stamps() -> std::sync::MutexGuard<'static, Stamps> {
    STAMPS.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// `(produced, flushed)` of `seq` in hostd's ring.
pub fn lookup(seq: u64) -> Option<(i64, Option<i64>)> {
    stamps().get(seq)
}

/// Whether `line` is a terminal redraw event: the daemon's compact JSON names its event once,
/// and base64 holds no quote, so the needle cannot match inside the data.
pub fn is_redraw(line: &[u8]) -> bool {
    const NEEDLES: [&[u8]; 3] =
        [br#""event":"output""#, br#""event":"agent-cli-frame""#, br#""event":"agent-cli-lean""#];
    line.first() == Some(&b'{')
        && NEEDLES.iter().any(|needle| line.windows(needle.len()).any(|w| w == *needle))
}

/// `line` with `"pseq": seq` added before its closing brace (a trailing newline kept).
pub fn with_seq(mut line: Vec<u8>, seq: u64) -> Vec<u8> {
    let newline = line.last() == Some(&b'\n');
    if newline {
        line.pop();
    }
    if line.last() != Some(&b'}') {
        if newline {
            line.push(b'\n');
        }
        return line;
    }
    line.pop();
    line.extend_from_slice(format!(",\"pseq\":{seq}}}").as_bytes());
    if newline {
        line.push(b'\n');
    }
    line
}

/// The id [`with_seq`] put at the end of `line`, if it is there.
pub fn trailing_seq(line: &[u8]) -> Option<u64> {
    const KEY: &[u8] = b",\"pseq\":";
    let body = line.strip_suffix(b"\n").unwrap_or(line).strip_suffix(b"}")?;
    let digits = body.iter().rev().take_while(|b| b.is_ascii_digit()).count();
    if digits == 0 || digits > 20 {
        return None;
    }
    let (head, number) = body.split_at(body.len() - digits);
    head.ends_with(KEY).then(|| std::str::from_utf8(number).ok()?.parse().ok()).flatten()
}

/// The flush mark of the redraw `line` carries, for the writer that hands it to the link.
pub fn flush_mark(line: &[u8]) -> Option<FlushMark> {
    stamps().mark(trailing_seq(line)?)
}

/// A daemon line on its way to a phone: a redraw gets its id and a flush mark, now.
pub fn stamp_line(line: Vec<u8>) -> (Vec<u8>, Option<FlushMark>) {
    if !is_redraw(&line) {
        return (line, None);
    }
    let stamp = stamps().push(epoch_us());
    (with_seq(line, stamp.seq), Some(stamp.flushed))
}

/// One clock sample, epoch ms: the phone sent at `t0`, the Mac received at `t1` and answered
/// at `t2`, the phone received at `t3`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Clock {
    pub t0: f64,
    pub t1: f64,
    pub t2: f64,
    pub t3: f64,
}

impl Clock {
    /// Mac clock minus phone clock (ms), NTP's midpoint.
    pub fn offset_ms(&self) -> f64 {
        ((self.t1 - self.t0) + (self.t2 - self.t3)) / 2.0
    }

    /// The round trip without the Mac's own time (ms).
    pub fn rtt_ms(&self) -> f64 {
        (self.t3 - self.t0) - (self.t2 - self.t1)
    }

    /// The sample with the shortest round trip: the least queueing, the best offset.
    pub fn best(samples: &[Clock]) -> Option<Clock> {
        samples
            .iter()
            .copied()
            .filter(|c| [c.t0, c.t1, c.t2, c.t3].iter().all(|v| v.is_finite()) && c.rtt_ms() >= 0.0)
            .min_by(|a, b| a.rtt_ms().total_cmp(&b.rtt_ms()))
    }
}

/// What a `phone-frames` line is, when it is not a pan.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Line {
    /// A clock probe sent at phone time `t0` (ms).
    Clock(f64),
    /// A paint report.
    Paint,
}

/// Reads the `kind` of a `phone-frames` line: `clock` and `paint` are this module's, anything
/// else is a pan (`None`).
pub fn kind_of(line: &[u8]) -> Option<Line> {
    #[derive(Deserialize)]
    struct Head {
        kind: Option<String>,
        t0: Option<f64>,
    }
    let head: Head = serde_json::from_slice(line).ok()?;
    match head.kind.as_deref()? {
        "clock" => head.t0.filter(|t| t.is_finite()).map(Line::Clock),
        "paint" => Some(Line::Paint),
        _ => None,
    }
}

/// The Mac's answer to a clock probe received at `t1_ms`.
pub fn clock_answer(t0: f64, t1_ms: f64) -> Vec<u8> {
    let t2 = epoch_us() as f64 / 1000.0;
    serde_json::json!({"kind": "clock", "t0": t0, "t1": t1_ms, "t2": t2}).to_string().into_bytes()
}

/// A paint report as the phone sends it.
#[derive(Debug, Clone, Deserialize)]
pub struct Report {
    #[serde(default)]
    pub program: Option<String>,
    #[serde(default)]
    pub app: Option<String>,
    /// `[seq, received, painted]`, phone epoch ms.
    pub samples: Vec<[f64; 3]>,
    /// `[t0, t1, t2, t3]` clock samples, epoch ms.
    #[serde(default)]
    pub clock: Vec<[f64; 4]>,
    /// The link's round trip the phone measured last (ms).
    #[serde(default)]
    pub rtt_ms: Option<u64>,
    /// What the report ran under, when the phone says (a harness's label: `sim`, a profile).
    #[serde(default)]
    pub load: Option<String>,
    /// The phone's Agent CLI Screen Changes setting (lean frames, at most one per 100 ms).
    #[serde(default)]
    pub agent_cli_hybrid: Option<bool>,
    /// Which path painted each sample, in order (`stream` or `datagram`, viewport sync's path
    /// selector); empty when the phone does not say.
    #[serde(default)]
    pub transports: Vec<String>,
}

/// p50, p95 and max of one part (ms), and how many samples.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct Part {
    pub n: usize,
    pub p50_ms: f64,
    pub p95_ms: f64,
    pub max_ms: f64,
}

impl Part {
    pub fn of(mut values: Vec<f64>) -> Option<Part> {
        values.retain(|v| v.is_finite());
        if values.is_empty() {
            return None;
        }
        values.sort_by(f64::total_cmp);
        let round = |v: f64| (v * 100.0).round() / 100.0;
        Some(Part {
            n: values.len(),
            p50_ms: round(crate::phone_frames::percentile(&values, 0.5)),
            p95_ms: round(crate::phone_frames::percentile(&values, 0.95)),
            max_ms: round(*values.last().unwrap_or(&0.0)),
        })
    }
}

/// One paint report, joined: one line of `phone-frames.jsonl` (`"kind": "paint"`).
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Summary {
    pub at_ms: i64,
    pub phone: String,
    pub kind: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub program: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub load: Option<String>,
    /// Samples the phone sent, and those whose stamps the ring still held.
    pub samples: usize,
    pub joined: usize,
    /// Mac minus phone clock (ms) and the round trip of the sample it came from.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub offset_ms: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub clock_rtt_ms: Option<f64>,
    /// The most the offset can be wrong by (ms): half the round trip of the sample it came
    /// from, since that sample's two directions can split the round trip at worst all one way.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub offset_error_ms: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rtt_ms: Option<u64>,
    /// The phone's Agent CLI Screen Changes setting when it sent the report.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent_cli_hybrid: Option<bool>,
    /// The link's route when the report came: `direct-lan`, `direct-wan`, `direct`, `relay`
    /// or `none` (`cmux_mobile_link::dial::route_name`); hostd decides it, the phone never says.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<&'static str>,
    /// (a) hostd read the redraw to its last byte handed to the socket.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mac: Option<Part>,
    /// (b) handed to the socket to the phone's receive (needs the offset).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub wire: Option<Part>,
    /// (c) the phone's receive to the present of the first frame that showed it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub phone_paint: Option<Part>,
    /// hostd read to the phone's paint (needs the offset).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub total: Option<Part>,
    /// The newest sample's total (ms): the live number the phone's overlay shows.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_total_ms: Option<f64>,
    /// Samples per path that painted them (`stream`, `datagram`), when the phone said.
    #[serde(skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub transports: std::collections::BTreeMap<String, usize>,
}

impl Summary {
    /// The answer hostd sends back on `phone-frames` for a paint report
    /// (`{"kind":"paint-summary",...}`): this summary without the phone's name, so a DEBUG
    /// overlay on the phone shows the Mac's join of its own report. A phone that does not read
    /// answers has closed its channel already; the line is dropped.
    pub fn answer(&self) -> Vec<u8> {
        let mut value = serde_json::to_value(self).unwrap_or_default();
        if let Some(object) = value.as_object_mut() {
            object.remove("phone");
            object.insert("kind".into(), "paint-summary".into());
        }
        value.to_string().into_bytes()
    }
}

/// Joins `report` from `phone` with the stamps `lookup` gives (hostd's ring).
pub fn summarize(
    report: Report,
    phone: &str,
    at_ms: i64,
    lookup: impl Fn(u64) -> Option<(i64, Option<i64>)>,
) -> Summary {
    let clock: Vec<Clock> = report
        .clock
        .iter()
        .take(MAX_CLOCK)
        .map(|c| Clock { t0: c[0], t1: c[1], t2: c[2], t3: c[3] })
        .collect();
    let best = Clock::best(&clock);
    let offset = best.map(|c| c.offset_ms());
    let samples = &report.samples[..];
    let (mut mac, mut wire, mut paint, mut total) = (Vec::new(), Vec::new(), Vec::new(), Vec::new());
    let mut joined = 0;
    for &[seq, rx, painted] in samples {
        if painted.is_finite() && rx.is_finite() && painted >= rx {
            paint.push(painted - rx);
        }
        if !(seq.is_finite() && seq >= 1.0) {
            continue;
        }
        let Some((produced_us, flushed_us)) = lookup(seq as u64) else { continue };
        joined += 1;
        let produced = produced_us as f64 / 1000.0;
        let flushed = flushed_us.map(|us| us as f64 / 1000.0);
        if let Some(flushed) = flushed {
            mac.push(flushed - produced);
        }
        if let Some(offset) = offset {
            if let Some(flushed) = flushed {
                wire.push(rx + offset - flushed);
            }
            if painted.is_finite() {
                total.push(painted + offset - produced);
            }
        }
    }
    let round = |v: f64| (v * 100.0).round() / 100.0;
    let last_total = total.last().copied().map(round);
    let mut transports = std::collections::BTreeMap::new();
    for transport in report.transports.iter().take(samples.len()) {
        let name = crate::phone_frames::label(transport);
        if !name.is_empty() {
            *transports.entry(name).or_insert(0) += 1;
        }
    }
    Summary {
        at_ms,
        phone: phone.to_owned(),
        kind: "paint",
        program: report.program.map(|p| crate::phone_frames::label(&p)).filter(|p| !p.is_empty()),
        app: report.app.map(|a| crate::phone_frames::label(&a)).filter(|a| !a.is_empty()),
        load: report.load.map(|l| crate::phone_frames::label(&l)).filter(|l| !l.is_empty()),
        samples: samples.len(),
        joined,
        offset_ms: offset.map(round),
        clock_rtt_ms: best.map(|c| round(c.rtt_ms())),
        offset_error_ms: best.map(|c| round(c.rtt_ms() / 2.0)),
        rtt_ms: report.rtt_ms,
        agent_cli_hybrid: report.agent_cli_hybrid,
        path: None,
        mac: Part::of(mac),
        wire: Part::of(wire),
        phone_paint: Part::of(paint),
        total: Part::of(total),
        last_total_ms: last_total,
        transports,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redraw_lines_get_an_id_others_do_not() {
        assert!(is_redraw(br#"{"data":"aGk=","event":"output","surface":1}"#));
        assert!(is_redraw(br#"{"event":"agent-cli-lean","f":"AAA="}"#));
        assert!(!is_redraw(br#"{"event":"size-state","surface":1}"#));
        assert!(!is_redraw(br#"{"id":3,"ok":true,"result":{}}"#));
        assert!(!is_redraw(b"not json \"event\":\"output\""));
        let line = with_seq(br#"{"data":"aGk=","event":"output","surface":1}"#.to_vec(), 42);
        assert_eq!(line, br#"{"data":"aGk=","event":"output","surface":1,"pseq":42}"#);
        let line = with_seq(b"{\"event\":\"output\"}\n".to_vec(), 7);
        assert_eq!(line, b"{\"event\":\"output\",\"pseq\":7}\n");
        let parsed: serde_json::Value = serde_json::from_slice(&line).unwrap();
        assert_eq!(parsed["pseq"], 7);
        // Not an object's end: left as it is.
        assert_eq!(with_seq(b"{\"event\":\"output\"\n".to_vec(), 7), b"{\"event\":\"output\"\n");
    }

    #[test]
    fn the_writer_finds_the_id_at_the_end() {
        assert_eq!(trailing_seq(b"{\"a\":1,\"pseq\":12}\n"), Some(12));
        assert_eq!(trailing_seq(b"{\"a\":1,\"pseq\":12}"), Some(12));
        assert_eq!(trailing_seq(b"{\"a\":1,\"xpseq\":12}"), None);
        assert_eq!(trailing_seq(b"{\"a\":12}"), None);
        assert_eq!(trailing_seq(b"{\"pseq\":}"), None);
        assert_eq!(trailing_seq(b"plain text\n"), None);
    }

    #[test]
    fn the_ring_keeps_the_newest_stamps_in_order() {
        let mut ring = Stamps::default();
        let first = ring.push(1_000);
        assert_eq!(first.seq, 1);
        assert_eq!(ring.get(1), Some((1_000, None)));
        first.flushed.set(1_500);
        assert_eq!(ring.get(1), Some((1_000, Some(1_500))));
        for i in 0..RING as i64 {
            ring.push(2_000 + i);
        }
        assert_eq!(ring.get(1), None, "the oldest went");
        assert_eq!(ring.get(2), Some((2_000, None)));
        assert_eq!(ring.get(RING as u64 + 1), Some((2_000 + RING as i64 - 1, None)));
        assert_eq!(ring.get(RING as u64 + 2), None, "not stamped yet");
        assert_eq!(ring.get(0), None);
    }

    #[test]
    fn the_offset_is_the_midpoint_of_the_shortest_round_trip() {
        // The Mac runs 500 ms ahead; one way 20 ms, 1 ms on the Mac.
        let clean = Clock { t0: 1000.0, t1: 1520.0, t2: 1521.0, t3: 1041.0 };
        assert_eq!(clean.offset_ms(), 500.0);
        assert_eq!(clean.rtt_ms(), 40.0);
        // Queued 100 ms on the way back: a worse estimate, and a longer trip.
        let queued = Clock { t0: 2000.0, t1: 2520.0, t2: 2521.0, t3: 2141.0 };
        assert_eq!(queued.offset_ms(), 450.0);
        assert_eq!(Clock::best(&[queued, clean]), Some(clean));
        // A sample whose phone times run backward is not one.
        let bad = Clock { t0: 10.0, t1: 0.0, t2: 0.0, t3: 5.0 };
        assert_eq!(Clock::best(&[bad]), None);
        assert_eq!(Clock::best(&[]), None);
    }

    #[test]
    fn a_report_splits_into_mac_wire_and_phone() {
        // The Mac 500 ms ahead of the phone. Line 1: read at Mac 10 000, flushed 2 ms later,
        // received 30 ms later (phone 9 532), painted 9 ms after that.
        let lookup = |seq: u64| match seq {
            1 => Some((10_000_000, Some(10_002_000))),
            2 => Some((10_100_000, Some(10_104_000))),
            3 => Some((10_200_000, None)),
            _ => None,
        };
        let report = Report {
            program: Some("claude".into()),
            app: None,
            samples: vec![
                [1.0, 9_532.0, 9_541.0],
                [2.0, 9_640.0, 9_657.0],
                [3.0, 9_700.0, 9_708.0],
                [99.0, 9_800.0, 9_801.0],
            ],
            clock: vec![[1000.0, 1520.0, 1521.0, 1041.0], [2000.0, 2520.0, 2521.0, 2141.0]],
            rtt_ms: Some(40),
            load: Some("sim".into()),
            agent_cli_hybrid: Some(false),
            transports: vec!["stream".into(), "datagram".into(), "stream".into(), "datagram".into()],
        };
        let s = summarize(report, "phone-1", 5, lookup);
        assert_eq!((s.samples, s.joined), (4, 3), "seq 99 went out of the ring");
        assert_eq!(s.offset_ms, Some(500.0));
        assert_eq!(s.clock_rtt_ms, Some(40.0));
        let mac = s.mac.unwrap();
        assert_eq!((mac.n, mac.p50_ms, mac.max_ms), (2, 2.0, 4.0), "seq 3 never flushed");
        let wire = s.wire.unwrap();
        assert_eq!((wire.n, wire.p50_ms, wire.max_ms), (2, 30.0, 36.0));
        let paint = s.phone_paint.unwrap();
        assert_eq!(
            (paint.n, paint.p50_ms, paint.max_ms),
            (4, 8.0, 17.0),
            "the phone's own part needs no stamp"
        );
        let total = s.total.unwrap();
        assert_eq!((total.n, total.p50_ms, total.max_ms), (3, 41.0, 57.0), "41, 57 and 8 ms");
        assert_eq!(s.offset_error_ms, Some(20.0), "half the best probe's 40 ms round trip");
        assert_eq!(s.last_total_ms, Some(8.0), "the newest joined sample, seq 3");
        let answer: serde_json::Value = serde_json::from_slice(&s.answer()).unwrap();
        assert_eq!(answer["kind"], "paint-summary");
        assert!(answer.get("phone").is_none(), "the phone's own name does not go back to it");
        assert_eq!(answer["total"]["p95_ms"], 57.0);
        assert_eq!(answer["offset_error_ms"], 20.0);
        assert_eq!(answer["last_total_ms"], 8.0);
        let transports: Vec<(&str, usize)> = s.transports.iter().map(|(k, v)| (k.as_str(), *v)).collect();
        assert_eq!(transports, [("datagram", 2), ("stream", 2)], "which path painted each frame");
    }

    #[test]
    fn without_a_clock_only_the_parts_on_one_clock_are_reported() {
        let report = Report {
            program: None,
            app: None,
            samples: vec![[1.0, 100.0, 108.0]],
            clock: vec![],
            rtt_ms: None,
            load: None,
            agent_cli_hybrid: None,
            transports: Vec::new(),
        };
        let s = summarize(report, "p", 0, |_| Some((0, Some(3_000))));
        assert_eq!(s.mac.map(|p| p.p50_ms), Some(3.0));
        assert_eq!(s.phone_paint.map(|p| p.p50_ms), Some(8.0));
        assert!(s.wire.is_none() && s.total.is_none() && s.offset_ms.is_none());
        let line = serde_json::to_value(&s).unwrap();
        assert_eq!(line["kind"], "paint");
        assert!(line.get("wire").is_none());
        assert!(line.get("transports").is_none(), "no path said, none written");
    }

    #[test]
    fn stamp_line_marks_only_redraws() {
        let (line, mark) = stamp_line(br#"{"id":1,"ok":true}"#.to_vec());
        assert!(mark.is_none());
        assert_eq!(line, br#"{"id":1,"ok":true}"#);
        let (line, mark) = stamp_line(b"{\"data\":\"aGk=\",\"event\":\"output\",\"surface\":1}\n".to_vec());
        let parsed: serde_json::Value = serde_json::from_slice(&line).unwrap();
        let seq = parsed["pseq"].as_u64().unwrap();
        let (produced, flushed) = lookup(seq).unwrap();
        assert!(produced > 0 && flushed.is_none());
        assert_eq!(trailing_seq(&line), Some(seq));
        assert_eq!(flush_mark(&line), mark);
        mark.unwrap().set(produced + 250);
        assert_eq!(lookup(seq), Some((produced, Some(produced + 250))));
    }
}
