//! The structured declaration tool for plan tripwires. The daemon owns the manifest so prose
//! cannot silently remove an unresolved check.

use super::{error_result, ok, refusal};
use crate::client::Client;
use crate::rpc::method;
use serde_json::{Value, json};
use std::sync::Arc;

pub(super) const NAME: &str = "tripwire_declare";

pub(super) fn tool() -> Value {
    json!({
        "name": NAME,
        "description": "Declare the real test files written first for this approved plan. Call once with up to 8 checks before implementation, then run each declared path explicitly. The manifest is immutable for this chat.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "items": {"type": "array", "minItems": 1, "maxItems": 8, "items": {"type": "object", "properties": {
                    "name": {"type": "string"}, "path": {"type": "string"}
                }, "required": ["name", "path"], "additionalProperties": false}}
            },
            "required": ["items"], "additionalProperties": false
        }
    })
}

pub(super) async fn call(daemon: &Arc<Client>, session: &str, args: &Value) -> Value {
    if session.is_empty() {
        return error_result("this server runs in no acpmux chat".to_owned());
    }
    let Some(object) = args.as_object() else {
        return error_result("arguments must be an object".to_owned());
    };
    let Some(items) = object.get("items").cloned() else {
        return error_result("items is required".to_owned());
    };
    match daemon
        .request(method::MUX_TRIPWIRE_DECLARE, json!({"sessionId": session, "items": items}))
        .await
    {
        Ok(state) => ok(
            "Tripwires declared. Write and run each named test path before finishing the plan."
                .to_owned(),
            json!({"tripwires": state}),
        ),
        Err(error) => refusal(error),
    }
}
