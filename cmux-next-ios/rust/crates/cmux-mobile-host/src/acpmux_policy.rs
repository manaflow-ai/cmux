//! The `acpmux` service's one narrowing on top of acpmux's own remote guard:
//! an agent a phone drives runs only in a mode that asks before each change.
//!
//! acpmux holds a remote (Web) connection to its reviewed asking modes, except
//! on the Codex bridge, where an authenticated Web connection may pick any
//! mode (acpmux `web_modes::any_mode_for_web`). A phone-started Codex chat
//! starts in the bridge's `ask` mode (acpmux `settle_web_session_mode`); this
//! filter keeps the phone from moving it, or any chat, to a mode that skips
//! asking (`agent`, `agent-full-access`, `acceptEdits`, `bypassPermissions`).
//! Every tool approval then reaches the person, and an Allow needs the
//! phone's Face ID signature.

use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};

use crate::control::SessionExposure;

/// The modes a phone may switch an agent to: Claude Code's `default` and
/// `plan`, the Codex bridge's `ask` (acpmux `ASKING_MODES`,
/// `BRIDGE_ASKING_MODES`). acpmux still checks each against the session's
/// family.
pub const PHONE_MODES: &[&str] = &["default", "plan", "ask"];

const GLOBAL_METHODS: &[&str] = &[
    "initialize",
    "session/new",
    "acp.session.new",
    "session/list",
    "acp.session.list",
    "_acpmux/status",
    "_acpmux/sessions",
    "_acpmux/watch",
];

/// Catalog queries are global when they do not ask about an existing chat.
/// Requests that carry a target still pass through canonical session checks.
pub(crate) fn global_request(request: &Value) -> bool {
    let Some(method) = request.get("method").and_then(Value::as_str) else { return false };
    (GLOBAL_METHODS.contains(&method) || matches!(method, "_acpmux/harnesses" | "_acpmux/models"))
        && !["sessionId", "session", "name"]
            .iter()
            .any(|key| request.get("params").and_then(|params| params.get(*key)).is_some())
}

/// The JSON-RPC error a phone gets for a refused message (code -32602,
/// `data.reason` `phone.mode_not_asking`), or None to forward it. A batch is
/// judged as a whole.
pub fn refusal(message: &str) -> Option<String> {
    let value: Value = serde_json::from_str(message).ok()?;
    let requests = match &value {
        Value::Array(items) => items.iter().collect::<Vec<_>>(),
        other => vec![other],
    };
    let bad = requests.iter().find(|r| !asks(r))?;
    Some(
        json!({
            "jsonrpc": "2.0",
            "id": bad.get("id").cloned().unwrap_or(Value::Null),
            "error": {
                "code": -32602,
                "message": "From iPhone, an agent runs only in a mode that asks before each change",
                "data": {"reason": "phone.mode_not_asking"},
            },
        })
        .to_string(),
    )
}

/// Config options a phone may set to any value: they choose a model or how hard
/// it thinks (acpmux `FREE_CONFIG_IDS`). `mode` is held to `PHONE_MODES`; any other
/// option (one that could carry an approval or sandbox setting) is refused.
pub const FREE_CONFIG_IDS: &[&str] = &["model", "effort", "reasoning_effort", "thought_level", "thinking"];

/// Methods that prompt a chat named only indirectly, so this filter cannot read its mode:
/// `_acpmux/steer` names a brief, and acpmux turns it into a `session/prompt` to the brief's
/// chat (`server/requests/briefs.rs`). The iPhone app never sends one; it is held to the
/// Full-access rule (refused here, or marked on a phone's own credential).
pub const INDIRECT_PROMPT_METHODS: &[&str] = &["_acpmux/steer"];

/// Whether one request keeps its agent asking: a mode set names a phone mode, a
/// config set names a free option or the mode, and no request prompts a chat this
/// filter cannot check.
fn asks(request: &Value) -> bool {
    let params = request.get("params");
    let field = |k: &str| params.and_then(|p| p.get(k));
    match request.get("method").and_then(Value::as_str) {
        Some(m) if INDIRECT_PROMPT_METHODS.contains(&m) => false,
        Some("session/set_mode") => mode_ok(field("modeId")),
        Some("session/set_config_option") => match field("configId").and_then(Value::as_str) {
            Some("mode") => mode_ok(field("value")),
            Some(id) => FREE_CONFIG_IDS.contains(&id),
            None => false,
        },
        _ => true,
    }
}

