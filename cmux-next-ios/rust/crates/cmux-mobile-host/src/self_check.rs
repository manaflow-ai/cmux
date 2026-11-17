//! The iPhone's hidden lean-terminal self-check (`cmux device self-check`).
//!
//! Does the lean agent-CLI terminal view on the phone draw exactly what the PTY
//! terminal draws? The phone answers that itself: it renders each case twice
//! (lean and PTY) and pixel-diffs the two on the device. This module relays the
//! Mac's ask to the phone and judges the counts the phone sends back.
//!
//! The phone opens the `self-check` service on every link (as it does
//! `needs-you`) and keeps it open. Bytes are newline-delimited JSON, one object
//! per line; a phone line can be several MB (it carries base64 PNGs), at most
//! [`MAX_LINE`].
//!
//! - phone -> host, first: `{"hello":{"version":1,"device":{...}}}`
//! - host -> phone: `{"run":ID,"rows":[1,...]}` (rows 1..=9)
//! - phone -> host, per case: `{"run":ID,"case":CASE}`
//! - phone -> host, last: `{"run":ID,"done":true}` or `{"run":ID,"error":"text"}`
//!
//! The link socket's `{"op":"self-check","phone":ID?,"rows":[..]?}` ([`run`])
//! picks a phone from the open channels ([`Registry`]), runs one check on it
//! (one at a time per phone), and answers a `{"progress":{..}}` line per case
//! as it arrives, then one final line: every row's verdict ([`judge`]) with the
//! cases as the phone sent them (images included).
//!
//! Machines never reach this service: `peer::need_for` does not offer it.

use std::collections::{BTreeSet, HashMap};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_mobile_link::ChannelEvent;
use cmux_mobile_link::link::{ChannelReceiver, ChannelSender};
use serde_json::{Map, Value, json};
use tokio::io::{AsyncWrite, AsyncWriteExt};
use tokio::sync::mpsc;

use crate::services::{Peer, Refusal};

/// A phone line's size limit (a case carries three base64 PNGs).
pub const MAX_LINE: usize = 64 * 1024 * 1024;
/// A case fails when more than this share of its grid pixels differ
/// (the cursor cell is already excluded by the phone).
pub const GRID_LIMIT: f64 = 0.0005;
/// A case fails when more than this share of one band's pixels differ.
pub const BAND_LIMIT: f64 = 0.001;
/// Rects (grid, cursor) are equal within this many points per number.
const RECT_TOLERANCE: f64 = 0.01;

/// The rows of the check, by number.
pub const ROWS: [(u64, &str); 9] = [
    (1, "headers"),
    (2, "first-and-last-columns"),
    (3, "wrapped-lines"),
    (4, "cjk-and-emoji"),
    (5, "box-drawing-tui"),
    (6, "alternate-screen"),
    (7, "cursor-position"),
    (8, "resize-and-rotate"),
    (9, "resume-after-background"),
];

/// How long a run waits for the phone.
#[derive(Debug, Clone, Copy)]
pub struct Limits {
    /// With no line from the phone.
    pub idle: Duration,
    /// For the whole run.
    pub overall: Duration,
}

/// The limits of a real run.
pub const LIMITS: Limits = Limits { idle: Duration::from_secs(120), overall: Duration::from_secs(20 * 60) };

/// The name of row `row`, if it is one.
pub fn row_name(row: u64) -> Option<&'static str> {
    ROWS.iter().find(|(number, _)| *number == row).map(|(_, name)| *name)
}

// ---------------------------------------------------------------------------
// Verdict
// ---------------------------------------------------------------------------

/// One case judged.
#[derive(Debug, Clone, PartialEq)]
pub struct Verdict {
    pub pass: bool,
    /// One line per reason it failed (empty when it passed).
    pub why: Vec<String>,
    /// Differing over compared grid pixels (0 when none were compared).
    pub grid_share: f64,
    /// Each band's differing over compared pixels, by band name.
    pub band_shares: Map<String, Value>,
}

fn number(value: Option<&Value>, key: &str) -> Option<f64> {
    value.and_then(|v| v.get(key)).and_then(Value::as_f64)
}

fn share(differing: f64, compared: f64) -> f64 {
    if compared > 0.0 { differing / compared } else { 0.0 }
}

/// `None` and `null` are no rect; an array of four numbers is one; anything else is malformed.
fn rect(value: Option<&Value>) -> Result<Option<[f64; 4]>, ()> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Array(numbers)) => {
            let numbers: Option<Vec<f64>> = numbers.iter().map(Value::as_f64).collect();
            numbers.and_then(|n| <[f64; 4]>::try_from(n).ok()).map(Some).ok_or(())
        }
        Some(_) => Err(()),
    }
}

fn same_rect(a: &[f64; 4], b: &[f64; 4]) -> bool {
    a.iter().zip(b.iter()).all(|(x, y)| (x - y).abs() <= RECT_TOLERANCE)
}

