//! A main-loop model call's usage, and when the chat's prompt cache expires (Leo, 2026-11-03:
//! "i heard claude's cache time was like 5min... idk if we maybe also wanna be showing that").
//!
//! Anthropic's prompt cache lives for its TTL after the last request that read or wrote it, and
//! each hit starts it again. After it lapses the next turn reads the whole context uncached. The
//! TTL is the tier Claude Code asked for, which each call's usage names: its
//! `cache_creation.ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens` say which tier the
//! call wrote, and a call that only read keeps the tier last seen. Claude Code picks the tier
//! itself (2.1.310: `FORCE_PROMPT_CACHING_5M`, `CLAUDE_CODE_PROMPT_CACHE_TTL`, the
//! `promptCacheTtl` setting, `ENABLE_PROMPT_CACHING_1H`, else 1 hour on a subscription and 5
//! minutes on an API key), so acpmux reads the tier off the calls rather than guess from those.
//! Every turn writes its new tail, so the tier is known from a chat's first call (all but 210 of
//! 79,919 main-loop calls in one host's transcripts, 2026-11-03); until a call names one there is
//! no expiry.
//!
//! The expiry is the call's start (`message_start`, whose usage already names the cache it read
//! and wrote, so a call stopped before its `message_delta` still moves it) plus that TTL. It goes
//! out as `_meta.acpmux.cacheExpiresAt` (unix ms) on the call's `usage_update` and on the result's
//! resend. A call that used no cache keeps the last expiry; a subagent's call (its cache is its
//! own) moves none; a compaction clears it (the next call writes a new cache).
//!
//! The same updates say how the cache did (Leo, 2026-11-18, the cache line): `cacheHit`, the last
//! main-loop call's cache reads over its whole prompt (0-1), and `cacheMiss`, the last call that
//! read under half of what the call before it left (`{cause, at}`), with its likely cause: a
//! compaction since, a model or effort change, the cache's expiry, else `unknown`. Settings names
//! an account's newest miss (`hub/account_usage.rs`, Leo, 2026-11-23: "the last cache-miss cause").
//!
//! Every miss of a turn is also counted by cause (`TurnMisses`) on the prompt result's
//! `_meta.harnessMagic.cacheAlarm`, RFD 0158 §1's per-call alarm: a turn-level share hides a
//! break when the turn's later calls read the cache the first one wrote again (`hub/cache_alarm.rs`).
//!
//! Every main-loop call of a chat that caches is also classed hit, new, compulsory, capacity,
//! conflict or churn with its refault gap, RFD 0182 B6's cache fault accounting, sent as
//! `_meta.acpmux.cacheFaults` (`cache_faults.rs`).

use super::Translator;
use crate::no_panic::JsonExt;
use cmux_json::JsonGet as _;
use serde_json::{Value, json};
use std::sync::Mutex as StdMutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

pub const FIVE_MINUTES_MS: u64 = 5 * 60 * 1000;
pub const ONE_HOUR_MS: u64 = 60 * 60 * 1000;
/// Under this much context left by the call before, a call that reads little is no miss worth
/// naming (a chat's first calls, a fresh compaction's tail).
pub const MIN_MISS_CONTEXT: u64 = 4_096;

