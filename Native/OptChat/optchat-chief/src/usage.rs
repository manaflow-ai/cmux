//! Chief usage analytics (plans/cmux-next/chief-usage-analytics-DESIGN.md).
//!
//! The usage ledger: `<optchat root>/usage/YYYY-MM.jsonl` (local month,
//! directory 0700, files 0600), one JSON line per billable unit (a Chief
//! turn, a compactor node, a subagent prompt) folded from the monitoring
//! trace's events (`trace.rs`). The trace hands every event to
//! [`Ledger::observe`]; nothing runs between events (no timer, no thread).
//! Old traces are converted once ([`backfill`]); whole month files are
//! pruned by age and size ([`prune`]). [`summarize`] folds the lines of one
//! or more Chiefs into the summary that `optchat-chief usage`, `cmux chief
//! usage` and the Chief Usage page read.
//!
//! ```text
//! optchat-chief usage [--since 7d] [--until 0] [--bucket hour|day|week|month]
//!                     [--by chief|agent|model|harness|kind] [--top N] [--json]
//!                     [--mux-home DIR]... [--chiefs]
//! optchat-chief usage backfill [--force] [--mux-home DIR]...
//! ```

use std::collections::{BTreeMap, HashMap};
use std::io::{BufRead, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// The ledger line format.
pub const VERSION: u32 = 1;
/// Months kept by default (`OPTCHAT_USAGE_KEEP_MONTHS`), the current one included.
pub const KEEP_MONTHS: u32 = 13;
/// The ledger directory's size cap; the oldest months go first.
pub const MAX_BYTES: u64 = 256 * 1024 * 1024;
/// A backfill lock older than this is a crashed backfill's and is taken over.
const STALE_LOCK: std::time::Duration = std::time::Duration::from_secs(600);
/// Models and sessions remembered per turn or subagent while the trace runs.
const MAX_REMEMBERED: usize = 256;
const HOUR_MS: i64 = 3_600_000;
const DAY_MS: i64 = 86_400_000;

/// One billable unit: a Chief turn, a compactor node or a subagent prompt.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Line {
    pub v: u32,
    /// When the unit ended (ms since the epoch).
    pub ts: u64,
    /// `turn`, `compactor` or `subagent`.
    pub kind: String,
    /// The turn key, the compactor node (`5236+4`) or the subagent id.
    pub key: String,
    /// The subagent id (`a241`) of a `subagent` line.
    pub agent: Option<String>,
    /// The subagent's acpmux session, for its link.
    pub session: Option<String>,
    pub model: Option<String>,
    pub harness: Option<String>,
    pub status: Option<String>,
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_write: u64,
    /// The unit's own cost in USD, as the harness reported it.
    pub usd: Option<f64>,
    /// A subagent's running total (Claude Code's `total_cost_usd` for its
    /// process), from which `usd` was derived.
    pub usd_cum: Option<f64>,
    /// Wall time of the unit.
    pub ms: Option<u64>,
    /// The harness process or session start.
    pub start_ms: Option<u64>,
    /// Time to the first token of the first request.
    pub ttft_ms: Option<u64>,
    /// `live` (the host wrote it) or `trace` (backfilled).
    pub src: String,
}

impl Line {
    fn tokens(&self) -> u64 {
        self.input + self.output + self.cache_read + self.cache_write
    }
}

/// The trace events the fold reads.
fn billable(ev: &str) -> bool {
    matches!(
        ev,
        "turn.end" | "node" | "subagent.answer" | "request" | "subagent.start"
    )
}

fn u(v: &Value, key: &str) -> u64 {
    v.get(key).and_then(Value::as_u64).unwrap_or(0)
}

fn opt_u(v: &Value, key: &str) -> Option<u64> {
    v.get(key).and_then(Value::as_u64)
}

fn opt_s(v: &Value, key: &str) -> Option<String> {
    v.get(key)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}

/// Turns trace events into ledger lines. It remembers each turn's and
/// subagent's last request model, each subagent's session and running cost.
#[derive(Default)]
pub struct Fold {
    models: HashMap<String, String>,
    sessions: HashMap<String, String>,
    cum: HashMap<String, f64>,
}

impl Fold {
    pub fn new() -> Fold {
        Fold::default()
    }

    /// Whether the fold has seen subagent `id`'s running cost.
    pub fn knows_cost(&self, id: &str) -> bool {
        self.cum.contains_key(id)
    }

    /// Sets subagent `id`'s last running cost (read back from the ledger
    /// after a host restart).
    pub fn seed_cost(&mut self, id: &str, cum: f64) {
        self.cum.insert(id.to_owned(), cum);
    }

    fn remember(map: &mut HashMap<String, String>, key: String, value: String) {
        if map.len() >= MAX_REMEMBERED && !map.contains_key(&key) {
            map.clear();
        }
        map.insert(key, value);
    }

