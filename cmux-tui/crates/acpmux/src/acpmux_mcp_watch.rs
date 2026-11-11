//! The `acpmux` MCP server's watch tools: `watch_add`, `watch_ls`, `watch_rm`, the daemon's
//! durable wake subscriptions (`_acpmux/watch_*`, `hub/watches.rs`) for a coordinator agent. They
//! make the same requests as `acpmux watch` (`cli/watch.rs`) over this server's connection, which
//! carries the chat's caller token on the local socket, so `to` defaults to this chat and the
//! daemon refuses nothing here it would not refuse the CLI. The text is the CLI's.

use super::{arg, error_result, ok, refusal};
use crate::client::Client;
use crate::rpc::method;
use serde_json::{Value, json};
use std::sync::Arc;

pub(super) const TOOLS: &[&str] = &["watch_add", "watch_ls", "watch_rm"];

/// The instruction the server gives with the tools.
pub(super) const STEER: &str = "To learn when other sessions finish or get blocked, call \
watch_add once with them instead of polling them with ls, last or info: the daemon wakes this chat \
with one message when one of them is done, even across restarts. To learn when a job in a cmux \
terminal ends, call watch_add with terminal and until [\"exit\"]: the message has its exit status.";

pub(super) fn tools() -> Vec<Value> {
    vec![
        json!({
            "name": "watch_add",
            "description": "Wake a chat once, with one ordinary message, when one of these sessions ends a turn, asks for permission or closes: a coordinator's way to learn a worker is done or blocked without polling. The daemon keeps the watch and the wake it owes across restarts and a recipient's outage, and removes the watch after its wake is delivered. Returns the watch id.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "sessions": {"type": "array", "items": {"type": "string"}, "minItems": 1, "description": "The sessions to watch: names, ids or host/name. Not with terminal."},
                    "terminal": {"type": "string", "description": "A cmux terminal (term_<id> or its name) to watch instead of sessions: wakes the chat once with the exact exit status (exit <code>, or signal <n> (<NAME>)) when its process ends. Use until [\"exit\"]."},
                    "to": {"type": "string", "description": "The session to wake (default: this chat)."},
                    "until": {"type": "array", "items": {"type": "string", "enum": ["ready", "permission", "done", "closed", "exit"]}, "description": "States that wake it (default ready and permission; exit, the only one, for terminal)."},
                    "match": {"type": "string", "description": "Only a turn whose transcript contains this text wakes it, such as BLOCKER."}
                }
            }
        }),
        json!({
            "name": "watch_ls",
            "description": "List the watches on this machine and the wakes they still owe: a wake is listed with its outbox state (queued, delivering, failed) until the recipient accepts it.",
            "inputSchema": {"type": "object", "properties": {}}
        }),
        json!({
            "name": "watch_rm",
            "description": "Remove a watch: it makes no new wake. Wakes it already owes are still delivered; the answer says how many.",
            "inputSchema": {
                "type": "object",
                "properties": {"id": {"type": "string", "description": "The watch id from watch_add or watch_ls."}},
                "required": ["id"]
            }
        }),
    ]
}

/// The request for a call, or the refusal the agent reads.
pub(super) fn request(name: &str, args: &Value) -> Result<(&'static str, Value), String> {
    let strings = |key: &str| -> Result<Vec<String>, String> {
        match args.get(key) {
            None | Some(Value::Null) => Ok(vec![]),
            Some(Value::Array(items)) => items
                .iter()
                .map(|v| v.as_str().map(str::to_owned).ok_or(format!("{key} must be strings")))
                .collect(),
            Some(_) => Err(format!("{key} must be an array of strings")),
        }
    };
    match name {
        "watch_add" => {
            let sessions = strings("sessions")?;
            if sessions.is_empty() {
                return Err("sessions or terminal is required: what to watch".to_owned());
            }
            let params = crate::cli::watch::add_params(
                sessions,
                arg(args, "to").map(str::to_owned),
                strings("until")?,
                arg(args, "match").map(str::to_owned),
            );
            Ok((method::MUX_WATCH_ADD, params))
        }
        "watch_rm" => {
            let id = arg(args, "id").ok_or("id is required")?;
            Ok((method::MUX_WATCH_RM, json!({"id": id})))
        }
        _ => Ok((method::MUX_WATCH_LS, json!({}))),
    }
}

pub(super) async fn call(daemon: &Arc<Client>, name: &str, args: &Value) -> Value {
    if name == "watch_add"
        && let Some(terminal) = arg(args, "terminal")
    {
        if args.get("sessions").is_some_and(|sessions| !sessions.is_null()) {
            return error_result("give sessions or terminal, not both".to_owned());
        }
        let until: Vec<String> = args
            .get("until")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(str::to_owned)
            .collect();
        let to = arg(args, "to").map(str::to_owned);
        return match crate::cli::watch::terminal_watch(terminal, to, &until).await {
            Ok(hook) => ok(crate::cli::watch::terminal_text(&hook), hook),
            Err(error) => error_result(error),
        };
    }
    let (m, params) = match request(name, args) {
        Ok(r) => r,
        Err(e) => return error_result(e),
    };
    match daemon.request(m, params).await {
        Ok(reply) => ok(crate::cli::watch::text(m, &reply), reply),
        Err(e) => refusal(e),
    }
}
