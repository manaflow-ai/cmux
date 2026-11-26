//! The chat's control tools for any other session (RFD 0167 row 8 (c), agents controlling agents
//! from the GUI): `wait` blocks until named sessions end a turn or need an answer and returns
//! each one's reply, and `cancel` stops another session's running turn. Leo, 2026-11-24: "i
//! never only want top x changes. you all need to be working through all useful ones end to end
//! to end."
//!
//! A chat could already start a child (`start_session`), wait on it (`wait_for_sessions`) and
//! stop it (`stop_session`, `subsession_mcp.rs`), but only inside its own tree; a coordinator
//! that messaged a peer lane with `send` had no tool to wait on that lane or stop its turn, and
//! ran `acpmux wait` or `acpmux cancel` in its shell, which the chat draws as a command block
//! and which a 60 s tool timeout cuts off. These are the same requests those CLI commands make
//! (`_acpmux/wait`, `session/cancel`, `cli/orchestrate.rs`, `cli/run/extra.rs`) over this
//! server's connection, which carries the chat's caller token, so the daemon refuses here what
//! it would refuse the CLI and can do nothing that CLI cannot.

use super::{arg, error_result, ok, refusal};
use crate::cli::output::{last_replies, turn_reply};
use crate::client::Client;
use crate::rpc::method;
use serde_json::{Value, json};
use std::sync::Arc;

pub(super) const WAIT: &str = "wait";
pub(super) const CANCEL: &str = "cancel";
pub(super) const TOOLS: &[&str] = &[WAIT, CANCEL];
/// The longest one `wait` call blocks: under Codex's 60 s MCP tool timeout, as
/// `wait_for_sessions` (`subsession_mcp.rs`). A longer wait is the next call.
pub(super) const MAX_WAIT_SECS: u64 = 50;
/// The most sessions one `wait` names.
const MAX_SESSIONS: usize = 32;

pub(super) fn tools() -> Vec<Value> {
    vec![
        json!({
            "name": WAIT,
            "description": "Wait until other sessions (any on this machine or a peer, not only ones you started) end their turn or need an answer, and return each one's state and last reply. Returns on the first unless all is true; a call blocks at most 50 s, so call again while timedOut. Use it after send instead of polling.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "sessions": {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": MAX_SESSIONS, "description": "The sessions: names, ids or host/name (as ls lists them)."},
                    "all": {"type": "boolean", "description": "Wait for every one, not just the first (default false)."},
                    "timeoutSeconds": {"type": "integer", "minimum": 1, "maximum": MAX_WAIT_SECS, "description": "Give up after this many seconds (default and most: 50)."}
                },
                "required": ["sessions"]
            }
        }),
        json!({
            "name": CANCEL,
            "description": "Stop another session's running turn, as its Stop button does: its queued messages stay queued, and it can be messaged again at once. Use it for a session you did not start (stop_session stops your own sub-sessions); never your own chat.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "The session: its name, id or host/name (as ls lists them)."}
                },
                "required": ["name"]
            }
        }),
    ]
}

pub(super) async fn call(daemon: &Arc<Client>, session: &str, name: &str, args: &Value) -> Value {
    match name {
        WAIT => wait(daemon, args).await,
        CANCEL => cancel(daemon, session, args).await,
        other => error_result(format!("unknown control tool {other}")),
    }
}

/// `wait`'s session keys, `all` and timeout, or the refusal the agent reads.
pub(super) fn wait_args(args: &Value) -> Result<(Vec<String>, bool, u64), String> {
    let keys: Vec<String> = match args.get("sessions") {
        Some(Value::Array(items)) => items
            .iter()
            .map(|v| {
                v.as_str()
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(str::to_owned)
                    .ok_or_else(|| "sessions must be an array of names".to_owned())
            })
            .collect::<Result<_, _>>()?,
        // One name where a list was asked: its meaning is clear.
        Some(Value::String(one)) if !one.trim().is_empty() => vec![one.trim().to_owned()],
        _ => vec![],
    };
    if keys.is_empty() {
        return Err("sessions is required: the sessions to wait on, as ls lists them".to_owned());
    }
    if keys.len() > MAX_SESSIONS {
        return Err(format!("at most {MAX_SESSIONS} sessions per wait"));
    }
    let all = args.get("all").and_then(Value::as_bool).unwrap_or(false);
    let secs = args
        .get("timeoutSeconds")
        .and_then(Value::as_u64)
        .unwrap_or(MAX_WAIT_SECS)
        .clamp(1, MAX_WAIT_SECS);
    Ok((keys, all, secs))
}

