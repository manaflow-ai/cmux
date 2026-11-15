//! Chief product analytics: anonymous, content-free events to PostHog
//! (docs/posthog/chief-product-analytics.md).
//!
//! The monitoring trace (`trace.rs`) hands every event to
//! [`Analytics::observe`] after it wrote the trace line, and every usage
//! ledger line to [`Analytics::observe_unit`]. `catalog::map` turns a trace
//! event into closed-schema PostHog events; those are appended to
//! `<optchat root>/analytics/queue.jsonl` (0600 in a 0700 directory) and the
//! caller returns. One thread, `chief-analytics`, sends the queue in batches
//! to PostHog's `/batch/` endpoint: right away once [`BATCH`] events wait,
//! else every [`FLUSH`]. A failed send keeps the batch and backs off (to
//! [`MAX_BACKOFF`]), so an offline Mac sends later; the queue stops growing
//! at [`MAX_QUEUE_BYTES`] and counts what it dropped. With nothing queued
//! the thread wakes only to re-read consent (every [`CONSENT_EVERY`]).
//!
//! Consent (`consent.rs`) is read at start and on each wake: when it turns
//! off, the queue is deleted and nothing more is written or sent.
//!
//! Identity: a random install id (`analytics/state.json`), never derived
//! from the machine, the user name or the home. A Cloud Chief, whose host
//! knows the signed-in Stack user, sends as that user (the same id the
//! server's `cloud_vm_*` and billing events use) with the `stack_team`
//! group. IP geolocation is off for every event.

pub mod catalog;
pub mod consent;

use std::io::{BufRead, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

pub use catalog::{Event, State};
pub use consent::Consent;

/// The main cmux PostHog project's public ingestion key (project 244066,
/// the one the classic app, the web and the server send to). A public key:
/// it can only write events.
pub const PROJECT_KEY: &str = "phc_opOVu7oFzR9wD3I6ZahFGOV2h3mqGpl5EHyQvmHciDP";
/// PostHog US ingestion.
pub const HOST: &str = "https://us.i.posthog.com";
/// Events per request, and the queue length that sends at once.
pub const BATCH: usize = 50;
/// Longest a queued event waits before a send is tried.
pub const FLUSH: Duration = Duration::from_secs(60);
/// How often consent is re-read while nothing is queued.
pub const CONSENT_EVERY: Duration = Duration::from_secs(300);
/// Longest wait after failed sends.
pub const MAX_BACKOFF: Duration = Duration::from_secs(30 * 60);
/// The queue file stops growing here (about 2,000 events).
pub const MAX_QUEUE_BYTES: u64 = 2 * 1024 * 1024;
const TIMEOUT: Duration = Duration::from_secs(20);

/// Who this host is, for the shared properties.
#[derive(Clone, Debug, Default)]
pub struct Config {
    /// `local` or `cloud`.
    pub source: &'static str,
    /// A Cloud Chief's signed-in Stack user id and team id.
    pub person: Option<String>,
    pub team: Option<String>,
    /// `OPTCHAT_BUILD_COMMIT`, or `unknown`.
    pub build: String,
    /// `stable`, `nightly`, `rc`, `dev`, `cli` or `cloud`.
    pub channel: String,
    /// The cmux app's version, when the app started this host.
    pub app_version: Option<String>,
    /// The turn engine: `acpmux` or `native`.
    pub engine: &'static str,
    /// Where events go; tests point it at a local server.
    pub endpoint: String,
}

impl Config {
    /// The production endpoint.
    pub fn endpoint() -> String {
        format!("{HOST}/batch/")
    }
}

/// The analytics of one Chief host. Clones share one queue and one sender.
#[derive(Clone)]
pub struct Analytics {
    inner: Arc<Inner>,
}

impl std::fmt::Debug for Analytics {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Analytics({})", self.inner.dir.display())
    }
}