fn show_rect(rect: Result<Option<[f64; 4]>, ()>) -> String {
    match rect {
        Ok(Some([x, y, w, h])) => format!("[{x:.2}, {y:.2}, {w:.2}, {h:.2}]"),
        Ok(None) => "none".to_owned(),
        Err(()) => "malformed".to_owned(),
    }
}

fn percent(share: f64) -> String {
    format!("{:.4}%", share * 100.0)
}

/// Judge one case as the phone sent it (the simulator pixel matrix's thresholds).
pub fn judge(case: &Value) -> Verdict {
    let mut why = Vec::new();
    if let Some(error) = case.get("error").filter(|e| !e.is_null()) {
        let text = error.as_str().map(str::to_owned).unwrap_or_else(|| error.to_string());
        why.push(format!("error: {text}"));
    }
    let pixels = case.get("pixels");
    let compared = number(pixels, "compared").unwrap_or(0.0);
    let differing = number(pixels, "differing").unwrap_or(0.0);
    if compared <= 0.0 {
        why.push("no pixels compared".to_owned());
    }
    let pty = case.get("pty");
    let lean = case.get("lean");
    let pty_grid = rect(pty.and_then(|p| p.get("grid")));
    let lean_grid = rect(lean.and_then(|l| l.get("grid")));
    match (pty_grid, lean_grid) {
        (Ok(Some(a)), Ok(Some(b))) if same_rect(&a, &b) => {}
        (a, b) => why.push(format!("grid rect: pty {} vs lean {}", show_rect(a), show_rect(b))),
    }
    let pty_cursor = rect(pty.and_then(|p| p.get("cursor")));
    let lean_cursor = rect(lean.and_then(|l| l.get("cursor")));
    match (pty_cursor, lean_cursor) {
        (Ok(None), Ok(None)) => {}
        (Ok(Some(a)), Ok(Some(b))) if same_rect(&a, &b) => {}
        (a, b) => why.push(format!("cursor: pty {} vs lean {}", show_rect(a), show_rect(b))),
    }
    if case.get("same_layout").and_then(Value::as_bool) == Some(true) {
        for key in ["full_screen", "alternate"] {
            let a = pty.and_then(|p| p.get(key)).and_then(Value::as_bool).unwrap_or(false);
            let b = lean.and_then(|l| l.get(key)).and_then(Value::as_bool).unwrap_or(false);
            if a != b {
                why.push(format!("{key}: pty {a} vs lean {b}"));
            }
        }
    }
    let grid_share = share(differing, compared);
    if grid_share > GRID_LIMIT {
        why.push(format!(
            "grid pixels: {} differ ({differing} of {compared}; limit {})",
            percent(grid_share),
            percent(GRID_LIMIT)
        ));
    }
    let mut band_shares = Map::new();
    for band in case.get("bands").and_then(Value::as_array).into_iter().flatten() {
        let name = band.get("name").and_then(Value::as_str).unwrap_or("?").to_owned();
        let compared = number(Some(band), "compared").unwrap_or(0.0);
        let differing = number(Some(band), "differing").unwrap_or(0.0);
        let band_share = share(differing, compared);
        if compared > 0.0 && band_share > BAND_LIMIT {
            why.push(format!(
                "band {name}: {} differ ({differing} of {compared}; limit {})",
                percent(band_share),
                percent(BAND_LIMIT)
            ));
        }
        band_shares.insert(name, json!(band_share));
    }
    Verdict { pass: why.is_empty(), why, grid_share, band_shares }
}

/// The case as received plus its verdict (`pass`, `why`, `grid_share`, `band_shares`).
pub fn judged(case: Value) -> Value {
    let verdict = judge(&case);
    let mut fields = match case {
        Value::Object(fields) => fields,
        other => {
            let mut fields = Map::new();
            fields.insert("received".into(), other);
            fields
        }
    };
    fields.insert("pass".into(), json!(verdict.pass));
    fields.insert("why".into(), json!(verdict.why));
    fields.insert("grid_share".into(), json!(verdict.grid_share));
    fields.insert("band_shares".into(), Value::Object(verdict.band_shares));
    Value::Object(fields)
}

