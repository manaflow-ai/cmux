//! Claude Code over its own stdio protocol, presented to the hub as an ACP
//! agent.
//!
//! `claude -p --input-format stream-json --output-format stream-json` keeps
//! one process alive for many turns. This module owns that process and
//! translates in both directions:
//!
//!   hub -> claude   ACP requests become user messages and control_requests
//!   claude -> hub   stream-json becomes session/update notifications,
//!                   session/request_permission requests, and responses to
//!                   the pending ACP request (session/prompt, initialize, ...)
//!
//! Nothing outside this file knows the Claude wire format.

use crate::config::AgentProfile;
use crate::rpc::{Id, Message, RpcError, method};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use tokio::sync::Mutex;

/// The session/update variants and ids this translator emits are plain ACP.
pub const AGENT_NAME: &str = "claude-stdio";

/// Claude mode ids, offered as ACP session modes.
const MODES: [(&str, &str); 5] = [
    ("default", "Ask for approval"),
    ("acceptEdits", "Accept edits"),
    ("plan", "Plan"),
    ("auto", "Auto"),
    ("bypassPermissions", "Bypass permissions"),
];

/// Model aliases Claude Code accepts on `set_model` and `--model`. Aliases
/// track Claude Code's own defaults; the `[1m]` suffix asks for the 1M
/// context window, and the full ids pin a model regardless of alias drift.
const MODELS: [(&str, &str); 12] = [
    ("default", "Default (Claude Code's choice)"),
    ("claude-fable-5-1", "Fable 5.1"),
    ("claude-fable-5-1[1m]", "Fable 5.1 · 1M context"),
    ("opus", "Opus"),
    ("opus[1m]", "Opus · 1M context"),
    ("claude-opus-5", "Opus 5"),
    ("opusplan", "Opus plan · Sonnet execute"),
    ("sonnet", "Sonnet"),
    ("sonnet[1m]", "Sonnet · 1M context"),
    ("claude-sonnet-5", "Sonnet 5"),
    ("haiku", "Haiku"),
    ("claude-haiku-4-5-20251001", "Haiku 4.5"),
];

/// The model aliases offered in pickers.
pub fn models() -> &'static [(&'static str, &'static str)] {
    &MODELS
}

#[derive(Debug, Clone)]
pub struct SpawnPlan {
    pub program: String,
    pub args: Vec<String>,
}

/// Build the claude command line. `resume` reopens an existing Claude
/// session (or forks it); `fresh_id` pins the id of a brand-new one so acpmux
/// knows it before the first turn.
pub fn spawn_plan(profile: &AgentProfile, resume: Option<&str>, fork: bool, fresh_id: Option<&str>) -> SpawnPlan {
    let program = profile.argv.first().cloned().unwrap_or_else(|| "claude".into());
    let mut args: Vec<String> = vec![
        "-p".into(),
        "--input-format".into(),
        "stream-json".into(),
        "--output-format".into(),
        "stream-json".into(),
        "--verbose".into(),
        "--include-partial-messages".into(),
        "--permission-prompt-tool".into(),
        "stdio".into(),
    ];
    if let Some(sid) = resume {
        args.push("--resume".into());
        args.push(sid.into());
        if fork {
            args.push("--fork-session".into());
        }
    } else if let Some(id) = fresh_id {
        args.push("--session-id".into());
        args.push(id.into());
    }
    // Everything after the program in argv is passed through, so a profile
    // can pin --model, --permission-mode, --settings, --mcp-config, ...
    args.extend(profile.argv.iter().skip(1).cloned());
    SpawnPlan { program, args }
}

/// Per-process translation state.
pub struct Translator {
    /// ACP request id -> what we are waiting on from claude.
    pending: Mutex<HashMap<String, Pending>>,
    /// claude control request_id -> ACP request id we issued to the hub.
    control_out: Mutex<HashMap<String, Id>>,
    next_control: AtomicI64,
    pub session_id: Mutex<Option<String>>,
    pub acp_session_id: String,
    mode: Mutex<String>,
    model: Mutex<String>,
    in_turn: AtomicBool,
    /// Text streamed so far in the current turn, to build the prompt result.
    pub cancelled: AtomicBool,
    pub slash_commands: Mutex<Vec<Value>>,
}