struct Inner {
    dir: PathBuf,
    config: Config,
    /// The consent decision's environment (`production` or `dev`); sending
    /// and writing stop while it is off.
    on: AtomicBool,
    environment: Mutex<&'static str>,
    /// The random install id (`analytics/id`), made the first time
    /// consent is on: a host that never sends writes nothing.
    install_id: std::sync::OnceLock<String>,
    state: Mutex<State>,
    /// Events appended to the queue file since the last send.
    queued: AtomicUsize,
    wake: Condvar,
    wake_lock: Mutex<bool>,
    /// Serializes queue appends with the sender's rename.
    queue_lock: Mutex<()>,
}

/// `<optchat root>/analytics`.
pub fn dir(root: &Path) -> PathBuf {
    root.join("analytics")
}

impl Analytics {
    /// Opens the analytics of the Chief whose optchat root is `root`, reads
    /// consent once, and starts the sender. None when the directory cannot
    /// be made. `read_consent` is called again on every wake.
    pub fn open(
        root: &Path,
        config: Config,
        read_consent: impl Fn() -> Consent + Send + 'static,
    ) -> Option<Analytics> {
        let dir = dir(root);
        let now = now_ms();
        let state = load_state(&dir);
        let decision = read_consent();
        let inner = Arc::new(Inner {
            dir,
            config,
            on: AtomicBool::new(matches!(decision, Consent::Send(_))),
            environment: Mutex::new(match decision {
                Consent::Send(env) => env,
                Consent::Off(_) => "production",
            }),
            install_id: std::sync::OnceLock::new(),
            state: Mutex::new(state),
            queued: AtomicUsize::new(0),
            wake: Condvar::new(),
            wake_lock: Mutex::new(false),
            queue_lock: Mutex::new(()),
        });
        let analytics = Analytics { inner };
        match decision {
            Consent::Off(_) => analytics.clear(),
            Consent::Send(_) if analytics.ready() => analytics.started(now),
            Consent::Send(_) => analytics.inner.on.store(false, Ordering::Relaxed),
        }
        let worker = analytics.clone();
        std::thread::Builder::new()
            .name("chief-analytics".into())
            .spawn(move || worker.run(read_consent))
            .ok()?;
        Some(analytics)
    }

    /// Whether events are written and sent now.
    pub fn is_on(&self) -> bool {
        self.inner.on.load(Ordering::Relaxed)
    }

    /// Makes the directory and the install id; false when they cannot be made.
    fn ready(&self) -> bool {
        if self.inner.install_id.get().is_some() {
            return true;
        }
        if make_dir(&self.inner.dir).is_err() {
            return false;
        }
        match install_id(&self.inner.dir) {
            Some(id) => {
                let _ = self.inner.install_id.set(id);
                true
            }
            None => false,
        }
    }

    fn started(&self, now: u64) {
        let new_install = {
            let mut state = self.lock_state();
            let new = state.installed_ms == 0;
            if new {
                state.installed_ms = now;
            }
            new
        };
        let mut events = vec![catalog::Event {
            name: "chief_host_started",
            properties: json!({"is_new_install": new_install, "engine": self.inner.config.engine})
                .as_object()
                .cloned()
                .unwrap_or_default(),
        }];
        let mut state = self.lock_state();
        events.extend(catalog::milestone(&mut state, "first_host_start", now));
        let rolled = self.roll_usage(&mut state, now);
        events.extend(rolled);
        save_state(&self.inner.dir, &state);
        drop(state);
        self.enqueue(events, now);
    }

    /// One trace event (`{"ts", "ev", ...}`).
    pub fn observe(&self, trace: &Value) {
        if !self.is_on() {
            return;
        }
        let now = trace
            .get("ts")
            .and_then(Value::as_u64)
            .unwrap_or_else(now_ms);
        let events = {
            let mut state = self.lock_state();
            if !self.is_on() {
                return;
            }
            let before = state.clone();
            let events = catalog::map(trace, &mut state, now);
            if *state != before {
                save_state(&self.inner.dir, &state);
            }
            events
        };
        self.enqueue(events, now);
    }

