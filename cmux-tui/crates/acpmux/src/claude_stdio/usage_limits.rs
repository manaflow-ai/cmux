//! The account's plan usage limits, from Claude Code's `rate_limit_event`
//! lines: how much of each limit window (the 5-hour session, the week) is
//! used and when it resets, for the pane's Context card. Sent as a
//! `session_info_update` with `_meta.acpmux.usageLimits`, and kept as the
//! session detail's `usageLimits` (`hub/views.rs`).
//!
//! Claude Code 2.1.307 writes `{"type": "rate_limit_event", "rate_limit_info":
//! {status, rateLimitType?, utilization?, resetsAt?, unifiedWindows?: {five_hour?,
//! seven_day?, seven_day_overage_included?: {utilization, resetsAt}}, ...}}`
//! when a window's rounded percentage or reset time moves. `utilization` is the
//! fraction of the window used (0-1; above 1 once usage runs past the cap) and
//! `resetsAt` unix seconds. The stream names no plan, so `plan` is never set.

use super::*;
use cmux_json::JsonSet as _;
use std::collections::BTreeMap;

/// Claude Code's limit windows and the ids acpmux names them by. The overage
/// windows (`overage`, `seven_day_overage_included`) are extra paid usage, not
/// a plan limit, and are left out.
const WINDOWS: &[(&str, &str)] = &[
    ("five_hour", "session"),
    ("seven_day", "weekly"),
    ("seven_day_opus", "weekly_opus"),
    ("seven_day_sonnet", "weekly_sonnet"),
];

fn window_id(claude: &str) -> Option<&'static str> {
    WINDOWS.iter().find(|(name, _)| *name == claude).map(|(_, id)| *id)
}

/// One window as acpmux sends it: `usedPercent` (0-100, two decimals, a window
/// past its cap reads 100) and `resetsAt` when Claude Code gave one. None
/// without a usable utilization.
fn window(id: &str, utilization: Option<&Value>, resets_at: Option<&Value>) -> Option<Value> {
    let used = utilization?.as_f64().filter(|u| u.is_finite())?;
    let percent = ((used * 100.0).clamp(0.0, 100.0) * 100.0).round() / 100.0;
    let mut w = json!({"id": id, "usedPercent": percent});
    if let Some(at) = resets_at.and_then(Value::as_i64).filter(|at| *at > 0) {
        w.set("resetsAt", json!(at));
    }
    Some(w)
}

/// The windows one `rate_limit_info` reports, by id: the limiting window it
/// names (`rateLimitType` with `utilization`), then each of `unifiedWindows`,
/// which wins for a window both name. Empty for anything malformed.
pub(super) fn usage_windows(info: &Value) -> BTreeMap<&'static str, Value> {
    let mut found = BTreeMap::new();
    if let Some(id) = info.get("rateLimitType").and_then(Value::as_str).and_then(window_id)
        && let Some(w) = window(id, info.get("utilization"), info.get("resetsAt"))
    {
        found.insert(id, w);
    }
    for (name, w) in info.get("unifiedWindows").and_then(Value::as_object).into_iter().flatten() {
        if let Some(id) = window_id(name)
            && let Some(w) = window(id, w.get("utilization"), w.get("resetsAt"))
        {
            found.insert(id, w);
        }
    }
    found
}

/// The saved `usageLimits` with a newer one's windows in it: each window the
/// newer one names replaces the saved one of its id, and the others stay (a
/// restarted Claude Code knows only what it saw since). Its `plan`, if any,
/// wins.
pub fn merge_usage_limits(saved: Option<&Value>, newer: &Value) -> Value {
    let mut windows: Vec<Value> =
        saved.and_then(|s| s.get("windows")).and_then(Value::as_array).cloned().unwrap_or_default();
    for w in newer.get("windows").and_then(Value::as_array).into_iter().flatten() {
        let Some(id) = w.get("id").and_then(Value::as_str) else { continue };
        match windows.iter_mut().find(|old| old.get("id").and_then(Value::as_str) == Some(id)) {
            Some(old) => *old = w.clone(),
            None => windows.push(w.clone()),
        }
    }
    let mut merged = json!({"windows": windows});
    if let Some(plan) = newer.get("plan").or_else(|| saved?.get("plan")).filter(|p| p.is_string()) {
        merged.set("plan", plan.clone());
    }
    merged
}

impl Translator {
    /// A `rate_limit_event` as a `session_info_update` carrying every window
    /// this Claude Code reported so far, each its newest value. None when the
    /// event names no window acpmux shows. Always the chat's own session: the
    /// limits are the account's, whichever stream (a subagent's) reported them.
    pub(super) async fn usage_limits_update(&self, line: &Value) -> Option<Message> {
        let found = usage_windows(line.get("rate_limit_info")?);
        if found.is_empty() {
            return None;
        }
        let mut kept = self.usage_limits.lock().await;
        kept.extend(found);
        let windows: Vec<Value> = kept.values().cloned().collect();
        let update = json!({
            "sessionUpdate": "session_info_update",
            "_meta": {"acpmux": {"usageLimits": {"windows": windows}}},
        });
        let params = json!({"sessionId": self.acp_session_id, "update": update});
        Some(Message::notification(method::SESSION_UPDATE, params))
    }
}
