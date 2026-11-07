//! The phone's ACP channel over one already authenticated Cloud daemon carrier.
//! Native surface ids never come from the phone. Discovery binds them to the
//! VM's stored agent tabs; pages and records retain their original ACP sequence
//! numbers. This adapter grants no approval, mode, filesystem or process API.
//!
//! `session/new` starts a Claude chat on the machine's own acpmux the way the
//! Mac does: a `registry:` agent tab in the machine's first workspace (one is
//! made when there is none), then `agent-session-start` with no folder (the
//! machine makes the chat's own folder) and policy `ask`. The phone names no
//! folder, harness other than Claude, model, MCP server, mode or policy.

use serde_json::{Value, json};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::time::{Duration, Instant};

const MAX_PENDING: usize = 32;
const MAX_SESSIONS: usize = 1024;
const DEADLINE: Duration = Duration::from_secs(15);
/// acpmux may start the agent process first (the phone's Mac `session/new` allows 90 s).
const START_DEADLINE: Duration = Duration::from_secs(90);
/// The only agent a phone starts on a Cloud machine: its default mode asks before acting,
/// so the prompt preflight below admits the new chat.
const PHONE_START_HARNESS: &str = "claude";

#[derive(Default)]
pub(crate) struct Effects {
    pub(crate) to_phone: Vec<Value>,
    pub(crate) to_native: Vec<Value>,
}

struct Tab {
    surface: u64,
    summary: Value,
}

enum Reply {
    Directory,
    Page { session: String, surface: u64, info: bool },
    Prepare { session: String, surface: u64, command: Value, kind: Simple },
    Simple { session: String, surface: u64, kind: Simple },
    /// `session/new`: the tree, then (when it has no workspace) a new one, the tab, the start.
    NewTree,
    NewWorkspace { registry: String },
    NewTab,
    Start { surface: u64 },
}

#[derive(Clone, Copy)]
enum Simple {
    Prompt,
    Cancel,
    Detach,
    Events,
}

struct Pending {
    phone_id: Option<Value>,
    reply: Reply,
    at: Instant,
    deadline: Duration,
}

pub(crate) struct Adapter {
    next: u64,
    pending: HashMap<u64, Pending>,
    tabs: BTreeMap<String, Tab>,
    surface_sessions: HashMap<u64, String>,
    attached: HashSet<u64>,
}

impl Adapter {
    // Machine/team authorization belongs to the service's fresh app snapshot,
    // and the native daemon's authenticated connection. Neither is an ACP arg.
    pub(crate) fn new(_machine: String, _team: String) -> Self {
        Self {
            next: 0,
            pending: HashMap::new(),
            tabs: BTreeMap::new(),
            surface_sessions: HashMap::new(),
            attached: HashSet::new(),
        }
    }

    fn call(&mut self, mut command: Value, phone_id: Option<Value>, reply: Reply) -> Effects {
        if self.pending.len() >= MAX_PENDING {
            return error(phone_id, -32000, "Too many Cloud chat requests");
        }
        if phone_id.is_some() && self.pending.values().any(|p| p.phone_id == phone_id) {
            return error(phone_id, -32600, "ACP request id is already pending");
        }
        let deadline = if matches!(reply, Reply::Start { .. }) { START_DEADLINE } else { DEADLINE };
        self.next += 1;
        command["id"] = json!(self.next);
        self.pending.insert(self.next, Pending { phone_id, reply, at: Instant::now(), deadline });
        Effects { to_native: vec![command], ..Effects::default() }
    }

