//! When the chat's prompt cache lapses (Leo, 2026-11-03: "i heard claude's cache time was like
//! 5min... idk if we maybe also wanna be showing that").
//!
//! Anthropic's prompt cache lives for its TTL after the last request that read or wrote it, and
//! each hit starts it again. After it lapses the next turn reads the whole context uncached. The
//! TTL is the tier Claude Code asked for, which each call's usage names: its
//! `cache_creation.ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens` say which tier the
//! call wrote. A call that only read keeps the tier last seen. Until a call has named one, the
//! TTL comes from the env Claude Code reads, in its own order (Claude Code 2.1.310):
//! `FORCE_PROMPT_CACHING_5M`, then `CLAUDE_CODE_PROMPT_CACHE_TTL`, then `ENABLE_PROMPT_CACHING_1H`.
//! With none of those (Claude Code's "automatic": 1 hour on a subscription, 5 minutes on an API key)
//! and no reported tier, the TTL is unknown and no expiry is sent. The `promptCacheTtl` setting is
//! not read: the first call's reported tier covers it.

use serde_json::Value;
use std::sync::atomic::Ordering;

pub const FIVE_MINUTES_MS: u64 = 5 * 60 * 1000;
pub const ONE_HOUR_MS: u64 = 60 * 60 * 1000;

/// The tier a call's usage says it wrote, if it wrote any. The 1 hour tier wins when a call wrote
/// both (its 5 minute writes are the shorter-lived prefix only in mixed setups, which Claude Code's
/// main loop does not make).
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

/// The TTL the main loop's cache gets from Claude Code's env, when the env decides it.
pub fn env_ttl_ms(env: impl Fn(&str) -> Option<String>) -> Option<u64> {
    let set = |key: &str| env(key).is_some_and(|v| !v.is_empty() && v != "0" && v != "false");
    if set("FORCE_PROMPT_CACHING_5M") {
        return Some(FIVE_MINUTES_MS);
    }
    match env("CLAUDE_CODE_PROMPT_CACHE_TTL").as_deref() {
        Some("5m") => return Some(FIVE_MINUTES_MS),
        Some("1h") => return Some(ONE_HOUR_MS),
        _ => {}
    }
    set("ENABLE_PROMPT_CACHING_1H").then_some(ONE_HOUR_MS)
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

impl super::Translator {
    /// The main loop's model request started (its `message_start`): the cache it reads or writes
    /// lives from now. Its usage may already name the tier.
    pub(super) fn cache_request_started(&self, usage: Option<&Value>, at_ms: u64) {
        self.cache_requested_at_ms.store(at_ms, Ordering::SeqCst);
        if let Some(ttl) = usage.and_then(reported_ttl_ms) {
            self.cache_ttl_ms.store(ttl, Ordering::SeqCst);
        }
    }

    /// The main loop's call reported its usage (`message_delta`): when its cache lapses, also kept
    /// for the turn's result. None when it used no cache or the TTL is unknown.
    pub(super) fn cache_call_usage(&self, usage: &Value, cache_tokens: u64) -> Option<u64> {
        if let Some(ttl) = reported_ttl_ms(usage) {
            self.cache_ttl_ms.store(ttl, Ordering::SeqCst);
        }
        let ttl = [&self.cache_ttl_ms, &self.cache_ttl_env_ms]
            .into_iter()
            .map(|t| t.load(Ordering::SeqCst))
            .find(|t| *t > 0);
        let at = self.cache_requested_at_ms.load(Ordering::SeqCst);
        let expires = expires_at_ms(at, ttl, cache_tokens);
        self.cache_expires_at_ms.store(expires.unwrap_or(0), Ordering::SeqCst);
        expires
    }

    /// When the chat's cache lapses, as the last call left it.
    pub(super) fn cache_expires_at(&self) -> Option<u64> {
        Some(self.cache_expires_at_ms.load(Ordering::SeqCst)).filter(|t| *t > 0)
    }

    /// A compaction replaced the context: the next call writes a new cache, so none is warm.
    pub(super) fn cache_compacted(&self) {
        self.cache_expires_at_ms.store(0, Ordering::SeqCst);
    }
}

/// Adds the cache's expiry to a `usage_update`'s `_meta.acpmux`: `cacheExpiresAt` (unix ms).
pub fn with_expiry(mut update: Value, expires_at_ms: Option<u64>) -> Value {
    let Some(at) = expires_at_ms else { return update };
    if let Some(obj) = update.as_object_mut() {
        let meta = obj.entry("_meta").or_insert_with(|| serde_json::json!({}));
        if let Some(meta) = meta.as_object_mut() {
            let acpmux = meta.entry("acpmux").or_insert_with(|| serde_json::json!({}));
            if let Some(acpmux) = acpmux.as_object_mut() {
                acpmux.insert("cacheExpiresAt".into(), at.into());
            }
        }
    }
    update
}

/// `env_ttl_ms` for the env a profile's Claude Code starts with: the profile's own values over
/// the daemon's, as the spawn merges them.
pub fn profile_ttl_ms(profile: &crate::config::HarnessProfile) -> Option<u64> {
    env_ttl_ms(|k| profile.env.get(k).cloned().or_else(|| std::env::var(k).ok()))
}
