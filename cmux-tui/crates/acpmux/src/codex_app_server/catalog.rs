//! The ACP translator consumes one model/list result. Collect all pages from the
//! running app-server, whose active provider, credentials and visibility rules own the list.
use cmux_codex_acp::Out;
use serde_json::{Value, json};

#[derive(Default)]
pub(super) struct Catalog {
    request: Option<Value>,
    rows: Vec<Value>,
    cursors: Vec<String>,
    waiting: Vec<Value>,
}

impl Catalog {
    pub fn start(&mut self, output: &mut [Out]) {
        for item in output {
            if let Out::Server(msg) = item
                && msg["method"] == "model/list"
            {
                self.request = msg.get("id").cloned();
                if let Some(params) = msg
                    .as_object_mut()
                    .map(|fields| fields.entry("params").or_insert_with(|| json!({})))
                    .and_then(Value::as_object_mut)
                {
                    params.insert("limit".into(), json!(100));
                }
            }
        }
    }

    /// Settings replay may start as soon as thread/start returns, before
    /// model/list has answered. Validate those picks against the complete list.
    pub fn hold_pick(&mut self, msg: &Value) -> bool {
        let pick = match msg["method"].as_str() {
            Some("session/set_model") => true,
            Some("session/set_config_option") => matches!(
                msg.pointer("/params/configId").and_then(Value::as_str),
                Some(
                    "model"
                        | "reasoning_effort"
                        | "effort"
                        | "thought_level"
                        | "fast-mode"
                        | "service_tier"
                )
            ),
            _ => false,
        };
        if self.request.is_some() && pick {
            self.waiting.push(msg.clone());
            return true;
        }
        false
    }

    pub fn take_picks(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.waiting)
    }

    pub fn receive(&mut self, msg: &Value) -> Option<Result<Value, Out>> {
        let request = self.request.as_ref()?;
        if msg.get("method").is_some() || msg.get("id") != Some(request) {
            return None;
        }
        if let Some(rows) = msg.pointer("/result/data").and_then(Value::as_array) {
            self.rows.extend(rows.iter().cloned().map(|mut row| {
                if row.get("id").is_none()
                    && let Some(model) = row.get("model").cloned()
                    && let Some(fields) = row.as_object_mut()
                {
                    fields.insert("id".into(), model);
                }
                row
            }));
        }
        if let Some(cursor) = msg.pointer("/result/nextCursor").and_then(Value::as_str)
            && !cursor.is_empty()
            && self.cursors.len() < 19
            && !self.cursors.iter().any(|c| c == cursor)
        {
            self.cursors.push(cursor.to_owned());
            return Some(Err(Out::Server(json!({"id": request, "method": "model/list",
                                                "params": {"cursor": cursor, "limit": 100}}))));
        }
        let request = self.request.take()?;
        self.cursors.clear();
        let rows = std::mem::take(&mut self.rows);
        Some(Ok(if rows.is_empty() && msg.get("error").is_some() {
            json!({"id": request, "error": msg["error"]})
        } else {
            json!({"id": request, "result": {"data": rows, "nextCursor": null}})
        }))
    }
}