#[derive(Debug, Clone)]
enum Pending {
    Initialize,
    NewOrLoad,
    Prompt,
    Control,
}

impl Translator {
    pub fn new(acp_session_id: String, mode: &str, model: &str) -> Arc<Self> {
        Arc::new(Self {
            pending: Mutex::new(HashMap::new()),
            control_out: Mutex::new(HashMap::new()),
            next_control: AtomicI64::new(1),
            session_id: Mutex::new(None),
            acp_session_id,
            mode: Mutex::new(mode.to_owned()),
            model: Mutex::new(model.to_owned()),
            in_turn: AtomicBool::new(false),
            cancelled: AtomicBool::new(false),
            slash_commands: Mutex::new(Vec::new()),
        })
    }

    pub async fn modes_value(&self) -> Value {
        json!({
            "currentModeId": *self.mode.lock().await,
            "availableModes": MODES.iter().map(|(id, name)| json!({"id": id, "name": name})).collect::<Vec<_>>(),
        })
    }

    pub async fn config_options_value(&self) -> Value {
        json!([
            {"id": "model", "name": "Model", "type": "select", "category": "model", "currentValue": *self.model.lock().await,
             "options": MODELS.iter().map(|(v, n)| json!({"value": v, "name": n})).collect::<Vec<_>>()},
            {"id": "mode", "name": "Permission mode", "type": "select", "category": "mode", "currentValue": *self.mode.lock().await,
             "options": MODES.iter().map(|(v, n)| json!({"value": v, "name": n})).collect::<Vec<_>>()},
        ])
    }