    /// One usage ledger line (a turn, a compactor node or a subagent
    /// prompt): added to the day's rollup, which goes as
    /// `chief_usage_daily` once the UTC day is over.
    pub fn observe_unit(&self, line: &crate::usage::Line) {
        if !self.is_on() {
            return;
        }
        let now = if line.ts > 0 { line.ts } else { now_ms() };
        let events = {
            let mut state = self.lock_state();
            // Consent may have turned off (and cleared the rollup) since the check above.
            if !self.is_on() {
                return;
            }
            let events = self.roll_usage(&mut state, now);
            state.usage.add(line);
            save_state(&self.inner.dir, &state);
            events
        };
        self.enqueue(events, now);
    }

    /// The finished day's rollup when `now` is a later UTC day.
    fn roll_usage(&self, state: &mut State, now: u64) -> Vec<Event> {
        let day = catalog::utc_day(now);
        if state.usage_day == day {
            return Vec::new();
        }
        let done = std::mem::take(&mut state.usage);
        let done_day = std::mem::replace(&mut state.usage_day, day);
        if done.is_empty() || done_day.is_empty() {
            return Vec::new();
        }
        vec![catalog::Event {
            name: "chief_usage_daily",
            properties: done
                .properties(&done_day)
                .as_object()
                .cloned()
                .unwrap_or_default(),
        }]
    }

    fn lock_state(&self) -> std::sync::MutexGuard<'_, State> {
        self.inner
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Appends `events` to the queue file; wakes the sender when the queue
    /// was empty (to send within [`FLUSH`]) and when a batch fills. False
    /// when nothing was written (off, full, or a failed write).
    fn enqueue(&self, events: Vec<Event>, now: u64) -> bool {
        if events.is_empty() || !self.is_on() {
            return false;
        }
        let mut bytes = Vec::new();
        for e in &events {
            bytes.extend(self.wire(e, now).to_string().into_bytes());
            bytes.push(b'\n');
        }
        let queue = self.inner.dir.join("queue.jsonl");
        {
            let _guard = self
                .inner
                .queue_lock
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            // Again under the lock: `clear` (consent off) takes it too, so
            // no write lands after the queue was deleted.
            if !self.is_on() {
                return false;
            }
            let size = std::fs::metadata(&queue).map_or(0, |m| m.len());
            if size + bytes.len() as u64 > MAX_QUEUE_BYTES {
                let mut state = self.lock_state();
                state.dropped = state.dropped.saturating_add(events.len() as u64);
                save_state(&self.inner.dir, &state);
                return false;
            }
            let opened = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .mode(0o600)
                .open(&queue);
            if opened.and_then(|mut f| f.write_all(&bytes)).is_err() {
                return false;
            }
        }
        let before = self.inner.queued.fetch_add(events.len(), Ordering::Relaxed);
        let queued = before + events.len();
        if before == 0 || (before < BATCH && queued >= BATCH) {
            self.notify();
        }
        true
    }