    /// The ledger line of `event`, if it ends a billable unit.
    pub fn observe(&mut self, event: &Value, src: &str) -> Option<Line> {
        let ev = event.get("ev").and_then(Value::as_str).unwrap_or("");
        let ts = u(event, "ts");
        let usage = event.get("usage").unwrap_or(&Value::Null);
        let base = |kind: &str, key: String| Line {
            v: VERSION,
            ts,
            kind: kind.to_owned(),
            key,
            harness: opt_s(event, "harness"),
            input: u(usage, "input"),
            output: u(usage, "output"),
            cache_read: u(usage, "cache_read"),
            cache_write: u(usage, "cache_write"),
            usd: event.get("cost_usd").and_then(Value::as_f64),
            ms: opt_u(event, "ms"),
            src: src.to_owned(),
            ..Line::default()
        };
        match ev {
            "request" => {
                let model = opt_s(event, "model")?;
                let scope = match (opt_s(event, "turn"), opt_s(event, "subagent")) {
                    (Some(turn), _) => format!("turn:{turn}"),
                    (None, Some(id)) => format!("sub:{id}"),
                    _ => return None,
                };
                Self::remember(&mut self.models, scope, model);
                None
            }
            "subagent.start" => {
                let (id, session) = (opt_s(event, "id")?, opt_s(event, "session")?);
                Self::remember(&mut self.sessions, id, session);
                None
            }
            "turn.end" => {
                let key = opt_s(event, "turn").unwrap_or_default();
                let remembered = self.models.remove(&format!("turn:{key}"));
                let mut line = base("turn", key);
                line.model = opt_s(event, "model").or(remembered);
                line.status = opt_s(event, "status");
                line.start_ms = opt_u(event, "start_ms");
                line.ttft_ms = opt_u(event, "ttft_ms");
                Some(line)
            }
            "node" => {
                let mut line = base("compactor", opt_s(event, "node").unwrap_or_default());
                line.model = opt_s(event, "model");
                line.status = Some(if event["ok"] == false { "error" } else { "ok" }.to_owned());
                let timing = event.get("timing").unwrap_or(&Value::Null);
                line.start_ms = opt_u(timing, "session_start_ms");
                line.ttft_ms = timing
                    .get("ttft_ms")
                    .and_then(Value::as_array)
                    .and_then(|a| a.first())
                    .and_then(Value::as_u64);
                Some(line)
            }
            "subagent.answer" => {
                if event.get("usage").is_none_or(Value::is_null)
                    && event.get("cost_usd").is_none_or(Value::is_null)
                {
                    return None;
                }
                let id = opt_s(event, "id")?;
                let mut line = base("subagent", id.clone());
                line.agent = Some(id.clone());
                line.session = self.sessions.get(&id).cloned();
                line.model = self.models.get(&format!("sub:{id}")).cloned();
                line.status = opt_s(event, "stop");
                line.usd_cum = line.usd;
                line.usd = line.usd_cum.map(|cum| match self.cum.get(&id) {
                    // The running total went down: the process restarted.
                    Some(prev) if cum + 1e-12 >= *prev => cum - prev,
                    _ => cum,
                });
                if let Some(cum) = line.usd_cum {
                    if self.cum.len() >= MAX_REMEMBERED && !self.cum.contains_key(&id) {
                        self.cum.clear();
                    }
                    self.cum.insert(id, cum);
                }
                Some(line)
            }
            _ => None,
        }
    }
}

/// `<optchat root>/usage`.
pub fn dir(root: &Path) -> PathBuf {
    root.join("usage")
}

fn local_month(ts: u64) -> String {
    chrono::DateTime::from_timestamp_millis(i64::try_from(ts).unwrap_or(i64::MAX))
        .map(|t| t.with_timezone(&chrono::Local).format("%Y-%m").to_string())
        .unwrap_or_else(|| "9999-12".to_owned())
}

fn now_ms() -> u64 {
    chrono::Utc::now().timestamp_millis().max(0) as u64
}

fn make_dir(dir: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)?;
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
}

fn keep_months() -> u32 {
    std::env::var("OPTCHAT_USAGE_KEEP_MONTHS")
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .filter(|n| *n > 0)
        .unwrap_or(KEEP_MONTHS)
}

/// Appends lines into their month files; prunes when a new month file starts.
struct Writer {
    dir: PathBuf,
}

impl Writer {
    fn append(&self, line: &Line) -> std::io::Result<()> {
        let month = local_month(line.ts);
        let file = self.dir.join(format!("{month}.jsonl"));
        let new_month = !file.exists();
        let mut bytes = serde_json::to_vec(line).map_err(std::io::Error::other)?;
        bytes.push(b'\n');
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(&file)?;
        // One write per line: O_APPEND keeps lines whole.
        f.write_all(&bytes)?;
        if new_month {
            prune(&self.dir, &local_month(now_ms()), keep_months(), MAX_BYTES);
        }
        Ok(())
    }
}

/// The live ledger of one Chief host, fed by its trace.
pub struct Ledger {
    writer: Writer,
    state: Mutex<LiveState>,
}

#[derive(Default)]
struct LiveState {
    fold: Fold,
    live_marked: bool,
}

