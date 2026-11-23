//! `remoteSandbox` in config.json: what a remote chain's sandboxed Claude Code
//! carries beyond acpmux's own settings (`hub/remote_sandbox.rs`).

use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// `remoteSandbox` in config.json. Absent or empty (the default) changes
/// nothing: the chain's inline `--settings` stay exactly acpmux's own.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct RemoteSandboxConfig {
    /// `hooks`: the user hooks a remote chain's Claude Code runs, in Claude
    /// Code's own `hooks` settings shape (`{"PreToolUse": [{"matcher": "Bash",
    /// "hooks": [{"type": "command", "command": "...", "timeout": 10}]}]}`).
    /// A chain whose profile brings its own model route skips the user
    /// settings source, and with it every user hook; only the hooks listed
    /// here run there, inside the same sandbox. They go into the chain's
    /// inline `--settings` under `hooks` alone: nothing here reaches its `env`.
    #[serde(skip_serializing_if = "RemoteSandboxHooks::is_empty")]
    pub hooks: RemoteSandboxHooks,
}

impl RemoteSandboxConfig {
    pub fn is_default(&self) -> bool {
        self == &Self::default()
    }
}

/// Event name to its matcher groups, checked when config.json is read.
#[derive(Debug, Clone, Serialize, PartialEq, Default)]
#[serde(transparent)]
pub struct RemoteSandboxHooks(BTreeMap<String, Vec<HookGroup>>);

/// One matcher group of an event: `{"matcher"?, "hooks": [...]}`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct HookGroup {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub matcher: Option<String>,
    pub hooks: Vec<HookCommand>,
}

/// One hook: `{"type": "command", "command", "timeout"?}` (seconds).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct HookCommand {
    #[serde(rename = "type")]
    pub kind: String,
    pub command: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timeout: Option<u64>,
}

impl RemoteSandboxHooks {
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// The `hooks` value for the chain's inline `--settings`; `None` when
    /// none is configured, so the settings stay byte for byte acpmux's own.
    pub fn settings_value(&self) -> Option<Value> {
        if self.0.is_empty() {
            return None;
        }
        serde_json::to_value(&self.0).ok()
    }

    fn check(events: &BTreeMap<String, Vec<HookGroup>>) -> Result<(), String> {
        for (event, groups) in events {
            if event.is_empty() || !event.chars().all(|c| c.is_ascii_alphanumeric()) {
                return Err(format!(
                    "remoteSandbox.hooks: {event:?} is not a Claude Code hook event name (for example PreToolUse)"
                ));
            }
            if groups.is_empty() {
                return Err(format!("remoteSandbox.hooks.{event}: lists no matcher group"));
            }
            for (g, group) in groups.iter().enumerate() {
                let at = format!("remoteSandbox.hooks.{event}[{g}]");
                if group.hooks.is_empty() {
                    return Err(format!("{at}.hooks: lists no hook"));
                }
                for (h, hook) in group.hooks.iter().enumerate() {
                    if hook.kind != "command" {
                        return Err(format!(
                            "{at}.hooks[{h}].type: {:?}; only \"command\" hooks run in a remote chain",
                            hook.kind
                        ));
                    }
                    if hook.command.trim().is_empty() {
                        return Err(format!("{at}.hooks[{h}].command: empty"));
                    }
                    if hook.timeout == Some(0) {
                        return Err(format!("{at}.hooks[{h}].timeout: must be at least 1 second"));
                    }
                }
            }
        }
        Ok(())
    }
}

impl<'de> Deserialize<'de> for RemoteSandboxHooks {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let events =
            Option::<BTreeMap<String, Vec<HookGroup>>>::deserialize(d)?.unwrap_or_default();
        Self::check(&events).map_err(serde::de::Error::custom)?;
        Ok(Self(events))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn parse(v: Value) -> Result<RemoteSandboxConfig, String> {
        serde_json::from_value(v).map_err(|e| e.to_string())
    }

    #[test]
    fn absent_and_empty_hooks_are_the_default() {
        assert!(parse(json!({})).unwrap().is_default());
        assert!(parse(json!({"hooks": {}})).unwrap().is_default());
        assert!(parse(json!({"hooks": null})).unwrap().is_default());
        assert_eq!(RemoteSandboxConfig::default().hooks.settings_value(), None);
        let cfg: crate::config::Config = serde_json::from_value(json!({})).unwrap();
        assert!(cfg.remote_sandbox.is_default());
        assert!(serde_json::to_value(&cfg).unwrap().get("remoteSandbox").is_none());
    }

    #[test]
    fn a_hook_list_round_trips_in_claude_codes_shape() {
        let hooks = json!({"PreToolUse": [{"matcher": "Bash", "hooks": [
            {"type": "command", "command": "/u/bin/guard", "timeout": 10}
        ]}], "Stop": [{"hooks": [{"type": "command", "command": "/u/bin/stop"}]}]});
        let cfg = parse(json!({"hooks": hooks})).unwrap();
        assert_eq!(cfg.hooks.settings_value(), Some(hooks.clone()));
        assert_eq!(serde_json::to_value(&cfg).unwrap(), json!({"hooks": hooks}));
    }

    #[test]
    fn a_malformed_hook_list_is_refused_with_its_place() {
        let cmd = |h: Value| json!({"hooks": {"PreToolUse": [{"hooks": [h]}]}});
        for (bad, says) in [
            (json!({"hooks": []}), "invalid type"),
            (json!({"hooks": {"PreToolUse": {}}}), "invalid type"),
            (json!({"hooks": {"": [{"hooks": []}]}}), "not a Claude Code hook event"),
            (json!({"hooks": {"Pre Tool": [{"hooks": []}]}}), "not a Claude Code hook event"),
            (json!({"hooks": {"PreToolUse": []}}), "remoteSandbox.hooks.PreToolUse: lists no"),
            (
                json!({"hooks": {"PreToolUse": [{"hooks": []}]}}),
                "PreToolUse[0].hooks: lists no hook",
            ),
            (cmd(json!({"type": "prompt", "command": "x"})), "only \"command\""),
            (cmd(json!({"type": "command", "command": " "})), "command: empty"),
            (cmd(json!({"type": "command", "command": "x", "timeout": 0})), "at least 1"),
            (cmd(json!({"type": "command", "command": "x", "env": {}})), "unknown field `env`"),
            (cmd(json!({"type": "command"})), "missing field `command`"),
            (
                json!({"hooks": {}, "env": {"ANTHROPIC_BASE_URL": "http://x"}}),
                "unknown field `env`",
            ),
        ] {
            let err = parse(bad.clone()).unwrap_err();
            assert!(err.contains(says), "{bad}: {err}");
        }
    }

    /// The refusal stops config.json from parsing (`Config::load_from` wraps
    /// it as "parse <path>"), naming where the list is wrong.
    #[test]
    fn a_malformed_hook_list_refuses_the_whole_config() {
        let text = json!({"remoteSandbox": {"hooks": {"Stop": [{"hooks": [{"type": "http", "command": "x"}]}]}}});
        let err = serde_json::from_str::<crate::config::Config>(&text.to_string()).unwrap_err();
        assert!(err.to_string().contains("remoteSandbox.hooks.Stop[0].hooks[0].type"), "{err}");
    }
}
