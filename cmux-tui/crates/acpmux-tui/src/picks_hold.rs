//! A model pick in a terminal chat keeps the chat's thinking level, as the GUI's model menu and
//! picker do (cmux#45385, #48546). Codex resets its level on a model switch, so a pick landed the
//! new model at its own default level. Leo: "all this picking models and effort levels and options
//! are smooth and they don't randomly change to other things".
//!
//! The model goes first, then the held level, then the detail is read again: a level that landed
//! before the model would be reset by it.

use super::*;

/// The effort-like option ids, in the order the Thinking picker looks for them.
pub(crate) const EFFORT_IDS: [&str; 5] =
    ["reasoning_effort", "effort", "thought_level", "thinking", "reasoning"];

/// The session detail's effort-like option and its current value, when one is set.
pub(crate) fn held_level(detail: &Value) -> Option<(String, String)> {
    let options = detail.get("configOptions")?.as_array()?;
    EFFORT_IDS.iter().find_map(|id| {
        let o = options.iter().find(|o| o.get("id").and_then(Value::as_str) == Some(id))?;
        let value = o.get("currentValue").and_then(Value::as_str)?;
        Some((id.to_string(), value.to_owned()))
    })
}

impl App {
    /// Switch `id` to `model`, then put the chat's level back on it. A model without that level
    /// refuses it quietly and runs its own.
    pub(crate) fn set_model_keeping_level(&self, id: &str, model: &str) {
        let held = self.details.get(id).and_then(held_level);
        let client = self.client.clone();
        let tx = self.tx.clone();
        let (id, model) = (id.to_owned(), model.to_owned());
        self.scope.spawn_until_cancelled("set model keeping level", async move {
            let params = json!({"sessionId": id, "modelId": model});
            if !Self::run_request(
                &client,
                &tx,
                method::SESSION_SET_MODEL,
                params,
                Some(format!("model {model}")),
            )
            .await
            {
                return;
            }
            if let Some((config_id, value)) = held {
                let params = json!({"sessionId": id, "configId": config_id, "value": value});
                let _ = client.request(method::SESSION_SET_CONFIG_OPTION, params).await;
            }
            Reread::Detail(id).run(&client, &tx).await;
        });
    }
}

#[cfg(test)]
mod tests {
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
        app.scope.close(std::time::Duration::from_secs(1)).await;
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
}
