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
        tokio::spawn(async move {
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
