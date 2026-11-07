//! The `acpmux` MCP server's `send_status` tool: a send's receipt. `send` answers with a
//! `deliveryId` while this daemon's outbox still owes the message (`hub/outbox.rs`); this reads
//! where it is by that id, or lists this chat's sent messages, as `acpmux send --status [ID]`
//! does (`cli/run/send_async.rs`), with the CLI's text.

use super::{arg, error_result, ok, refusal};
use crate::client::Client;
use crate::rpc::method;
use serde_json::{Value, json};
use std::sync::Arc;

pub(super) const NAME: &str = "send_status";

/// How many of this chat's sent messages the list shows.
const LIST_LIMIT: u64 = 20;

pub(super) fn tool() -> Value {
    json!({
        "name": NAME,
        "description": "Where a message you sent is: queued, delivering, delivered or failed, with its attempts and last error. Pass the deliveryId send returned; with none, lists the messages this chat sent, newest first. Use it instead of sending a message again.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "deliveryId": {"type": "string", "description": "The deliveryId from send (default: list this chat's sent messages)."}
            }
        }
    })
}

/// The request for a call from the chat `session`, or the refusal the agent reads.
pub(super) fn request(session: &str, args: &Value) -> Result<Value, String> {
    if let Some(id) = arg(args, "deliveryId") {
        return Ok(json!({"deliveryId": id}));
    }
    if session.is_empty() {
        return Err("deliveryId is required: this server runs in no acpmux chat to list".to_owned());
    }
    Ok(json!({"list": true, "caller": session, "limit": LIST_LIMIT}))
}

pub(super) async fn call(daemon: &Arc<Client>, session: &str, args: &Value) -> Value {
    let params = match request(session, args) {
        Ok(p) => p,
        Err(e) => return error_result(e),
    };
    let listing = params.get("list").is_some();
    match daemon.request(method::MUX_SEND_STATUS, params).await {
        Ok(reply) if listing => {
            let lines = crate::cli::run::sent_list_lines(&reply, crate::store::now_ms());
            ok(lines.join("\n"), reply)
        }
        Ok(reply) => ok(crate::cli::run::sent_status_line(&reply), reply),
        Err(e) => refusal(e),
    }
}