impl std::fmt::Debug for Ledger {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Ledger({})", self.writer.dir.display())
    }
}

impl Ledger {
    /// The ledger in `dir` (created 0700).
    pub fn open(dir: &Path) -> std::io::Result<Ledger> {
        make_dir(dir)?;
        Ok(Ledger {
            writer: Writer {
                dir: dir.to_owned(),
            },
            state: Mutex::new(LiveState::default()),
        })
    }

    /// Takes one trace event (`{"ts", "ev", ...}`) and appends its line, if
    /// it ends a billable unit. A failed write is dropped, as the trace's.
    pub fn observe(&self, event: &Value) {
        let ev = event.get("ev").and_then(Value::as_str).unwrap_or("");
        if !billable(ev) {
            return;
        }
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        // After a host restart: the subagent's last running cost, so its
        // next prompt is not counted from zero.
        if ev == "subagent.answer"
            && let Some(id) = event.get("id").and_then(Value::as_str)
            && !state.fold.knows_cost(id)
            && let Some(cum) = last_cost(&self.writer.dir, id)
        {
            state.fold.seed_cost(id, cum);
        }
        let Some(line) = state.fold.observe(event, "live") else {
            return;
        };
        if !state.live_marked {
            state.live_marked = true;
            let marker = self.writer.dir.join("live-since");
            if !marker.exists() {
                let _ = std::fs::OpenOptions::new()
                    .create_new(true)
                    .write(true)
                    .mode(0o600)
                    .open(&marker)
                    .and_then(|mut f| f.write_all(line.ts.to_string().as_bytes()));
            }
        }
        let _ = self.writer.append(&line);
    }
}

/// The month files of `dir`, oldest first.
fn month_files(dir: &Path) -> Vec<(String, PathBuf)> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut files: Vec<(String, PathBuf)> = entries
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            let month = name.strip_suffix(".jsonl")?;
            let b = month.as_bytes();
            (b.len() == 7
                && b[4] == b'-'
                && b.iter()
                    .enumerate()
                    .all(|(i, c)| i == 4 || c.is_ascii_digit()))
            .then(|| (month.to_owned(), e.path()))
        })
        .collect();
    files.sort();
    files
}

/// The last running cost the ledger holds for subagent `id`.
fn last_cost(dir: &Path, id: &str) -> Option<f64> {
    let needle = format!("\"agent\":{}", Value::String(id.to_owned()));
    for (_, file) in month_files(dir).into_iter().rev().take(2) {
        let Ok(f) = std::fs::File::open(&file) else {
            continue;
        };
        let best = std::io::BufReader::new(f)
            .lines()
            .map_while(Result::ok)
            .filter(|l| l.contains(&needle))
            .filter_map(|l| serde_json::from_str::<Line>(&l).ok())
            .filter(|l| l.kind == "subagent" && l.usd_cum.is_some())
            .max_by_key(|l| l.ts);
        if let Some(line) = best {
            return line.usd_cum;
        }
    }
    None
}

/// Every line with `since_ms <= ts < until_ms`, oldest first.
pub fn read(dir: &Path, since_ms: u64, until_ms: u64) -> Result<Vec<Line>, String> {
    // A day of slack: the month files are named in local time.
    // Clamped to year 9999, so a far bound (u64::MAX) never wraps to a negative time.
    const MAX_MS: u64 = 253_402_300_799_000;
    let first = local_month(since_ms.min(MAX_MS).saturating_sub(DAY_MS as u64));
    let last = local_month(until_ms.min(MAX_MS - DAY_MS as u64) + DAY_MS as u64);
    let mut lines = Vec::new();
    for (month, file) in month_files(dir) {
        if month < first || month > last {
            continue;
        }
        let f = std::fs::File::open(&file).map_err(|e| format!("{}: {e}", file.display()))?;
        for text in std::io::BufReader::new(f).lines().map_while(Result::ok) {
            if let Ok(line) = serde_json::from_str::<Line>(&text)
                && line.ts >= since_ms
                && line.ts < until_ms
            {
                lines.push(line);
            }
        }
    }
    lines.sort_by_key(|l| l.ts);
    Ok(lines)
}

/// What a backfill converted.
#[derive(Debug, Default)]
pub struct Backfill {
    /// Lines written.
    pub lines: u64,
    /// Trace files read.
    pub files: u64,
}

/// Removes the backfill lock when the backfill ends, failed or not.
struct LockGuard(PathBuf);

impl Drop for LockGuard {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

fn take_lock(path: &Path) -> Result<LockGuard, String> {
    let create = || {
        std::fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(path)
    };
    match create() {
        Ok(_) => Ok(LockGuard(path.to_owned())),
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            let stale = std::fs::metadata(path)
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| t.elapsed().ok())
                .is_some_and(|age| age > STALE_LOCK);
            if stale {
                let _ = std::fs::remove_file(path);
                if create().is_ok() {
                    return Ok(LockGuard(path.to_owned()));
                }
            }
            Err("another usage backfill is running".to_owned())
        }
        Err(e) => Err(format!("{}: {e}", path.display())),
    }
}