    /// Translate one ACP request from the hub into zero or more lines for
    /// claude's stdin, and optionally an immediate ACP response.
    pub async fn outbound(&self, msg: &Message) -> Outbound {
        match msg {
            Message::Request { id, method: m, params } => {
                let p = params.clone().unwrap_or(Value::Null);
                match m.as_str() {
                    method::INITIALIZE => {
                        self.pending.lock().await.insert(id.to_string(), Pending::Initialize);
                        Outbound::Lines(vec![json!({
                            "type": "control_request",
                            "request_id": format!("init-{}", id),
                            "request": {"subtype": "initialize", "hooks": {}, "supportedDialogKinds": ["ask_user_question", "exit_plan_mode", "permission"]}
                        })])
                    }
                    method::SESSION_NEW | method::SESSION_LOAD => {
                        // The claude process already carries the session.
                        // Its id arrives in system/init on the first turn; for
                        // a resumed process we already know it.
                        let sid = self.session_id.lock().await.clone();
                        match sid {
                            Some(sid) => Outbound::Reply(Message::ok(id.clone(), json!({
                                "sessionId": sid,
                                "modes": self.modes_value().await,
                                "configOptions": self.config_options_value().await,
                            }))),
                            None => {
                                // Ask claude for its init by sending initialize; system/init
                                // only appears on first prompt, so we synthesize the id
                                // lazily: reply with a placeholder that is corrected on init.
                                self.pending.lock().await.insert(id.to_string(), Pending::NewOrLoad);
                                Outbound::Lines(vec![])
                            }
                        }
                    }
                    method::SESSION_PROMPT => {
                        let blocks = p.get("prompt").and_then(Value::as_array).cloned().unwrap_or_default();
                        let content: Vec<Value> = blocks
                            .iter()
                            .map(|b| match b.get("type").and_then(Value::as_str) {
                                Some("text") => json!({"type": "text", "text": b.get("text").and_then(Value::as_str).unwrap_or("")}),
                                Some("image") => json!({"type": "image", "source": {"type": "base64", "media_type": b.get("mimeType").and_then(Value::as_str).unwrap_or("image/png"), "data": b.get("data").and_then(Value::as_str).unwrap_or("")}}),
                                _ => json!({"type": "text", "text": b.get("text").and_then(Value::as_str).unwrap_or("")}),
                            })
                            .collect();
                        self.in_turn.store(true, Ordering::SeqCst);
                        self.cancelled.store(false, Ordering::SeqCst);
                        self.pending.lock().await.insert(id.to_string(), Pending::Prompt);
                        Outbound::Lines(vec![json!({"type": "user", "message": {"role": "user", "content": content}})])
                    }
                    method::SESSION_SET_MODE => {
                        let mode = p.get("modeId").and_then(Value::as_str).unwrap_or("default").to_owned();
                        *self.mode.lock().await = mode.clone();
                        self.pending.lock().await.insert(id.to_string(), Pending::Control);
                        Outbound::Lines(vec![json!({"type": "control_request", "request_id": format!("ctl-{}", id), "request": {"subtype": "set_permission_mode", "mode": mode}})])
                    }
                    method::SESSION_SET_CONFIG_OPTION => {
                        let cid = p.get("configId").and_then(Value::as_str).unwrap_or("");
                        let val = p.get("value").and_then(Value::as_str).unwrap_or("").to_owned();
                        match cid {
                            "model" => {
                                *self.model.lock().await = val.clone();
                                self.pending.lock().await.insert(id.to_string(), Pending::Control);
                                Outbound::Lines(vec![json!({"type": "control_request", "request_id": format!("ctl-{}", id), "request": {"subtype": "set_model", "model": val}})])
                            }
                            "mode" => {
                                *self.mode.lock().await = val.clone();
                                self.pending.lock().await.insert(id.to_string(), Pending::Control);
                                Outbound::Lines(vec![json!({"type": "control_request", "request_id": format!("ctl-{}", id), "request": {"subtype": "set_permission_mode", "mode": val}})])
                            }
                            other => Outbound::Reply(Message::err(id.clone(), RpcError::invalid_params(format!("unknown config option {other}")))),
                        }
                    }
                    method::SESSION_SET_MODEL => {
                        let val = p.get("modelId").and_then(Value::as_str).unwrap_or("default").to_owned();
                        *self.model.lock().await = val.clone();
                        self.pending.lock().await.insert(id.to_string(), Pending::Control);
                        Outbound::Lines(vec![json!({"type": "control_request", "request_id": format!("ctl-{}", id), "request": {"subtype": "set_model", "model": val}})])
                    }
                    method::SESSION_FORK => {
                        // Forking needs a new process (--fork-session); the hub does that.
                        Outbound::Reply(Message::err(id.clone(), RpcError::new(-32002, "fork is handled by respawn")))
                    }
                    other => Outbound::Reply(Message::err(id.clone(), RpcError::method_not_found(other))),
                }
            }
            Message::Notification { method: m, .. } => {
                if m == method::SESSION_CANCEL {
                    self.cancelled.store(true, Ordering::SeqCst);
                    let n = self.next_control.fetch_add(1, Ordering::SeqCst);
                    Outbound::Lines(vec![json!({"type": "control_request", "request_id": format!("int-{n}"), "request": {"subtype": "interrupt"}})])
                } else {
                    Outbound::Lines(vec![])
                }
            }
            Message::Response { id, result, error } => {
                // The hub answered a permission request we raised.
                let ctl = self.control_out.lock().await.iter().find(|(_, v)| **v == *id).map(|(k, _)| k.clone());
                let Some(ctl_id) = ctl else { return Outbound::Lines(vec![]) };
                self.control_out.lock().await.remove(&ctl_id);
                let outcome = result.as_ref().and_then(|r| r.get("outcome")).cloned().unwrap_or(Value::Null);
                let selected = outcome.get("optionId").and_then(Value::as_str).unwrap_or("");
                let response = if error.is_some() || outcome.get("outcome").and_then(Value::as_str) == Some("cancelled") || selected.starts_with("reject") {
                    json!({"behavior": "deny", "message": "The user rejected this action."})
                } else {
                    // allow / allow_always: pass the (possibly answered) input back.
                    let updated = result.as_ref().and_then(|r| r.pointer("/_meta/updatedInput")).cloned();
                    match updated {
                        Some(u) => json!({"behavior": "allow", "updatedInput": u}),
                        None => json!({"behavior": "allow"}),
                    }
                };
                Outbound::Lines(vec![json!({"type": "control_response", "response": {"subtype": "success", "request_id": ctl_id, "response": response}})])
            }
        }
    }