/// The rows of a run, each with its judged cases: every requested row, then any
/// other row a case named. A row passes when it has a case and every case passed.
/// Returns whether every row passed.
pub fn rows_report(requested: &[u64], cases: Vec<Value>) -> (bool, Vec<Value>) {
    let mut numbers: Vec<u64> = requested.to_vec();
    for case in &cases {
        if let Some(row) = case.get("row").and_then(Value::as_u64)
            && !numbers.contains(&row)
        {
            numbers.push(row);
        }
    }
    let mut by_row: HashMap<u64, Vec<Value>> = HashMap::new();
    for case in cases {
        let row = case.get("row").and_then(Value::as_u64).unwrap_or(0);
        by_row.entry(row).or_default().push(case);
    }
    let mut all_pass = true;
    let rows = numbers
        .into_iter()
        .map(|row| {
            let cases = by_row.remove(&row).unwrap_or_default();
            let passed = |c: &&Value| c.get("pass").and_then(Value::as_bool) == Some(true);
            let mut why: Vec<String> = Vec::new();
            if cases.is_empty() {
                why.push("no case ran".to_owned());
            }
            for case in cases.iter().filter(|c| !passed(c)) {
                let id = case.get("id").and_then(Value::as_str).unwrap_or("?");
                for line in case.get("why").and_then(Value::as_array).into_iter().flatten() {
                    why.push(format!("{id}: {}", line.as_str().unwrap_or_default()));
                }
            }
            let pass = why.is_empty();
            all_pass &= pass;
            json!({
                "row": row,
                "name": row_name(row).unwrap_or("unknown"),
                "pass": pass,
                "why": why,
                "cases": cases,
            })
        })
        .collect();
    (all_pass, rows)
}

/// The rows a request asks for: 1..=9 each once, in order; none or empty is all 9.
pub fn requested_rows(value: Option<&Value>) -> Result<Vec<u64>, String> {
    let all = || ROWS.iter().map(|(n, _)| *n).collect::<Vec<u64>>();
    match value {
        None | Some(Value::Null) => Ok(all()),
        Some(Value::Array(rows)) if rows.is_empty() => Ok(all()),
        Some(Value::Array(rows)) => {
            let mut set = BTreeSet::new();
            for row in rows {
                match row.as_u64().filter(|n| row_name(*n).is_some()) {
                    Some(n) => set.insert(n),
                    None => return Err(format!("rows are numbers 1 to 9, not {row}")),
                };
            }
            Ok(set.into_iter().collect())
        }
        Some(other) => Err(format!("rows is a list of numbers 1 to 9, not {other}")),
    }
}

// ---------------------------------------------------------------------------
// Lines
// ---------------------------------------------------------------------------

/// Splits a byte stream into lines however its chunks fall.
#[derive(Debug)]
pub struct LineBuffer {
    buffer: Vec<u8>,
    /// Bytes of `buffer` known to hold no newline.
    scanned: usize,
    max: usize,
}

/// A line longer than the limit.
#[derive(Debug, PartialEq, Eq)]
pub struct LineTooLong;

impl LineBuffer {
    pub fn new(max: usize) -> Self {
        Self { buffer: Vec::new(), scanned: 0, max }
    }

    /// The lines `data` completes (without their newline; empty ones skipped).
    pub fn push(&mut self, data: &[u8]) -> Result<Vec<Vec<u8>>, LineTooLong> {
        self.buffer.extend_from_slice(data);
        let mut lines = Vec::new();
        let mut start = 0;
        let mut from = self.scanned;
        while let Some(at) = self.buffer.get(from..).and_then(|rest| rest.iter().position(|&b| b == b'\n')) {
            let end = from + at;
            if let Some(line) = self.buffer.get(start..end) {
                let line = line.strip_suffix(b"\r").unwrap_or(line);
                if !line.is_empty() {
                    lines.push(line.to_vec());
                }
            }
            start = end + 1;
            from = start;
        }
        self.buffer.drain(..start);
        self.scanned = self.buffer.len();
        if self.buffer.len() > self.max || lines.iter().any(|l| l.len() > self.max) {
            return Err(LineTooLong);
        }
        Ok(lines)
    }
}

// ---------------------------------------------------------------------------
// Registry of the phones' open channels
// ---------------------------------------------------------------------------

/// A run handed to a phone's channel.
#[derive(Debug)]
pub struct Command {
    pub run: String,
    pub rows: Vec<u64>,
    /// The phone's lines of this run (cases, then `done` or `error`).
    pub lines: mpsc::UnboundedSender<Value>,
}

#[derive(Debug, Clone)]
struct Phone {
    device_id: String,
    device: Value,
    generation: u64,
    commands: mpsc::UnboundedSender<Command>,
    busy: Arc<AtomicBool>,
}

/// The phones' open `self-check` channels, by device id (the latest wins).
#[derive(Debug, Default)]
pub struct Registry {
    phones: Mutex<HashMap<String, Phone>>,
    generation: AtomicU64,
}

fn listed(phones: &HashMap<String, Phone>) -> Vec<Value> {
    let mut list: Vec<&Phone> = phones.values().collect();
    list.sort_by(|a, b| a.device_id.cmp(&b.device_id));
    list.into_iter().map(|p| json!({"device_id": p.device_id, "device": p.device})).collect()
}

/// The process's registry.
pub fn registry() -> &'static Registry {
    static REGISTRY: OnceLock<Registry> = OnceLock::new();
    REGISTRY.get_or_init(Registry::default)
}

/// One channel's place in the registry; removed when dropped (unless a newer one took it).
#[derive(Debug)]
pub struct Registration<'a> {
    registry: &'a Registry,
    device_id: String,
    generation: u64,
}