    pub(crate) fn phone(&mut self, request: Value) -> Result<Effects, String> {
        let object = request.as_object().ok_or("ACP request must be an object")?;
        let id = object.get("id").cloned();
        if id.as_ref().is_some_and(|v| !v.is_string() && !v.is_number()) {
            return Err("ACP request id must be a string or number".into());
        }
        let method = object.get("method").and_then(Value::as_str).ok_or("ACP request has no method")?;
        let empty = json!({});
        let params = object.get("params").unwrap_or(&empty);
        if !params.is_object() {
            return Ok(error(id, -32602, "ACP params must be an object"));
        }
        match method {
            "initialize" => {
                return Ok(answer(
                    id,
                    json!({"protocolVersion":1,
                "serverInfo":{"name":"cmux-cloud","version":env!("CARGO_PKG_VERSION")},
                "_meta":{"acpmux":{"fullAccess":false}}}),
                ));
            }
            "_acpmux/watch" | "_acpmux/sessions" => {
                if params.get("cursor").is_some() {
                    return Ok(error(id, -32602, "Cloud session list has no continuation cursor"));
                }
                return Ok(self.call(json!({"cmd":"list-workspaces"}), id, Reply::Directory));
            }
            "session/new" => {
                if let Some(refusal) = new_session_refusal(params) {
                    return Ok(error(id, -32602, refusal));
                }
                return Ok(self.call(json!({"cmd":"list-workspaces"}), id, Reply::NewTree));
            }
            "_acpmux/attach" | "_acpmux/events" | "_acpmux/info" | "_acpmux/detach" | "session/prompt"
            | "session/cancel" => {}
            _ => return Ok(error(id, -32601, "This action is not supported by the Cloud chat relay")),
        }
        let Some(session) = params.get("sessionId").and_then(Value::as_str) else {
            return Ok(error(id, -32602, "sessionId is required"));
        };
        let Some(tab) = self.tabs.get(session) else {
            return Ok(error(
                id,
                -32000,
                "Cloud chat is not in this machine's directory; reconnect to refresh",
            ));
        };
        let surface = tab.surface;
        if method == "_acpmux/attach" || method == "_acpmux/info" {
            let mut command = page_command("agent-session-attach", surface, params);
            let info = method == "_acpmux/info";
            if info {
                command["limit"] = json!(1);
            }
            return Ok(self.call(command, id, Reply::Page { session: session.into(), surface, info }));
        }
        let (command, kind) = match method {
            "_acpmux/events" => (page_command("agent-session-events", surface, params), Simple::Events),
            "_acpmux/detach" => (json!({"cmd":"agent-session-detach","surface":surface}), Simple::Detach),
            "session/cancel" => (json!({"cmd":"agent-session-cancel","surface":surface}), Simple::Cancel),
            "session/prompt" => {
                let Some(blocks) = params.get("prompt").and_then(Value::as_array) else {
                    return Ok(error(id, -32602, "A text prompt is required"));
                };
                let mut text = String::new();
                for block in blocks {
                    if block.get("type").and_then(Value::as_str) != Some("text") {
                        return Ok(error(id, -32602, "Cloud relay currently supports text prompts"));
                    }
                    let Some(part) = block.get("text").and_then(Value::as_str) else {
                        return Ok(error(id, -32602, "Invalid text prompt"));
                    };
                    text.push_str(part);
                }
                let Some(prompt) = params
                    .pointer("/_meta/acpmux/promptId")
                    .and_then(Value::as_str)
                    .filter(|p| !p.is_empty() && p.len() <= 160)
                else {
                    return Ok(error(id, -32602, "A stable promptId is required"));
                };
                if text.trim().is_empty() {
                    return Ok(error(id, -32602, "A text prompt is required"));
                }
                if params.pointer("/_meta/acpmux/steer") == Some(&json!(true)) {
                    return Ok(error(id, -32602, "Steering is not supported by the Cloud chat relay"));
                }
                (
                    json!({"cmd":"agent-session-prompt","surface":surface,"prompt_id":prompt,"text":text}),
                    Simple::Prompt,
                )
            }
            _ => unreachable!("methods checked above"),
        };
        // Always read current mode/policy immediately before prompting. A cached
        // attachment can outlive a mode change made on the Mac.
        if matches!(kind, Simple::Prompt)
            || (!self.attached.contains(&surface) && !matches!(kind, Simple::Detach))
        {
            return Ok(self.call(
                json!({"cmd":"agent-session-attach","surface":surface,"limit":1}),
                id,
                Reply::Prepare { session: session.into(), surface, command, kind },
            ));
        }
        Ok(self.call(command, id, Reply::Simple { session: session.into(), surface, kind }))
    }

