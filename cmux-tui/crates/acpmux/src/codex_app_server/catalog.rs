//! Collect the configured provider's pages on this app-server connection. The ACP
//! translator consumes one model/list result and uses it to validate later tier picks.
use cmux_codex_acp::Out;
use serde_json::{Value, json};

#[derive(Default)]
pub(super) struct Catalog {
    request: Option<Value>,
    provider: Option<String>,
    rows: Vec<Value>,
    cursors: Vec<String>,
}

pub(super) const CONFIG: &str = "cmux.catalog.config";
const PAGE: &str = "cmux.catalog.page";

impl Catalog {
    pub fn start(&mut self, output: &mut [Out]) {
        for item in output {
            if let Out::Server(msg) = item
                && msg["method"] == "model/list"
            {
                self.request = msg.get("id").cloned();
                *msg = json!({"id": CONFIG, "method": "config/read", "params": {}});
            }
        }
    }

    fn page(&self) -> Out {
        let mut params = serde_json::Map::new();
        if let Some(provider) = &self.provider {
            params.insert("modelProvider".into(), json!(provider));
        }
        if let Some(cursor) = self.cursors.last() {
            params.insert("cursor".into(), json!(cursor));
        }
        Out::Server(json!({"id": PAGE, "method": "model/list", "params": params}))
    }

    /// Consume only our own replies. Errors on older servers fall back to their
    /// default list. A failed later page leaves the previously received rows usable.
    pub fn receive(&mut self, msg: &Value) -> Option<Result<Value, Out>> {
        self.request.as_ref()?;
        if msg.get("method").is_some() {
            return None;
        }
        match msg.get("id")?.as_str()? {
            CONFIG => {
                self.provider = msg
                    .pointer("/result/config/model_provider")
                    .and_then(Value::as_str)
                    .map(str::to_owned);
                Some(Err(self.page()))
            }
            PAGE => {
                if msg.pointer("/error/code").and_then(Value::as_i64) == Some(-32602)
                    && self.rows.is_empty()
                    && self.cursors.is_empty()
                    && self.provider.take().is_some()
                {
                    return Some(Err(self.page()));
                }
                if let Some(rows) = msg.pointer("/result/data").and_then(Value::as_array) {
                    self.rows.extend(rows.iter().cloned().map(|mut row| {
                        if row.get("id").is_none()
                            && let Some(model) = row.get("model").cloned()
                        {
                            row["id"] = model;
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
                    return Some(Err(self.page()));
                }
                let request = self.request.take()?;
                let rows = std::mem::take(&mut self.rows);
                self.cursors.clear();
                self.provider = None;
                Some(Ok(if rows.is_empty() && msg.get("error").is_some() {
                    json!({"id": request, "error": msg["error"]})
                } else {
                    json!({"id": request, "result": {"data": rows, "nextCursor": null}})
                }))
            }
            _ => None,
        }
    }
}