/// Converts the trace (`<root>/traces`) into ledger lines once: the events
/// before the live ledger's first line, after the last backfill's end.
/// Writes `backfill.json` when done; with it present and `force` false,
/// does nothing.
pub fn backfill(root: &Path, force: bool) -> Result<Backfill, String> {
    let ledger = dir(root);
    make_dir(&ledger).map_err(|e| format!("{}: {e}", ledger.display()))?;
    let marker = ledger.join("backfill.json");
    let done: Option<Value> = std::fs::read_to_string(&marker)
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok());
    if done.is_some() && !force {
        return Ok(Backfill::default());
    }
    let _lock = take_lock(&ledger.join("backfill.lock"))?;
    let after = done.as_ref().map_or(0, |d| u(d, "through_ts"));
    let live_since: u64 = std::fs::read_to_string(ledger.join("live-since"))
        .ok()
        .and_then(|t| t.trim().parse().ok())
        .unwrap_or(u64::MAX);
    let traces = root.join("traces");
    let mut files: Vec<PathBuf> = std::fs::read_dir(&traces)
        .map(|entries| {
            entries
                .flatten()
                .map(|e| e.path())
                .filter(|p| p.extension().is_some_and(|x| x == "jsonl"))
                .collect()
        })
        .unwrap_or_default();
    files.sort();
    let writer = Writer {
        dir: ledger.clone(),
    };
    let mut fold = Fold::new();
    let mut report = Backfill::default();
    let mut through = after;
    // Months retention would delete at once are not written.
    let oldest = month_minus(&local_month(now_ms()), keep_months().saturating_sub(1));
    for file in &files {
        let Ok(f) = std::fs::File::open(file) else {
            continue;
        };
        report.files += 1;
        for text in std::io::BufReader::new(f).lines().map_while(Result::ok) {
            // Most trace lines are tools and requests: skip the rest unparsed.
            let wanted = [
                "\"ev\":\"turn.end\"",
                "\"ev\":\"node\"",
                "\"ev\":\"subagent.answer\"",
                "\"ev\":\"request\"",
                "\"ev\":\"subagent.start\"",
            ];
            if !wanted.iter().any(|w| text.contains(w)) {
                continue;
            }
            let Ok(event) = serde_json::from_str::<Value>(&text) else {
                continue;
            };
            let ts = u(&event, "ts");
            if ts <= after || ts >= live_since {
                continue;
            }
            if let Some(line) = fold.observe(&event, "trace")
                && local_month(line.ts) >= oldest
            {
                writer
                    .append(&line)
                    .map_err(|e| format!("{}: {e}", ledger.display()))?;
                report.lines += 1;
                through = through.max(ts);
            }
        }
    }
    let record = json!({"through_ts": through, "lines": report.lines, "files": report.files, "at": now_ms()});
    std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .mode(0o600)
        .open(&marker)
        .and_then(|mut f| f.write_all(record.to_string().as_bytes()))
        .map_err(|e| format!("{}: {e}", marker.display()))?;
    Ok(report)
}

/// `YYYY-MM` minus `n` months.
fn month_minus(month: &str, n: u32) -> String {
    let (y, m) = month.split_once('-').unwrap_or(("0", "1"));
    let (y, m): (i64, i64) = (y.parse().unwrap_or(0), m.parse().unwrap_or(1));
    let index = y * 12 + (m - 1) - i64::from(n);
    format!(
        "{:04}-{:02}",
        index.div_euclid(12),
        index.rem_euclid(12) + 1
    )
}

/// Deletes month files older than `keep_months` (the month `month` counts
/// as one), then the oldest month files until the directory's files total
/// at most `max_bytes`. Never deletes `month`'s file. Returns what it deleted.
pub fn prune(dir: &Path, month: &str, keep_months: u32, max_bytes: u64) -> Vec<PathBuf> {
    let oldest = month_minus(month, keep_months.saturating_sub(1));
    let mut removed = Vec::new();
    let mut files = month_files(dir);
    files.retain(|(m, path)| {
        if m.as_str() < oldest.as_str() && std::fs::remove_file(path).is_ok() {
            removed.push(path.clone());
            return false;
        }
        true
    });
    let size = |p: &Path| std::fs::metadata(p).map_or(0, |m| m.len());
    let mut total: u64 = std::fs::read_dir(dir)
        .map(|entries| {
            entries
                .flatten()
                .filter(|e| e.file_type().is_ok_and(|t| t.is_file()))
                .map(|e| size(&e.path()))
                .sum()
        })
        .unwrap_or(0);
    for (m, path) in files {
        if total <= max_bytes || m == month {
            break;
        }
        let len = size(&path);
        if std::fs::remove_file(&path).is_ok() {
            total = total.saturating_sub(len);
            removed.push(path);
        }
    }
    removed
}

/// The width of one chart point.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Bucket {
    Hour,
    Day,
    /// Monday to Sunday.
    Week,
    Month,
}