/// The chat's prompt cache as its main loop's last call left it, in unix ms (0: none yet).
#[derive(Default)]
pub(super) struct CacheClock {
    /// The TTL a call last named.
    ttl_ms: AtomicU64,
    /// When the last call started.
    requested_at_ms: AtomicU64,
    /// When the cache lapses (0: none in use, not known, or compacted).
    expires_at_ms: AtomicU64,
    /// The last call's hit ratio in thousandths, plus one (0: no call yet).
    hit_milli: AtomicU64,
    /// The last call that missed: its likely cause and when it started.
    miss: StdMutex<Option<(&'static str, u64)>>,
    /// The model and effort the last call ran with.
    ran_with: StdMutex<Option<(String, String)>>,
    /// A compaction since the last call.
    compacted_since: AtomicBool,
    /// This turn's misses, for RFD 0158 §1's alarm (`take_turn_misses`).
    turn_misses: StdMutex<TurnMisses>,
    /// Every main-loop call's cache fault class so far (RFD 0182 B6, `cache_faults.rs`).
    faults: StdMutex<super::cache_faults::FaultCounts>,
}

/// One turn's main-loop calls that missed the cache, by cause (RFD 0158 §1). A miss with no
/// cause the daemon can name (`unknown`: still warm, same model, effort and no compaction) is a
/// prefix churn; the others are declared boundaries.
#[derive(Default, Debug, Clone, PartialEq)]
pub struct TurnMisses {
    pub by_cause: std::collections::BTreeMap<&'static str, u64>,
    /// The context those misses wrote again instead of reading.
    pub unread_tokens: u64,
}

impl TurnMisses {
    pub fn churn(&self) -> u64 {
        self.by_cause.get("unknown").copied().unwrap_or(0)
    }

    /// The counters for the turn's `_meta.harnessMagic.cacheAlarm`; None with no miss.
    pub fn to_json(&self) -> Option<Value> {
        let total: u64 = self.by_cause.values().sum();
        (total > 0).then(|| {
            json!({
                "callMisses": total,
                "callChurn": self.churn(),
                "callDeclared": total - self.churn(),
                "callUnreadTokens": self.unread_tokens,
                "cause": self.by_cause,
            })
        })
    }
}

/// Why a call read under half of the context the call before it left: a compaction since
/// (`compacted`), a model or effort change, the cache's expiry (the call started at or after
/// `expired_at`, 0 when none was known), else `unknown`.
pub fn miss_cause(
    compacted: bool,
    model_changed: bool,
    effort_changed: bool,
    expired_at: u64,
    at_ms: u64,
) -> &'static str {
    if compacted {
        "compaction"
    } else if model_changed {
        "model"
    } else if effort_changed {
        "effort"
    } else if expired_at > 0 && at_ms >= expired_at {
        "expired"
    } else {
        "unknown"
    }
}

/// The tier a call's usage says it wrote, if it wrote any.
pub fn reported_ttl_ms(usage: &Value) -> Option<u64> {
    let tier = |key: &str| usage.pointer(&format!("/cache_creation/{key}")).and_then(Value::as_u64);
    if tier("ephemeral_1h_input_tokens").is_some_and(|n| n > 0) {
        Some(ONE_HOUR_MS)
    } else if tier("ephemeral_5m_input_tokens").is_some_and(|n| n > 0) {
        Some(FIVE_MINUTES_MS)
    } else {
        None
    }
}

/// When the cache a call used lapses: its request time plus the TTL. None when the call used no
/// cache (nothing read or written: caching is off for it), or the TTL is unknown.
pub fn expires_at_ms(requested_at_ms: u64, ttl_ms: Option<u64>, cache_tokens: u64) -> Option<u64> {
    (cache_tokens > 0 && requested_at_ms > 0).then_some(())?;
    ttl_ms.filter(|ttl| *ttl > 0).map(|ttl| requested_at_ms.saturating_add(ttl))
}

pub fn now_ms() -> u64 {
    crate::store::now_ms()
}