    pub(crate) fn native(&mut self, response: Value) -> Result<Effects, String> {
        if response.get("event").is_some() {
            return self.event(response);
        }
        let Some(id) = response.get("id").and_then(Value::as_u64) else {
            return Ok(Effects::default());
        };
        let Some(pending) = self.pending.remove(&id) else {
            return Ok(Effects::default());
        };
        if response.get("ok") != Some(&json!(true)) {
            let message =
                response.get("error").and_then(Value::as_str).unwrap_or("Cloud daemon refused the request");
            let mut out = error(pending.phone_id, -32000, message);
            // A start the machine refused leaves no empty chat tab behind.
            if let Reply::Start { surface } = pending.reply {
                out.to_native.push(json!({"cmd":"close-surface","surface":surface}));
            }
            return Ok(out);
        }
        let data = response.get("data").cloned().unwrap_or_else(|| json!({}));
        let phone = pending.phone_id;
        match pending.reply {
            Reply::Directory => {
                let tabs = discover(&data)?;
                let summaries = tabs.values().map(|t| t.summary.clone()).collect::<Vec<_>>();
                let next: HashMap<_, _> =
                    tabs.iter().map(|(session, tab)| (tab.surface, session.clone())).collect();
                let stale: Vec<_> = self
                    .attached
                    .iter()
                    .copied()
                    .filter(|surface| self.surface_sessions.get(surface) != next.get(surface))
                    .collect();
                let mut reply = answer(phone, json!({"sessions":summaries}));
                for surface in stale {
                    self.attached.remove(&surface);
                    reply.to_native.push(json!({"cmd":"agent-session-detach","surface":surface}));
                }
                self.surface_sessions = next;
                self.tabs = tabs;
                Ok(reply)
            }
            Reply::Page { session, surface, info } => {
                if self.surface_sessions.get(&surface) != Some(&session)
                    || data.pointer("/session/sessionId").and_then(Value::as_str) != Some(session.as_str())
                {
                    return Ok(error(phone, -32000, "Cloud tab no longer names the selected chat"));
                }
                self.attached.insert(surface);
                if let Some(tab) = self.tabs.get_mut(&session) {
                    tab.summary = data["session"].clone();
                }
                Ok(answer(phone, if info { data["session"].clone() } else { data }))
            }
            Reply::Prepare { session, surface, command, kind } => {
                if self.surface_sessions.get(&surface) != Some(&session)
                    || data.pointer("/session/sessionId").and_then(Value::as_str) != Some(session.as_str())
                {
                    return Ok(error(phone, -32000, "Cloud tab no longer names the selected chat"));
                }
                self.attached.insert(surface);
                if matches!(kind, Simple::Prompt) && !phone_prompt_mode(&data["session"]) {
                    return Ok(error(
                        phone,
                        -32000,
                        "Cloud phone prompts require an asking agent mode and permission policy",
                    ));
                }
                Ok(self.call(command, phone, Reply::Simple { session, surface, kind }))
            }
            Reply::NewTree => {
                let Some(registry) =
                    data.get("registry_id").and_then(Value::as_str).filter(|r| !r.is_empty())
                else {
                    return Ok(error(phone, -32000, "Cloud machine did not name its workspace store"));
                };
                let registry = registry.to_owned();
                match chat_workspace(&data) {
                    Some(workspace) => Ok(self.new_tab(phone, &registry, workspace)),
                    None => Ok(self.call(
                        json!({"cmd":"create-workspace"}),
                        phone,
                        Reply::NewWorkspace { registry },
                    )),
                }
            }
            Reply::NewWorkspace { registry } => match data.get("workspace").and_then(Value::as_u64) {
                Some(workspace) => Ok(self.new_tab(phone, &registry, workspace)),
                None => Ok(error(phone, -32000, "Cloud machine did not make a workspace")),
            },
            Reply::NewTab => {
                let Some(surface) = data.get("surface").and_then(Value::as_u64) else {
                    return Ok(error(phone, -32000, "Cloud machine did not make the chat tab"));
                };
                // The machine's own acpmux starts the chat with policy `ask`, in a folder it
                // makes for it; the owner word lets it start on this owned machine at all.
                let start = json!({"cmd":"agent-session-start","surface":surface,
                    "harness":PHONE_START_HARNESS,"vm_kind":"owner"});
                Ok(self.call(start, phone, Reply::Start { surface }))
            }
            Reply::Start { surface } => {
                let Some(session) = data
                    .get("session")
                    .and_then(Value::as_str)
                    .filter(|s| !s.is_empty() && s.len() <= 160)
                else {
                    return Ok(error(phone, -32000, "Cloud machine did not start the chat"));
                };
                // The directory refuses a machine past MAX_SESSIONS chats; a start past it would
                // drop this channel at the next refresh, so it closes its tab instead.
                if self.tabs.len() >= MAX_SESSIONS && !self.tabs.contains_key(session) {
                    let mut out = error(phone, -32000, "Cloud machine has too many chats");
                    out.to_native.push(json!({"cmd":"close-surface","surface":surface}));
                    return Ok(out);
                }
                let summary = json!({"sessionId":session,"name":"","harness":PHONE_START_HARNESS,
                    "updatedAt":now_ms()});
                self.tabs.insert(session.to_owned(), Tab { surface, summary: summary.clone() });
                self.surface_sessions.insert(surface, session.to_owned());
                // The phone lists the chat now, before its next directory read.
                let listed = json!({"jsonrpc":"2.0","method":"_acpmux/session_changed",
                    "params":{"sessionId":session,"session":summary,"kind":"created"}});
                let mut out = answer(phone, json!({"sessionId":session}));
                out.to_phone.insert(0, listed);
                Ok(out)
            }
            Reply::Simple { session, surface, kind } => {
                if matches!(kind, Simple::Detach) {
                    self.attached.remove(&surface);
                }
                if matches!(kind, Simple::Prompt) {
                    // Native prompt replies only after durable prompt_accepted, not turn end.
                    let accepted = json!({"jsonrpc":"2.0","method":"_acpmux/prompt_accepted","params":{
                        "sessionId":session,"promptId":data["prompt_id"],"turnId":data["turn_id"],"queued":data["queued"]}});
                    let mut result = answer(phone, json!({}));
                    result.to_phone.insert(0, accepted);
                    Ok(result)
                } else {
                    Ok(answer(phone, data))
                }
            }
        }
    }