    /// Translate one line from claude's stdout into ACP messages for the hub.
    pub async fn inbound(&self, line: &Value) -> Vec<Message> {
        let kind = line.get("type").and_then(Value::as_str).unwrap_or("");
        let sub = line.get("subtype").and_then(Value::as_str).unwrap_or("");
        let sid = self.acp_session_id.clone();
        let upd = |u: Value| Message::notification(method::SESSION_UPDATE, json!({"sessionId": sid, "update": u}));
        let mut out = Vec::new();
        match kind {
            "system" if sub == "init" => {
                if let Some(s) = line.get("session_id").and_then(Value::as_str) {
                    *self.session_id.lock().await = Some(s.to_owned());
                }
                if let Some(m) = line.get("model").and_then(Value::as_str) {
                    *self.model.lock().await = m.to_owned();
                }
                if let Some(m) = line.get("permissionMode").and_then(Value::as_str) {
                    *self.mode.lock().await = m.to_owned();
                }
                // Answer a pending session/new or session/load now that we have the id.
                let waiting: Vec<String> = self.pending.lock().await.iter().filter(|(_, p)| matches!(p, Pending::NewOrLoad)).map(|(k, _)| k.clone()).collect();
                for k in waiting {
                    self.pending.lock().await.remove(&k);
                    let id: Id = serde_json::from_str(&k).unwrap_or(Value::String(k.clone()));
                    out.push(Message::ok(id, json!({
                        "sessionId": self.session_id.lock().await.clone(),
                        "modes": self.modes_value().await,
                        "configOptions": self.config_options_value().await,
                    })));
                }
                out.push(upd(json!({"sessionUpdate": "session_info_update", "title": Value::Null, "_meta": {"claude": {"tools": line.get("tools"), "mcp_servers": line.get("mcp_servers"), "model": line.get("model")}}})));
                out.push(upd(json!({"sessionUpdate": "config_option_update", "configOptions": self.config_options_value().await})));
            }
            "stream_event" => {
                let ev = line.get("event").cloned().unwrap_or(Value::Null);
                match ev.get("type").and_then(Value::as_str) {
                    Some("content_block_delta") => {
                        let d = ev.get("delta").cloned().unwrap_or(Value::Null);
                        match d.get("type").and_then(Value::as_str) {
                            Some("text_delta") => out.push(upd(json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": d.get("text").and_then(Value::as_str).unwrap_or("")}}))),
                            Some("thinking_delta") => {
                                let t = d.get("thinking").and_then(Value::as_str).unwrap_or("");
                                if !t.is_empty() {
                                    out.push(upd(json!({"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": t}})));
                                }
                            }
                            _ => {}
                        }
                    }
                    Some("message_delta") => {
                        if let Some(u) = ev.get("usage") {
                            let used = u.get("input_tokens").and_then(Value::as_u64).unwrap_or(0)
                                + u.get("cache_read_input_tokens").and_then(Value::as_u64).unwrap_or(0)
                                + u.get("cache_creation_input_tokens").and_then(Value::as_u64).unwrap_or(0)
                                + u.get("output_tokens").and_then(Value::as_u64).unwrap_or(0);
                            out.push(upd(json!({"sessionUpdate": "usage_update", "used": used, "size": 0})));
                        }
                    }
                    _ => {}
                }
            }
            "assistant" => {
                for c in line.pointer("/message/content").and_then(Value::as_array).cloned().unwrap_or_default() {
                    if c.get("type").and_then(Value::as_str) == Some("tool_use") {
                        let name = c.get("name").and_then(Value::as_str).unwrap_or("tool");
                        let input = c.get("input").cloned().unwrap_or(Value::Null);
                        out.push(upd(json!({
                            "sessionUpdate": "tool_call",
                            "toolCallId": c.get("id"),
                            "title": tool_title(name, &input),
                            "kind": tool_kind(name),
                            "status": "in_progress",
                            "rawInput": input,
                            "_meta": {"claude": {"tool": name}}
                        })));
                    }
                }
            }
            "user" => {
                for c in line.pointer("/message/content").and_then(Value::as_array).cloned().unwrap_or_default() {
                    if c.get("type").and_then(Value::as_str) == Some("tool_result") {
                        let text = match c.get("content") {
                            Some(Value::String(s)) => s.clone(),
                            Some(Value::Array(a)) => a.iter().filter_map(|x| x.get("text").and_then(Value::as_str)).collect::<Vec<_>>().join("\n"),
                            _ => String::new(),
                        };
                        let is_err = c.get("is_error").and_then(Value::as_bool).unwrap_or(false);
                        out.push(upd(json!({
                            "sessionUpdate": "tool_call_update",
                            "toolCallId": c.get("tool_use_id"),
                            "status": if is_err { "failed" } else { "completed" },
                            "content": [{"type": "content", "content": {"type": "text", "text": text}}],
                        })));
                    }
                }
            }
            "control_request" => {
                let req = line.get("request").cloned().unwrap_or(Value::Null);
                let rid = line.get("request_id").and_then(Value::as_str).unwrap_or("").to_owned();
                match req.get("subtype").and_then(Value::as_str) {
                    Some("can_use_tool") => {
                        let name = req.get("tool_name").and_then(Value::as_str).unwrap_or("tool");
                        let input = req.get("input").cloned().unwrap_or(Value::Null);
                        let n = self.next_control.fetch_add(1, Ordering::SeqCst);
                        let acp_id = Value::from(1_000_000 + n);
                        self.control_out.lock().await.insert(rid.clone(), acp_id.clone());
                        let interactive = req.get("requires_user_interaction").and_then(Value::as_bool).unwrap_or(false);
                        let mut options = vec![
                            json!({"optionId": "allow_once", "name": if interactive { "Answer" } else { "Allow" }, "kind": "allow_once"}),
                        ];
                        if !interactive {
                            options.push(json!({"optionId": "allow_always", "name": "Allow for this session", "kind": "allow_always"}));
                        }
                        options.push(json!({"optionId": "reject_once", "name": "Reject", "kind": "reject_once"}));
                        out.push(Message::request(acp_id, method::SESSION_REQUEST_PERMISSION, json!({
                            "sessionId": sid,
                            "toolCall": {
                                "toolCallId": req.get("tool_use_id"),
                                "title": tool_title(name, &input),
                                "kind": tool_kind(name),
                                "status": "pending",
                                "rawInput": input,
                                "_meta": {"claude": {"tool": name, "interactive": interactive, "suggestions": req.get("permission_suggestions"), "description": req.get("description")}}
                            },
                            "options": options,
                        })));
                    }
                    Some(other) => {
                        // Anything else (hook_callback, mcp_message) is declined.
                        tracing::debug!("claude control_request {other} declined");
                        let _ = other;
                    }
                    None => {}
                }
            }
            "control_response" => {
                let resp = line.get("response").cloned().unwrap_or(Value::Null);
                let rid = resp.get("request_id").and_then(Value::as_str).unwrap_or("");
                let ok = resp.get("subtype").and_then(Value::as_str) == Some("success");
                let inner = resp.get("response").cloned().unwrap_or(Value::Null);
                if let Some(acp) = rid.strip_prefix("init-") {
                    let id: Id = serde_json::from_str(acp).unwrap_or(Value::String(acp.to_owned()));
                    self.pending.lock().await.remove(&id.to_string());
                    if let Some(cmds) = inner.get("commands").and_then(Value::as_array) {
                        *self.slash_commands.lock().await = cmds.clone();
                    }
                    out.push(Message::ok(id, json!({
                        "protocolVersion": 1,
                        "agentInfo": {"name": AGENT_NAME, "title": "Claude Code", "version": inner.get("version").cloned().unwrap_or(Value::Null)},
                        "agentCapabilities": {"loadSession": true, "promptCapabilities": {"image": true, "embeddedContext": true}, "sessionCapabilities": {"fork": {}, "list": {}, "close": {}}},
                        "authMethods": [],
                        "_meta": {"steering": {"supported": false}, "claude": {"commands": inner.get("commands"), "capabilities": inner.get("capabilities")}}
                    })));
                    if let Some(cmds) = inner.get("commands").and_then(Value::as_array) {
                        let list: Vec<Value> = cmds.iter().map(|c| json!({"name": c.get("name"), "description": c.get("description")})).collect();
                        out.push(upd(json!({"sessionUpdate": "available_commands_update", "availableCommands": list})));
                    }
                } else if let Some(acp) = rid.strip_prefix("ctl-") {
                    let id: Id = serde_json::from_str(acp).unwrap_or(Value::String(acp.to_owned()));
                    self.pending.lock().await.remove(&id.to_string());
                    if ok {
                        let mode = self.mode.lock().await.clone();
                        out.push(upd(json!({"sessionUpdate": "current_mode_update", "currentModeId": mode})));
                        out.push(Message::ok(id, json!({"configOptions": self.config_options_value().await, "currentModeId": mode})));
                    } else {
                        out.push(Message::err(id, RpcError::internal(resp.get("error").and_then(Value::as_str).unwrap_or("control request failed"))));
                    }
                }
                // "int-*" acks need no reply; the result message ends the turn.
            }
            "result" => {
                // A resumed process emits one empty result (num_turns 0, no
                // API time) right after its system/init, before the real
                // turn. That is startup noise, not the end of our prompt.
                let startup_noise = line.get("num_turns").and_then(Value::as_u64) == Some(0)
                    && line.get("duration_api_ms").and_then(Value::as_u64) == Some(0)
                    && !self.cancelled.load(Ordering::SeqCst);
                if startup_noise {
                    return out;
                }
                self.in_turn.store(false, Ordering::SeqCst);
                let waiting: Vec<String> = self.pending.lock().await.iter().filter(|(_, p)| matches!(p, Pending::Prompt)).map(|(k, _)| k.clone()).collect();
                let cancelled = self.cancelled.swap(false, Ordering::SeqCst);
                let stop = if cancelled || (sub == "error_during_execution" && line.get("result").map(Value::is_null).unwrap_or(true)) {
                    "cancelled"
                } else if sub == "error_max_turns" {
                    "max_turn_requests"
                } else if sub.starts_with("error") {
                    "refusal"
                } else {
                    "end_turn"
                };
                for k in waiting {
                    self.pending.lock().await.remove(&k);
                    let id: Id = serde_json::from_str(&k).unwrap_or(Value::String(k.clone()));
                    if sub.starts_with("error") && !cancelled && stop != "cancelled" {
                        out.push(Message::err(id, RpcError::internal(line.get("result").and_then(Value::as_str).unwrap_or(sub))));
                    } else {
                        out.push(Message::ok(id, json!({"stopReason": stop, "_meta": {"claude": {"subtype": sub, "cost_usd": line.get("total_cost_usd"), "usage": line.get("usage"), "num_turns": line.get("num_turns")}}})));
                    }
                }
            }
            _ => {}
        }
        out
    }
}

pub enum Outbound {
    Lines(Vec<Value>),
    Reply(Message),
}

fn tool_kind(name: &str) -> &'static str {
    match name {
        "Read" | "Glob" | "Grep" | "NotebookRead" => "read",
        "Write" | "Edit" | "MultiEdit" | "NotebookEdit" => "edit",
        "Bash" | "BashOutput" | "KillShell" => "execute",
        "WebFetch" | "WebSearch" => "fetch",
        "Task" | "Agent" => "think",
        "AskUserQuestion" | "ExitPlanMode" => "other",
        _ => "other",
    }
}

