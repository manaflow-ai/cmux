//! The Chief's product events (docs/posthog/chief-product-analytics.md).
//!
//! [`map`] turns one monitoring-trace event (`trace.rs`) into at most a few
//! PostHog events. It is pure: the caller hands it the per-install state
//! ([`State`]) it updates (milestones, first use per day). Every property is
//! a closed token, a count, a duration, a bool or a cost: a value that is not
//! one of the known tokens becomes `other`. No message, reply, task, report,
//! tool argument, error text, path, URL, name or id from the trace is ever
//! copied: the trace's `{bytes, hash, prefix}` texts are read only to derive
//! a closed class (`error_class`), and never leave this function.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

/// Every event name this module sends. `catalog_is_pinned` keeps the docs
/// and the dashboards in step with it.
pub const EVENTS: [&str; 13] = [
    "chief_host_started",
    "chief_activation_milestone_reached",
    "chief_daily_active",
    "chief_message_received",
    "chief_turn_completed",
    "chief_tool_used",
    "chief_subagents_spawned",
    "chief_subagent_started",
    "chief_subagent_finished",
    "chief_compactor_failed",
    "chief_error",
    "chief_usage_daily",
    "chief_analytics_dropped",
];

/// The activation milestones, in funnel order.
pub const MILESTONES: [&str; 7] = [
    "first_host_start",
    "first_message",
    "first_reply",
    "first_subagent",
    "first_subagent_done",
    "first_landed_work",
    "first_day_7_return",
];

/// What one install remembers between events (saved in `analytics/state.json`).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct State {
    /// When this install first ran the Chief with analytics (ms).
    pub installed_ms: u64,
    /// Milestones already sent.
    pub milestones: BTreeSet<String>,
    /// The UTC day (`YYYY-MM-DD`) `chief_daily_active` was last sent for.
    pub active_day: String,
    /// The UTC day `tools_seen` is for.
    pub tools_day: String,
    /// Tool tokens already sent as `chief_tool_used` on `tools_day`.
    pub tools_seen: BTreeSet<String>,
    /// The day the usage rollup in `usage` is for.
    pub usage_day: String,
    /// The running rollup of `usage_day` (sent as `chief_usage_daily`).
    pub usage: Usage,
    /// Events dropped since the last `chief_analytics_dropped` (full queue).
    pub dropped: u64,
    /// What only this host's run needs: never saved.
    #[serde(skip)]
    pub live: Live,
}

/// Per-run memory of `map`: the turn that posted a reply by tool, and the
/// hourly caps on repeated failure events. Not saved, and equal to any
/// other `Live`, so changing it never rewrites `state.json`.
#[derive(Clone, Debug, Default)]
pub struct Live {
    /// Turns still open whose `send` or `reply` tool call succeeded (a side
    /// chat's turn can overlap the main chat's); `turn.end` removes its own.
    replied_turns: BTreeSet<String>,
    /// `event:reason` -> (UTC hour, sent this hour, held back since sent).
    bursts: std::collections::HashMap<String, (u64, u32, u64)>,
}

impl PartialEq for Live {
    fn eq(&self, _: &Self) -> bool {
        true
    }
}

/// At most this many `chief_compactor_failed` or `chief_error` events of one
/// reason or kind per install and hour: a failing loop (25,075 compactor
/// failures from 4 installs in a day, 2026-11-15) sends a sample, and the
/// next one sent carries `repeats_dropped`, the count held back before it.
pub const BURST_PER_HOUR: u32 = 10;

fn capped(state: &mut State, mut e: Event, now_ms: u64) -> Option<Event> {
    let reason = ["reason", "kind"]
        .iter()
        .find_map(|k| e.properties.get(*k).and_then(Value::as_str))
        .unwrap_or("");
    let key = format!("{}:{reason}", e.name);
    let hour = now_ms / 3_600_000;
    let slot = state.live.bursts.entry(key).or_insert((hour, 0, 0));
    if slot.0 != hour {
        slot.0 = hour;
        slot.1 = 0;
    }
    if slot.1 >= BURST_PER_HOUR {
        slot.2 += 1;
        return None;
    }
    slot.1 += 1;
    if slot.2 > 0 {
        e.properties.insert("repeats_dropped".into(), json!(slot.2));
        slot.2 = 0;
    }
    Some(e)
}

/// One day's billable units, by kind (from the usage ledger's lines).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Usage {
    pub turns: u64,
    pub compactor_nodes: u64,
    pub subagent_prompts: u64,
    pub turn_usd: f64,
    pub compactor_usd: f64,
    pub subagent_usd: f64,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_tokens: u64,
}

