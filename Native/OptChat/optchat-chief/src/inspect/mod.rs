//! The memory inspector (plans/cmux-next/optchat-inspector.md): a read-only
//! JSON API over the live memory, the monitoring trace and the settle
//! status, for the React page the app opens from "Chief: Open Memory
//! Inspector". It answers two questions a person asks about a Chief: what
//! did the model see at a turn, and where did each line of it come from.
//!
//! Read-only by construction: it calls only the chat's read methods
//! (`render_view`, `render_parts`, `node`, `message`, `zoom`, `date`,
//! `status`), searches through a read-only SQLite connection
//! (`ReadOnly`, `query_only`), and reads trace and status files. Nothing
//! here can append, build a node, or write state.
//!
//! `http.rs` serves it on 127.0.0.1 behind a per-launch token.

pub mod http;
mod trace_cache;
mod tree;
mod turns;

use std::path::PathBuf;
use std::sync::Arc;

use optchat_host::OptChat;
use serde_json::{Value, json};

pub use turns::{TurnPrompt, turn_prompt};

/// What the inspector reads.
pub struct Inspector {
    pub chat: Arc<OptChat>,
    /// The trace directory (`optchat/traces`).
    pub traces: PathBuf,
    /// `state/settle.json`, present while a turn waits for the compactor.
    pub settle_status: PathBuf,
    /// The turn sessions' system text as this host built it (prompt.rs).
    pub system_text: String,
    trace: trace_cache::TraceCache,
}

/// An API answer: a JSON body, or an HTTP status and a plain reason.
pub type Answer = Result<Value, (u16, String)>;

pub(crate) fn bad(why: impl Into<String>) -> (u16, String) {
    (400, why.into())
}

pub(crate) fn not_found(why: impl Into<String>) -> (u16, String) {
    (404, why.into())
}

impl Inspector {
    pub fn new(
        chat: Arc<OptChat>,
        traces: PathBuf,
        settle_status: PathBuf,
        system_text: String,
    ) -> Inspector {
        Inspector {
            chat,
            traces,
            settle_status,
            system_text,
            trace: trace_cache::TraceCache::default(),
        }
    }

    /// Recent trace events (the timeline's window), parsed once per line.
    fn recent(&self) -> Vec<Value> {
        self.trace.events(&self.traces, since_ms(RECENT_DAYS))
    }

    /// Answers one GET request: `path` without the query, `query` decoded.
    pub fn answer(&self, path: &str, query: &[(String, String)]) -> Answer {
        let q = |key: &str| {
            query
                .iter()
                .find(|(k, _)| k == key)
                .map(|(_, v)| v.as_str())
        };
        match path {
            "/api/status" => Ok(self.status()),
            "/api/turns" => self.turns(q("limit")),
            "/api/turn" => self.turn(q("key").unwrap_or("now")),
            "/api/node" => self.node(q("name").unwrap_or("")),
            "/api/level" => self.level(q("l"), q("from"), q("limit")),
            "/api/date" => self.date(q("id")),
            "/api/search" => self.search(q("q").unwrap_or(""), q("limit")),
            _ => Err(not_found(format!("no API {path}"))),
        }
    }

    /// The live state: memory counts, compactor work and failures, the
    /// settle wait, the running turn (a `turn.start` with no `turn.end`).
    pub fn status(&self) -> Value {
        let s = self.chat.status();
        let settle = std::fs::read(&self.settle_status)
            .ok()
            .and_then(|b| serde_json::from_slice::<Value>(&b).ok());
        let events = self.recent();
        let summaries = turns::summaries(&events);
        let running = summaries
            .iter()
            .rev()
            .find(|t| t["status"].is_null())
            .cloned();
        let last = summaries
            .iter()
            .rev()
            .find(|t| !t["status"].is_null())
            .cloned();
        let last_error = events
            .iter()
            .rev()
            .find(|e| e.get("error").is_some_and(|x| !x.is_null()))
            .map(|e| json!({"ts": e["ts"], "ev": e["ev"], "error": e["error"]["prefix"], "node": e.get("node"), "turn": e.get("turn")}));
        let top = 63u32.saturating_sub(s.messages.leading_zeros());
        json!({
            "messages": s.messages,
            "view_lines": s.view_lines,
            "view_bytes": s.view_size,
            "budget": s.budget,
            "unbuilt": s.unbuilt,
            "nodes_built": s.built,
            "busy": s.busy.iter().map(|n| n.name()).collect::<Vec<_>>(),
            "failures": s.failures.iter().map(|f| json!({"node": f.node.name(), "error": crate::trace::prefix(&f.error)})).collect::<Vec<_>>(),
            "fatal": s.fatal,
            "closed": s.closed,
            "settled": s.unbuilt == 0,
            "settle": settle,
            "top_level": if s.messages == 0 { Value::Null } else { json!(top) },
            "running_turn": running,
            "last_turn": last,
            "last_error": last_error,
            "trace_on": self.traces.is_dir(),
            "constants": {
                "node_bytes": optchat_core::NODE,
                "view_bytes": optchat_core::VIEW,
                "marks": optchat_core::MARKS,
                "grid": crate::prompt::GRID,
                "placeholder": optchat_core::PLACEHOLDER,
            },
        })
    }