impl Bucket {
    pub fn name(self) -> &'static str {
        match self {
            Bucket::Hour => "hour",
            Bucket::Day => "day",
            Bucket::Week => "week",
            Bucket::Month => "month",
        }
    }

    pub fn parse(text: &str) -> Option<Bucket> {
        Some(match text {
            "hour" => Bucket::Hour,
            "day" => Bucket::Day,
            "week" => Bucket::Week,
            "month" => Bucket::Month,
            _ => return None,
        })
    }

    /// The bucket a window of `ms` charts in: ≤ 2 days hours, ≤ 60 days
    /// days, ≤ a year weeks, else months.
    pub fn for_window(ms: u64) -> Bucket {
        let days = ms / DAY_MS as u64;
        match days {
            0..=2 => Bucket::Hour,
            3..=60 => Bucket::Day,
            61..=366 => Bucket::Week,
            _ => Bucket::Month,
        }
    }

    /// The start of the bucket holding `ts`, at UTC offset `off_ms`.
    fn start(self, ts: i64, off_ms: i64) -> i64 {
        let local = ts + off_ms;
        let start = match self {
            Bucket::Hour => local.div_euclid(HOUR_MS) * HOUR_MS,
            Bucket::Day => local.div_euclid(DAY_MS) * DAY_MS,
            Bucket::Week => {
                let day = local.div_euclid(DAY_MS);
                // Day 0 (1970-01-01) was a Thursday, three days after a Monday.
                (day - (day + 3).rem_euclid(7)) * DAY_MS
            }
            Bucket::Month => {
                use chrono::Datelike;
                let date = chrono::DateTime::from_timestamp_millis(local)
                    .map(|t| t.date_naive())
                    .unwrap_or_default();
                month_start(date.year(), date.month())
            }
        };
        start - off_ms
    }

    /// The start of the bucket after the one starting at `start`.
    fn next(self, start: i64, off_ms: i64) -> i64 {
        match self {
            Bucket::Hour => start + HOUR_MS,
            Bucket::Day => start + DAY_MS,
            Bucket::Week => start + 7 * DAY_MS,
            Bucket::Month => {
                use chrono::Datelike;
                let date = chrono::DateTime::from_timestamp_millis(start + off_ms)
                    .map(|t| t.date_naive())
                    .unwrap_or_default();
                let (y, m) = if date.month() == 12 {
                    (date.year() + 1, 1)
                } else {
                    (date.year(), date.month() + 1)
                };
                month_start(y, m) - off_ms
            }
        }
    }
}

/// 00:00 UTC on the first of month `m` of year `y`, in ms.
fn month_start(y: i32, m: u32) -> i64 {
    chrono::NaiveDate::from_ymd_opt(y, m, 1)
        .and_then(|d| d.and_hms_opt(0, 0, 0))
        .map_or(0, |t| t.and_utc().timestamp_millis())
}

/// What the breakdown groups by.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum By {
    Chief,
    /// The Chief's own turns (`chief`), its compactor and each subagent.
    Agent,
    Model,
    Harness,
    Kind,
}

impl By {
    pub fn name(self) -> &'static str {
        match self {
            By::Chief => "chief",
            By::Agent => "agent",
            By::Model => "model",
            By::Harness => "harness",
            By::Kind => "kind",
        }
    }

    pub fn parse(text: &str) -> Option<By> {
        Some(match text {
            "chief" => By::Chief,
            "agent" => By::Agent,
            "model" => By::Model,
            "harness" => By::Harness,
            "kind" => By::Kind,
            _ => return None,
        })
    }
}

/// One Chief whose ledger is summarized.
#[derive(Clone, Debug)]
pub struct Chief {
    /// Its id (`chief-id` in its home), or `default`.
    pub id: String,
    pub label: String,
    /// Its mux home.
    pub home: String,
}

/// What [`summarize`] reports.
#[derive(Clone, Copy, Debug)]
pub struct Query {
    pub since_ms: u64,
    pub until_ms: u64,
    pub bucket: Bucket,
    pub by: By,
    /// How many of the most expensive units to list.
    pub top: usize,
    /// The local time's offset from UTC, in seconds (buckets are local).
    pub offset_s: i32,
}

/// Sums over a set of lines.
#[derive(Default)]
struct Agg {
    units: u64,
    turns: u64,
    input: u64,
    output: u64,
    cache_read: u64,
    cache_write: u64,
    usd: f64,
    ms: Vec<u64>,
    ttft: Vec<u64>,
    start: Vec<u64>,
}

impl Agg {
    fn add(&mut self, l: &Line) {
        self.units += 1;
        self.input += l.input;
        self.output += l.output;
        self.cache_read += l.cache_read;
        self.cache_write += l.cache_write;
        self.usd += l.usd.unwrap_or(0.0);
        // Latency is what a person waits on: the Chief's turns.
        if l.kind == "turn" {
            self.turns += 1;
            self.ms.extend(l.ms);
            self.ttft.extend(l.ttft_ms);
            self.start.extend(l.start_ms);
        }
    }