impl Usage {
    pub fn is_empty(&self) -> bool {
        self.turns + self.compactor_nodes + self.subagent_prompts == 0
    }

    /// Adds one usage ledger line (`usage::Line`).
    pub fn add(&mut self, line: &crate::usage::Line) {
        let usd = line
            .usd
            .filter(|v| v.is_finite() && *v >= 0.0)
            .unwrap_or(0.0);
        match line.kind.as_str() {
            "turn" => {
                self.turns += 1;
                self.turn_usd += usd;
            }
            "compactor" => {
                self.compactor_nodes += 1;
                self.compactor_usd += usd;
            }
            "subagent" => {
                self.subagent_prompts += 1;
                self.subagent_usd += usd;
            }
            _ => return,
        }
        self.input_tokens = self.input_tokens.saturating_add(line.input);
        self.output_tokens = self.output_tokens.saturating_add(line.output);
        self.cache_read_tokens = self.cache_read_tokens.saturating_add(line.cache_read);
        self.cache_write_tokens = self.cache_write_tokens.saturating_add(line.cache_write);
    }

    /// The `chief_usage_daily` properties of this rollup.
    pub fn properties(&self, day: &str) -> Value {
        let read = self.cache_read_tokens;
        let all = read
            .saturating_add(self.cache_write_tokens)
            .saturating_add(self.input_tokens);
        json!({
            "day": day,
            "turns": self.turns,
            "compactor_nodes": self.compactor_nodes,
            "subagent_prompts": self.subagent_prompts,
            "turn_cost_usd": cents(self.turn_usd),
            "compactor_cost_usd": cents(self.compactor_usd),
            "subagent_cost_usd": cents(self.subagent_usd),
            "cost_usd": cents(self.turn_usd + self.compactor_usd + self.subagent_usd),
            "input_tokens": self.input_tokens,
            "output_tokens": self.output_tokens,
            "cache_read_tokens": read,
            "cache_write_tokens": self.cache_write_tokens,
            "cache_hit_rate": ratio(read, all),
        })
    }
}

/// One PostHog event before the shared properties: its name and properties.
#[derive(Clone, Debug, PartialEq)]
pub struct Event {
    pub name: &'static str,
    pub properties: Map<String, Value>,
}

fn event(name: &'static str, properties: Value) -> Event {
    let properties = match properties {
        Value::Object(map) => map,
        _ => Map::new(),
    };
    Event { name, properties }
}

/// The UTC day of `ms` as `YYYY-MM-DD`.
pub fn utc_day(ms: u64) -> String {
    chrono::DateTime::from_timestamp_millis(i64::try_from(ms).unwrap_or(i64::MAX))
        .map(|t| t.format("%Y-%m-%d").to_string())
        .unwrap_or_default()
}

/// A milestone event, once per install; None when it was already sent.
pub fn milestone(state: &mut State, name: &str, now_ms: u64) -> Option<Event> {
    let name = MILESTONES.iter().find(|m| **m == name)?;
    if !state.milestones.insert((*name).to_owned()) {
        return None;
    }
    let days = now_ms.saturating_sub(state.installed_ms) / 86_400_000;
    Some(event(
        "chief_activation_milestone_reached",
        json!({"milestone": name, "days_since_install": days}),
    ))
}