impl Drop for Registration<'_> {
    fn drop(&mut self) {
        let mut phones = self.registry.phones.lock().unwrap_or_else(|e| e.into_inner());
        if phones.get(&self.device_id).is_some_and(|p| p.generation == self.generation) {
            phones.remove(&self.device_id);
        }
    }
}

impl Registration<'_> {
    /// A newer hello on the same channel.
    pub fn update_device(&self, device: Value) {
        let mut phones = self.registry.phones.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(phone) = phones.get_mut(&self.device_id).filter(|p| p.generation == self.generation) {
            phone.device = device;
        }
    }
}

impl Registry {
    /// A phone's channel said hello: runs for it now come out of the returned receiver.
    pub fn register(
        &self,
        device_id: &str,
        device: Value,
    ) -> (Registration<'_>, mpsc::UnboundedReceiver<Command>) {
        let generation = self.generation.fetch_add(1, Ordering::Relaxed) + 1;
        let (commands, receiver) = mpsc::unbounded_channel();
        let phone = Phone {
            device_id: device_id.to_owned(),
            device,
            generation,
            commands,
            busy: Arc::new(AtomicBool::new(false)),
        };
        self.phones.lock().unwrap_or_else(|e| e.into_inner()).insert(device_id.to_owned(), phone);
        (Registration { registry: self, device_id: device_id.to_owned(), generation }, receiver)
    }

    /// The connected phones: `[{"device_id","device"}]`, sorted by id.
    pub fn phones(&self) -> Vec<Value> {
        listed(&self.phones.lock().unwrap_or_else(|e| e.into_inner()))
    }