fn tool_title(name: &str, input: &Value) -> String {
    let s = |k: &str| input.get(k).and_then(Value::as_str).map(str::to_owned);
    match name {
        "Bash" => s("command").map(|c| c.lines().next().unwrap_or("").chars().take(120).collect()).unwrap_or_else(|| "Bash".into()),
        "Read" | "Write" | "Edit" | "MultiEdit" => format!("{name} {}", s("file_path").map(|p| Path::new(&p).file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or(p)).unwrap_or_default()),
        "Glob" | "Grep" => format!("{name} {}", s("pattern").unwrap_or_default()),
        "WebFetch" => format!("Fetch {}", s("url").unwrap_or_default()),
        "WebSearch" => format!("Search {}", s("query").unwrap_or_default()),
        "Task" | "Agent" => format!("Agent: {}", s("description").unwrap_or_default()),
        "AskUserQuestion" => input.pointer("/questions/0/question").and_then(Value::as_str).map(|q| format!("Question: {q}")).unwrap_or_else(|| "Question".into()),
        "ExitPlanMode" => "Approve plan".into(),
        _ => name.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn prompt_becomes_user_line_and_result_answers_it() {
        let t = Translator::new("acp-1".into(), "default", "haiku");
        let req = Message::request(7, method::SESSION_PROMPT, json!({"sessionId": "acp-1", "prompt": [{"type": "text", "text": "hi"}]}));
        let Outbound::Lines(lines) = t.outbound(&req).await else { panic!() };
        assert_eq!(lines[0]["type"], "user");
        assert_eq!(lines[0]["message"]["content"][0]["text"], "hi");
        let msgs = t.inbound(&json!({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "yo"}}})).await;
        assert!(matches!(&msgs[0], Message::Notification { method, .. } if method == method::SESSION_UPDATE));
        let msgs = t.inbound(&json!({"type": "result", "subtype": "success", "result": "yo"})).await;
        match &msgs[0] {
            Message::Response { id, result, .. } => {
                assert_eq!(*id, Value::from(7));
                assert_eq!(result.as_ref().unwrap()["stopReason"], "end_turn");
            }
            _ => panic!(),
        }
    }

    #[tokio::test]
    async fn interrupt_result_is_cancelled() {
        let t = Translator::new("acp-1".into(), "default", "haiku");
        t.outbound(&Message::request(1, method::SESSION_PROMPT, json!({"prompt": [{"type": "text", "text": "go"}]}))).await;
        let Outbound::Lines(lines) = t.outbound(&Message::notification(method::SESSION_CANCEL, json!({}))).await else { panic!() };
        assert_eq!(lines[0]["request"]["subtype"], "interrupt");
        let msgs = t.inbound(&json!({"type": "result", "subtype": "error_during_execution", "is_error": true, "result": null})).await;
        match &msgs[0] {
            Message::Response { result, .. } => assert_eq!(result.as_ref().unwrap()["stopReason"], "cancelled"),
            _ => panic!(),
        }
    }

    #[tokio::test]
    async fn resume_startup_result_is_ignored() {
        let t = Translator::new("acp-1".into(), "default", "haiku");
        t.outbound(&Message::request(3, method::SESSION_PROMPT, json!({"prompt": [{"type": "text", "text": "q"}]}))).await;
        let noise = t.inbound(&json!({"type": "result", "subtype": "success", "result": "", "num_turns": 0, "duration_api_ms": 0})).await;
        assert!(noise.is_empty(), "startup result must not answer the prompt");
        let real = t.inbound(&json!({"type": "result", "subtype": "success", "result": "A", "num_turns": 1, "duration_api_ms": 500})).await;
        assert!(matches!(&real[0], Message::Response { id, .. } if *id == Value::from(3)));
    }

    #[tokio::test]
    async fn permission_round_trip() {
        let t = Translator::new("acp-1".into(), "default", "haiku");
        let msgs = t.inbound(&json!({"type": "control_request", "request_id": "abc", "request": {"subtype": "can_use_tool", "tool_name": "Write", "input": {"file_path": "/x/y.txt", "content": "ok"}, "tool_use_id": "tu1"}})).await;
        let Message::Request { id, method: m, params } = &msgs[0] else { panic!() };
        assert_eq!(m, method::SESSION_REQUEST_PERMISSION);
        assert_eq!(params.as_ref().unwrap()["toolCall"]["title"], "Write y.txt");
        let Outbound::Lines(lines) = t.outbound(&Message::ok(id.clone(), json!({"outcome": {"outcome": "selected", "optionId": "allow_once"}}))).await else { panic!() };
        assert_eq!(lines[0]["response"]["request_id"], "abc");
        assert_eq!(lines[0]["response"]["response"]["behavior"], "allow");
    }
}