/// The events one trace event becomes. `now_ms` is the event's time.
pub fn map(trace: &Value, state: &mut State, now_ms: u64) -> Vec<Event> {
    let ev = trace.get("ev").and_then(Value::as_str).unwrap_or("");
    let mut out = Vec::new();
    match ev {
        "usage.message" => {
            let from = token(str_of(trace, "from"), &["human", "agent", "other"]);
            out.push(event(
                "chief_message_received",
                json!({
                    "sender": from,
                    "images": bool_of(trace, "images"),
                    "files": bool_of(trace, "files"),
                    "remote": bool_of(trace, "remote"),
                    "side": bool_of(trace, "side"),
                }),
            ));
            if from == "human" {
                out.extend(milestone(state, "first_message", now_ms));
            }
        }
        "turn.end" => {
            let status = token(
                str_of(trace, "status"),
                &["ok", "error", "cancelled", "stopped", "owner_stopped", "superseded", "refused"],
            );
            let usage = trace.get("usage");
            let n = |key: &str| usage.and_then(|u| u.get(key)).and_then(Value::as_u64).unwrap_or(0);
            let (input, read, write) = (n("input"), n("cache_read"), n("cache_write"));
            let error = trace
                .get("error")
                .filter(|e| !e.is_null())
                .map(|e| error_class(e.get("prefix").and_then(Value::as_str).unwrap_or("")));
            // The Chief answers by its `send` tool and then ends the turn
            // itself (`stopped`): that is a replied, finished turn.
            let sent = str_of(trace, "turn").is_some_and(|t| state.live.replied_turns.remove(t));
            let replied = trace.get("reply").is_some_and(|r| !r.is_null()) || sent;
            out.push(event(
                "chief_turn_completed",
                json!({
                    "turn_status": status,
                    "error_class": error,
                    "replied": replied,
                    "harness": harness(str_of(trace, "harness")),
                    "harness_kind": token(str_of(trace, "harness_kind"), &["acp", "native", "cli", "other"]),
                    "model": model(str_of(trace, "model")),
                    "effort": effort(str_of(trace, "effort")),
                    "tier": trace.get("tier").and_then(Value::as_u64),
                    "duration_ms": trace.get("ms").and_then(Value::as_u64),
                    "start_ms": trace.get("start_ms").and_then(Value::as_u64),
                    "ttft_ms": trace.get("ttft_ms").and_then(Value::as_u64),
                    "headers_ms": trace.get("headers_ms").and_then(Value::as_u64),
                    "first_draft_ms": trace.get("first_draft_ms").and_then(Value::as_u64),
                    "posted_to_first_draft_ms": trace.get("posted_to_first_draft_ms").and_then(Value::as_u64),
                    "requests": trace.get("requests").and_then(Value::as_u64),
                    "tools": trace.get("tools").and_then(Value::as_u64),
                    "tool_errors": trace.get("tool_errors").and_then(Value::as_u64),
                    "input_tokens": input,
                    "output_tokens": n("output"),
                    "cache_read_tokens": read,
                    "cache_write_tokens": write,
                    "cache_hit_rate": ratio(read, read.saturating_add(write).saturating_add(input)),
                    "cost_usd": trace.get("cost_usd").and_then(Value::as_f64).map(micros),
                    "harness_refused": bool_of(trace, "harness_refused"),
                }),
            ));
            if status == "ok" || (status == "stopped" && replied) {
                let day = utc_day(now_ms);
                if state.active_day != day {
                    state.active_day = day;
                    out.push(event("chief_daily_active", json!({})));
                    let days = now_ms.saturating_sub(state.installed_ms) / 86_400_000;
                    if (7..14).contains(&days) {
                        out.extend(milestone(state, "first_day_7_return", now_ms));
                    }
                }
                if replied {
                    out.extend(milestone(state, "first_reply", now_ms));
                }
            }
        }
        "tool" if trace.get("turn").is_some() => {
            let name = tool(str_of(trace, "name"));
            if matches!(name, "send" | "reply")
                && trace.get("ok") != Some(&Value::Bool(false))
                && let Some(turn) = str_of(trace, "turn")
            {
                // A turn that never ends (a lost session) must not grow this.
                if state.live.replied_turns.len() >= 32 {
                    state.live.replied_turns.pop_first();
                }
                state.live.replied_turns.insert(turn.to_owned());
            }
            let day = utc_day(now_ms);
            if state.tools_day != day {
                state.tools_day = day;
                state.tools_seen.clear();
            }
            if state.tools_seen.insert(name.to_owned()) {
                out.push(event("chief_tool_used", json!({"tool": name})));
            }
        }
        "spawn" => {
            let ids = trace.get("ids").and_then(Value::as_array).map_or(0, Vec::len);
            let places = trace.get("placements").and_then(Value::as_array);
            let count = |want: &str| {
                places.map_or(0, |p| {
                    p.iter()
                        .filter(|x| match x.get("place").and_then(Value::as_str) {
                            Some("here") => want == "here",
                            Some("cloud") => want == "cloud",
                            Some(_) => want == "peer",
                            None => false,
                        })
                        .count()
                })
            };
            out.push(event(
                "chief_subagents_spawned",
                json!({
                    "count": ids,
                    "harness": harness(str_of(trace, "harness")),
                    "here": count("here"),
                    "cloud": count("cloud"),
                    "peer": count("peer"),
                    "settle_ms": trace.get("settle_ms").and_then(Value::as_u64),
                }),
            ));
            if ids > 0 {
                out.extend(milestone(state, "first_subagent", now_ms));
            }
        }
        "subagent.start" => out.push(event(
            "chief_subagent_started",
            json!({
                "harness": harness(str_of(trace, "harness")),
                "harness_kind": token(str_of(trace, "harness_kind"), &["acp", "native", "cli", "other"]),
                "goal": bool_of(trace, "goal"),
                "peer": trace.get("peer").is_some_and(|p| !p.is_null()),
                "start_ms": trace.get("ms").and_then(Value::as_u64),
            }),
        )),
        "subagent.done" => {
            let landed = bool_of(trace, "landed");
            let stopped = bool_of(trace, "stopped");
            out.push(event(
                "chief_subagent_finished",
                json!({
                    "outcome": if landed { "landed" } else if bool_of(trace, "unlanded") { "unlanded" } else if stopped { "stopped" } else { "done" },
                    "landed": landed,
                    "stopped": stopped,
                    "duration_ms": trace.get("ms").and_then(Value::as_u64),
                    "tools": trace.get("tools").and_then(Value::as_u64),
                    "tool_errors": trace.get("tool_errors").and_then(Value::as_u64),
                }),
            ));
            if !stopped {
                out.extend(milestone(state, "first_subagent_done", now_ms));
            }
            if landed {
                out.extend(milestone(state, "first_landed_work", now_ms));
            }
        }
        "node" if trace.get("ok") == Some(&Value::Bool(false)) => out.push(event(
            "chief_compactor_failed",
            json!({
                "reason": "node_failed",
                "error_class": error_class(
                    trace.get("error").and_then(|e| e.get("prefix")).and_then(Value::as_str).unwrap_or("")
                ),
                "harness": harness(str_of(trace, "harness")),
                "duration_ms": trace.get("ms").and_then(Value::as_u64),
            }),
        )),
        "compactor.capacity" => out.push(event(
            "chief_compactor_failed",
            json!({
                "reason": "capacity",
                "error_class": "rate_limited",
                "harness": harness(str_of(trace, "route")),
                "http_status": trace.get("status").and_then(Value::as_u64),
                "failover": trace.get("failover").is_some_and(|f| !f.is_null()),
            }),
        )),
        "harness.refused" => out.push(error_event("harness_refused", trace)),
        "turn.capacity_wait" => out.push(error_event("capacity_wait", trace)),
        "turn.ttl_refused" => out.push(error_event("turn_ttl_refused", trace)),
        "subagent.stuck" => out.push(error_event("subagent_stuck", trace)),
        "subagent.stop_refused" => out.push(error_event("subagent_stop_refused", trace)),
        "tell.undelivered" => out.push(error_event("tell_undelivered", trace)),
        "chief.reply_too_long" => out.push(error_event("reply_too_long", trace)),
        "subagent.workspace" if trace.get("error").is_some_and(|e| !e.is_null()) => {
            out.push(error_event("subagent_workspace_failed", trace))
        }
        _ => {}
    }
    out.into_iter()
        .filter_map(|e| match e.name {
            "chief_compactor_failed" | "chief_error" => capped(state, e, now_ms),
            _ => Some(e),
        })
        .collect()
}