async fn wait(daemon: &Arc<Client>, args: &Value) -> Value {
    let (keys, all, secs) = match wait_args(args) {
        Ok(v) => v,
        Err(e) => return error_result(e),
    };
    let mut ids = Vec::with_capacity(keys.len());
    for key in &keys {
        match crate::cli::run::resolve_id(daemon, key).await {
            Ok(id) => ids.push(id),
            Err(e) => return refusal(e),
        }
    }
    let params = json!({"sessions": ids, "all": all, "timeoutMs": secs * 1000});
    let reply = match daemon.request(method::MUX_WAIT, params).await {
        Ok(v) => v,
        Err(e) => return refusal(e),
    };
    let timed_out = reply.get("timedOut").and_then(Value::as_bool).unwrap_or(false);
    let pick = if all || timed_out { "sessions" } else { "resolved" };
    let shown = reply.get(pick).and_then(Value::as_array).cloned().unwrap_or_default();
    let mut rows = Vec::with_capacity(shown.len());
    for s in &shown {
        let id = s.get("sessionId").and_then(Value::as_str).unwrap_or_default().to_owned();
        // Only a session whose turn ended has a reply to give; a running one's is the last turn's.
        let ended = !timed_out || s.get("turn").is_none_or(Value::is_null);
        let reply = if ended { session_reply(daemon, &id, s).await } else { String::new() };
        rows.push(row(s, reply));
    }
    ok(wait_text(&rows, timed_out, secs), json!({"sessions": rows, "timedOut": timed_out}))
}

/// The reply of the turn `s` last ended, else the chat's last reply.
async fn session_reply(daemon: &Arc<Client>, id: &str, s: &Value) -> String {
    if let Some(turn) = s.pointer("/lastTurn/turnId").and_then(Value::as_str)
        && let Ok(Some(own)) = turn_reply(daemon, id, turn).await
    {
        return own;
    }
    last_replies(daemon, id, 1).await.unwrap_or_default().pop().unwrap_or_default()
}

/// One waited-on session as the tool answers it.
pub(super) fn row(s: &Value, reply: String) -> Value {
    let id = s.get("sessionId").and_then(Value::as_str).unwrap_or_default();
    json!({
        "name": s.get("name").and_then(Value::as_str).unwrap_or(id),
        "sessionId": id,
        "status": s.get("status"),
        "pendingPermissions": s.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0),
        "waitingOn": s.get("waitingOn"),
        "waitingPrompt": s.get("waitingPrompt"),
        "lastTurnStatus": s.pointer("/lastTurn/status"),
        "reply": reply,
    })
}

/// What the agent reads: one block per session, its state line then its reply.
pub(super) fn wait_text(rows: &[Value], timed_out: bool, secs: u64) -> String {
    let mut out = Vec::new();
    if timed_out {
        out.push(format!("No session resolved in {secs} s; call wait again to keep waiting."));
    }
    for r in rows {
        let g = |k: &str| r.get(k).and_then(Value::as_str).unwrap_or_default();
        let pending = r.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0);
        let state = match (g("waitingOn"), g("waitingPrompt")) {
            ("question", p) if !p.is_empty() => format!("asks a question: {p}"),
            ("question", _) => "asks a question".to_owned(),
            _ if pending > 0 => format!("waiting for permission ({pending})"),
            _ if g("lastTurnStatus") == "failed" => format!("{}: turn failed", g("status")),
            _ => g("status").to_owned(),
        };
        out.push(format!("{}: {state}", g("name")));
        if !g("reply").is_empty() {
            out.push(g("reply").to_owned());
        }
    }
    if out.is_empty() {
        out.push("Nothing to wait on.".to_owned());
    }
    out.join("\n\n")
}

async fn cancel(daemon: &Arc<Client>, session: &str, args: &Value) -> Value {
    let Some(name) = arg(args, "name") else {
        return error_result("name is required".to_owned());
    };
    let id = match crate::cli::resolve::control_id(daemon, name).await {
        Ok(id) => id,
        Err(e) => return refusal(e),
    };
    if !session.is_empty() && id == session {
        return error_result(
            "that is this chat: end your own turn by answering, not with cancel".to_owned(),
        );
    }
    // As a request, as `acpmux cancel` sends it: the reply says the daemon took the cancel.
    match daemon.request(method::SESSION_CANCEL, json!({"sessionId": id})).await {
        Ok(_) => ok(
            format!("Stopped {name}'s running turn (if one ran). Its queued messages stay queued."),
            json!({"sessionId": id, "cancelSent": true}),
        ),
        Err(e) => refusal(e),
    }
}