impl CacheClock {
    /// A main-loop call started at `at_ms`, with the usage its start names, on `ran_with` (its
    /// model and effort), after the call before left `context` tokens for it to read.
    fn started(&self, usage: Option<&Value>, at_ms: u64, context: u64, ran_with: (String, String)) {
        let expired_at = self.expires_at_ms.load(Ordering::SeqCst);
        let before =
            self.ran_with.lock().unwrap_or_else(|e| e.into_inner()).replace(ran_with.clone());
        let compacted = self.compacted_since.swap(false, Ordering::SeqCst);
        let previous_at = self.requested_at_ms.swap(at_ms, Ordering::SeqCst);
        let Some(usage) = usage else { return };
        self.call(usage);
        let input = usage.get_u64("input_tokens").unwrap_or(0);
        let read = usage.get_u64("cache_read_input_tokens").unwrap_or(0);
        let write = usage.get_u64("cache_creation_input_tokens").unwrap_or(0);
        let prompt = input + read + write;
        if let Some(milli) = (read * 1000).checked_div(prompt) {
            self.hit_milli.store(milli + 1, Ordering::SeqCst);
        }
        // Only a chat whose calls use the cache misses it.
        let caching = self.ttl_ms.load(Ordering::SeqCst) > 0;
        if !caching {
            return;
        }
        let mut cause = "";
        if context >= MIN_MISS_CONTEXT && read.saturating_mul(2) < context {
            let (model, effort) =
                before.map_or((false, false), |(m, e)| (m != ran_with.0, e != ran_with.1));
            cause = miss_cause(compacted, model, effort, expired_at, at_ms);
            *self.miss.lock().unwrap_or_else(|e| e.into_inner()) = Some((cause, at_ms));
            let mut turn = self.turn_misses.lock().unwrap_or_else(|e| e.into_inner());
            *turn.by_cause.entry(cause).or_default() += 1;
            turn.unread_tokens = turn.unread_tokens.saturating_add(context.saturating_sub(read));
        }
        let fault = super::cache_faults::classify(previous_at == 0, context, read, cause);
        let gap = if previous_at == 0 { 0 } else { at_ms.saturating_sub(previous_at) };
        self.faults.lock().unwrap_or_else(|e| e.into_inner()).record(
            fault,
            context.saturating_sub(read),
            gap,
        );
    }

    /// Adds how the cache did to a main-loop `usage_update`'s `_meta.acpmux` (module docs).
    fn stamp(&self, acpmux: &mut Value) {
        if let Some(milli) = self.hit_milli.load(Ordering::SeqCst).checked_sub(1) {
            acpmux.set("cacheHit", json!(milli as f64 / 1000.0));
        }
        if let Some((cause, at)) = *self.miss.lock().unwrap_or_else(|e| e.into_inner()) {
            acpmux.set("cacheMiss", json!({"cause": cause, "at": at}));
        }
        if let Some(faults) = self.faults.lock().unwrap_or_else(|e| e.into_inner()).to_json() {
            acpmux.set("cacheFaults", faults);
        }
    }

    /// A turn's resend of its context: its expiry and how the cache did.
    pub(super) fn resend(&self, mut update: Value) -> Value {
        update = with_expiry(update, self.expires_at());
        if let Some(obj) = update.as_object_mut() {
            let meta = obj.entry("_meta").or_insert_with(|| json!({}));
            if let Some(meta) = meta.as_object_mut() {
                let acpmux = meta.entry("acpmux").or_insert_with(|| json!({}));
                self.stamp(acpmux);
            }
        }
        update
    }

    /// The last call's `usage`: the cache's expiry from it, kept for the turn's result.
    fn call(&self, usage: &Value) -> Option<u64> {
        if let Some(ttl) = reported_ttl_ms(usage) {
            self.ttl_ms.store(ttl, Ordering::SeqCst);
        }
        let cache = usage.get_u64("cache_read_input_tokens").unwrap_or(0)
            + usage.get_u64("cache_creation_input_tokens").unwrap_or(0);
        if cache == 0 {
            return self.expires_at();
        }
        let ttl = Some(self.ttl_ms.load(Ordering::SeqCst));
        let at = self.requested_at_ms.load(Ordering::SeqCst);
        let expires = expires_at_ms(at, ttl, cache);
        self.expires_at_ms.store(expires.unwrap_or(0), Ordering::SeqCst);
        expires
    }

    /// This turn's misses, and the next turn counts its own.
    pub(super) fn take_turn_misses(&self) -> TurnMisses {
        std::mem::take(&mut *self.turn_misses.lock().unwrap_or_else(|e| e.into_inner()))
    }

    pub(super) fn expires_at(&self) -> Option<u64> {
        Some(self.expires_at_ms.load(Ordering::SeqCst)).filter(|t| *t > 0)
    }

