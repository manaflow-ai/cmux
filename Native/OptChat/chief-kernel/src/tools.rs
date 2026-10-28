//! The Chief's tool contract (stub).

use serde_json::Value;

/// The tool list (stub).
pub fn tool_list(_subagent: bool, _allows: &dyn Fn(&str) -> bool) -> Value {
    Value::Array(Vec::new())
}

/// The per-engine specs (stub).
pub fn specs(_engine: &str, _grant_json: &str) -> Result<Value, String> {
    Err("not yet".into())
}
