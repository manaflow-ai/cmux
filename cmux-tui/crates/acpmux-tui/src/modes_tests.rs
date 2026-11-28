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
    let m = |ids: &[&str]| ids.iter().map(|i| (i.to_string(), i.to_string())).collect::<Vec<_>>();
    let claude = m(&["default", "acceptEdits", "plan", "bypassPermissions"]);
    assert_eq!(plan_toggle("acceptEdits", &claude).as_deref(), Ok("plan"));
    assert_eq!(plan_toggle("plan", &claude).as_deref(), Ok("default"));
    assert_eq!(plan_toggle("plan", &m(&["build", "plan"])).as_deref(), Ok("build"));
    assert!(plan_toggle("auto", &m(&["read-only", "auto"])).is_err());
}
