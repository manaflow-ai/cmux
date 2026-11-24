//! Who asks this daemon for what: every request, by its caller and method, counted with its bytes
//! and its reply's bytes over the last ten minutes, for `_acpmux/callers` and
//! `acpmux daemon stats`.
//!
//! A caller is the client name its `initialize` gave (`clientInfo.name`), the connection's origin,
//! the unix socket peer's pid (none for a WebSocket) and the acpmux session it named at its first
//! `initialize` (proven or not). So a client that asks too often is named well enough to find its
//! process: on 2026-11-21 one client read `listReplies` about 650 times a minute, and only an RPC
//! read named it; a client that reconnects again and again shows as many `initialize` requests.
//!
//! Constant memory: at most [`ENTRIES`] (caller, method) pairs, each a ring of [`SLOTS`] buckets of
//! [`BUCKET_SECS`]; a new pair past the cap takes the place of the one seen longest ago (counted
//! in `evicted`). No timer: a bucket is reused when its slot comes round again.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Instant;

use serde_json::{Map, Value, json};

/// At most this many (caller, method) pairs remembered.
pub const ENTRIES: usize = 512;
/// Seconds per bucket.
pub const BUCKET_SECS: u64 = 10;
/// Buckets per pair: ten minutes.
pub const SLOTS: usize = 60;
/// The longest window a read may ask for.
pub const MAX_WINDOW_SECS: u64 = BUCKET_SECS * SLOTS as u64;
/// Methods listed under each caller.
const METHODS_PER_CALLER: usize = 5;
/// Callers and methods listed when the read names no `top`.
const DEFAULT_TOP: usize = 20;

/// Who sent a request.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Caller {
    /// `clientInfo.name` of its `initialize`, `""` before one.
    pub client: String,
    /// `local`, `web`, `app` or `peer`.
    pub origin: &'static str,
    /// The unix socket peer's pid, read at accept.
    pub pid: Option<u32>,
    /// The acpmux session it named at its first `initialize`.
    pub session: Option<String>,
    /// Whether that session was proven by its token.
    pub proven: bool,
}

#[derive(Default, Clone, Copy)]
struct Bucket {
    /// The absolute bucket index (`secs / BUCKET_SECS`) these counts are of.
    slot: u64,
    requests: u32,
    request_bytes: u32,
    reply_bytes: u32,
}

struct Entry {
    ring: Box<[Bucket; SLOTS]>,
    last_secs: u64,
    total_requests: u64,
}

impl Entry {
    fn new() -> Self {
        Self { ring: Box::new([Bucket::default(); SLOTS]), last_secs: 0, total_requests: 0 }
    }

    /// The bucket of `secs`, cleared if it last held an older slot.
    #[allow(
        clippy::indexing_slicing,
        reason = "slot % SLOTS is always below SLOTS, the ring's length"
    )]
    fn bucket(&mut self, secs: u64) -> &mut Bucket {
        let slot = secs / BUCKET_SECS;
        let bucket = &mut self.ring[(slot % SLOTS as u64) as usize];
        if bucket.slot != slot {
            *bucket = Bucket { slot, ..Bucket::default() };
        }
        bucket
    }

    /// Sums over the buckets of the last `window` seconds before `now`.
    fn sum(&self, now: u64, window: u64) -> Sum {
        let current = now / BUCKET_SECS;
        let span = window.div_ceil(BUCKET_SECS).clamp(1, SLOTS as u64);
        let oldest = (current + 1).saturating_sub(span);
        let mut sum = Sum::default();
        for b in self.ring.iter().filter(|b| b.slot >= oldest && b.slot <= current) {
            sum.requests += u64::from(b.requests);
            sum.request_bytes += u64::from(b.request_bytes);
            sum.reply_bytes += u64::from(b.reply_bytes);
        }
        sum
    }
}

#[derive(Default, Clone, Copy)]
struct Sum {
    requests: u64,
    request_bytes: u64,
    reply_bytes: u64,
}

