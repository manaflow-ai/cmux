//! The phone's ACP channel over one already authenticated Cloud daemon carrier.
//! Native surface ids never come from the phone. Discovery binds them to the
//! VM's stored agent tabs; pages and records retain their original ACP sequence
//! numbers. This adapter grants no approval, mode, filesystem or process API.

use serde_json::{Value, json};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::time::{Duration, Instant};

const MAX_PENDING: usize = 32;
const MAX_SESSIONS: usize = 1024;
const DEADLINE: Duration = Duration::from_secs(15);

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
        self.next += 1;
        command["id"] = json!(self.next);
        self.pending.insert(self.next, Pending { phone_id, reply, at: Instant::now() });
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
            return Ok(error(pending.phone_id, -32000, message));
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

    pub(crate) fn expire(&mut self) -> Effects {
        let now = Instant::now();
        let expired = self
            .pending
            .iter()
            .filter(|(_, p)| now.duration_since(p.at) >= DEADLINE)
            .map(|(id, _)| *id)
            .collect::<Vec<_>>();
        let mut out = Effects::default();
        for id in expired {
            if let Some(pending) = self.pending.remove(&id) {
                out.to_phone.extend(error(pending.phone_id, -32000, "Cloud chat request timed out").to_phone);
            }
        }
        out
    }
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
}