    /// A compaction replaced the context: the next call writes a new cache, so none is warm.
    pub(super) fn compacted(&self) {
        self.expires_at_ms.store(0, Ordering::SeqCst);
        self.compacted_since.store(true, Ordering::SeqCst);
    }
}

impl Translator {
    /// A main-loop call started (its `message_start`, on `model`): the cache it read or wrote
    /// lives from now.
    pub(super) async fn call_started(&self, usage: Option<&Value>, model: Option<&str>) {
        let model = match model {
            Some(m) => m.to_owned(),
            None => self.loop_model.lock().await.clone(),
        };
        let effort = self.effort.lock().await.clone();
        let context = self.context_end.load(Ordering::SeqCst);
        self.cache.started(usage, now_ms(), context, (model, effort));
    }

    /// One model call's usage (its `message_delta`) as the `usage_update` acpmux sends, of the
    /// chat's main loop unless `subagent`.
    pub(super) fn call_usage(&self, u: &Value, subagent: bool) -> Value {
        // `used` is the context held by the last request. It is the prompt side of the usage,
        // including cache reads/writes, and deliberately excludes output: the context ring must
        // not grow from generated text.
        let (input, output) =
            (u.get_u64("input_tokens").unwrap_or(0), u.get_u64("output_tokens").unwrap_or(0));
        let cache_read = u.get_u64("cache_read_input_tokens").unwrap_or(0);
        let cache_write = u.get_u64("cache_creation_input_tokens").unwrap_or(0);
        let used = input + cache_read + cache_write;
        let mut acpmux = json!({"call": true});
        // A subagent's usage is its own context, not the chat's, and its cache is its own too.
        if !subagent {
            self.context_used.store(used, Ordering::SeqCst);
            // What the next call will read: this one's prompt and what it wrote.
            self.context_end.store(used + output, Ordering::SeqCst);
            self.turn_calls.fetch_add(1, Ordering::SeqCst);
            self.context_from_compaction.store(false, Ordering::SeqCst);
            if let Some(at) = self.cache.call(u) {
                acpmux.set("cacheExpiresAt", json!(at));
            }
            self.cache.stamp(&mut acpmux);
            // When the call went out and came back (`model_calls.rs`).
            if let Some(timing) = self.model_clock.ended(now_ms()) {
                acpmux.set("timing", timing);
            }
        }
        let size = self.context_window.load(Ordering::SeqCst);
        // One model call's own usage, marked so a client can add a turn's calls up (the pane's
        // running line). The result's resend is the context ring's and is not marked. A
        // subagent's calls are marked too: they are the turn's spend. The four counts split the
        // call so the line can say its output apart from what it read (fresh input, cache reads
        // and cache writes).
        let mut update = json!({
            "sessionUpdate": "usage_update",
            "used": used,
            "size": size,
            "inputTokens": input,
            "cachedReadTokens": cache_read,
            "cachedWriteTokens": cache_write,
            "outputTokens": output,
            "_meta": {"acpmux": acpmux},
        });
        // The chat's context after this call (its prompt and its output), so the running line
        // can say what the context holds rather than every call's reads added up. A
        // subagent's call names none: its context is not the chat's.
        if !subagent {
            update.set("contextTokens", json!(used + output));
        }
        update
    }
}

/// Adds the cache's expiry to a `usage_update`'s `_meta.acpmux`: `cacheExpiresAt` (unix ms).
pub fn with_expiry(mut update: Value, expires_at_ms: Option<u64>) -> Value {
    let Some(at) = expires_at_ms else { return update };
    if let Some(obj) = update.as_object_mut() {
        let meta = obj.entry("_meta").or_insert_with(|| json!({}));
        if let Some(meta) = meta.as_object_mut() {
            let acpmux = meta.entry("acpmux").or_insert_with(|| json!({}));
            if let Some(acpmux) = acpmux.as_object_mut() {
                acpmux.insert("cacheExpiresAt".into(), at.into());
            }
        }
    }
    update
}

#[cfg(test)]
#[path = "prompt_cache_tests.rs"]
mod tests;
