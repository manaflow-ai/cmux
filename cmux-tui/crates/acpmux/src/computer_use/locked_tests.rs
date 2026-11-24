use super::*;

fn body(result: &Value) -> Value {
    serde_json::from_str(result["content"][0]["text"].as_str().unwrap()).unwrap()
}

#[test]
fn mac_locked_becomes_the_typed_state_and_keeps_while_locked() {
    let mut out = ToolOutput::error("mac_locked", "the Mac is locked");
    out.body["whileLocked"] = json!({"setting": "computerUse.whileLocked", "value": "off"});
    let result = to_mcp(Outcome::Output(out));
    assert_eq!(result["isError"], true);
    assert_eq!(result["_meta"][STATE_META], CODE);
    let b = body(&result);
    assert_eq!(b["code"], CODE);
    assert_eq!(b["state"], "locked");
    assert_eq!(b["error"], MESSAGE);
    assert_eq!(b["detail"], "the Mac is locked");
    assert!(b.get("worker_code").is_none());
    assert_eq!(b["whileLocked"]["setting"], "computerUse.whileLocked");
    let routes: Vec<_> =
        b["routes"].as_array().unwrap().iter().map(|r| r["route"].as_str().unwrap()).collect();
    assert_eq!(routes, ["unlock", "remote", "cloud"]);
}

#[test]
fn legacy_screen_locked_maps_to_mac_locked() {
    let out = ToolOutput::error("screen_locked", "screen is locked");
    let Outcome::Output(mapped) = map(Outcome::Output(out)) else { panic!("an output") };
    assert_eq!(mapped.code.as_deref(), Some(CODE));
    assert_eq!(mapped.body["worker_code"], "screen_locked");
    assert_eq!(mapped.body["detail"], "screen is locked");
    // A request-level refusal and a remote machine's refusal map the same way.
    for failed in [
        Outcome::Failed { code: "worker_error".into(), message: "screen_locked: locked".into() },
        Outcome::Failed { code: "mac_locked".into(), message: "locked".into() },
    ] {
        let result = to_mcp(failed);
        assert_eq!(result["_meta"][STATE_META], CODE);
        assert_eq!(body(&result)["state"], "locked");
    }
}

#[test]
fn other_results_pass_through_unchanged() {
    let cases = [
        Outcome::Output(ToolOutput::error("app_denied", "denied")),
        Outcome::Output(ToolOutput::ok(json!({"code": "mac_locked"}))),
        Outcome::Off(String::new()),
        Outcome::Failed { code: "worker_error".into(), message: "mac_lockedness".into() },
        Outcome::Failed { code: "computer_use_unavailable".into(), message: "away".into() },
    ];
    for outcome in cases {
        assert_eq!(map(outcome.clone()), outcome);
        let result = to_mcp(outcome.clone());
        assert_eq!(result, outcome.to_mcp());
        assert!(result.get("_meta").is_none());
    }
}
