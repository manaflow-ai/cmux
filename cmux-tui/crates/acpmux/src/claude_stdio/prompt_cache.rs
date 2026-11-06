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

use super::Translator;
use crate::no_panic::JsonExt;
use serde_json::{Value, json};
use std::sync::atomic::{AtomicU64, Ordering};

pub const FIVE_MINUTES_MS: u64 = 5 * 60 * 1000;
pub const ONE_HOUR_MS: u64 = 60 * 60 * 1000;

/// The chat's prompt cache as its main loop's last call left it, in unix ms (0: none yet).
#[derive(Default)]
pub(super) struct CacheClock {
    /// The TTL a call last named.
    ttl_ms: AtomicU64,
    /// When the last call started.
    requested_at_ms: AtomicU64,
    /// When the cache lapses (0: none in use, not known, or compacted).
    expires_at_ms: AtomicU64,
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

fn tokens(usage: &Value, key: &str) -> u64 {
    usage.get(key).and_then(Value::as_u64).unwrap_or(0)
}

impl CacheClock {
    /// A main-loop call started at `at_ms`, with the usage its start names.
    fn started(&self, usage: Option<&Value>, at_ms: u64) {
        self.requested_at_ms.store(at_ms, Ordering::SeqCst);
        if let Some(usage) = usage {
            self.call(usage);
        }
    }

    /// The last call's `usage`: the cache's expiry from it, kept for the turn's result.
    fn call(&self, usage: &Value) -> Option<u64> {
        if let Some(ttl) = reported_ttl_ms(usage) {
            self.ttl_ms.store(ttl, Ordering::SeqCst);
        }
        let cache =
            tokens(usage, "cache_read_input_tokens") + tokens(usage, "cache_creation_input_tokens");
        if cache == 0 {
            return self.expires_at();
        }
        let ttl = Some(self.ttl_ms.load(Ordering::SeqCst));
        let at = self.requested_at_ms.load(Ordering::SeqCst);
        let expires = expires_at_ms(at, ttl, cache);
        self.expires_at_ms.store(expires.unwrap_or(0), Ordering::SeqCst);
        expires
    }

    pub(super) fn expires_at(&self) -> Option<u64> {
        Some(self.expires_at_ms.load(Ordering::SeqCst)).filter(|t| *t > 0)
    }

    /// A compaction replaced the context: the next call writes a new cache, so none is warm.
    pub(super) fn compacted(&self) {
        self.expires_at_ms.store(0, Ordering::SeqCst);
    }
}

impl Translator {
    /// A main-loop call started (its `message_start`): the cache it read or wrote lives from now.
    pub(super) fn call_started(&self, usage: Option<&Value>) {
        self.cache.started(usage, now_ms());
    }

    /// One model call's usage (its `message_delta`) as the `usage_update` acpmux sends, of the
    /// chat's main loop unless `subagent`.
    pub(super) fn call_usage(&self, u: &Value, subagent: bool) -> Value {
        // `used` is the context held by the last request. It is the prompt side of the usage,
        // including cache reads/writes, and deliberately excludes output: the context ring must
        // not grow from generated text.
        let (input, output) = (tokens(u, "input_tokens"), tokens(u, "output_tokens"));
        let cache_read = tokens(u, "cache_read_input_tokens");
        let cache_write = tokens(u, "cache_creation_input_tokens");
        let used = input + cache_read + cache_write;
        let mut acpmux = json!({"call": true});
        // A subagent's usage is its own context, not the chat's, and its cache is its own too.
        if !subagent {
            self.context_used.store(used, Ordering::SeqCst);
            self.context_from_compaction.store(false, Ordering::SeqCst);
            if let Some(at) = self.cache.call(u) {
                acpmux.set("cacheExpiresAt", json!(at));
            }
        }
        let size = self.context_window.load(Ordering::SeqCst);
        // One model call's own usage, marked so a client can add a turn's calls up (the pane's
        // running line). The result's resend is the context ring's and is not marked. A
        // subagent's calls are marked too: they are the turn's spend. The four counts split the
        // call so the line can say its output apart from what it read (fresh input, cache reads
        // and cache writes).
        json!({
            "sessionUpdate": "usage_update",
            "used": used,
            "size": size,
            "inputTokens": input,
            "cachedReadTokens": cache_read,
            "cachedWriteTokens": cache_write,
            "outputTokens": output,
            "_meta": {"acpmux": acpmux},
        })
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
