//! The `acpmux` MCP server's ask tools (RFD 0010 piece 5; `server/asks.rs`,
//! `hub/ask_ledger/query.rs`): `asks_search`, `asks_get` and `asks_link`, over the person's asks
//! in the default-off ask ledger. An agent finds what the person asked before (and who took it),
//! reads one ask with its events, and links its work to it ("this PR builds ask X"). Listed only
//! on a machine whose ledger captured an ask (`query::captured_on`), so a machine that never
//! turned the `askLedger` experiment on sees no new tools. The RFD's `asks.search` names are
//! spelled with `_`: MCP tool names cannot hold a dot in Claude Code.

use super::{error_result, ok, refusal};
use crate::client::Client;
use crate::rpc::method;
use serde_json::{Value, json};
use std::sync::Arc;

pub(super) const TOOLS: [&str; 3] = ["asks_search", "asks_get", "asks_link"];

pub(super) fn tools() -> Vec<Value> {
    vec![
        json!({
            "name": "asks_search",
            "description": "Search what the person asked across every chat on this machine (the ask ledger), newest first, before asking them again or building something they may have asked for already. Each row: id, status (open, routed, inProgress, landed, answered, dropped), owner (who took it), sessionId, createdAt (ms) and the first 300 characters. matched counts every match. No q lists the newest asks.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "q": {"type": "string", "description": "Words the ask's text must all hold (case-insensitive)."},
                    "status": {"type": "string", "enum": crate::hub::ask_ledger::query::STATUSES, "description": "Only asks with this status."},
                    "limit": {"type": "integer", "minimum": 1, "maximum": crate::hub::ask_ledger::query::SEARCH_MAX, "description": "How many (default 20)."}
                }
            }
        }),
        json!({
            "name": "asks_get",
            "description": "One ask whole by id (from asks_search): its full text, status, owner, and every event after its capture (routed, picked, prOpened, prMerged, answered, reopened, dropped), each with who and when.",
            "inputSchema": {
                "type": "object",
                "properties": {"id": {"type": "string", "description": "The ask's id (ask-...)."}},
                "required": ["id"]
            }
        }),
        json!({
            "name": "asks_link",
            "description": "Record what happened to an ask, as this chat: picked (you took it), routed (to: the lane or chat that has it), prOpened or prMerged (repo owner/name, number), answered, reopened, dropped (reason). Status and owner follow from these events. Returns the ask after it.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "id": {"type": "string", "description": "The ask's id (ask-...)."},
                    "kind": {"type": "string", "enum": ["picked", "routed", "prOpened", "prMerged", "answered", "reopened", "dropped"]},
                    "to": {"type": "string", "description": "routed: who has it now (HOST/NAME or a session id)."},
                    "repo": {"type": "string", "description": "prOpened, prMerged: owner/name."},
                    "number": {"type": "integer", "minimum": 1, "description": "prOpened, prMerged: the PR number."},
                    "reason": {"type": "string", "description": "dropped: why."}
                },
                "required": ["id", "kind"]
            }
        }),
    ]
}

/// The daemon method and params of one ask tool call.
pub(super) fn request(name: &str, args: &Value) -> Result<(&'static str, Value), String> {
    if !args.is_object() {
        return Err("arguments must be an object".to_owned());
    }
    let method = match name {
        "asks_search" => method::MUX_ASKS_SEARCH,
        "asks_get" => method::MUX_ASKS_GET,
        "asks_link" => method::MUX_ASKS_LINK,
        _ => return Err(format!("unknown ask tool {name}")),
    };
    Ok((method, args.clone()))
}

/// One ask tool call.
pub(super) async fn call(daemon: &Arc<Client>, name: &str, args: &Value) -> Value {
    let (method, params) = match request(name, args) {
        Ok(r) => r,
        Err(e) => return error_result(e),
    };
    match daemon.request(method, params).await {
        Ok(answer) => {
            ok(serde_json::to_string_pretty(&answer).unwrap_or_else(|_| answer.to_string()), answer)
        }
        Err(e) => refusal(e),
    }
}

#[cfg(test)]
#[path = "acpmux_mcp_asks_tests.rs"]
mod tests;