/// Methods that make an existing session act for the phone (or copy it): the
/// session's CURRENT mode must ask too. acpmux lets an authenticated remote
/// connection drive a Codex bridge session in any mode, so a session the Mac
/// started in `agent` or `agent-full-access` would run a phone's prompt without
/// asking. Answering a pending permission is not here: that is the asking.
pub const SESSION_CONTROL_METHODS: &[&str] = &[
    "session/prompt",
    "_acpmux/retry",
    "session/fork",
    "acp.session.fork",
    "session/load",
    "session/resume",
    "_acpmux/queue_edit",
    "_acpmux/handoff_prepare",
    "_acpmux/handoff_start",
];

/// The session a control request acts on (`sessionId`), for the mode check.
pub fn controlled_session(message: &str) -> Option<(Value, String)> {
    let value: Value = serde_json::from_str(message).ok()?;
    let method = value.get("method").and_then(Value::as_str)?;
    if !SESSION_CONTROL_METHODS.contains(&method) {
        return None;
    }
    // acpmux's own key order (`server::session_key`): sessionId, then session, then name.
    let params = value.get("params")?;
    let session = ["sessionId", "session", "name"]
        .iter()
        .find_map(|k| params.get(*k).and_then(Value::as_str))?
        .to_owned();
    Some((value.get("id").cloned().unwrap_or(Value::Null), session))
}

fn request_session(request: &Value) -> Option<String> {
    let params = request.get("params")?;
    let values = ["sessionId", "session", "name"]
        .iter()
        .filter_map(|key| params.get(*key).and_then(Value::as_str))
        .collect::<Vec<_>>();
    if values.windows(2).any(|pair| pair[0] != pair[1]) {
        return None;
    }
    values.first().map(|value| (*value).to_owned())
}

/// Every request id and target session in a JSON-RPC message, including batch
/// items. The service uses this to bind responses and revoke a live link.
pub fn request_targets(message: &str) -> Vec<(String, String)> {
    let Ok(value) = serde_json::from_str::<Value>(message) else { return Vec::new() };
    let requests = match &value {
        Value::Array(items) => items.iter().collect::<Vec<_>>(),
        other => vec![other],
    };
    requests
        .into_iter()
        .filter_map(|request| {
            let id = request.get("id")?.to_string();
            Some((id, request_session(request)?))
        })
        .collect()
}

pub fn response_id(message: &str) -> Option<String> {
    serde_json::from_str::<Value>(message).ok()?.get("id").map(Value::to_string)
}

pub fn response_ids(message: &str) -> Vec<String> {
    let Ok(value) = serde_json::from_str::<Value>(message) else { return Vec::new() };
    match value {
        Value::Array(items) => items.iter().filter_map(|v| v.get("id").map(Value::to_string)).collect(),
        value => value.get("id").map(Value::to_string).into_iter().collect(),
    }
}

fn exposure_error(id: Value, reason: &str) -> String {
    json!({"jsonrpc":"2.0", "id": id, "error": {"code": -32602,
        "message": "This chat is not exposed to iPhone Remote Control",
        "data": {"reason": reason}}})
    .to_string()
}

fn allowed(state: &SessionExposure, session: &str, _bound: &HashSet<String>) -> bool {
    if !state.available {
        return false;
    }
    if state.blocked.contains(session) {
        return false;
    }
    // The acpmux resolver accepts aliases (`name` and short IDs). Until a
    // trusted response binds a canonical ID, reject short aliases under a
    // configured policy rather than guessing which chat they denote.
    if state.configured && uuid::Uuid::parse_str(session).is_err() && !_bound.contains(session) {
        return false;
    }
    // `bound` carries the successful result of session/new for this live link.
    // Missing sessions inherit the Mac-wide setting until explicitly revoked.
    true
}

/// Refuse a request that is not explicitly global or that names a blocked chat.
/// This runs before Full Access marking; credentials never bypass exposure.
pub fn exposure_refusal(message: &str, state: &SessionExposure, bound: &HashSet<String>) -> Option<String> {
    exposure_refusal_with_replies(message, state, bound, &HashMap::new())
}

