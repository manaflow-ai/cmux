//! The Chief's `version` tool: the cmux report and the Chief's own versions.

use std::path::Path;

use serde_json::Value;

/// The tool's answer (stub).
pub fn report(cmux: &dyn Fn() -> Result<Value, String>, home: &Path) -> Value {
    let _ = (cmux, home);
    Value::Null
}