    /// The phone `wanted` names (case-insensitive), or the only one; else the error answer.
    fn pick(&self, wanted: Option<&str>) -> Result<Phone, Value> {
        let phones = self.phones.lock().unwrap_or_else(|e| e.into_inner());
        let no_phone = || {
            json!({
                "error": "no_phone",
                "message": "no iPhone with this app version has a link to this Mac: open cmux on the phone",
            })
        };
        match wanted.map(str::trim).filter(|w| !w.is_empty()) {
            Some(wanted) => phones
                .values()
                .find(|p| p.device_id.eq_ignore_ascii_case(wanted))
                .cloned()
                .ok_or_else(no_phone),
            None => {
                let mut all = phones.values();
                match (all.next(), all.next()) {
                    (None, _) => Err(no_phone()),
                    (Some(one), None) => Ok(one.clone()),
                    (Some(_), Some(_)) => Err(json!({
                        "error": "several_phones",
                        "message": "several iPhones have a link to this Mac: name one with --phone DEVICE_ID",
                        "phones": listed(&phones),
                    })),
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// The phone's channel
// ---------------------------------------------------------------------------

/// The `self-check` service: the phone's long-lived channel. Registered at its
/// hello; relays runs to the phone and the phone's lines of the current run back.
pub async fn serve(peer: &Peer, sender: &ChannelSender, receiver: ChannelReceiver) -> Result<(), Refusal> {
    serve_in(registry(), &peer.device_id, sender, receiver).await
}

enum Incoming {
    Phone(Option<ChannelEvent>),
    Command(Option<Command>),
}

async fn serve_in(
    registry: &Registry,
    device_id: &str,
    sender: &ChannelSender,
    mut receiver: ChannelReceiver,
) -> Result<(), Refusal> {
    let mut lines = LineBuffer::new(MAX_LINE);
    let mut registered: Option<(Registration<'_>, mpsc::UnboundedReceiver<Command>)> = None;
    // A newer channel of the same phone took its place: this one only drains.
    let mut superseded = false;
    let mut active: Option<(String, mpsc::UnboundedSender<Value>)> = None;
    loop {
        let incoming = match registered.as_mut() {
            None => Incoming::Phone(receiver.recv().await),
            Some((_, commands)) => tokio::select! {
                event = receiver.recv() => Incoming::Phone(event),
                command = commands.recv() => Incoming::Command(command),
            },
        };
        match incoming {
            Incoming::Phone(Some(ChannelEvent::Data(data))) => {
                let complete = lines
                    .push(&data)
                    .map_err(|LineTooLong| Refusal::new("too_long", "a self-check line past 64 MiB"))?;
                for line in complete {
                    let Ok(message) = serde_json::from_slice::<Value>(&line) else {
                        tracing::info!(bytes = line.len(), "self-check: a line that is not JSON");
                        continue;
                    };
                    if let Some(hello) = message.get("hello") {
                        let device = hello.get("device").cloned().unwrap_or_else(|| json!({}));
                        match &registered {
                            Some((registration, _)) => registration.update_device(device),
                            None if !superseded => {
                                tracing::info!(peer = device_id, "self-check: the phone is ready");
                                registered = Some(registry.register(device_id, device));
                            }
                            None => {}
                        }
                        continue;
                    }
                    let Some(run) = message.get("run").and_then(Value::as_str) else { continue };
                    let Some((id, to_run)) = &active else { continue };
                    if run != id.as_str() {
                        continue;
                    }
                    let finished = message.get("done").and_then(Value::as_bool) == Some(true)
                        || message.get("error").is_some_and(|e| !e.is_null());
                    if to_run.send(message).is_err() || finished {
                        active = None;
                    }
                }
            }
            Incoming::Phone(Some(ChannelEvent::Closed(_)) | None) => return Ok(()),
            Incoming::Command(Some(command)) => {
                let ask = json!({"run": command.run, "rows": command.rows});
                let mut line = ask.to_string().into_bytes();
                line.push(b'\n');
                if sender.send(Bytes::from(line)).await.is_err() {
                    return Ok(());
                }
                active = Some((command.run, command.lines));
            }
            Incoming::Command(None) => {
                registered = None;
                superseded = true;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// One run, for the link socket
// ---------------------------------------------------------------------------

async fn write_line(out: &mut (impl AsyncWrite + Unpin), value: &Value) -> std::io::Result<()> {
    let mut line = value.to_string().into_bytes();
    line.push(b'\n');
    out.write_all(&line).await?;
    out.flush().await
}

/// Resets a phone's busy flag when its run ends, however it ends.
struct Busy(Arc<AtomicBool>);

impl Drop for Busy {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

fn run_id() -> String {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or_default();
    format!("sc-{now}-{}", NEXT.fetch_add(1, Ordering::Relaxed))
}

/// `{"op":"self-check","phone":ID?,"rows":[..]?}` on the link socket: progress
/// lines, then one final line (the report or an error).
pub async fn run(
    registry: &Registry,
    request: &Value,
    limits: Limits,
    out: &mut (impl AsyncWrite + Unpin),
) -> std::io::Result<()> {
    let rows = match requested_rows(request.get("rows")) {
        Ok(rows) => rows,
        Err(message) => return write_line(out, &json!({"error": "bad_request", "message": message})).await,
    };
    let phone = match registry.pick(request.get("phone").and_then(Value::as_str)) {
        Ok(phone) => phone,
        Err(answer) => return write_line(out, &answer).await,
    };
    if phone.busy.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire).is_err() {
        let answer = json!({"error": "busy", "message": "a self-check already runs on that iPhone"});
        return write_line(out, &answer).await;
    }
    let _busy = Busy(Arc::clone(&phone.busy));
    let id = run_id();
    let (lines_tx, mut lines) = mpsc::unbounded_channel();
    let closed =
        json!({"error": "closed", "message": "the iPhone's self-check channel closed during the run"});
    if phone.commands.send(Command { run: id.clone(), rows: rows.clone(), lines: lines_tx }).is_err() {
        return write_line(out, &closed).await;
    }
    tracing::info!(run = id, phone = phone.device_id, ?rows, "self-check: asked the phone");
    let deadline = Instant::now() + limits.overall;
    let mut cases = Vec::new();
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        let wait = left.min(limits.idle);
        let line = match tokio::time::timeout(wait, lines.recv()).await {
            Ok(Some(line)) => line,
            Ok(None) => return write_line(out, &closed).await,
            Err(_) => {
                let message = if left <= limits.idle {
                    format!("the self-check took longer than {} s", limits.overall.as_secs())
                } else {
                    format!("the iPhone sent nothing for {} s", limits.idle.as_secs())
                };
                return write_line(out, &json!({"error": "timeout", "message": message})).await;
            }
        };
        if let Some(case) = line.get("case") {
            let case = judged(case.clone());
            let progress = json!({"progress": {
                "row": case.get("row").cloned().unwrap_or(Value::Null),
                "id": case.get("id").cloned().unwrap_or(Value::Null),
                "pass": case.get("pass").cloned().unwrap_or(json!(false)),
            }});
            write_line(out, &progress).await?;
            cases.push(case);
        } else if let Some(error) = line.get("error").filter(|e| !e.is_null()) {
            let text = error.as_str().map(str::to_owned).unwrap_or_else(|| error.to_string());
            return write_line(out, &json!({"error": "phone_error", "message": text})).await;
        } else if line.get("done").and_then(Value::as_bool) == Some(true) {
            break;
        }
    }
    let (pass, rows) = rows_report(&rows, cases);
    let answer = json!({
        "ok": true,
        "phone": phone.device_id,
        "device": phone.device,
        "pass": pass,
        "thresholds": {"grid": GRID_LIMIT, "band": BAND_LIMIT},
        "rows": rows,
    });
    write_line(out, &answer).await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rect_json(r: [f64; 4]) -> Value {
        json!(r)
    }

    /// A case where lean and PTY drew the same pixels.
    fn exact(row: u64, id: &str) -> Value {
        json!({
            "row": row, "id": id, "session": "claude-code-2.1.310", "label": "", "at_ms": 1234,
            "pan_end": false, "same_layout": true,
            "pixels": {"differing": 0, "compared": 1_000_000},
            "bands": [
                {"name": "header", "differing": 0, "compared": 40_000},
                {"name": "firstColumn", "differing": 0, "compared": 20_000},
                {"name": "lastColumn", "differing": 0, "compared": 20_000},
            ],
            "pty": {"grid": rect_json([0.0, 44.0, 390.0, 700.0]), "cursor": rect_json([8.0, 60.0, 8.0, 16.0]),
                    "full_screen": false, "alternate": false},
            "lean": {"grid": rect_json([0.0, 44.0, 390.0, 700.0]), "cursor": rect_json([8.0, 60.0, 8.0, 16.0]),
                     "full_screen": false, "alternate": false},
            "images": {"pty": "aGk=", "lean": "aGk=", "diff": "aGk="},
        })
    }

    fn set(case: &mut Value, path: &[&str], value: Value) {
        let mut at = case;
        for key in path {
            at = at.get_mut(*key).unwrap();
        }
        *at = value;
    }

    fn band(case: &mut Value, name: &str, differing: u64) {
        for band in case["bands"].as_array_mut().unwrap() {
            if band["name"] == name {
                band["differing"] = json!(differing);
            }
        }
    }

    #[test]
    fn an_exact_case_passes() {
        let verdict = judge(&exact(1, "row1-a"));
        assert!(verdict.pass, "{:?}", verdict.why);
        assert_eq!(verdict.grid_share, 0.0);
        assert_eq!(verdict.band_shares.len(), 3);
        // At the limit is still a pass.
        let mut at_limit = exact(1, "row1-a");
        set(&mut at_limit, &["pixels", "differing"], json!(500));
        band(&mut at_limit, "header", 40);
        assert!(judge(&at_limit).pass, "{:?}", judge(&at_limit).why);
    }

    #[test]
    fn a_case_shifted_by_one_cell_fails_on_grid_and_band() {
        let mut shifted = exact(2, "row2-shifted");
        set(&mut shifted, &["pixels", "differing"], json!(40_000));
        band(&mut shifted, "firstColumn", 12_000);
        let verdict = judge(&shifted);
        assert!(!verdict.pass);
        assert!(verdict.why.iter().any(|w| w.starts_with("grid pixels: 4.0000%")), "{:?}", verdict.why);
        assert!(verdict.why.iter().any(|w| w.starts_with("band firstColumn: 60.0000%")), "{:?}", verdict.why);
        assert_eq!(verdict.why.len(), 2, "{:?}", verdict.why);
        assert!((verdict.grid_share - 0.04).abs() < 1e-12);
        assert_eq!(verdict.band_shares["firstColumn"], json!(0.6));
    }

    #[test]
    fn a_band_alone_fails_a_case_under_the_grid_limit() {
        let mut case = exact(2, "row2-last");
        set(&mut case, &["pixels", "differing"], json!(400)); // 0.04% of the grid
        band(&mut case, "lastColumn", 30); // 0.15% of the band
        let verdict = judge(&case);
        assert!(!verdict.pass);
        assert_eq!(verdict.why.len(), 1, "{:?}", verdict.why);
        assert!(verdict.why[0].starts_with("band lastColumn: 0.1500%"), "{:?}", verdict.why);
        // A band with nothing compared never fails.
        let mut empty = exact(2, "row2-empty");
        set(&mut empty, &["bands"], json!([{"name": "header", "differing": 5, "compared": 0}]));
        assert!(judge(&empty).pass, "{:?}", judge(&empty).why);
    }

    #[test]
    fn cursors_must_match_and_two_missing_ones_do() {
        let mut moved = exact(7, "row7-moved");
        set(&mut moved, &["lean", "cursor"], json!([16.0, 60.0, 8.0, 16.0]));
        let verdict = judge(&moved);
        assert!(!verdict.pass);
        assert!(verdict.why[0].starts_with("cursor: pty [8.00"), "{:?}", verdict.why);
        let mut one_missing = exact(7, "row7-missing");
        set(&mut one_missing, &["lean", "cursor"], Value::Null);
        assert_eq!(judge(&one_missing).why, ["cursor: pty [8.00, 60.00, 8.00, 16.00] vs lean none"]);
        let mut both_missing = exact(7, "row7-none");
        set(&mut both_missing, &["lean", "cursor"], Value::Null);
        set(&mut both_missing, &["pty", "cursor"], Value::Null);
        assert!(judge(&both_missing).pass);
        // Within the tolerance.
        let mut close = exact(7, "row7-close");
        set(&mut close, &["lean", "cursor"], json!([8.005, 60.0, 8.0, 16.0]));
        assert!(judge(&close).pass);
    }

    #[test]
    fn grid_rect_and_screen_modes_must_match() {
        let mut grid = exact(8, "row8-grid");
        set(&mut grid, &["lean", "grid"], json!([0.0, 44.0, 390.0, 690.0]));
        assert!(judge(&grid).why.iter().any(|w| w.starts_with("grid rect:")));
        let mut alternate = exact(6, "row6-alt");
        set(&mut alternate, &["lean", "alternate"], json!(true));
        assert_eq!(judge(&alternate).why, ["alternate: pty false vs lean true"]);
        // Only compared when the two share a layout.
        set(&mut alternate, &["same_layout"], json!(false));
        assert!(judge(&alternate).pass);
    }

    #[test]
    fn an_error_case_or_nothing_compared_fails() {
        let mut error = exact(9, "row9-err");
        error.as_object_mut().unwrap().insert("error".into(), json!("the PTY never drew"));
        assert_eq!(judge(&error).why, ["error: the PTY never drew"]);
        let mut empty = exact(9, "row9-empty");
        set(&mut empty, &["pixels", "compared"], json!(0));
        assert_eq!(judge(&empty).why, ["no pixels compared"]);
        assert!(!judge(&json!({"row": 1})).pass);
    }

    #[test]
    fn rows_pass_only_with_a_case_and_every_case_passing() {
        let mut shifted = exact(2, "row2-shifted");
        set(&mut shifted, &["pixels", "differing"], json!(40_000));
        let cases = vec![judged(exact(1, "row1-a")), judged(exact(2, "row2-ok")), judged(shifted)];
        let (pass, rows) = rows_report(&[1, 2, 3], cases);
        assert!(!pass);
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[0]["name"], "headers");
        assert_eq!(rows[0]["pass"], true);
        assert_eq!(rows[0]["why"], json!([]));
        assert_eq!(rows[1]["name"], "first-and-last-columns");
        assert_eq!(rows[1]["pass"], false);
        assert_eq!(rows[1]["cases"].as_array().unwrap().len(), 2);
        assert!(rows[1]["why"][0].as_str().unwrap().starts_with("row2-shifted: grid pixels"), "{}", rows[1]);
        assert_eq!(rows[2]["name"], "wrapped-lines");
        assert_eq!(rows[2]["why"], json!(["no case ran"]));
        // The judged case keeps what the phone sent.
        assert_eq!(rows[0]["cases"][0]["images"]["pty"], "aGk=");
        assert_eq!(rows[0]["cases"][0]["grid_share"], json!(0.0));
        let (pass, _) = rows_report(&[1], vec![judged(exact(1, "row1-a"))]);
        assert!(pass);
    }

    #[test]
    fn requested_rows_are_one_to_nine() {
        assert_eq!(requested_rows(None).unwrap().len(), 9);
        assert_eq!(requested_rows(Some(&json!([]))).unwrap().len(), 9);
        assert_eq!(requested_rows(Some(&json!([3, 1, 3]))).unwrap(), [1, 3]);
        assert!(requested_rows(Some(&json!([0]))).is_err());
        assert!(requested_rows(Some(&json!([10]))).is_err());
        assert!(requested_rows(Some(&json!("1"))).is_err());
    }

    #[test]
    fn lines_split_however_the_chunks_fall() {
        let text = b"{\"a\":1}\n{\"b\":2}\r\n\n{\"c\":3}\n";
        for size in 1..text.len() {
            let mut buffer = LineBuffer::new(1024);
            let mut lines = Vec::new();
            for chunk in text.chunks(size) {
                lines.extend(buffer.push(chunk).unwrap());
            }
            assert_eq!(
                lines,
                [b"{\"a\":1}".to_vec(), b"{\"b\":2}".to_vec(), b"{\"c\":3}".to_vec()],
                "chunk {size}"
            );
        }
        let mut small = LineBuffer::new(4);
        assert_eq!(small.push(b"12345"), Err(LineTooLong));
    }

    /// A stand-in phone: answers each run with `cases` then `end`.
    fn fake_phone(mut commands: mpsc::UnboundedReceiver<Command>, cases: Vec<Value>, end: Option<Value>) {
        tokio::spawn(async move {
            while let Some(command) = commands.recv().await {
                for case in &cases {
                    let _ = command.lines.send(json!({"run": command.run, "case": case}));
                }
                if let Some(end) = &end {
                    let mut end = end.clone();
                    end["run"] = json!(command.run);
                    let _ = command.lines.send(end);
                }
            }
        });
    }

    fn answer_lines(out: &[u8]) -> Vec<Value> {
        out.split(|&b| b == b'\n')
            .filter(|l| !l.is_empty())
            .map(|l| serde_json::from_slice(l).unwrap())
            .collect()
    }

    const QUICK: Limits = Limits { idle: Duration::from_millis(200), overall: Duration::from_secs(5) };

    #[tokio::test]
    async fn a_run_picks_the_phone_and_reports_each_case() {
        let registry = Registry::default();
        let mut out = Vec::new();
        run(&registry, &json!({"op": "self-check"}), QUICK, &mut out).await.unwrap();
        assert_eq!(answer_lines(&out)[0]["error"], "no_phone");

        let (_one, commands) = registry.register("PHONE-1", json!({"model": "iPhone17,1"}));
        let mut shifted = exact(2, "row2-shifted");
        set(&mut shifted, &["pixels", "differing"], json!(40_000));
        // The phone's channel drops lines of other runs itself (serve_in): the stand-in sends this run's only.
        let (lines_phone, phone_commands) = (vec![exact(1, "row1-a"), shifted], commands);
        tokio::spawn(async move {
            let mut phone_commands = phone_commands;
            while let Some(command) = phone_commands.recv().await {
                assert_eq!(command.rows, [1, 2]);
                for case in &lines_phone {
                    let _ = command.lines.send(json!({"run": command.run, "case": case}));
                }
                let _ = command.lines.send(json!({"run": command.run, "done": true}));
            }
        });
        let mut out = Vec::new();
        run(&registry, &json!({"op": "self-check", "phone": "phone-1", "rows": [2, 1]}), QUICK, &mut out)
            .await
            .unwrap();
        let lines = answer_lines(&out);
        assert_eq!(lines.len(), 3, "{lines:?}");
        assert_eq!(lines[0]["progress"], json!({"row": 1, "id": "row1-a", "pass": true}));
        assert_eq!(lines[1]["progress"], json!({"row": 2, "id": "row2-shifted", "pass": false}));
        let last = &lines[2];
        assert_eq!(last["ok"], true);
        assert_eq!(last["phone"], "PHONE-1");
        assert_eq!(last["device"]["model"], "iPhone17,1");
        assert_eq!(last["pass"], false);
        assert_eq!(last["thresholds"], json!({"grid": 0.0005, "band": 0.001}));
        assert_eq!(last["rows"][0]["pass"], true);
        assert_eq!(last["rows"][1]["pass"], false);

        // A second phone: no id is ambiguous.
        let (_two, _commands_two) = registry.register("PHONE-2", json!({}));
        let mut out = Vec::new();
        run(&registry, &json!({}), QUICK, &mut out).await.unwrap();
        let answer = &answer_lines(&out)[0];
        assert_eq!(answer["error"], "several_phones");
        assert_eq!(answer["phones"].as_array().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn a_phone_runs_one_check_at_a_time_and_its_errors_reach_the_socket() {
        let registry = Registry::default();
        let (_registration, commands) = registry.register("phone", json!({}));
        fake_phone(commands, vec![exact(1, "row1-a")], Some(json!({"error": "the lean view never drew"})));
        let busy = {
            let phones = registry.phones.lock().unwrap();
            Arc::clone(&phones["phone"].busy)
        };
        busy.store(true, Ordering::Release);
        let mut out = Vec::new();
        run(&registry, &json!({}), QUICK, &mut out).await.unwrap();
        assert_eq!(answer_lines(&out)[0]["error"], "busy");
        busy.store(false, Ordering::Release);
        let mut out = Vec::new();
        run(&registry, &json!({"rows": [1]}), QUICK, &mut out).await.unwrap();
        let lines = answer_lines(&out);
        assert_eq!(lines.len(), 2, "{lines:?}");
        assert_eq!(lines[1]["error"], "phone_error");
        assert_eq!(lines[1]["message"], "the lean view never drew");
        assert!(!busy.load(Ordering::Acquire), "the run ended: not busy");
    }

    #[tokio::test]
    async fn a_silent_phone_times_out_and_a_closed_one_is_closed() {
        let registry = Registry::default();
        let (registration, commands) = registry.register("silent", json!({}));
        fake_phone(commands, Vec::new(), None);
        let mut out = Vec::new();
        run(&registry, &json!({}), QUICK, &mut out).await.unwrap();
        assert_eq!(answer_lines(&out)[0]["error"], "timeout");
        drop(registration);
        assert!(registry.phones().is_empty());

        // The channel goes away during the run.
        let (registration, mut commands) = registry.register("closing", json!({}));
        let phone = async move {
            let command = commands.recv().await.unwrap();
            drop(registration);
            drop(command);
        };
        let mut out = Vec::new();
        let ((), result) = tokio::join!(phone, run(&registry, &json!({}), QUICK, &mut out));
        result.unwrap();
        assert_eq!(answer_lines(&out)[0]["error"], "closed");
    }

    #[test]
    fn the_latest_channel_of_a_phone_wins() {
        let registry = Registry::default();
        let (old, _old_commands) = registry.register("phone", json!({"app": "1"}));
        let (new, _new_commands) = registry.register("phone", json!({"app": "2"}));
        drop(old);
        assert_eq!(registry.phones(), [json!({"device_id": "phone", "device": {"app": "2"}})]);
        new.update_device(json!({"app": "3"}));
        assert_eq!(registry.phones()[0]["device"]["app"], "3");
        drop(new);
        assert!(registry.phones().is_empty());
    }
}