fn error_event(kind: &str, trace: &Value) -> Event {
    let role = token(
        str_of(trace, "role"),
        &["chief", "compactor", "subagent", "other"],
    );
    let mut props = json!({"kind": kind});
    if trace.get("role").is_some() {
        props["role"] = json!(role);
    }
    if let Some(h) = str_of(trace, "harness") {
        props["harness"] = json!(harness(Some(h)));
    }
    event("chief_error", props)
}

fn str_of<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str)
}

fn bool_of(v: &Value, key: &str) -> bool {
    v.get(key).and_then(Value::as_bool).unwrap_or(false)
}

/// `value` when it is one of `allowed`, else `other` (`none` when absent).
pub fn token(value: Option<&str>, allowed: &[&'static str]) -> &'static str {
    match value {
        None => "none",
        Some(v) => allowed
            .iter()
            .find(|a| **a == v)
            .copied()
            .unwrap_or("other"),
    }
}

/// A harness id as a closed token.
pub fn harness(value: Option<&str>) -> &'static str {
    token(
        value,
        &[
            "claude",
            "claude-cr",
            "claude-sr",
            "claude_stdio",
            "codex",
            "codex-sr",
            "opencode",
            "gemini",
            "pi",
            "cursor",
            "native",
            "amp",
            "goose",
            "droid",
        ],
    )
}

/// A model id: kept when it is a known vendor's id shape (no account,
/// path or free text can match), else `other`; `default` when unset.
pub fn model(value: Option<&str>) -> String {
    let Some(v) = value.map(str::trim).filter(|v| !v.is_empty()) else {
        return "default".to_owned();
    };
    let v = v.to_ascii_lowercase();
    let v = v.strip_suffix("[1m]").unwrap_or(&v);
    let known = [
        "claude-", "gpt-", "o1", "o3", "o4", "gemini-", "codex-", "grok-", "kimi-", "glm-", "qwen",
        "deepseek",
    ];
    let shape = v.len() <= 48
        && v.bytes().all(|b| {
            b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-' || b == b'.' || b == b'_'
        });
    let alias = ["opus", "sonnet", "haiku", "fable", "default"];
    if shape && (known.iter().any(|k| v.starts_with(k)) || alias.contains(&v)) {
        v.to_owned()
    } else {
        "other".to_owned()
    }
}

/// An effort level as a closed token.
pub fn effort(value: Option<&str>) -> &'static str {
    match value {
        None => "default",
        Some(v) => token(
            Some(v),
            &["minimal", "low", "medium", "high", "xhigh", "max"],
        ),
    }
}