    fn event(&mut self, event: Value) -> Result<Effects, String> {
        let Some(surface) = event.get("surface").and_then(Value::as_u64) else {
            return Ok(Effects::default());
        };
        let Some(session) = self.surface_sessions.get(&surface) else {
            return Ok(Effects::default());
        };
        let (method, field) = match event.get("event").and_then(Value::as_str) {
            Some("agent-session-record") => ("_acpmux/event", "record"),
            Some("agent-session-permission") => ("_acpmux/permission_pending", "request"),
            Some("agent-session-changed") => ("_acpmux/session_changed", "change"),
            Some("agent-session-closed") => {
                self.attached.remove(&surface);
                return Ok(Effects {
                    to_phone: vec![json!({"jsonrpc":"2.0","method":"_acpmux/lagged","params":{}})],
                    ..Effects::default()
                });
            }
            _ => return Ok(Effects::default()),
        };
        let Some(params) = event.get(field) else {
            return Err("Invalid Cloud event".into());
        };
        let event_session =
            params.get("sessionId").or_else(|| params.pointer("/session/sessionId")).and_then(Value::as_str);
        if event_session != Some(session.as_str()) {
            return Ok(Effects::default());
        }
        Ok(Effects {
            to_phone: vec![json!({"jsonrpc":"2.0","method":method,"params":params})],
            ..Effects::default()
        })
    }

    /// The phone left: every start still waiting closes its empty tab, since no one will open it.
    pub(crate) fn abandon(&mut self) -> Effects {
        let mut out = Effects::default();
        for (_, pending) in self.pending.drain() {
            if let Reply::Start { surface } = pending.reply {
                out.to_native.push(json!({"cmd":"close-surface","surface":surface}));
            }
        }
        out
    }

    pub(crate) fn expire(&mut self) -> Effects {
        let now = Instant::now();
        let expired = self
            .pending
            .iter()
            .filter(|(_, p)| now.duration_since(p.at) >= p.deadline)
            .map(|(id, _)| *id)
            .collect::<Vec<_>>();
        let mut out = Effects::default();
        for id in expired {
            if let Some(pending) = self.pending.remove(&id) {
                out.to_phone.extend(error(pending.phone_id, -32000, "Cloud chat request timed out").to_phone);
                // A start that never answered leaves no empty chat tab behind either.
                if let Reply::Start { surface } = pending.reply {
                    out.to_native.push(json!({"cmd":"close-surface","surface":surface}));
                }
            }
        }
        out
    }
}

impl Adapter {
    fn new_tab(&mut self, phone: Option<Value>, registry: &str, workspace: u64) -> Effects {
        let tab = json!({"cmd":"new-conversation-tab","workspace":workspace,
            "agent_session":{"host":format!("registry:{registry}"),"harness":PHONE_START_HARNESS}});
        self.call(tab, phone, Reply::NewTab)
    }
}

/// Why a phone `session/new` is refused, if it is: it may carry only the ACP fields a client
/// always sends (`cwd` is ignored, `mcpServers` must be empty) and acpmux's `harness` and
/// `policy` when they name Claude and `ask`.
fn new_session_refusal(params: &Value) -> Option<&'static str> {
    let object = params.as_object()?;
    if object.keys().any(|key| !matches!(key.as_str(), "cwd" | "mcpServers" | "_meta")) {
        return Some("Cloud chats from a phone take no other options");
    }
    if object.get("mcpServers").is_some_and(|m| m.as_array().is_none_or(|m| !m.is_empty())) {
        return Some("Cloud chats from a phone take no MCP servers");
    }
    if object.get("_meta").is_some_and(|m| m.as_object().is_none_or(|m| m.keys().any(|k| k != "acpmux"))) {
        return Some("Cloud chats from a phone take no other options");
    }
    let acpmux = params.pointer("/_meta/acpmux");
    if acpmux.is_some_and(|a| {
        a.as_object().is_none_or(|a| a.keys().any(|k| !matches!(k.as_str(), "harness" | "policy")))
    }) {
        return Some("Cloud chats from a phone take no other options");
    }
    let harness = acpmux.and_then(|a| a.get("harness"));
    if harness.is_some_and(|h| h.as_str() != Some(PHONE_START_HARNESS)) {
        return Some("A phone starts Claude chats on a Cloud machine");
    }
    let policy = acpmux.and_then(|a| a.get("policy"));
    if policy.is_some_and(|p| p.as_str() != Some("ask")) {
        return Some("Cloud chats from a phone ask before acting");
    }
    None
}

/// The workspace a phone's new chat goes in: the active ordinary workspace (`kind` `normal`, or
/// none from an older daemon), else the first ordinary one; a home or app workspace is skipped.
fn chat_workspace(tree: &Value) -> Option<u64> {
    let ordinary = tree
        .get("workspaces")?
        .as_array()?
        .iter()
        .filter(|w| w.get("kind").is_none_or(|k| k.is_null() || k == "normal"))
        .collect::<Vec<_>>();
    ordinary
        .iter()
        .find(|w| w.get("active") == Some(&json!(true)))
        .or_else(|| ordinary.first())
        .and_then(|w| w.get("id")?.as_u64())
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
}

fn page_command(cmd: &str, surface: u64, params: &Value) -> Value {
    let mut out = json!({"cmd":cmd,"surface":surface});
    for (from, to) in
        [("afterSeq", "after_seq"), ("beforeSeq", "before_seq"), ("limit", "limit"), ("kinds", "kinds")]
    {
        if let Some(value) = params.get(from) {
            out[to] = value.clone();
        }
    }
    out
}