    fn json(&mut self) -> Value {
        let read = self.cache_read;
        let all = read + self.cache_write + self.input;
        let hit = (all > 0).then(|| read as f64 / all as f64);
        json!({
            "units": self.units,
            "turns": self.turns,
            "input": self.input,
            "output": self.output,
            "cache_read": self.cache_read,
            "cache_write": self.cache_write,
            "usd": self.usd,
            "hit": hit,
            "ms_p50": percentile(&mut self.ms, 0.5),
            "ms_p95": percentile(&mut self.ms, 0.95),
            "ttft_p50": percentile(&mut self.ttft, 0.5),
            "ttft_p95": percentile(&mut self.ttft, 0.95),
            "start_p50": percentile(&mut self.start, 0.5),
            "start_p95": percentile(&mut self.start, 0.95),
        })
    }
}

/// The nearest-rank percentile `p` of `values`, or None when empty.
fn percentile(values: &mut [u64], p: f64) -> Option<u64> {
    if values.is_empty() {
        return None;
    }
    values.sort_unstable();
    let rank = (p * values.len() as f64).ceil() as usize;
    Some(values[rank.clamp(1, values.len()) - 1])
}

/// The breakdown key and label of `line` of `chief`.
fn group(by: By, chief: &Chief, line: &Line) -> (String, String) {
    let unknown = || "unknown".to_owned();
    let key = match by {
        By::Chief => return (chief.id.clone(), chief.label.clone()),
        By::Agent => match line.kind.as_str() {
            "turn" => "chief".to_owned(),
            "compactor" => "compactor".to_owned(),
            _ => line.agent.clone().unwrap_or_else(unknown),
        },
        By::Model => line.model.clone().unwrap_or_else(unknown),
        By::Harness => line.harness.clone().unwrap_or_else(unknown),
        By::Kind => line.kind.clone(),
    };
    (key.clone(), key)
}

/// The app's link to a subagent line's chat, when its session is known.
fn link(chief: &Chief, line: &Line) -> Option<String> {
    let session = line.session.as_deref()?;
    let ok = session
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.');
    (ok && !session.is_empty()).then(|| {
        format!(
            "cmux://chief/{}/session/{session}",
            crate::paths::home_id(Path::new(&chief.home))
        )
    })
}

/// The summary of `chiefs`' lines in the query's window: totals, one point
/// per bucket (empty buckets included), the breakdown (most expensive
/// first) and the most expensive units.
pub fn summarize(chiefs: &[(Chief, Vec<Line>)], q: &Query) -> Value {
    let off = i64::from(q.offset_s) * 1000;
    let (since, until) = (q.since_ms as i64, q.until_ms as i64);
    let mut starts = Vec::new();
    let mut index = HashMap::new();
    let mut t = q.bucket.start(since, off);
    while t < until && starts.len() < 10_000 {
        index.insert(t, starts.len());
        starts.push(t);
        t = q.bucket.next(t, off);
    }
    let mut series: Vec<Agg> = starts.iter().map(|_| Agg::default()).collect();
    let mut totals = Agg::default();
    let mut groups: BTreeMap<String, (String, Agg)> = BTreeMap::new();
    let mut top: Vec<(&Chief, &Line)> = Vec::new();
    for (chief, lines) in chiefs {
        for line in lines {
            if line.ts < q.since_ms || line.ts >= q.until_ms {
                continue;
            }
            totals.add(line);
            if let Some(i) = index.get(&q.bucket.start(line.ts as i64, off)) {
                series[*i].add(line);
            }
            let (key, label) = group(q.by, chief, line);
            groups
                .entry(key)
                .or_insert_with(|| (label, Agg::default()))
                .1
                .add(line);
            if q.top > 0 {
                top.push((chief, line));
            }
        }
    }
    let mut by: Vec<(String, String, Agg)> =
        groups.into_iter().map(|(k, (l, a))| (k, l, a)).collect();
    by.sort_by(|a, b| {
        b.2.usd
            .total_cmp(&a.2.usd)
            .then_with(|| {
                (b.2.input + b.2.output + b.2.cache_read + b.2.cache_write)
                    .cmp(&(a.2.input + a.2.output + a.2.cache_read + a.2.cache_write))
            })
            .then_with(|| a.0.cmp(&b.0))
    });
    top.sort_by(|a, b| {
        b.1.usd
            .unwrap_or(0.0)
            .total_cmp(&a.1.usd.unwrap_or(0.0))
            .then_with(|| b.1.tokens().cmp(&a.1.tokens()))
            .then_with(|| b.1.ts.cmp(&a.1.ts))
    });
    top.truncate(q.top);
    json!({
        "v": VERSION,
        "since": q.since_ms,
        "until": q.until_ms,
        "bucket": q.bucket.name(),
        "by_kind": q.by.name(),
        "chiefs": chiefs.iter().map(|(c, _)| json!({"id": c.id, "label": c.label, "home": c.home})).collect::<Vec<_>>(),
        "totals": totals.json(),
        "series": starts.iter().zip(series.iter_mut()).map(|(t, a)| {
            let mut point = a.json();
            point["t"] = json!(t);
            point
        }).collect::<Vec<_>>(),
        "by": by.into_iter().map(|(key, label, mut a)| {
            let mut row = a.json();
            row["key"] = json!(key);
            row["label"] = json!(label);
            row
        }).collect::<Vec<_>>(),
        "top": top.into_iter().map(|(c, l)| json!({
            "ts": l.ts,
            "chief": c.id,
            "kind": l.kind,
            "agent": l.agent,
            "key": l.key,
            "model": l.model,
            "harness": l.harness,
            "usd": l.usd,
            "input": l.input,
            "output": l.output,
            "cache_read": l.cache_read,
            "cache_write": l.cache_write,
            "ms": l.ms,
            "link": link(c, l),
        })).collect::<Vec<_>>(),
    })
}

