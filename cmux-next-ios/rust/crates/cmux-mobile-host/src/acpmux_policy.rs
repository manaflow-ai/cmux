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

/// The modes a phone may switch an agent to: Claude Code's `default` and
/// `plan`, the Codex bridge's `ask` (acpmux `ASKING_MODES`,
/// `BRIDGE_ASKING_MODES`). acpmux still checks each against the session's
/// family.
pub const PHONE_MODES: &[&str] = &["default", "plan", "ask"];

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