fn discover(data: &Value) -> Result<BTreeMap<String, Tab>, String> {
    let workspaces =
        data.get("workspaces").and_then(Value::as_array).ok_or("Cloud directory has no workspace list")?;
    let mut out = BTreeMap::<String, Tab>::new();
    for workspace in workspaces {
        for screen in workspace.get("screens").and_then(Value::as_array).into_iter().flatten() {
            for pane in screen.get("panes").and_then(Value::as_array).into_iter().flatten() {
                for tab in pane.get("tabs").and_then(Value::as_array).into_iter().flatten() {
                    let Some(surface) = tab.get("surface").and_then(Value::as_u64) else {
                        continue;
                    };
                    let Some(agent) = tab.pointer("/conversation/agent_session") else {
                        continue;
                    };
                    let Some(session) =
                        agent.get("session").and_then(Value::as_str).filter(|s| !s.is_empty())
                    else {
                        continue;
                    };
                    if session.len() > 160 {
                        return Err("Invalid Cloud session identity".into());
                    }
                    if out.len() >= MAX_SESSIONS && !out.contains_key(session) {
                        return Err("Cloud directory exceeds session limit".into());
                    }
                    let summary = json!({"sessionId":session,"name":tab.get("name").and_then(Value::as_str)
                        .or_else(|| tab.get("title").and_then(Value::as_str)).unwrap_or(session),
                        "harness":agent.get("harness").and_then(Value::as_str).unwrap_or("agent")});
                    // The same chat may have multiple tabs; choose one deterministically.
                    if out.get(session).is_none_or(|old| surface < old.surface) {
                        out.insert(session.into(), Tab { surface, summary });
                    }
                }
            }
        }
    }
    Ok(out)
}

// A fail-closed preflight, not the VM's authorization boundary: the VM must
// enforce the mobile restriction atomically at dispatch and throughout the turn.
// In particular a Codex mode name cannot establish which bridge profile runs.
fn phone_prompt_mode(session: &Value) -> bool {
    let family = session
        .get("family")
        .and_then(Value::as_str)
        .or_else(|| session.get("harness").and_then(Value::as_str));
    let mode = session.get("currentModeId").and_then(Value::as_str);
    matches!((family, mode), (Some("claude"), Some("default" | "plan")) | (Some("codex"), Some("ask")))
        && session.pointer("/enforcement/policy").and_then(Value::as_str) == Some("ask")
}

fn answer(id: Option<Value>, result: Value) -> Effects {
    Effects {
        to_phone: id.map(|id| json!({"jsonrpc":"2.0","id":id,"result":result})).into_iter().collect(),
        ..Effects::default()
    }
}