/// Parsed `optchat-chief usage` arguments.
#[derive(Debug)]
struct Args {
    backfill: bool,
    force: bool,
    since_ms: u64,
    until_ms: u64,
    bucket: Option<Bucket>,
    by: By,
    top: usize,
    json: bool,
    homes: Vec<PathBuf>,
    chiefs: bool,
}

/// `30m`, `24h`, `7d`, `2w`, `1y` (a bare number is minutes), or `all`.
fn window_ms(text: &str) -> Result<u64, String> {
    let text = text.trim();
    if text == "all" {
        return Ok(u64::MAX / 2);
    }
    if let Some(n) = text.strip_suffix('w') {
        return crate::report::duration_ms(&format!("{n}d")).map(|d| d * 7);
    }
    if let Some(n) = text.strip_suffix('y') {
        return crate::report::duration_ms(&format!("{n}d")).map(|d| d * 365);
    }
    crate::report::duration_ms(text)
}

fn parse(args: &[String]) -> Result<Args, String> {
    let mut words = args.to_vec();
    let backfill = words.first().is_some_and(|w| w == "backfill");
    if backfill {
        words.remove(0);
    }
    let (mut since, mut until) = ("7d".to_owned(), "0".to_owned());
    let mut out = Args {
        backfill,
        force: false,
        since_ms: 0,
        until_ms: 0,
        bucket: None,
        by: By::Chief,
        top: 10,
        json: false,
        homes: Vec::new(),
        chiefs: false,
    };
    let mut i = 0;
    while i < words.len() {
        let (key, inline) = match words[i].split_once('=') {
            Some((k, v)) => (k.to_owned(), Some(v.to_owned())),
            None => (words[i].clone(), None),
        };
        let mut value = || -> Result<String, String> {
            if let Some(v) = &inline {
                return Ok(v.clone());
            }
            i += 1;
            words.get(i).cloned().ok_or(format!("{key} needs a value"))
        };
        match key.as_str() {
            "--json" => out.json = true,
            "--force" => out.force = true,
            "--chiefs" => out.chiefs = true,
            "--since" => since = value()?,
            "--until" => until = value()?,
            "--bucket" => {
                let v = value()?;
                out.bucket = Some(
                    Bucket::parse(&v)
                        .ok_or(format!("bad --bucket {v:?} (hour, day, week, month)"))?,
                );
            }
            "--by" => {
                let v = value()?;
                out.by = By::parse(&v).ok_or(format!(
                    "bad --by {v:?} (chief, agent, model, harness, kind)"
                ))?;
            }
            "--top" => {
                let v = value()?;
                out.top = v.parse().map_err(|_| format!("bad --top {v:?}"))?;
            }
            "--mux-home" => out.homes.push(PathBuf::from(value()?)),
            other => return Err(format!("unknown argument {other}")),
        }
        i += 1;
    }
    let now = now_ms();
    out.until_ms = if until == "0" || until == "now" {
        now + 1
    } else {
        now.saturating_sub(window_ms(&until)?)
    };
    out.since_ms = out.until_ms.saturating_sub(window_ms(&since)?);
    Ok(out)
}

/// The Chief of mux home `home`: its `chief-id`, else `default`.
fn chief_of(home: &Path) -> Chief {
    let id = std::fs::read_to_string(home.join("chief-id"))
        .ok()
        .map(|t| t.trim().to_owned())
        .filter(|t| !t.is_empty())
        .unwrap_or_else(|| "default".to_owned());
    Chief {
        label: id.clone(),
        id,
        home: home.display().to_string(),
    }
}

/// The homes to read: the given ones (else this host's), and with
/// `chiefs` each Chief under their `c/` directory.
fn homes(args: &Args) -> Vec<PathBuf> {
    let mut homes = if args.homes.is_empty() {
        vec![crate::paths::mux_home()]
    } else {
        args.homes.clone()
    };
    if args.chiefs || args.homes.is_empty() {
        let mut more = Vec::new();
        for home in &homes {
            if let Ok(entries) = std::fs::read_dir(home.join("c")) {
                let mut found: Vec<PathBuf> = entries
                    .flatten()
                    .map(|e| e.path())
                    .filter(|p| p.join("optchat").is_dir())
                    .collect();
                found.sort();
                more.extend(found);
            }
        }
        homes.extend(more);
    }
    homes
}