/// As [`exposure_refusal`], while accepting method-less JSON-RPC replies to
/// requests the server already issued on this link (approval answers).
pub fn exposure_refusal_with_replies(
    message: &str,
    state: &SessionExposure,
    bound: &HashSet<String>,
    replies: &HashMap<String, String>,
) -> Option<String> {
    let value: Value = match serde_json::from_str(message) {
        Ok(value) => value,
        Err(_) => return Some(exposure_error(Value::Null, "remote_control.invalid_json")),
    };
    let requests = match &value {
        Value::Array(items) => items.iter().collect::<Vec<_>>(),
        other => vec![other],
    };
    for request in requests {
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let Some(_method) = request.get("method").and_then(Value::as_str) else {
            if let Some(session) = replies.get(&id.to_string()) {
                if !allowed(state, session, bound) {
                    return Some(exposure_error(id, "remote_control.session_not_exposed"));
                }
                continue;
            }
            return Some(exposure_error(id, "remote_control.invalid_request"));
        };
        if global_request(request) {
            continue;
        }
        let Some(session) = request_session(request) else {
            return Some(exposure_error(id, "remote_control.session_required"));
        };
        if !allowed(state, &session, bound) {
            return Some(exposure_error(id, "remote_control.session_not_exposed"));
        }
    }
    None
}

/// Record session IDs returned by `session/new` so the live link retains the
/// newly-created chat even when the server response contains no other fields.
pub fn returned_session_id(message: &str) -> Option<String> {
    let value: Value = serde_json::from_str(message).ok()?;
    value.get("result")?.get("sessionId").and_then(Value::as_str).map(str::to_owned)
}

pub fn returned_sessions(message: &str) -> Vec<(String, String)> {
    let Ok(value) = serde_json::from_str::<Value>(message) else { return Vec::new() };
    let replies = match &value {
        Value::Array(items) => items.iter().collect::<Vec<_>>(),
        other => vec![other],
    };
    replies
        .into_iter()
        .filter_map(|reply| {
            Some((reply.get("id")?.to_string(), reply.get("result")?.get("sessionId")?.as_str()?.to_owned()))
        })
        .collect()
}

fn contains_blocked_session(value: &Value, state: &SessionExposure, bound: &HashSet<String>) -> bool {
    match value {
        Value::Object(object) => object.iter().any(|(key, value)| {
            if matches!(key.as_str(), "sessionId" | "session" | "agent_session")
                && let Some(id) = value.as_str()
            {
                return !allowed(state, id, bound);
            }
            // A recognized key can hold a wrapper object. Its nested sessionId
            // is still authority-bearing; matching the outer key never stops traversal.
            contains_blocked_session(value, state, bound)
        }),
        Value::Array(values) => values.iter().any(|value| contains_blocked_session(value, state, bound)),
        _ => false,
    }
}

/// Filter a server reply/notification. Session-list rows are removed one by
/// one; an opaque reply naming a blocked session is dropped fail closed.
pub fn filter_response(message: &str, state: &SessionExposure, bound: &HashSet<String>) -> Option<String> {
    if !state.available {
        return None;
    }
    if !state.configured {
        return Some(message.to_owned());
    }
    let mut value: Value = serde_json::from_str(message).ok()?;
    fn filter_lists(value: &mut Value, state: &SessionExposure, bound: &HashSet<String>) {
        match value {
            Value::Object(object) => {
                if let Some(Value::Array(rows)) = object.get_mut("sessions") {
                    rows.retain(|row| !contains_blocked_session(row, state, bound));
                }
                for child in object.values_mut() {
                    filter_lists(child, state, bound);
                }
            }
            Value::Array(items) => {
                for item in items {
                    filter_lists(item, state, bound);
                }
            }
            _ => {}
        }
    }
    filter_lists(&mut value, state, bound);
    if contains_blocked_session(&value, state, bound) {
        return None;
    }
    Some(value.to_string())
}

fn daemon_chat_blocked(value: &Value, state: &SessionExposure, trusted_response: bool) -> bool {
    // Phone-supplied conversation aliases require canonical authorization;
    // trusted daemon rows already name their actual chat, including valid
    // short IDs. Bare daemon `session`/`session_id` fields instead name a
    // terminal registry or source label and must remain untouched.
    [
        "/agent_session",
        "/conversation/agent_session",
        "/extra/conversation/agent_session",
    ]
    .iter()
    .any(|path| {
        value
            .pointer(path)
            .and_then(|agent| agent.as_str().or_else(|| agent.get("session").and_then(Value::as_str)))
            .is_some_and(|id| {
                if trusted_response { state.blocked.contains(id) } else { !allowed(state, id, &HashSet::new()) }
            })
    })
        // Terminal hooks use native harness IDs, not acpmux aliases. The
        // daemon compares expect_agent.session exactly; a short native ID
        // must keep working when an unrelated chat's exposure changes.
        || ["/agent_session_id", "/extra/agent_session_id", "/expect_agent/session"].iter().any(|path| {
            value.pointer(path).and_then(Value::as_str).is_some_and(|id| state.blocked.contains(id))
        })
}

