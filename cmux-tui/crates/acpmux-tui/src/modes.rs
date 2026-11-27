//! What a session's ACP `modes` are worth as modes, as the GUI composer reads them (cmux
//! `permissionModes.ts`, a8103b585910 and 26b667f3206c). Lawrence, 2026-11-19: "pi should not have a
//! "mode"".
//!
//! An agent with config options may still send `modes` for older clients, as a copy of one option.
//! Claude Code's and Codex's copy is their `mode` option (real modes). Pi's is its `thought_level`
//! option ("Thinking: off" … "xhigh"), which the effort chip already draws, so the terminal drew a
//! Mode chip and a Mode picker of thinking levels. Those copies are dropped here.

use serde_json::Value;
use std::collections::BTreeSet;

/// The session detail's modes as (id, name), or none when they only copy a config option that is
/// not a mode option. Modes with no config options beside them (OpenCode, Gemini) are real.
pub(crate) fn real_modes(detail: &Value) -> Vec<(String, String)> {
    let modes: Vec<(String, String)> = detail
        .pointer("/modes/availableModes")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|m| {
            let id = m.get("id").and_then(Value::as_str)?.to_owned();
            let name = m.get("name").and_then(Value::as_str).unwrap_or(&id).to_owned();
            Some((id, name))
        })
        .collect();
    let ids: BTreeSet<&str> = modes.iter().map(|(id, _)| id.as_str()).collect();
    let copied = detail.get("configOptions").and_then(Value::as_array).is_some_and(|options| {
        options.iter().any(|o| {
            let is_mode = o.get("category").and_then(Value::as_str) == Some("mode")
                || o.get("id").and_then(Value::as_str) == Some("mode");
            let mut values = BTreeSet::new();
            choice_values(o.get("options"), &mut values);
            !is_mode && !values.is_empty() && values == ids
        })
    });
    if copied { Vec::new() } else { modes }
}

/// An option's choice values, its groups' included (ACP `SessionConfigSelectGroup`).
fn choice_values<'a>(raw: Option<&'a Value>, out: &mut BTreeSet<&'a str>) {
    for choice in raw.and_then(Value::as_array).into_iter().flatten() {
        if choice.get("options").is_some_and(Value::is_array) {
            choice_values(choice.get("options"), out);
        } else if let Some(v) = choice.get("value").and_then(Value::as_str) {
            out.insert(v);
        }
    }
}

/// Whether the composer draws a Mode chip for `mode`: a harness's plain default carries no
/// information, and neither does a mode that is only a copy of another option.
pub(crate) fn shows_mode_chip(mode: &str, detail: Option<&Value>) -> bool {
    if mode.is_empty() || matches!(mode, "default" | "normal" | "agent" | "build") {
        return false;
    }
    // Before the detail arrives, the transcript's mode is all there is.
    detail.is_none_or(|d| d.pointer("/modes/availableModes").is_none() || !real_modes(d).is_empty())
}

/// Where Toggle Plan Mode goes from `current` among `modes` (the GUI's key, 7a5d1f137ac6): into the
/// agent's Plan mode, or out of it to its default (the first mode that is not Plan when it lists no
/// `default`). Err when the agent has no Plan mode.
pub(crate) fn plan_toggle(
    current: &str,
    modes: &[(String, String)],
) -> Result<String, &'static str> {
    let is_plan = |id: &str| id.eq_ignore_ascii_case("plan");
    let plan = modes.iter().find(|(id, _)| is_plan(id)).ok_or("this agent has no Plan mode")?;
    if !is_plan(current) {
        return Ok(plan.0.clone());
    }
    modes
        .iter()
        .find(|(id, _)| id == "default")
        .or_else(|| modes.iter().find(|(id, _)| !is_plan(id)))
        .map(|(id, _)| id.clone())
        .ok_or("this agent has no mode to leave Plan for")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn pi() -> Value {
        json!({
            "modes": {"currentModeId": "medium", "availableModes": [
                {"id": "off", "name": "Thinking: off"}, {"id": "medium", "name": "Thinking: medium"},
                {"id": "xhigh", "name": "Thinking: xhigh"},
            ]},
            "configOptions": [{"id": "thought_level", "category": "thought_level", "currentValue": "medium",
                "options": [{"value": "off"}, {"value": "medium"}, {"value": "xhigh"}]}],
        })
    }

    #[test]
    fn pi_thinking_levels_are_no_mode() {
        assert!(real_modes(&pi()).is_empty());
        assert!(!shows_mode_chip("medium", Some(&pi())));
    }

    #[test]
    fn real_modes_stay() {
        // Claude Code's modes copy its own mode option.
        let claude = json!({
            "modes": {"availableModes": [{"id": "default"}, {"id": "plan", "name": "Plan"}]},
            "configOptions": [{"id": "mode", "options": [{"value": "default"}, {"value": "plan"}]},
                {"id": "model", "options": [{"group": "g", "options": [{"value": "opus"}]}]}],
        });
        assert_eq!(real_modes(&claude).len(), 2);
        assert!(shows_mode_chip("plan", Some(&claude)));
        // OpenCode's come with no config options.
        let opencode = json!({"modes": {"availableModes": [{"id": "build"}, {"id": "plan"}]}});
        assert_eq!(real_modes(&opencode)[1], ("plan".into(), "plan".into()));
        // An option that names only some of the modes is not their copy.
        let partial = json!({
            "modes": {"availableModes": [{"id": "off"}, {"id": "plan"}]},
            "configOptions": [{"id": "effort", "options": [{"value": "off"}]}],
        });
        assert_eq!(real_modes(&partial).len(), 2);
        // Defaults and an unknown detail.
        assert!(!shows_mode_chip("default", None));
        assert!(shows_mode_chip("plan", None));
    }

    #[test]
    fn plan_toggle_goes_in_and_back_out() {
        let m =
            |ids: &[&str]| ids.iter().map(|i| (i.to_string(), i.to_string())).collect::<Vec<_>>();
        let claude = m(&["default", "acceptEdits", "plan", "bypassPermissions"]);
        assert_eq!(plan_toggle("acceptEdits", &claude).as_deref(), Ok("plan"));
        assert_eq!(plan_toggle("plan", &claude).as_deref(), Ok("default"));
        assert_eq!(plan_toggle("plan", &m(&["build", "plan"])).as_deref(), Ok("build"));
        assert!(plan_toggle("auto", &m(&["read-only", "auto"])).is_err());
    }
}