impl Sum {
    fn add(&mut self, other: Sum) {
        self.requests += other.requests;
        self.request_bytes += other.request_bytes;
        self.reply_bytes += other.reply_bytes;
    }

    fn json(self, window: u64) -> Map<String, Value> {
        let mut row = Map::new();
        row.insert("requests".into(), json!(self.requests));
        row.insert("requestBytes".into(), json!(self.request_bytes));
        row.insert("replyBytes".into(), json!(self.reply_bytes));
        row.insert(
            "perMinute".into(),
            json!((self.requests as f64 * 60.0 / window.max(1) as f64 * 10.0).round() / 10.0),
        );
        row
    }
}

#[derive(Default)]
struct State {
    entries: HashMap<(Caller, String), Entry>,
    evicted: u64,
}

/// The counts; [`global`] is this daemon's.
pub struct CallerStats {
    state: Mutex<Option<State>>,
}

impl CallerStats {
    pub const fn new() -> Self {
        Self { state: Mutex::new(None) }
    }

    fn with<R>(&self, f: impl FnOnce(&mut State) -> R) -> R {
        let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        f(state.get_or_insert_with(State::default))
    }

    /// `caller` sent a request for `method` of `bytes` (its line) at `secs` since the daemon began.
    pub fn observe_request_at(&self, caller: &Caller, method: &str, bytes: usize, secs: u64) {
        self.with(|state| {
            let entry = entry(state, caller, method);
            entry.last_secs = secs;
            entry.total_requests += 1;
            let bucket = entry.bucket(secs);
            bucket.requests = bucket.requests.saturating_add(1);
            bucket.request_bytes = bucket.request_bytes.saturating_add(clamp(bytes));
        });
    }

    /// The reply to `caller`'s `method` request was `bytes` (its line), at `secs`.
    pub fn observe_reply_at(&self, caller: &Caller, method: &str, bytes: usize, secs: u64) {
        self.with(|state| {
            let entry = entry(state, caller, method);
            entry.last_secs = secs;
            let bucket = entry.bucket(secs);
            bucket.reply_bytes = bucket.reply_bytes.saturating_add(clamp(bytes));
        });
    }

    /// [`Self::observe_request_at`] now.
    pub fn observe_request(&self, caller: &Caller, method: &str, bytes: usize) {
        self.observe_request_at(caller, method, bytes, now_secs());
    }

    /// [`Self::observe_reply_at`] now.
    pub fn observe_reply(&self, caller: &Caller, method: &str, bytes: usize) {
        self.observe_reply_at(caller, method, bytes, now_secs());
    }