/// A tool name as a closed token: the Chief's own tools by name, a
/// harness's built-in tools by name, any other MCP tool as `mcp_other`.
pub fn tool(value: Option<&str>) -> &'static str {
    const CHIEF: [&str; 31] = [
        "send",
        "reply",
        "react",
        "stop",
        "sleep",
        "watch",
        "spawn",
        "tell",
        "control",
        "profile",
        "remember",
        "cloud_workspace",
        "mcp",
        "zoom",
        "date",
        "peers",
        "escalate_auth",
        "goal",
        "pack",
        "skills",
        "browse",
        "fleet_wait",
        "voice",
        "screen_share",
        "show",
        "draft",
        "settings",
        "engine",
        "usage",
        "trace",
        "github",
    ];
    const BUILTIN: [&str; 16] = [
        "bash",
        "read",
        "edit",
        "write",
        "grep",
        "glob",
        "webfetch",
        "websearch",
        "toolsearch",
        "skill",
        "todowrite",
        "notebookedit",
        "str_replace_based_edit_tool",
        "text_editor",
        "multiedit",
        "ls",
    ];
    let Some(name) = value else { return "none" };
    let lower = name.to_ascii_lowercase();
    if let Some(rest) = lower.strip_prefix("mcp__") {
        let (server, tool) = rest.split_once("__").unwrap_or((rest, ""));
        if matches!(server, "optchat" | "chief")
            && let Some(t) = CHIEF.iter().find(|c| **c == tool)
        {
            return t;
        }
        return if server == "cmux" {
            "mcp_cmux"
        } else {
            "mcp_other"
        };
    }
    CHIEF
        .iter()
        .chain(BUILTIN.iter())
        .find(|c| **c == lower)
        .copied()
        .unwrap_or("other")
}

/// The class of an error from its first characters (the trace's prefix):
/// the only thing about an error text that is sent.
pub fn error_class(prefix: &str) -> &'static str {
    let p = prefix.to_ascii_lowercase();
    let has = |words: &[&str]| words.iter().any(|w| p.contains(w));
    if has(&[
        "rate limit",
        "rate_limit",
        "429",
        "too many requests",
        "usage limit",
        "quota",
    ]) {
        "rate_limited"
    } else if has(&["overloaded", "529", "capacity", "503", "unavailable"]) {
        "overloaded"
    } else if has(&[
        "401",
        "403",
        "unauthorized",
        "forbidden",
        "auth",
        "login",
        "credential",
        "api key",
    ]) {
        "auth"
    } else if has(&["timed out", "timeout", "deadline"]) {
        "timeout"
    } else if has(&[
        "context",
        "too long",
        "too large",
        "prompt is too",
        "max_tokens",
    ]) {
        "context_too_long"
    } else if has(&[
        "connection",
        "network",
        "dns",
        "unreachable",
        "reset by peer",
        "broken pipe",
        "eof",
    ]) {
        "network"
    } else if has(&[
        "acpmux", "session", "harness", "spawn", "exited", "killed", "signal",
    ]) {
        "harness"
    } else if has(&[
        "500",
        "502",
        "504",
        "internal server",
        "api error",
        "server error",
    ]) {
        "server"
    } else {
        "other"
    }
}

/// `part / whole` to 3 decimals; None when `whole` is 0.
fn ratio(part: u64, whole: u64) -> Option<f64> {
    (whole > 0).then(|| ((part as f64 / whole as f64) * 1000.0).round() / 1000.0)
}

/// USD to 6 decimals (a turn costs fractions of a cent).
fn micros(usd: f64) -> f64 {
    if usd.is_finite() {
        (usd * 1e6).round() / 1e6
    } else {
        0.0
    }
}

/// USD to 4 decimals.
fn cents(usd: f64) -> f64 {
    if usd.is_finite() {
        (usd * 1e4).round() / 1e4
    } else {
        0.0
    }
}