fn error(id: Option<Value>, code: i32, message: &str) -> Effects {
    Effects {
        to_phone: id
            .map(|id| json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}}))
            .into_iter()
            .collect(),
        ..Effects::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn adapter() -> Adapter {
        Adapter::new("vm_owner".into(), "team_owner".into())
    }
    fn phone(a: &mut Adapter, id: u64, method: &str, params: Value) -> Effects {
        a.phone(json!({"jsonrpc":"2.0","id":id,"method":method,"params":params})).unwrap()
    }
    fn respond(a: &mut Adapter, command: &Value, data: Value) -> Effects {
        a.native(json!({"id":command["id"],"ok":true,"data":data})).unwrap()
    }
    fn directory(a: &mut Adapter) {
        let asked = phone(a, 1, "_acpmux/watch", json!({"enabled":true}));
        assert_eq!(asked.to_native[0]["cmd"], "list-workspaces");
        let out = respond(
            a,
            &asked.to_native[0],
            json!({"workspaces":[{"screens":[{"panes":[{"tabs":[
                {"surface":7,"name":"Cloud chat","conversation":{"agent_session":{"session":"sess_a","harness":"claude"}}},
                {"surface":99,"kind":"pty","name":"not a chat"}
            ]}]}]}]}),
        );
        assert_eq!(out.to_phone[0]["result"]["sessions"].as_array().unwrap().len(), 1);
        assert_eq!(out.to_phone[0]["result"]["sessions"][0]["sessionId"], "sess_a");
    }

    #[test]
    fn native_history_and_live_records_keep_their_actual_sequence_and_shape() {
        let mut a = adapter();
        directory(&mut a);
        let asked = phone(
            &mut a,
            2,
            "_acpmux/attach",
            json!({"sessionId":"sess_a","afterSeq":41,"limit":50,"kinds":["transcript"],"eventStream":true}),
        );
        assert_eq!(asked.to_native[0]["cmd"], "agent-session-attach");
        assert_eq!(asked.to_native[0]["surface"], 7);
        assert_eq!(asked.to_native[0]["after_seq"], 41);
        assert!(asked.to_native[0].get("sessionId").is_none());
        let record = json!({"sessionId":"sess_a","seq":57,"at":1234,"dir":"in","kind":"session.update",
            "msg":{"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"actual answer"}}}}});
        let page = json!({"session":{"sessionId":"sess_a","name":"Cloud chat"},"events":[record],"hasMore":true});
        let reply = respond(&mut a, &asked.to_native[0], page.clone());
        assert_eq!(reply.to_phone[0]["result"], page);
        let live =
            a.native(json!({"event":"agent-session-record","surface":7,"record":record})).unwrap();
        assert_eq!(live.to_phone[0]["params"], record);
        assert_eq!(live.to_phone[0]["method"], "_acpmux/event");
        let other = a.native(json!({"event":"agent-session-record","surface":7,"record":{"sessionId":"sess_other","seq":58}})).unwrap();
        assert!(other.to_phone.is_empty());
    }

    #[test]
    fn prompt_attaches_then_answers_at_durable_acceptance_without_waiting_for_turn_end() {
        let mut a = adapter();
        directory(&mut a);
        let params = json!({"sessionId":"sess_a","prompt":[{"type":"text","text":"one"},{"type":"text","text":" two"}],
            "_meta":{"acpmux":{"promptId":"phone-unique-1","steer":false}}});
        let asked = phone(&mut a, 2, "session/prompt", params);
        assert_eq!(asked.to_native[0]["cmd"], "agent-session-attach");
        let ready = respond(
            &mut a,
            &asked.to_native[0],
            json!({"session":{"sessionId":"sess_a","harness":"claude","currentModeId":"default",
                "enforcement":{"policy":"ask"}},"events":[]}),
        );
        assert!(ready.to_phone.is_empty());
        assert_eq!(ready.to_native[0]["cmd"], "agent-session-prompt");
        assert_eq!(ready.to_native[0]["text"], "one two");
        assert_eq!(ready.to_native[0]["prompt_id"], "phone-unique-1");
        let accepted = respond(
            &mut a,
            &ready.to_native[0],
            json!({"prompt_id":"phone-unique-1","turn_id":"turn-9","queued":false}),
        );
        assert_eq!(accepted.to_phone[0]["method"], "_acpmux/prompt_accepted");
        assert_eq!(accepted.to_phone[1]["id"], 2);
        assert_eq!(accepted.to_phone[1]["result"], json!({}));
    }

    #[test]
    fn every_prompt_rechecks_mode_and_refuses_full_access_unknown_or_auto_approved_sessions() {
        for (family, mode, policy, allowed) in [
            ("claude", "default", "ask", true),
            ("claude", "plan", "ask", true),
            ("codex", "ask", "ask", true),
            ("claude", "bypassPermissions", "ask", false),
            ("claude", "acceptEdits", "ask", false),
            ("codex", "agent-full-access", "ask", false),
            ("codex", "agent", "ask", false),
            ("codex", "read-only", "ask", false),
            ("unknown", "default", "ask", false),
            ("claude", "default", "allow", false),
            ("claude", "", "ask", false),
        ] {
            let mut a = adapter();
            directory(&mut a);
            let attach = phone(&mut a, 2, "_acpmux/attach", json!({"sessionId":"sess_a"}));
            respond(
                &mut a,
                &attach.to_native[0],
                json!({"session":{"sessionId":"sess_a",
                "harness":"claude","currentModeId":"default","enforcement":{"policy":"ask"}}}),
            );
            let asked = phone(
                &mut a,
                3,
                "session/prompt",
                json!({"sessionId":"sess_a",
                "prompt":[{"type":"text","text":"hello"}],"_meta":{"acpmux":{"promptId":"stable"}}}),
            );
            assert_eq!(asked.to_native[0]["cmd"], "agent-session-attach");
            let result = respond(
                &mut a,
                &asked.to_native[0],
                json!({"session":{"sessionId":"sess_a",
                "family":family,"currentModeId":mode,"enforcement":{"policy":policy}}}),
            );
            assert_eq!(!result.to_native.is_empty(), allowed, "{family}/{mode}/{policy}");
            if !allowed {
                assert!(result.to_phone[0].get("error").is_some());
            }
        }
        assert!(!phone_prompt_mode(&json!({})));
        assert!(!phone_prompt_mode(&json!({"harness":"claude","currentModeId":"default"})));
    }

    #[test]
    fn cannot_route_unknown_session_or_native_commands_or_unsigned_approvals() {
        let mut a = adapter();
        directory(&mut a);
        for (method, params) in [
            ("_acpmux/attach", json!({"sessionId":"other","surface":7})),
            ("agent-session-trust", json!({"surface":7})),
            ("_acpmux/permission_respond", json!({"sessionId":"sess_a","optionId":"allow"})),
            ("session/prompt", json!({"sessionId":"sess_a","prompt":[{"type":"text","text":"hello"}]})),
        ] {
            let reply = phone(&mut a, 2, method, params);
            assert!(reply.to_native.is_empty());
            assert!(reply.to_phone[0].get("error").is_some());
            assert!(reply.to_phone[0].get("result").is_none());
        }
    }

    #[test]
    fn page_cursors_are_not_renumbered_and_rebound_tabs_cannot_prompt_another_chat() {
        let mut a = adapter();
        directory(&mut a);
        let request =
            phone(&mut a, 2, "_acpmux/events", json!({"sessionId":"sess_a","beforeSeq":818,"limit":9}));
        let ready =
            respond(&mut a, &request.to_native[0], json!({"session":{"sessionId":"sess_a"},"events":[]}));
        assert_eq!(ready.to_native[0]["cmd"], "agent-session-events");
        assert_eq!(ready.to_native[0]["before_seq"], 818);
        let result = respond(&mut a, &ready.to_native[0], json!({"events":[{"seq":801}],"hasMore":true}));
        assert_eq!(result.to_phone[0]["result"]["events"][0]["seq"], 801);
        let mut other = adapter();
        directory(&mut other);
        let request = phone(
            &mut other,
            2,
            "session/prompt",
            json!({"sessionId":"sess_a","prompt":[{"type":"text","text":"hello"}],"_meta":{"acpmux":{"promptId":"stable"}}}),
        );
        let rejected =
            respond(&mut other, &request.to_native[0], json!({"session":{"sessionId":"different"}}));
        assert!(rejected.to_native.is_empty());
        assert!(rejected.to_phone[0].get("error").is_some());
    }

    #[test]
    fn directory_refresh_detaches_stale_surfaces_and_refuses_inflight_old_pages() {
        let mut a = adapter();
        directory(&mut a);
        let attach = phone(&mut a, 2, "_acpmux/attach", json!({"sessionId":"sess_a"}));
        respond(&mut a, &attach.to_native[0], json!({"session":{"sessionId":"sess_a"}}));
        let stale = phone(&mut a, 3, "_acpmux/attach", json!({"sessionId":"sess_a"}));
        let refresh = phone(&mut a, 4, "_acpmux/sessions", json!({}));
        let removed = respond(&mut a, &refresh.to_native[0], json!({"workspaces":[]}));
        assert_eq!(removed.to_native, vec![json!({"cmd":"agent-session-detach","surface":7})]);
        assert!(!a.attached.contains(&7));
        let late = respond(&mut a, &stale.to_native[0], json!({"session":{"sessionId":"sess_a"}}));
        assert!(late.to_phone[0].get("error").is_some());
        assert!(!a.attached.contains(&7));
        let event = a
            .native(
                json!({"event":"agent-session-record","surface":7,"record":{"sessionId":"sess_a","seq":58}}),
            )
            .unwrap();
        assert!(event.to_phone.is_empty());
    }

    #[test]
    fn pending_requests_are_bounded_expire_and_ignore_late_replies() {
        let mut a = adapter();
        let first = phone(&mut a, 0, "_acpmux/sessions", json!({}));
        for id in 1..MAX_PENDING as u64 {
            assert_eq!(phone(&mut a, id, "_acpmux/sessions", json!({})).to_native.len(), 1);
        }
        assert!(phone(&mut a, 99, "_acpmux/sessions", json!({})).to_native.is_empty());
        for p in a.pending.values_mut() {
            p.at = Instant::now() - DEADLINE;
        }
        assert_eq!(a.expire().to_phone.len(), MAX_PENDING);
        assert!(respond(&mut a, &first.to_native[0], json!({"workspaces":[]})).to_phone.is_empty());
        assert_eq!(phone(&mut a, 100, "_acpmux/sessions", json!({})).to_native.len(), 1);
    }

    fn refuse(a: &mut Adapter, command: &Value, message: &str) -> Effects {
        a.native(json!({"id":command["id"],"ok":false,"error":message})).unwrap()
    }

    /// `session/new` in a machine that has workspaces: the tab goes in the active ordinary one.
    fn start_chat(a: &mut Adapter, id: u64) -> Value {
        let tree = phone(a, id, "session/new", json!({"cwd":"/","mcpServers":[],
            "_meta":{"acpmux":{"harness":"claude","policy":"ask"}}}));
        assert_eq!(tree.to_native[0]["cmd"], "list-workspaces");
        let tab = respond(a, &tree.to_native[0], json!({"registry_id":"reg-1","workspaces":[
            {"id":1,"kind":"home","active":false,"screens":[]},
            {"id":3,"kind":"app","active":false,"screens":[]},
            {"id":4,"kind":"normal","active":false,"screens":[]},
            {"id":5,"kind":"normal","active":true,"screens":[]}]}));
        assert_eq!(tab.to_native[0]["cmd"], "new-conversation-tab");
        assert_eq!(tab.to_native[0]["workspace"], 5);
        assert_eq!(tab.to_native[0]["agent_session"], json!({"host":"registry:reg-1","harness":"claude"}));
        let start = respond(a, &tab.to_native[0], json!({"surface":31}));
        start.to_native[0].clone()
    }

    #[test]
    fn a_phone_starts_a_claude_chat_in_the_machine_store_and_can_prompt_it() {
        let mut a = adapter();
        let start = start_chat(&mut a, 2);
        // No folder, model, policy or MCP server from the phone: the machine picks the folder and
        // starts with policy `ask`.
        assert_eq!(start, json!({"cmd":"agent-session-start","id":start["id"],"surface":31,
            "harness":"claude","vm_kind":"owner"}));
        assert_eq!(a.pending.values().next().unwrap().deadline, START_DEADLINE);
        let started =
            respond(&mut a, &start, json!({"surface":31,"session":"sess_new","conversation":"conv_1"}));
        assert_eq!(started.to_phone[0]["method"], "_acpmux/session_changed");
        assert_eq!(started.to_phone[0]["params"]["session"]["sessionId"], "sess_new");
        assert_eq!(started.to_phone[1], json!({"jsonrpc":"2.0","id":2,"result":{"sessionId":"sess_new"}}));
        // The new chat is in the directory before the next refresh, so the phone prompts it at once.
        let asked = phone(&mut a, 3, "session/prompt", json!({"sessionId":"sess_new",
            "prompt":[{"type":"text","text":"hi"}],"_meta":{"acpmux":{"promptId":"p-1"}}}));
        assert_eq!(asked.to_native[0]["cmd"], "agent-session-attach");
        assert_eq!(asked.to_native[0]["surface"], 31);
    }

    #[test]
    fn a_machine_with_no_ordinary_workspace_gets_one_for_the_chat() {
        let mut a = adapter();
        let tree = phone(&mut a, 2, "session/new", json!({}));
        let made = respond(&mut a, &tree.to_native[0],
            json!({"registry_id":"reg-1","workspaces":[{"id":1,"kind":"home","active":true}]}));
        assert_eq!(made.to_native[0]["cmd"], "create-workspace");
        let tab = respond(&mut a, &made.to_native[0], json!({"workspace":9,"key":"k"}));
        assert_eq!(tab.to_native[0]["cmd"], "new-conversation-tab");
        assert_eq!(tab.to_native[0]["workspace"], 9);
    }

    #[test]
    fn a_refused_start_closes_its_empty_tab_and_tells_the_phone() {
        let mut a = adapter();
        let start = start_chat(&mut a, 2);
        let refused = refuse(&mut a, &start, "agent_session.acpmux_unavailable");
        assert_eq!(refused.to_phone[0]["id"], 2);
        assert_eq!(refused.to_phone[0]["error"]["message"], "agent_session.acpmux_unavailable");
        assert_eq!(refused.to_native, vec![json!({"cmd":"close-surface","surface":31})]);
        assert!(a.surface_sessions.is_empty());
    }

    #[test]
    fn a_phone_start_names_no_other_agent_policy_server_or_option() {
        let mut a = adapter();
        for params in [
            json!({"_meta":{"acpmux":{"harness":"codex"}}}),
            json!({"_meta":{"acpmux":{"policy":"auto"}}}),
            json!({"mcpServers":[{"name":"x","command":"sh"}]}),
            json!({"mcpServers":"sh"}),
            json!({"model":"opus"}),
            json!({"_meta":{"acpmux":{"harness":"claude","model":"opus"}}}),
            json!({"_meta":{"acpmux":{"mode":"bypassPermissions"}}}),
            json!({"_meta":{"acpmux":{"harness":7}}}),
            json!({"_meta":{"acpmux":"claude"}}),
            json!({"_meta":{"other":{}}}),
        ] {
            let out = phone(&mut a, 2, "session/new", params.clone());
            assert!(out.to_native.is_empty(), "{params}");
            assert_eq!(out.to_phone[0]["error"]["code"], -32602, "{params}");
        }
    }

    #[test]
    fn a_start_that_times_out_closes_its_empty_tab() {
        let mut a = adapter();
        start_chat(&mut a, 2);
        for p in a.pending.values_mut() {
            p.at = Instant::now() - START_DEADLINE;
        }
        let out = a.expire();
        assert_eq!(out.to_phone[0]["id"], 2);
        assert_eq!(out.to_native, vec![json!({"cmd":"close-surface","surface":31})]);
    }

    #[test]
    fn a_start_past_the_session_cap_closes_its_tab_instead_of_listing_it() {
        let mut a = adapter();
        let start = start_chat(&mut a, 2);
        for n in 0..MAX_SESSIONS {
            a.tabs.insert(format!("s-{n}"), Tab { surface: 1000 + n as u64, summary: json!({}) });
        }
        let out = respond(&mut a, &start, json!({"session":"new-chat"}));
        assert_eq!(out.to_phone[0]["id"], 2);
        assert_eq!(out.to_phone[0]["error"]["message"], "Cloud machine has too many chats");
        assert_eq!(out.to_native, vec![json!({"cmd":"close-surface","surface":31})]);
        assert_eq!(a.tabs.len(), MAX_SESSIONS);
        assert!(!a.surface_sessions.contains_key(&31));
    }

    #[test]
    fn a_phone_that_leaves_mid_start_closes_its_empty_tab() {
        let mut a = adapter();
        start_chat(&mut a, 2);
        let out = a.abandon();
        assert!(out.to_phone.is_empty());
        assert_eq!(out.to_native, vec![json!({"cmd":"close-surface","surface":31})]);
        assert!(a.pending.is_empty());
        // Nothing else was waiting: nothing to close.
        assert!(a.abandon().to_native.is_empty());
    }
}