    /// The event as PostHog's batch API takes it, with the shared properties.
    fn wire(&self, e: &Event, now: u64) -> Value {
        let c = &self.inner.config;
        let mut p: Map<String, Value> = e.properties.clone();
        p.retain(|_, v| !v.is_null());
        let install = self.inner.install_id.get().cloned().unwrap_or_default();
        let distinct = c.person.clone().unwrap_or_else(|| install.clone());
        p.insert("distinct_id".into(), json!(distinct));
        p.insert("chief_install_id".into(), json!(install));
        p.insert("product".into(), json!("chief"));
        p.insert("schema_version".into(), json!(1));
        p.insert("source".into(), json!(c.source));
        p.insert("channel".into(), json!(c.channel));
        p.insert("chief_build".into(), json!(short_build(&c.build)));
        p.insert("chief_version".into(), json!(env!("CARGO_PKG_VERSION")));
        if let Some(v) = &c.app_version {
            p.insert("app_version".into(), json!(v));
        }
        p.insert("os".into(), json!(std::env::consts::OS));
        p.insert("arch".into(), json!(std::env::consts::ARCH));
        p.insert("environment".into(), json!(*self.lock_env()));
        p.insert("$lib".into(), json!("optchat-chief"));
        p.insert("$lib_version".into(), json!(env!("CARGO_PKG_VERSION")));
        p.insert("$geoip_disable".into(), json!(true));
        if let Some(team) = &c.team {
            p.insert("$groups".into(), json!({"stack_team": team}));
        }
        if e.name == "chief_activation_milestone_reached"
            && p.get("milestone").and_then(Value::as_str) == Some("first_host_start")
        {
            p.insert("$set_once".into(), json!({"chief_first_seen_ms": now}));
        }
        json!({
            "event": e.name,
            "uuid": uuid_v4(),
            "timestamp": chrono::DateTime::from_timestamp_millis(i64::try_from(now).unwrap_or(0))
                .map(|t| t.to_rfc3339_opts(chrono::SecondsFormat::Millis, true)),
            "properties": p,
        })
    }

