//! Claude Code's prompt suggestions: after a turn Claude Code may predict the person's next
//! prompt (`{"type": "prompt_suggestion", "suggestion": ...}`, Claude Code 2.1.310), which the
//! composer shows as ghost text in an empty input (Leo, 2026-11-03: "i know there's suggested
//! prompts that you can right arrow/tab to do stuff with... maybe we can expose it in cmux-next
//! too").
//!
//! Two switches decide it. The settings key [`SETTING`] (on by default) is the global one, read
//! at each process start: off, acpmux never asks Claude Code for suggestions and the chat has no
//! option for them. On, `initialize` asks for them and each chat has the `prompt-suggestions`
//! option ([`OPTION`], saved with the chat like fast mode): off pauses that process's suggestions
//! (`set_prompt_suggestions_paused`, so no extra model call is made) and drops any that still
//! come. Claude Code keeps its own rules: none on a chat's first turn, none from the person's own
//! `promptSuggestionEnabled: false`, and fewer after 20 go unused in a row (its back-off, which a
//! forced `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=1` would turn off, so acpmux never sets it).
//!
//! The line is marked internal in Claude Code's schema: a line without a usable `suggestion`
//! string is dropped, never an error.

use super::*;

/// The settings key of the global switch (cmux.json).
pub const SETTING: &str = "agents.promptSuggestions";
/// The chat's own switch, a config option with values `on` and `off`.
pub const OPTION: &str = "prompt-suggestions";
/// Longest suggestion passed on; a longer one is not a next prompt.
const MAX_CHARS: usize = 2_000;

/// The value MDM or the team policy forces for [`SETTING`], as the app last pushed it
/// (`_acpmux/chat_settings` `promptSuggestions`, `promptSuggestionsManaged`; kept in
/// `start-mode.json` across a restart, `hub/start_mode_state.rs`): 0 nothing forced, 1 off, 2 on.
/// acpmux reads only the settings file, so without the push a managed value never reached it.
static MANAGED: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(0);

/// Records the forced value (`None`: nothing forces it).
pub(crate) fn set_managed(forced: Option<bool>) {
    let raw = match forced {
        None => 0,
        Some(false) => 1,
        Some(true) => 2,
    };
    MANAGED.store(raw, Ordering::Relaxed);
}

pub(crate) fn managed() -> Option<bool> {
    match MANAGED.load(Ordering::Relaxed) {
        1 => Some(false),
        2 => Some(true),
        _ => None,
    }
}

/// The switch from a forced value and the file's: a forced value beats the file either way;
/// with nothing forced, the file's value, on when unset.
pub(crate) fn effective(forced: Option<bool>, file: Option<bool>) -> bool {
    forced.or(file).unwrap_or(true)
}

/// The global switch now: what MDM or the team policy forces, else what the settings file says
/// (on when unset or unreadable).
pub fn enabled_in_settings() -> bool {
    let file = match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => {
            crate::user_settings::value(&doc, SETTING).and_then(|v| v.as_bool())
        }
        _ => None,
    };
    effective(managed(), file)
}

/// A chat's saved `prompt-suggestions` value as its pick: on unless it says off.
pub fn chat_pick(saved: Option<String>) -> bool {
    saved.as_deref() != Some("off")
}

/// The `session/update` a suggestion (or `None`, its clearing) is sent as.
pub(super) fn update(suggestion: Option<&str>) -> Value {
    json!({"sessionUpdate": "prompt_suggestion", "suggestion": suggestion})
}

impl Translator {
    /// Whether this process asked Claude Code for suggestions and the chat has them on.
    pub(super) fn suggestions_on(&self) -> bool {
        self.suggestions_offered.load(Ordering::SeqCst)
            && self.prompt_suggestions.load(Ordering::SeqCst)
    }

    /// The `initialize` fields and lines for suggestions: asks for them while the global switch
    /// is on, then pauses them at once when the chat has them off.
    pub(super) fn suggestion_init(&self, id: &Id, global: bool) -> Option<Value> {
        self.suggestions_offered.store(global, Ordering::SeqCst);
        (global && !self.prompt_suggestions.load(Ordering::SeqCst))
            .then(|| pause_line(&format!("boot-psp-{id}"), true))
    }

    /// The chat's `prompt-suggestions` option, while the global switch offers it.
    pub(super) fn suggestion_option(&self) -> Option<Value> {
        self.suggestions_offered.load(Ordering::SeqCst).then(|| {
            json!({"id": OPTION, "name": "Prompt suggestions", "type": "select", "category": "model_config",
             "currentValue": if self.prompt_suggestions.load(Ordering::SeqCst) { "on" } else { "off" },
             "options": [
                 {"value": "off", "name": "Off"},
                 {"value": "on", "name": "On", "description": "Suggests your next prompt after a turn; one extra model call per turn, which counts toward usage"},
             ]})
        })
    }

    /// `session/set_config_option` for [`OPTION`]: the chat's pick changes now, and the pause
    /// goes to Claude Code. Its answer is not waited on for the change: a Claude Code without the
    /// pause answers an error and keeps suggesting, and acpmux drops those instead.
    pub(super) async fn set_suggestions(&self, id: &Id, value: &str) -> Outbound {
        let on = match value {
            "on" => true,
            "off" => false,
            _ => {
                return Outbound::Reply(Message::err(
                    id.clone(),
                    RpcError::invalid_params("prompt-suggestions must be on or off"),
                ));
            }
        };
        if !self.suggestions_offered.load(Ordering::SeqCst) {
            return Outbound::Reply(Message::err(
                id.clone(),
                RpcError::invalid_params(format!(
                    "prompt suggestions are off in settings ({SETTING})"
                )),
            ));
        }
        self.prompt_suggestions.store(on, Ordering::SeqCst);
        self.pending.lock().await.insert(id.to_string(), Pending::Suggestions);
        Outbound::Lines(vec![pause_line(&format!("psp-{id}"), !on)])
    }

    /// Claude Code's answer to a chat's pause: the option's new value, and the shown suggestion
    /// cleared when it went off.
    pub(super) async fn suggestions_set(&self, acp: &str, sid: &str) -> Vec<Message> {
        let id: Id = serde_json::from_str(acp).unwrap_or(Value::String(acp.to_owned()));
        self.pending.lock().await.remove(&id.to_string());
        let mut out = Vec::new();
        if !self.prompt_suggestions.load(Ordering::SeqCst) {
            out.push(Message::notification(
                method::SESSION_UPDATE,
                json!({"sessionId": sid, "update": update(None)}),
            ));
        }
        let mode = self.mode.lock().await.clone();
        out.push(Message::ok(
            id,
            json!({"configOptions": self.config_options_value().await, "currentModeId": mode}),
        ));
        out
    }

    /// A `prompt_suggestion` line as its update, or `None` when the chat has them off or the
    /// line carries no usable suggestion.
    pub(super) fn suggestion_update(&self, line: &Value) -> Option<Value> {
        if !self.suggestions_on() {
            return None;
        }
        let text = line.get("suggestion").and_then(Value::as_str)?.trim();
        (!text.is_empty() && text.chars().count() <= MAX_CHARS).then(|| update(Some(text)))
    }
}

/// Claude Code's `set_prompt_suggestions_paused` control request.
fn pause_line(request_id: &str, paused: bool) -> Value {
    json!({"type": "control_request", "request_id": request_id, "request": {"subtype": "set_prompt_suggestions_paused", "paused": paused}})
}
