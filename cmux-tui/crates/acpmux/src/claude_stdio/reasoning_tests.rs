//! Claude Code's reasoning and fast-mode options (Lawrence 2026-10-09: "make sure our claude
//! supports all of these options"): Low to Max with Extra High, Ultracode, Ultrathink, and
//! Fast mode On/Off. Verified against Claude Code 2.1.287: `apply_flag_settings` takes
//! `effortLevel`, `ultracode` and `fastMode` live; Ultrathink is a prompt prefix.

use super::*;

fn option<'a>(options: &'a Value, id: &str) -> &'a Value {
    options.as_array().unwrap().iter().find(|o| o["id"] == id).unwrap_or(&Value::Null)
}

fn flag_settings(lines: &[Value]) -> Value {
    lines
        .iter()
        .find(|l| l["request"]["subtype"] == "apply_flag_settings")
        .map(|l| l["request"]["settings"].clone())
        .unwrap_or(Value::Null)
}

#[tokio::test]
async fn effort_lists_extra_high_ultracode_and_ultrathink() {
    let t = Translator::new("acp-1".into(), "default", "opus", "default");
    let options = t.config_options_value().await;
    let effort = option(&options, "effort");
    let names: Vec<(&str, &str)> = effort["options"]
        .as_array()
        .unwrap()
        .iter()
        .map(|o| (o["value"].as_str().unwrap(), o["name"].as_str().unwrap()))
        .collect();
    for wanted in [
        ("low", "Low"),
        ("medium", "Medium"),
        ("high", "High"),
        ("xhigh", "Extra High"),
        ("max", "Max"),
        ("ultracode", "Ultracode"),
        ("ultrathink", "Ultrathink"),
    ] {
        assert!(names.contains(&wanted), "missing {wanted:?} in {names:?}");
    }
    let ultracode =
        effort["options"].as_array().unwrap().iter().find(|o| o["value"] == "ultracode");
    assert!(ultracode.unwrap()["description"].as_str().is_some_and(|d| d.contains("multi-agent")));
}

#[tokio::test]
async fn fast_mode_is_an_on_off_option_applied_live() {
    let t = Translator::new("acp-1".into(), "default", "opus", "default");
    let options = t.config_options_value().await;
    let fast = option(&options, "fast-mode");
    assert_eq!(fast["currentValue"], "off");
    let values: Vec<&str> =
        fast["options"].as_array().unwrap().iter().map(|o| o["value"].as_str().unwrap()).collect();
    assert_eq!(values, ["off", "on"]);
    let Outbound::Lines(lines) = t
        .outbound(&Message::request(
            4,
            method::SESSION_SET_CONFIG_OPTION,
            json!({"configId": "fast-mode", "value": "on"}),
        ))
        .await
    else {
        panic!("fast-mode on must reach Claude Code")
    };
    assert_eq!(flag_settings(&lines), json!({"fastMode": true}));
    t.inbound(&json!({"type": "control_response", "response": {"subtype": "success", "request_id": "ctl-4"}}))
        .await;
    assert_eq!(option(&t.config_options_value().await, "fast-mode")["currentValue"], "on");
}

#[tokio::test]
async fn ultracode_is_xhigh_plus_the_ultracode_flag() {
    let t = Translator::new("acp-1".into(), "default", "opus", "high");
    let Outbound::Lines(lines) = t
        .outbound(&Message::request(
            5,
            method::SESSION_SET_CONFIG_OPTION,
            json!({"configId": "effort", "value": "ultracode"}),
        ))
        .await
    else {
        panic!()
    };
    assert_eq!(flag_settings(&lines), json!({"effortLevel": "xhigh", "ultracode": true}));
    // Any other level turns Ultracode off again.
    let Outbound::Lines(lines) = t
        .outbound(&Message::request(
            6,
            method::SESSION_SET_CONFIG_OPTION,
            json!({"configId": "effort", "value": "medium"}),
        ))
        .await
    else {
        panic!()
    };
    assert_eq!(flag_settings(&lines), json!({"effortLevel": "medium", "ultracode": false}));
}

#[tokio::test]
async fn ultrathink_prefixes_the_prompt_and_keeps_the_effort() {
    let t = Translator::new("acp-1".into(), "default", "opus", "high");
    let Outbound::Lines(lines) = t
        .outbound(&Message::request(
            7,
            method::SESSION_SET_CONFIG_OPTION,
            json!({"configId": "effort", "value": "ultrathink"}),
        ))
        .await
    else {
        panic!()
    };
    // No effort level change: only Ultracode is cleared.
    assert_eq!(flag_settings(&lines), json!({"ultracode": false}));
    t.inbound(&json!({"type": "control_response", "response": {"subtype": "success", "request_id": "ctl-7"}}))
        .await;
    let Outbound::Lines(lines) = t
        .outbound(&Message::request(
            8,
            method::SESSION_PROMPT,
            json!({"prompt": [{"type": "text", "text": "fix the race"}]}),
        ))
        .await
    else {
        panic!()
    };
    assert_eq!(lines[0]["message"]["content"][0]["text"], "Ultrathink:\nfix the race");
}

#[tokio::test]
async fn a_respawned_ultracode_session_starts_at_xhigh_with_its_flags() {
    let profile = HarnessProfile {
        kind: crate::config::HarnessKind::ClaudeStdio,
        argv: vec!["claude".into()],
        env: Default::default(),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let plan = spawn_plan(&profile, None, false, Some("id"), Some("ultracode"), "default", None);
    assert!(plan.args.windows(2).any(|w| w == ["--effort", "xhigh"]), "{:?}", plan.args);
    let plan = spawn_plan(&profile, None, false, Some("id"), Some("ultrathink"), "default", None);
    assert!(!plan.args.iter().any(|a| a == "--effort"), "{:?}", plan.args);
    // The ultracode flag goes out with initialize, on the same live channel.
    let t = Translator::new("acp-1".into(), "default", "opus", "ultracode");
    let Outbound::Lines(lines) =
        t.outbound(&Message::request(1, method::INITIALIZE, json!({}))).await
    else {
        panic!()
    };
    assert_eq!(lines[0]["request"]["subtype"], "initialize");
    assert_eq!(flag_settings(&lines), json!({"effortLevel": "xhigh", "ultracode": true}));
}