/// Remove daemon rows with a blocked agent identity, preserving unrelated
/// terminal rows and their daemon/registry `session` fields.
pub fn filter_daemon_response(message: &str, state: &SessionExposure) -> Option<String> {
    if !state.available {
        return None;
    }
    if !state.configured {
        return Some(message.to_owned());
    }
    let mut value: Value = serde_json::from_str(message).ok()?;
    fn clean(value: &mut Value, state: &SessionExposure) {
        if daemon_chat_blocked(value, state, true) {
            *value = Value::Null;
            return;
        }
        match value {
            Value::Object(object) => {
                for rows in object.values_mut() {
                    clean(rows, state);
                }
            }
            Value::Array(items) => {
                for item in items.iter_mut() {
                    clean(item, state);
                }
                items.retain(|item| !item.is_null());
            }
            _ => {}
        }
    }
    clean(&mut value, state);
    Some(value.to_string())
}

pub fn daemon_request_blocked(message: &str, state: &SessionExposure) -> bool {
    if !state.available {
        return true;
    }
    state.configured
        && serde_json::from_str::<Value>(message)
            .ok()
            .is_some_and(|value| daemon_chat_blocked(&value, state, false))
}

/// The refusal for a control request on a session whose current mode (acpmux
/// `_acpmux/info` `currentModeId`) does not ask; None when it asks or is unknown
/// (acpmux's own guard decides then).
pub fn mode_refusal(id: &Value, current_mode: Option<&str>) -> Option<String> {
    let mode = current_mode?;
    if PHONE_MODES.contains(&mode) {
        return None;
    }
    Some(
        json!({
            "jsonrpc": "2.0",
            "id": id,
            "error": {
                "code": -32602,
                "message": format!("This chat runs in a mode that doesn't ask before each change ({mode}). Switch it to a mode that asks on the Mac to use it from your iPhone."),
                "data": {"reason": "phone.mode_not_asking", "mode": mode},
            },
        })
        .to_string(),
    )
}

/// `message` with every request marked `_meta.acpmux.requireFullAccess` (acpmux
/// `server/remote_guard.rs`): what this filter refuses, sent on a phone's own acpmux
/// credential, which acpmux runs only when that phone's Full-access setting (set on the
/// Mac, off by default) covers it. None when a request has no params object to mark: it
/// is refused here then.
pub fn marked(message: &str) -> Option<String> {
    let mut value: Value = serde_json::from_str(message).ok()?;
    let requests: Vec<&mut Value> = match &mut value {
        Value::Array(items) => items.iter_mut().collect(),
        other => vec![other],
    };
    for request in requests {
        if request.get("method").is_none() {
            continue;
        }
        let meta = request.get_mut("params")?.as_object_mut()?.entry("_meta").or_insert_with(|| json!({}));
        let acpmux = meta.as_object_mut()?.entry("acpmux").or_insert_with(|| json!({}));
        acpmux.as_object_mut()?.insert("requireFullAccess".into(), Value::Bool(true));
    }
    Some(value.to_string())
}