    /// The `_acpmux/callers` answer at `now`: over the last `since` seconds (at most
    /// [`MAX_WINDOW_SECS`]), the `top` callers by requests, each with its busiest methods, and the
    /// `top` methods with how many callers sent them.
    pub fn report_at(&self, now: u64, since: u64, top: usize) -> Value {
        let window = since.clamp(1, MAX_WINDOW_SECS);
        let top = top.max(1);
        self.with(|state| {
            let mut callers: HashMap<&Caller, (Sum, Vec<(&str, Sum)>)> = HashMap::new();
            let mut methods: HashMap<&str, (Sum, usize)> = HashMap::new();
            for ((caller, method), entry) in &state.entries {
                let sum = entry.sum(now, window);
                if sum.requests == 0 && sum.reply_bytes == 0 {
                    continue;
                }
                let row = callers.entry(caller).or_default();
                row.0.add(sum);
                row.1.push((method.as_str(), sum));
                let m = methods.entry(method.as_str()).or_default();
                m.0.add(sum);
                m.1 += 1;
            }
            let mut callers: Vec<_> = callers.into_iter().collect();
            callers.sort_by(|a, b| {
                (b.1.0.requests, b.1.0.reply_bytes, a.0).cmp(&(
                    a.1.0.requests,
                    a.1.0.reply_bytes,
                    b.0,
                ))
            });
            let caller_count = callers.len();
            let callers: Vec<Value> = callers
                .into_iter()
                .take(top)
                .map(|(caller, (sum, mut by_method))| {
                    by_method.sort_by(|a, b| (b.1.requests, a.0).cmp(&(a.1.requests, b.0)));
                    let mut row = sum.json(window);
                    row.insert("client".into(), json!(caller.client));
                    row.insert("origin".into(), json!(caller.origin));
                    row.insert("pid".into(), json!(caller.pid));
                    row.insert("session".into(), json!(caller.session));
                    row.insert("sessionProven".into(), json!(caller.proven));
                    row.insert(
                        "methods".into(),
                        by_method
                            .into_iter()
                            .take(METHODS_PER_CALLER)
                            .map(|(method, sum)| {
                                let mut m = sum.json(window);
                                m.insert("method".into(), json!(method));
                                Value::Object(m)
                            })
                            .collect::<Vec<Value>>()
                            .into(),
                    );
                    Value::Object(row)
                })
                .collect();
            let mut methods: Vec<_> = methods.into_iter().collect();
            methods.sort_by(|a, b| (b.1.0.requests, a.0).cmp(&(a.1.0.requests, b.0)));
            let method_count = methods.len();
            let methods: Vec<Value> = methods
                .into_iter()
                .take(top)
                .map(|(method, (sum, n))| {
                    let mut row = sum.json(window);
                    row.insert("method".into(), json!(method));
                    row.insert("callers".into(), json!(n));
                    Value::Object(row)
                })
                .collect();
            json!({
                "windowSecs": window,
                "maxWindowSecs": MAX_WINDOW_SECS,
                "bucketSecs": BUCKET_SECS,
                "uptimeSecs": now,
                "entries": state.entries.len(),
                "maxEntries": ENTRIES,
                "evicted": state.evicted,
                "callerCount": caller_count,
                "methodCount": method_count,
                "callers": callers,
                "methods": methods,
            })
        })
    }

    /// The `_acpmux/callers` answer for `params` (`{sinceSecs?, top?}`).
    pub fn report(&self, params: &Value) -> Value {
        let since = params.get("sinceSecs").and_then(Value::as_u64).unwrap_or(60);
        let top = params
            .get("top")
            .and_then(Value::as_u64)
            .map_or(DEFAULT_TOP, |n| usize::try_from(n).unwrap_or(usize::MAX));
        self.report_at(now_secs(), since, top)
    }
}

impl Default for CallerStats {
    fn default() -> Self {
        Self::new()
    }
}

fn clamp(bytes: usize) -> u32 {
    u32::try_from(bytes).unwrap_or(u32::MAX)
}

/// The entry of (`caller`, `method`), made if new; past [`ENTRIES`] it replaces the pair seen
/// longest ago.
fn entry<'a>(state: &'a mut State, caller: &Caller, method: &str) -> &'a mut Entry {
    // A lookup by a borrowed pair would need a key type of its own; one clone per request is the
    // cost of the plain map.
    let key = (caller.clone(), method.to_owned());
    if !state.entries.contains_key(&key) && state.entries.len() >= ENTRIES {
        let oldest = state.entries.iter().min_by_key(|(_, e)| e.last_secs).map(|(k, _)| k.clone());
        if let Some(oldest) = oldest {
            state.entries.remove(&oldest);
            state.evicted += 1;
        }
    }
    state.entries.entry(key).or_insert_with(Entry::new)
}

/// Seconds since this daemon first counted.
fn now_secs() -> u64 {
    static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_secs()
}

static GLOBAL: CallerStats = CallerStats::new();

/// This daemon's counts.
pub fn global() -> &'static CallerStats {
    &GLOBAL
}

#[cfg(test)]
#[path = "caller_stats_tests.rs"]
mod tests;
