//! The chat's log records masked before they leave the laptop (security review of cmux#52931,
//! item 4): a token the person pasted or a tool printed reaches neither the store nor the Auto
//! machine as plain text. The log on this machine keeps its records as they were.

use serde_json::Value;

/// Masks every string in `record`, at any depth, with `secret_scan::mask`. Keys stay as they
/// are: they are the record's shape, not what was said.
pub(super) fn redact(record: &mut Value) {
    match record {
        Value::String(text) => *text = crate::secret_scan::mask(text),
        Value::Array(items) => items.iter_mut().for_each(redact),
        Value::Object(fields) => fields.values_mut().for_each(redact),
        _ => {}
    }
}
