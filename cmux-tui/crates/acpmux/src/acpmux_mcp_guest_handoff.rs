//! The transport-hub experiment: continue an external chat in cmux using a bounded capsule.
//! Labs > Show Preview Features is off by default. This adds no link or session until called.

use super::*;
use crate::user_settings::Settings;

pub(super) const NAME: &str = "handoff";

pub(super) fn enabled(settings: &Settings) -> bool {
    match settings {
        Settings::Parsed(doc) => {
            crate::user_settings::value(doc, "labs.previewFeatures") == Some(json!(true))
        }
        Settings::Missing | Settings::Unreadable(_) => false,
    }
}

pub(super) fn tool() -> Value {
    // The same destination choices and asking policy as `new`; only the first message differs.
    let mut tool = new_tool();
    tool.set("name", json!(NAME));
    tool.set("description", json!(
        "Continue this external chat in a new cmux session. Supply a self-contained capsule with the goal, decisions, current progress and next step; the target cannot read this chat. Returns the session and its link, just like new, and keeps the same asking policy. Experimental: enable Settings > Advanced > Labs > Show Preview Features, then reconnect this MCP server."
    ));
    if let Some(schema) = tool.get_mut("inputSchema").and_then(Value::as_object_mut) {
        schema.insert("required".into(), json!(["capsule"]));
        if let Some(properties) = schema.get_mut("properties").and_then(Value::as_object_mut) {
            properties.remove("prompt");
            properties.insert("capsule".into(), json!({
                "type": "string",
                "minLength": 1,
                "maxLength": crate::hub::MAX_CAPSULE_BYTES,
                "description": "The continuation summary, including the task to perform next. At most 65536 UTF-8 bytes, the same bound as Continue In. Oversized summaries are refused, never silently cut."
            }));
        }
    }
    tool
}

/// Validate before any CLI/daemon effect. Keep the caller's capsule byte-for-byte as stdin,
/// under Continue In's shared bound; `new` owns provenance, destination and asking enforcement.
pub(super) fn arguments(args: &Value, enabled: bool) -> Result<Value, String> {
    if !enabled {
        return Err("handoff is off: enable Settings > Advanced > Labs > Show Preview Features and reconnect this MCP server".into());
    }
    let capsule = args
        .get("capsule")
        .and_then(Value::as_str)
        .filter(|text| !text.trim().is_empty())
        .ok_or_else(|| {
            "capsule is required: include the goal, progress and next step".to_owned()
        })?;
    if capsule.len() > crate::hub::MAX_CAPSULE_BYTES {
        return Err(format!(
            "capsule is {} UTF-8 bytes; summarize it to at most {} bytes",
            capsule.len(),
            crate::hub::MAX_CAPSULE_BYTES
        ));
    }
    let mut forwarded = args.clone();
    forwarded.set("prompt", json!(capsule));
    if let Some(object) = forwarded.as_object_mut() {
        object.remove("capsule");
    }
    Ok(forwarded)
}

#[cfg(test)]
#[path = "acpmux_mcp_guest_handoff_tests.rs"]
mod tests;
