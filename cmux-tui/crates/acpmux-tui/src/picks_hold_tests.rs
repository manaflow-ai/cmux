use super::held_level;
use serde_json::json;

#[cfg(unix)]
#[tokio::test]
async fn closing_the_tui_cancels_a_queued_model_pick() {
    let (app, mut requests) = crate::interaction_tests::app().await;
    app.set_model_keeping_level("test-session", "gpt-5");
    assert_eq!(app.scope.len(), 1, "the TUI owns the model request");
    let report = app.scope.close(std::time::Duration::from_secs(1)).await;
    assert!(report.still_running.is_empty(), "the model request ignored shutdown");
    assert!(requests.try_recv().is_err(), "a model pick ran after the TUI closed");
}

#[cfg(unix)]
#[tokio::test]
async fn an_owned_model_pick_restores_effort_after_setting_the_model() {
    let (mut app, mut requests) = crate::interaction_tests::app().await;
    app.details.insert(
        "test-session".into(),
        json!({"configOptions": [
            {"id": "reasoning_effort", "currentValue": "high"},
        ]}),
    );
    app.set_model_keeping_level("test-session", "gpt-5");
    for method in
        [acpmux::rpc::method::SESSION_SET_MODEL, acpmux::rpc::method::SESSION_SET_CONFIG_OPTION]
    {
        let request = tokio::time::timeout(std::time::Duration::from_secs(2), requests.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(request["method"], method);
        if method == acpmux::rpc::method::SESSION_SET_CONFIG_OPTION {
            assert_eq!(request["params"]["value"], "high");
        }
    }
    let report = app.scope.close(std::time::Duration::from_secs(1)).await;
    assert!(report.joined(), "{report}");
}

#[test]
fn reads_the_level_the_thinking_picker_reads() {
    let codex = json!({"configOptions": [
        {"id": "model", "currentValue": "gpt-5"},
        {"id": "reasoning_effort", "currentValue": "high"},
    ]});
    assert_eq!(held_level(&codex), Some(("reasoning_effort".into(), "high".into())));
    let pi = json!({"configOptions": [{"id": "thought_level", "currentValue": "off"}]});
    assert_eq!(held_level(&pi), Some(("thought_level".into(), "off".into())));
    assert_eq!(held_level(&json!({"configOptions": [{"id": "model"}]})), None);
    assert_eq!(held_level(&json!({})), None);
}