fn usd(x: f64) -> String {
    if x != 0.0 && x.abs() < 0.01 {
        format!("${x:.4}")
    } else {
        format!("${x:.2}")
    }
}

fn pct(x: &Value) -> String {
    x.as_f64()
        .map_or("-".to_owned(), |x| format!("{:.0}%", x * 100.0))
}

fn secs(x: &Value) -> String {
    x.as_u64()
        .map_or("-".to_owned(), |ms| format!("{:.1} s", ms as f64 / 1000.0))
}

fn count(x: &Value) -> String {
    let n = x.as_u64().unwrap_or(0);
    match n {
        0..1_000 => n.to_string(),
        1_000..1_000_000 => format!("{:.1}k", n as f64 / 1e3),
        _ => format!("{:.1}M", n as f64 / 1e6),
    }
}

fn clock(ts: u64) -> String {
    chrono::DateTime::from_timestamp_millis(ts as i64)
        .map(|t| {
            t.with_timezone(&chrono::Local)
                .format("%Y-%m-%d %H:%M")
                .to_string()
        })
        .unwrap_or_default()
}

/// The summary as plain text.
fn text(s: &Value, by: By) -> String {
    let t = &s["totals"];
    let turns = t["turns"].as_u64().unwrap_or(0);
    let mut out = format!(
        "Chief usage {} to {} (by {})\n",
        clock(u(s, "since")),
        clock(u(s, "until")),
        by.name()
    );
    out.push_str(&format!(
        "  {} · {turns} turn{} · {} units · tokens in {} out {} cache read {} write {} · cache hit {}\n",
        usd(t["usd"].as_f64().unwrap_or(0.0)),
        if turns == 1 { "" } else { "s" },
        t["units"],
        count(&t["input"]),
        count(&t["output"]),
        count(&t["cache_read"]),
        count(&t["cache_write"]),
        pct(&t["hit"]),
    ));
    out.push_str(&format!(
        "  turn time p50 {} p95 {} · first token p50 {} · process start p50 {}\n",
        secs(&t["ms_p50"]),
        secs(&t["ms_p95"]),
        secs(&t["ttft_p50"]),
        secs(&t["start_p50"]),
    ));
    out.push_str(&format!("\nBy {}:\n", by.name()));
    for row in s["by"].as_array().into_iter().flatten() {
        out.push_str(&format!(
            "  {:<32} {:>10}  {:>5} units  hit {:>4}\n",
            row["label"].as_str().unwrap_or("?"),
            usd(row["usd"].as_f64().unwrap_or(0.0)),
            row["units"],
            pct(&row["hit"]),
        ));
    }
    let top = s["top"].as_array().cloned().unwrap_or_default();
    if !top.is_empty() {
        out.push_str("\nMost expensive:\n");
        for row in top {
            out.push_str(&format!(
                "  {} {:>10}  {} {} {} {}\n",
                clock(u(&row, "ts")),
                usd(row["usd"].as_f64().unwrap_or(0.0)),
                row["kind"].as_str().unwrap_or("?"),
                row["agent"]
                    .as_str()
                    .unwrap_or(row["key"].as_str().unwrap_or("")),
                row["model"].as_str().unwrap_or("-"),
                row["link"].as_str().unwrap_or(""),
            ));
        }
    }
    out
}

/// Runs `optchat-chief usage`; Ok carries what to print.
pub fn run(args: &[String]) -> Result<String, String> {
    let args = parse(args)?;
    let homes = homes(&args);
    if args.backfill {
        let mut out = String::new();
        for home in &homes {
            let root = crate::paths::Paths::new(home).root;
            let report = backfill(&root, args.force)?;
            out.push_str(&format!(
                "{}: {} line(s) from {} trace file(s)\n",
                home.display(),
                report.lines,
                report.files
            ));
        }
        return Ok(out);
    }
    let mut chiefs = Vec::new();
    for home in &homes {
        let root = crate::paths::Paths::new(home).root;
        let ledger = dir(&root);
        if !ledger.join("backfill.json").exists() && root.join("traces").is_dir() {
            // Another reader backfilling now: read what is there.
            let _ = backfill(&root, false);
        }
        chiefs.push((chief_of(home), read(&ledger, args.since_ms, args.until_ms)?));
    }
    let q = Query {
        since_ms: args.since_ms,
        until_ms: args.until_ms,
        bucket: args
            .bucket
            .unwrap_or_else(|| Bucket::for_window(args.until_ms - args.since_ms)),
        by: args.by,
        top: args.top,
        offset_s: chrono::Local::now().offset().local_minus_utc(),
    };
    let summary = summarize(&chiefs, &q);
    Ok(if args.json {
        format!("{summary}\n")
    } else {
        text(&summary, args.by)
    })
}