    fn turns(&self, limit: Option<&str>) -> Answer {
        let limit = parse_or(limit, 200usize)?.clamp(1, 2000);
        let events = self.recent();
        let all = turns::summaries(&events);
        let more = all.len() > limit;
        let page: Vec<Value> = all[all.len().saturating_sub(limit)..].to_vec();
        Ok(json!({"turns": page, "more": more, "days": RECENT_DAYS}))
    }

    fn turn(&self, key: &str) -> Answer {
        if key == "now" {
            return Ok(turns::current(self));
        }
        let mut start = self
            .trace
            .turn_start(&self.traces, key)
            .ok_or_else(|| not_found(format!("no turn {key} in the trace")))?;
        let events = crate::report::for_turn(&self.trace.events(&self.traces, 0), key);
        // A turn Claude Code refused the marker on ran again without it.
        if events.iter().any(|e| e["ev"] == "turn.unmarked") {
            start["layout"]["marker"] = json!(false);
        }
        let prompt = turn_prompt(&self.chat, &start, &self.system_text);
        let mut out = turns::prompt_json(&prompt, &start);
        self.decorate(&mut out, &prompt);
        out["events"] = json!(events);
        Ok(out)
    }

    fn date(&self, id: Option<&str>) -> Answer {
        let id: u64 = parse_or(id, u64::MAX)?;
        match self.chat.date(id) {
            Some(date) => Ok(
                json!({"id": id, "date": date, "stamp": self.chat.stamp(id), "call": format!("date({id})")}),
            ),
            None => Err(not_found(format!("No message {id}."))),
        }
    }

    fn search(&self, text: &str, limit: Option<&str>) -> Answer {
        let limit = parse_or(limit, 30usize)?.clamp(1, 200);
        if text.trim().is_empty() {
            return Ok(json!({"hits": []}));
        }
        let db = optchat_host::db::ReadOnly::open(&self.chat.db_path())
            .map_err(|e| (500, format!("opening the memory read-only: {e}")))?;
        let hits = db
            .search(text, limit)
            .map_err(|e| (500, format!("search: {e}")))?;
        let hits: Vec<Value> = hits
            .into_iter()
            .map(|h| match h {
                optchat_host::db::Hit::Message { id, kind, snippet } => {
                    json!({"type": "message", "id": id, "kind": kind, "snippet": snippet, "name": format!("{id}+1")})
                }
                optchat_host::db::Hit::Node { node, snippet } => {
                    json!({"type": "node", "name": node.name(), "level": node.l, "snippet": snippet})
                }
            })
            .collect();
        Ok(json!({"hits": hits}))
    }
}

/// How far back the timeline and the live view read the trace.
pub const RECENT_DAYS: u64 = 14;

fn since_ms(days: u64) -> u64 {
    let now = chrono::Local::now().timestamp_millis().max(0) as u64;
    now.saturating_sub(days * 24 * 3600 * 1000)
}

pub(crate) fn parse_or<T: std::str::FromStr>(
    value: Option<&str>,
    default: T,
) -> Result<T, (u16, String)> {
    match value {
        None | Some("") => Ok(default),
        Some(v) => v.parse().map_err(|_| bad(format!("not a number: {v:?}"))),
    }
}

/// The paths the tools socket's `inspect` tool answers: every read-only API
/// path, and nothing else (no page, no ticket).
pub const INSPECT_PATHS: [&str; 7] = [
    "/api/status",
    "/api/turns",
    "/api/turn",
    "/api/node",
    "/api/level",
    "/api/date",
    "/api/search",
];

/// Largest answer the `inspect` tool returns; a larger one is refused (413),
/// never cut.
pub const INSPECT_MAX_BYTES: usize = 4 * 1024 * 1024;

/// The tools socket's `inspect` tool: `{"tool": "inspect", "method"?: "GET",
/// "path": "/api/..", "query"?: {key: value}}` answers `{"status": 200,
/// "body": ..}` or `{"status": 4xx|5xx, "error": ".."}`. Read-only by
/// construction: GET only, the `INSPECT_PATHS` allowlist, `cap` bytes at most.
pub fn tool_answer(inspector: &Inspector, req: &Value, cap: usize) -> Value {
    let fail = |status: u16, why: &str| json!({"status": status, "error": why});
    let method = req.get("method").and_then(Value::as_str).unwrap_or("GET");
    if method != "GET" {
        return fail(405, "the inspector is read-only: GET only");
    }
    let path = req.get("path").and_then(Value::as_str).unwrap_or("");
    if !INSPECT_PATHS.contains(&path) {
        return fail(404, "not an inspector path");
    }
    let query: Vec<(String, String)> = req
        .get("query")
        .and_then(Value::as_object)
        .map(|q| {
            q.iter()
                .filter_map(|(k, v)| {
                    let v = match v {
                        Value::String(s) => s.clone(),
                        Value::Number(n) => n.to_string(),
                        _ => return None,
                    };
                    Some((k.clone(), v))
                })
                .collect()
        })
        .unwrap_or_default();
    match inspector.answer(path, &query) {
        Ok(body) => {
            if body.to_string().len() > cap {
                return fail(413, "the answer is larger than the inspector's cap");
            }
            json!({"status": 200, "body": body})
        }
        Err((status, why)) => fail(status, &why),
    }
}