    fn lock_env(&self) -> std::sync::MutexGuard<'_, &'static str> {
        self.inner
            .environment
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn notify(&self) {
        let mut flag = self
            .inner
            .wake_lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        *flag = true;
        self.inner.wake.notify_one();
    }

    /// Sends what is queued now (tests).
    pub fn flush(&self) -> Result<usize, String> {
        self.send_pending()
    }

    /// Deletes the queue, the batch in flight and the day's rollup. Never
    /// makes the directory: a host that was never on writes nothing.
    fn clear(&self) {
        let _guard = self
            .inner
            .queue_lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let _ = std::fs::remove_file(self.inner.dir.join("queue.jsonl"));
        let _ = std::fs::remove_file(self.inner.dir.join("sending.jsonl"));
        self.inner.queued.store(0, Ordering::Relaxed);
        let mut state = self.lock_state();
        state.usage = Default::default();
        state.dropped = 0;
        if self.inner.dir.exists() {
            save_state(&self.inner.dir, &state);
        }
    }

    /// Applies a consent decision now (the sender does this on every wake).
    pub fn apply_consent(&self, decision: Consent) {
        match decision {
            Consent::Send(env) => {
                *self.lock_env() = env;
                let was = self.inner.on.load(Ordering::Relaxed);
                if !was && self.ready() {
                    self.inner.on.store(true, Ordering::Relaxed);
                    self.started(now_ms());
                }
            }
            Consent::Off(_) => {
                if self.inner.on.swap(false, Ordering::Relaxed) {
                    self.clear();
                }
            }
        }
    }

    fn run(&self, read_consent: impl Fn() -> Consent) {
        let mut backoff = FLUSH;
        let mut last_try = Instant::now();
        let mut failing = false;
        loop {
            let queued = self.inner.queued.load(Ordering::Relaxed);
            let pending = queued > 0 || self.inner.dir.join("sending.jsonl").exists();
            let wait = if pending {
                backoff.min(CONSENT_EVERY)
            } else {
                CONSENT_EVERY
            };
            {
                let flag = self
                    .inner
                    .wake_lock
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                let (mut flag, _) = self
                    .inner
                    .wake
                    .wait_timeout_while(flag, wait, |woken| !*woken)
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                *flag = false;
            }
            self.apply_consent(read_consent());
            if !self.is_on() {
                continue;
            }
            self.dropped_note();
            // A full batch goes at once, unless sends are failing: then
            // every try waits out the backoff (offline, 429, 5xx).
            let full = self.inner.queued.load(Ordering::Relaxed) >= BATCH;
            if (!full || failing) && last_try.elapsed() < backoff {
                continue;
            }
            last_try = Instant::now();
            match self.send_pending() {
                Ok(_) => {
                    backoff = FLUSH;
                    failing = false;
                }
                Err(_) => {
                    backoff = (backoff * 2).min(MAX_BACKOFF);
                    failing = true;
                }
            }
        }
    }

    /// A `chief_analytics_dropped` for events the full queue refused.
    fn dropped_note(&self) {
        let dropped = {
            let mut state = self.lock_state();
            let n = std::mem::take(&mut state.dropped);
            if n > 0 {
                save_state(&self.inner.dir, &state);
            }
            n
        };
        if dropped > 0 {
            let note = catalog::Event {
                name: "chief_analytics_dropped",
                properties: json!({"count": dropped})
                    .as_object()
                    .cloned()
                    .unwrap_or_default(),
            };
            // Still full: the count waits for the next wake, not lost.
            if !self.enqueue(vec![note], now_ms()) && self.is_on() {
                // `enqueue` counted the refused note itself; count only what it stood for.
                let mut state = self.lock_state();
                state.dropped = state.dropped.saturating_sub(1).saturating_add(dropped);
                save_state(&self.inner.dir, &state);
            }
        }
    }

    /// Sends `sending.jsonl` (a batch a failed send kept), then the queue.
    /// The queue is renamed under the append lock, so no event is lost
    /// between reading and deleting it.
    fn send_pending(&self) -> Result<usize, String> {
        if !self.is_on() {
            return Ok(0);
        }
        let sending = self.inner.dir.join("sending.jsonl");
        let mut sent = 0;
        if sending.exists() {
            sent += self.send_file(&sending)?;
        }
        {
            let _guard = self
                .inner
                .queue_lock
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let queue = self.inner.dir.join("queue.jsonl");
            if !queue.exists() {
                return Ok(sent);
            }
            std::fs::rename(&queue, &sending).map_err(|e| e.to_string())?;
            self.inner.queued.store(0, Ordering::Relaxed);
        }
        sent += self.send_file(&sending)?;
        Ok(sent)
    }

    /// Posts `file`'s events in batches; deletes it when all went. A batch
    /// the server refused as malformed (400) is dropped, not retried forever.
    fn send_file(&self, file: &Path) -> Result<usize, String> {
        let reader = std::io::BufReader::new(std::fs::File::open(file).map_err(|e| e.to_string())?);
        let events: Vec<Value> = reader
            .lines()
            .map_while(Result::ok)
            .filter_map(|l| serde_json::from_str(&l).ok())
            .collect();
        let mut sent = 0;
        for (n, chunk) in events.chunks(BATCH).enumerate() {
            match post(&self.inner.config.endpoint, chunk) {
                Ok(()) | Err(PostError::Refused) => sent += chunk.len(),
                Err(PostError::Retry(e)) => {
                    // Keep what is not sent yet for the next try.
                    let rest: Vec<u8> = events
                        .iter()
                        .skip(n * BATCH)
                        .flat_map(|v| {
                            let mut b = v.to_string().into_bytes();
                            b.push(b'\n');
                            b
                        })
                        .collect();
                    let _ = write_private(file, &rest);
                    return Err(e);
                }
            }
        }
        let _ = std::fs::remove_file(file);
        Ok(sent)
    }
}

enum PostError {
    /// Offline, a timeout, a 5xx or a 429: try again later.
    Retry(String),
    /// The server refused the batch itself (4xx): never sent again.
    Refused,
}

fn post(endpoint: &str, batch: &[Value]) -> Result<(), PostError> {
    let body = json!({"api_key": PROJECT_KEY, "batch": batch});
    match ureq::post(endpoint)
        .timeout(TIMEOUT)
        .set("Content-Type", "application/json")
        .send_string(&body.to_string())
    {
        Ok(_) => Ok(()),
        Err(ureq::Error::Status(code, _)) if code == 429 || code >= 500 => {
            Err(PostError::Retry(format!("HTTP {code}")))
        }
        Err(ureq::Error::Status(_, _)) => Err(PostError::Refused),
        Err(ureq::Error::Transport(t)) => Err(PostError::Retry(t.kind().to_string())),
    }
}

fn short_build(build: &str) -> String {
    let b: String = build.chars().take(12).collect();
    if !b.is_empty() && b.chars().all(|c| c.is_ascii_hexdigit()) {
        b
    } else {
        "unknown".into()
    }
}

fn now_ms() -> u64 {
    u64::try_from(chrono::Utc::now().timestamp_millis()).unwrap_or(0)
}

fn make_dir(dir: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)?;
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
}

fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let tmp = path.with_extension("tmp");
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)?;
    f.write_all(bytes)?;
    drop(f);
    std::fs::rename(tmp, path)
}

fn load_state(dir: &Path) -> State {
    std::fs::read(dir.join("state.json"))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

fn save_state(dir: &Path, state: &State) {
    if let Ok(bytes) = serde_json::to_vec(state) {
        let _ = write_private(&dir.join("state.json"), &bytes);
    }
}

/// The install id in `analytics/id`, made once: 16 random bytes as a v4 UUID.
fn install_id(dir: &Path) -> Option<String> {
    let path = dir.join("id");
    if let Ok(text) = std::fs::read_to_string(&path) {
        let id = text.trim();
        if id.len() == 36 && id.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-') {
            return Some(id.to_owned());
        }
    }
    let id = uuid_v4();
    write_private(&path, id.as_bytes()).ok()?;
    Some(id)
}

/// A random v4 UUID (PostHog dedupes events by it).
pub fn uuid_v4() -> String {
    use ring::rand::SecureRandom;
    let mut b = [0u8; 16];
    if ring::rand::SystemRandom::new().fill(&mut b).is_err() {
        let n = now_ms().to_le_bytes();
        b[..8].copy_from_slice(&n);
    }
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let h: String = b.iter().map(|x| format!("{x:02x}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &h[0..8],
        &h[8..12],
        &h[12..16],
        &h[16..20],
        &h[20..32]
    )
}

/// This build's channel: from the bundle id of the app that started the
/// host (`CMUX_CHIEF_APP_BUNDLE_ID`), else from where the binary is.
pub fn channel(source: &str, env: &dyn Fn(&str) -> Option<String>, exe: Option<&Path>) -> String {
    if source == "cloud" {
        return "cloud".into();
    }
    if let Some(id) = env("CMUX_CHIEF_APP_BUNDLE_ID").filter(|id| !id.trim().is_empty()) {
        return match id.trim().strip_prefix("com.cmuxterm.app") {
            Some("") => "stable",
            Some(".nightly") => "nightly",
            Some(".rc") => "rc",
            _ => "dev",
        }
        .into();
    }
    let Some(app) = exe.and_then(|p| {
        p.ancestors()
            .find(|a| a.extension().is_some_and(|e| e == "app"))
            .and_then(|a| a.file_stem())
            .map(|s| s.to_string_lossy().to_ascii_lowercase())
    }) else {
        return "cli".into();
    };
    if app.contains("dev") || app.contains("debug") || app.contains("staging") {
        "dev".into()
    } else if app.contains("nightly") {
        "nightly".into()
    } else if app.contains(" rc") || app.ends_with("rc") {
        "rc".into()
    } else if app == "cmux" || app == "cmux next" {
        "stable".into()
    } else {
        "dev".into()
    }
}

/// A release build: no debug assertions and not a DEV, tagged or
/// unknown app (channel `dev`).
pub fn release_build(channel: &str) -> bool {
    !cfg!(debug_assertions) && channel != "dev"
}
