//! Codex's plan usage limits as acpmux's `usageLimits`, the shape Claude Code's are kept in
//! (`claude_stdio/usage_limits.rs`): `{windows: [{id, usedPercent, resetsAt?, windowMins?}],
//! plan?, credits?}`, so the pane reads one shape for both.
//!
//! `codex app-server` sends `account/rateLimits/updated` with a snapshot `{limitId?, limitName?,
//! primary?, secondary?: {usedPercent (0-100), windowDurationMins?, resetsAt? (unix seconds)},
//! credits?: {hasCredits, unlimited, balance?}, planType?}`; cmux-codex-acp merges each into the
//! last and sends it as a `session_info_update` with `_meta.codexAppServer.rateLimits`. The hub
//! keeps it as the session's `usageLimits` (`hub/permissions.rs`).

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

/// The id of a window `mins` long: the 5-hour window is `session` and the week `weekly`, as
/// Claude's; any other length its minutes (`60m`); one with no length its snapshot slot.
fn window_id(mins: Option<u64>, slot: &str) -> String {
    match mins {
        Some(300) => "session".into(),
        Some(10080) => "weekly".into(),
        Some(m) => format!("{m}m"),
        None => slot.into(),
    }
}

/// One window as acpmux sends it, None without a usable `usedPercent`. A window past its cap
/// reads 100.
fn window(slot: &str, w: &Value) -> Option<Value> {
    let used = w.get("usedPercent")?.as_f64().filter(|u| u.is_finite())?;
    let percent = (used.clamp(0.0, 100.0) * 100.0).round() / 100.0;
    let mins = w.get("windowDurationMins").and_then(Value::as_u64).filter(|m| *m > 0);
    let mut out = json!({"id": window_id(mins, slot), "usedPercent": percent});
    if let Some(m) = mins {
        out.set("windowMins", json!(m));
    }
    if let Some(at) = w.get("resetsAt").and_then(Value::as_i64).filter(|at| *at > 0) {
        out.set("resetsAt", json!(at));
    }
    Some(out)
}

/// The credits line: unlimited, or the balance Codex names. None when the account holds none.
fn credits(c: &Value) -> Option<Value> {
    if c.get("unlimited").and_then(Value::as_bool) == Some(true) {
        return Some(json!({"unlimited": true}));
    }
    if c.get("hasCredits").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    let balance =
        c.get("balance").and_then(Value::as_str).map(str::trim).filter(|b| !b.is_empty())?;
    Some(json!({"balance": balance}))
}

/// Whether a Codex rate-limit snapshot is the plan's own (no `limitId`, or `codex`): another
/// limit's (a model's) windows are not the plan's, and leave the saved limits as they are.
pub fn is_plan_snapshot(snapshot: &Value) -> bool {
    snapshot.is_object()
        && snapshot.get("limitId").and_then(Value::as_str).is_none_or(|id| id == "codex")
}

/// A Codex rate-limit snapshot as `usageLimits`. None when it reports neither a window nor
/// credits (a plan name alone is no limit), and for another limit than Codex's own
/// ([`is_plan_snapshot`]).
pub fn usage_limits(snapshot: &Value) -> Option<Value> {
    if !is_plan_snapshot(snapshot) {
        return None;
    }
    let windows: Vec<Value> = ["primary", "secondary"]
        .into_iter()
        .filter_map(|slot| window(slot, snapshot.get(slot)?))
        .collect();
    let credits = snapshot.get("credits").and_then(credits);
    if windows.is_empty() && credits.is_none() {
        return None;
    }
    let mut out = json!({"windows": windows});
    if let Some(plan) = snapshot.get("planType").and_then(Value::as_str).filter(|p| !p.is_empty()) {
        out.set("plan", json!(plan));
    }
    if let Some(c) = credits {
        out.set("credits", c);
    }
    Some(out)
}

/// `account/rateLimits/read`'s result (`{rateLimits, rateLimitsByLimitId?}`) as `usageLimits`: the
/// plan's own snapshot (`rateLimitsByLimitId.codex` when the reply keys them, else `rateLimits`),
/// mapped as an update's ([`usage_limits`]). None when it reports no plan limit.
pub fn read_usage_limits(result: &Value) -> Option<Value> {
    let keyed = result.pointer("/rateLimitsByLimitId/codex").filter(|s| s.is_object());
    usage_limits(keyed.or_else(|| result.get("rateLimits"))?)
}