fn mode_ok(mode: Option<&Value>) -> bool {
    mode.and_then(Value::as_str).is_some_and(|m| PHONE_MODES.contains(&m))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn exposure(blocked: &[&str]) -> SessionExposure {
        SessionExposure {
            available: true,
            configured: true,
            allowed: HashSet::new(),
            blocked: blocked.iter().map(|id| (*id).to_owned()).collect(),
        }
    }

    fn set_mode(mode: &str) -> String {
        json!({"jsonrpc": "2.0", "id": 7, "method": "session/set_mode", "params": {"sessionId": "s", "modeId": mode}})
            .to_string()
    }

    #[test]
    fn a_phone_switches_agents_only_to_asking_modes() {
        for mode in PHONE_MODES {
            assert_eq!(refusal(&set_mode(mode)), None, "{mode}");
        }
        for mode in [
            "agent",
            "agent-full-access",
            "read-only",
            "acceptEdits",
            "bypassPermissions",
            "dontAsk",
            "auto",
            "build",
        ] {
            let answer: Value = serde_json::from_str(&refusal(&set_mode(mode)).expect(mode)).unwrap();
            assert_eq!(answer["id"], 7);
            assert_eq!(answer["error"]["data"]["reason"], "phone.mode_not_asking");
        }
    }

    #[test]
    fn the_mode_config_option_is_held_to_the_same_rule() {
        let set = |id: &str, value: &str| {
            json!({"jsonrpc": "2.0", "id": 1, "method": "session/set_config_option",
                   "params": {"sessionId": "s", "configId": id, "value": value}})
            .to_string()
        };
        assert_eq!(refusal(&set("mode", "ask")), None);
        assert!(refusal(&set("mode", "agent-full-access")).is_some());
        // Model and effort choose how it thinks, never what runs without asking.
        assert_eq!(refusal(&set("model", "gpt-5.5")), None);
        assert_eq!(refusal(&set("effort", "high")), None);
        // A missing or non-string mode is refused, not forwarded.
        let missing =
            json!({"jsonrpc": "2.0", "id": 2, "method": "session/set_mode", "params": {"sessionId": "s"}});
        assert!(refusal(&missing.to_string()).is_some());
    }

    #[test]
    fn other_config_options_are_refused() {
        let set = |id: &str| {
            json!({"jsonrpc": "2.0", "id": 1, "method": "session/set_config_option",
                   "params": {"sessionId": "s", "configId": id, "value": "x"}})
            .to_string()
        };
        for id in ["approval_policy", "sandbox", "approvalPolicy", "fast-mode"] {
            assert!(refusal(&set(id)).is_some(), "{id}");
        }
        let no_id = json!({"jsonrpc": "2.0", "id": 1, "method": "session/set_config_option", "params": {"sessionId": "s", "value": "x"}});
        assert!(refusal(&no_id.to_string()).is_some());
    }

    #[test]
    fn wrapped_chat_ids_and_legacy_daemon_rows_cannot_bypass_exposure() {
        let hidden = "00000000-0000-7000-8000-000000000001";
        let state = exposure(&[hidden]);
        for reply in [
            json!({"session":{"sessionId":hidden,"text":"private"}}),
            json!({"agent_session":{"sessionId":hidden,"text":"private"}}),
        ] {
            assert!(filter_response(&reply.to_string(), &state, &HashSet::new()).is_none());
        }
        for row in [
            json!({"agent_session":hidden,"title":"private"}),
            json!({"extra":{"conversation":{"agent_session":{"session":hidden}}},"title":"private"}),
        ] {
            let reply = json!({"data":{"tabs":[row,{"title":"terminal"}]}}).to_string();
            let filtered: Value =
                serde_json::from_str(&filter_daemon_response(&reply, &state).unwrap()).unwrap();
            assert_eq!(filtered["data"]["tabs"], json!([{"title":"terminal"}]));
        }
        assert!(daemon_request_blocked(&json!({"agent_session":hidden}).to_string(), &state));
    }

    #[test]
    fn catalog_queries_are_global_but_targeted_queries_are_checked() {
        for state in [SessionExposure::default(), exposure(&["00000000-0000-7000-8000-000000000001"])] {
            for method in GLOBAL_METHODS.iter().chain(["_acpmux/harnesses", "_acpmux/models"].iter()) {
                let global = json!({"id":1,"method":method,"params":{}}).to_string();
                assert!(exposure_refusal(&global, &state, &HashSet::new()).is_none());
                if state.configured {
                    for key in ["sessionId", "session", "name"] {
                        let targeted = json!({"id":2,"method":method,"params":{key:"00000000-0000-7000-8000-000000000001"}});
                        assert!(!global_request(&targeted));
                        assert!(exposure_refusal(&targeted.to_string(), &state, &HashSet::new()).is_some());
                        let malformed = json!({"id":3,"method":method,"params":{key:null}});
                        assert!(!global_request(&malformed));
                    }
                }
            }
        }
    }

    #[test]
    fn daemon_nested_projection_keeps_other_tabs_and_terminal_identity() {
        let blocked = "00000000-0000-7000-8000-000000000001";
        let visible = "sess-a";
        let state = exposure(&[blocked, "sess-blocked"]);
        let message = json!({"id":1,"data":{"session":"main","workspaces":[{"tabs":[
            {"id":"hidden","agent_session":{"session":blocked}},
            {"id":"short-hidden","extra":{"conversation":{"agent_session":{"session":"sess-blocked"}}}},
            {"id":"visible","agent_session":{"session":visible}},
            {"id":"terminal"}
        ]}]}})
        .to_string();
        let filtered: Value =
            serde_json::from_str(&filter_daemon_response(&message, &state).unwrap()).unwrap();
        assert_eq!(filtered["data"]["session"], "main");
        let tabs = filtered.pointer("/data/workspaces/0/tabs").unwrap().as_array().unwrap();
        assert_eq!(tabs.len(), 2);
        assert_eq!(tabs[0]["id"], "visible");
        assert_eq!(tabs[1]["id"], "terminal");
        let singleton = json!({"agent_session":{"session":blocked}}).to_string();
        assert_eq!(filter_daemon_response(&singleton, &state).as_deref(), Some("null"));
        let alias = json!({"cmd":"new-conversation-tab","agent_session":{"session":"alias"}}).to_string();
        assert!(daemon_request_blocked(&alias, &state));
    }

    #[test]
    fn daemon_agent_rosters_events_and_projections_hide_blocked_agents() {
        let blocked = "00000000-0000-7000-8000-000000000001";
        let visible = "0b6c3f8e";
        let state = exposure(&[blocked]);
        for (key, hidden, shown) in [
            (
                "agents",
                json!({"surface":7,"state":"idle","agent_session_id":blocked,"last_prompt":"private"}),
                json!({"surface":8,"state":"idle","agent_session_id":visible}),
            ),
            (
                "agents",
                json!({"id":"hidden","extra":{"agent_session_id":blocked},"state":"idle"}),
                json!({"id":"visible","extra":{"agent_session_id":visible},"state":"idle"}),
            ),
        ] {
            let terminal = json!({"id":"terminal","session":blocked,"session_id":"main"});
            let message = json!({"id":1,"data":{key:[hidden,shown.clone(),terminal.clone()]}});
            let filtered: Value =
                serde_json::from_str(&filter_daemon_response(&message.to_string(), &state).unwrap()).unwrap();
            assert_eq!(filtered["data"][key], json!([shown, terminal]));
        }
        let event = json!({"event":"agent-changed","surface":7,"agent_session_id":blocked,
                           "state":"idle","last_prompt":"private"});
        assert_eq!(filter_daemon_response(&event.to_string(), &state).as_deref(), Some("null"));
    }

    #[test]
    fn daemon_expected_agent_is_checked_independently_of_terminal_session() {
        let blocked = "00000000-0000-7000-8000-000000000001";
        let visible = "0b6c3f8e";
        let state = exposure(&[blocked]);
        let request = json!({"id":1,"cmd":"send","surface":7,"text":"private",
                             "expect_agent":{"session":blocked},"submit":true});
        assert!(daemon_request_blocked(&request.to_string(), &state));
        let visible_request = json!({"id":2,"cmd":"send","surface":8,"text":"hello",
                                     "expect_agent":{"session":visible},"submit":true});
        assert!(!daemon_request_blocked(&visible_request.to_string(), &state));
        let terminal = json!({"id":3,"cmd":"send","surface":9,"session":blocked,"text":"ls"});
        assert!(!daemon_request_blocked(&terminal.to_string(), &state));
    }

    #[test]
    fn exposure_keeps_unmentioned_chats_and_rejects_blocked_batches() {
        let state = exposure(&["00000000-0000-7000-8000-000000000001"]);
        let visible = r#"{"jsonrpc":"2.0","id":1,"method":"session/prompt","params":{"sessionId":"00000000-0000-7000-8000-000000000002"}}"#;
        assert_eq!(exposure_refusal(visible, &state, &HashSet::new()), None);
        let batch = format!(
            "[{visible},{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{{\"sessionId\":\"00000000-0000-7000-8000-000000000001\"}}}}]"
        );
        assert!(exposure_refusal(&batch, &state, &HashSet::new()).is_some());
    }

    #[test]
    fn nested_lists_are_filtered_and_binary_is_not_used_as_json() {
        let state = exposure(&["00000000-0000-7000-8000-000000000001"]);
        let reply = r#"{"jsonrpc":"2.0","id":1,"result":{"data":{"sessions":[{"sessionId":"00000000-0000-7000-8000-000000000002"},{"sessionId":"00000000-0000-7000-8000-000000000001"}]}}}"#;
        let filtered = filter_response(reply, &state, &HashSet::new()).unwrap();
        assert!(filtered.contains("00000000-0000-7000-8000-000000000002"));
        assert!(!filtered.contains("00000000-0000-7000-8000-000000000001"));
        assert!(filter_response("not-json", &state, &HashSet::new()).is_none());
    }

    #[test]
    fn server_approval_replies_are_allowed_only_when_correlated() {
        let state = exposure(&[]);
        let answer = r#"{"jsonrpc":"2.0","id":"approval-1","result":{"approved":true}}"#;
        assert!(exposure_refusal(answer, &state, &HashSet::new()).is_some());
        let mut replies = HashMap::new();
        replies.insert("\"approval-1\"".into(), "00000000-0000-7000-8000-000000000002".into());
        assert_eq!(exposure_refusal_with_replies(answer, &state, &HashSet::new(), &replies), None);
    }

    #[test]
    fn aliases_and_conflicting_target_keys_fail_closed() {
        let state = exposure(&["00000000-0000-7000-8000-000000000001"]);
        let alias = json!({"jsonrpc":"2.0","id":1,"method":"session/prompt","params":{"sessionId":"short"}})
            .to_string();
        assert!(exposure_refusal(&alias, &state, &HashSet::new()).is_some());
        let conflicting = json!({"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"00000000-0000-7000-8000-000000000002","name":"00000000-0000-7000-8000-000000000001"}}).to_string();
        assert!(exposure_refusal(&conflicting, &state, &HashSet::new()).is_some());
    }

    #[test]
    fn session_new_batch_response_binds_each_returned_chat() {
        let reply = r#"[{"jsonrpc":"2.0","id":1,"result":{"sessionId":"00000000-0000-7000-8000-000000000003"}},{"jsonrpc":"2.0","id":2,"result":{"sessionId":"00000000-0000-7000-8000-000000000004"}}]"#;
        let mut sessions = returned_sessions(reply);
        sessions.sort();
        assert_eq!(
            sessions,
            vec![
                ("1".into(), "00000000-0000-7000-8000-000000000003".into()),
                ("2".into(), "00000000-0000-7000-8000-000000000004".into())
            ]
        );
    }

    /// A Mac-started Codex chat in `agent` (no asking) is not driven from a phone.
    #[test]
    fn control_of_a_session_needs_its_current_mode_to_ask() {
        let prompt = json!({"jsonrpc": "2.0", "id": 9, "method": "session/prompt", "params": {"sessionId": "s1", "prompt": []}});
        let (id, session) = controlled_session(&prompt.to_string()).unwrap();
        assert_eq!((id.clone(), session.as_str()), (json!(9), "s1"));
        let answer: Value = serde_json::from_str(&mode_refusal(&id, Some("agent")).unwrap()).unwrap();
        assert_eq!(answer["id"], 9);
        assert_eq!(answer["error"]["data"]["reason"], "phone.mode_not_asking");
        assert!(mode_refusal(&id, Some("agent-full-access")).is_some());
        assert!(mode_refusal(&id, Some("bypassPermissions")).is_some());
        assert_eq!(mode_refusal(&id, Some("ask")), None);
        assert_eq!(mode_refusal(&id, Some("default")), None);
        assert_eq!(mode_refusal(&id, None), None);
        // acpmux also takes the session as `session` or `name`.
        for key in ["session", "name"] {
            let r = json!({"jsonrpc": "2.0", "id": 4, "method": "session/prompt", "params": {key: "s2", "prompt": []}});
            assert_eq!(controlled_session(&r.to_string()).map(|(_, s)| s).as_deref(), Some("s2"), "{key}");
        }
        // Answering a pending permission is the asking itself.
        let answer = json!({"jsonrpc": "2.0", "id": 2, "method": "_acpmux/permission_respond", "params": {"sessionId": "s1"}});
        assert!(controlled_session(&answer.to_string()).is_none());
        for m in ["session/fork", "session/load", "session/resume", "_acpmux/handoff_prepare"] {
            let r = json!({"jsonrpc": "2.0", "id": 3, "method": m, "params": {"sessionId": "s1"}});
            assert!(controlled_session(&r.to_string()).is_some(), "{m}");
        }
    }

    #[test]
    fn both_fork_names_have_identical_phone_controls() {
        for key in ["sessionId", "session", "name"] {
            for method in ["session/fork", "acp.session.fork"] {
                let request = json!({"jsonrpc": "2.0", "id": 17, "method": method,
                    "params": {key: "source", "throughSeq": 12}});
                let text = request.to_string();
                let (id, session) = controlled_session(&text).expect(method);
                assert_eq!((id.clone(), session.as_str()), (json!(17), "source"));
                for mode in PHONE_MODES {
                    assert_eq!(mode_refusal(&id, Some(mode)), None, "{method}: {mode}");
                }
                for mode in ["agent", "agent-full-access", "bypassPermissions"] {
                    let refused: Value =
                        serde_json::from_str(&mode_refusal(&id, Some(mode)).expect(method)).unwrap();
                    assert_eq!(refused["id"], 17);
                    assert_eq!(refused["error"]["data"]["reason"], "phone.mode_not_asking");
                    let marked: Value = serde_json::from_str(&marked(&text).unwrap()).unwrap();
                    assert_eq!(marked["params"]["_meta"]["acpmux"]["requireFullAccess"], true);
                    assert_eq!(marked["params"][key], "source");
                    assert_eq!(marked["params"]["throughSeq"], 12);
                    assert_eq!(marked["method"], method);
                }
            }
        }
    }

    #[test]
    fn retry_checks_the_current_mode_and_requires_full_access_when_it_does_not_ask() {
        let retry = json!({"jsonrpc": "2.0", "id": 12, "method": "_acpmux/retry",
                           "params": {"sessionId": "s1"}})
        .to_string();
        let (id, session) = controlled_session(&retry).expect("retry controls the existing session");
        assert_eq!(session, "s1");
        assert_eq!(mode_refusal(&id, Some("ask")), None);
        let refusal: Value = serde_json::from_str(
            &mode_refusal(&id, Some("agent-full-access")).expect("refused on the dashboard token"),
        )
        .unwrap();
        assert_eq!(refusal["id"], 12);
        assert_eq!(refusal["error"]["data"]["reason"], "phone.mode_not_asking");
        let marked_retry: Value = serde_json::from_str(&marked(&retry).unwrap()).unwrap();
        assert_eq!(marked_retry["params"]["_meta"]["acpmux"]["requireFullAccess"], true);
        assert_eq!(marked_retry["method"], "_acpmux/retry");
        assert_eq!(marked_retry["params"]["sessionId"], "s1");
    }

    /// On a phone's own credential, what the filter refuses goes on marked, for acpmux to
    /// run only when that phone's Full-access setting covers it.
    #[test]
    fn a_refused_request_is_marked_for_acpmux_to_decide() {
        let marked_set: Value =
            serde_json::from_str(&marked(&set_mode("agent-full-access")).unwrap()).unwrap();
        assert_eq!(marked_set["params"]["_meta"]["acpmux"]["requireFullAccess"], true);
        assert_eq!(marked_set["params"]["modeId"], "agent-full-access");
        let prompt = json!({"jsonrpc": "2.0", "id": 3, "method": "session/prompt",
                            "params": {"sessionId": "s", "prompt": [], "_meta": {"acpmux": {"via": "x"}}}});
        let batch = Value::Array(vec![prompt, serde_json::from_str(&set_mode("agent")).unwrap()]);
        let marked_batch: Value = serde_json::from_str(&marked(&batch.to_string()).unwrap()).unwrap();
        for request in marked_batch.as_array().unwrap() {
            assert_eq!(request["params"]["_meta"]["acpmux"]["requireFullAccess"], true, "{request}");
        }
        assert_eq!(marked_batch[0]["params"]["_meta"]["acpmux"]["via"], "x", "the rest of _meta stays");
        // A brief steer prompts a chat the filter cannot check: refused, or marked.
        let steer = json!({"jsonrpc": "2.0", "id": 5, "method": "_acpmux/steer", "params": {"briefId": "b", "text": "go"}});
        assert!(refusal(&steer.to_string()).is_some(), "refused on the dashboard token");
        let marked_steer: Value = serde_json::from_str(&marked(&steer.to_string()).unwrap()).unwrap();
        assert_eq!(marked_steer["params"]["_meta"]["acpmux"]["requireFullAccess"], true);
        // No params object to mark: not forwarded.
        let bare = json!({"jsonrpc": "2.0", "id": 1, "method": "session/set_mode"});
        assert_eq!(marked(&bare.to_string()), None);
        assert_eq!(marked("not json"), None);
    }

    #[test]
    fn other_messages_and_batches() {
        let prompt = json!({"jsonrpc": "2.0", "id": 3, "method": "session/prompt", "params": {"sessionId": "s", "prompt": []}});
        assert_eq!(refusal(&prompt.to_string()), None);
        assert_eq!(refusal(r#"{"jsonrpc":"2.0","id":4,"result":{}}"#), None);
        let batch = Value::Array(vec![prompt, serde_json::from_str(&set_mode("agent")).unwrap()]);
        assert!(refusal(&batch.to_string()).is_some());
    }
}
