//! `acpmux acpmux-mcp`: the `acpmux` MCP stdio server every local agent session gets
//! (`agent_tools.rs`), the same on every harness: message another session (a lane, a
//! coordinator, a chat on a peer) and read the sessions, instead of piping text into `acpmux
//! send` in a shell, which a chat draws as a command block. Behind the `cmux` server its tools
//! are `acpmux_send`, `acpmux_ls`, `acpmux_last` and `acpmux_info`.
//!
//! Each tool is the request the agent's own `acpmux` CLI makes, over a connection that carries
//! the session's caller token from this server's env (`hub/person.rs` (a)), on this daemon's
//! socket only. So it can do nothing that CLI cannot, and the daemon records a message it sends
//! as that session's (`session_message`, `prompt_provenance.rs`), never as the person's words.
//! A remote-origin session gets no tools at all (`agent_tools::left_out`).

use std::sync::Arc;
use std::time::Duration;

use crate::cli::output::{PromptId, last_replies};
use crate::client::Client;
use crate::rpc::method;
use crate::secret_mcp::error_result;
use anyhow::Result;
use serde_json::{Value, json};

pub const SERVER_NAME: &str = "acpmux";
/// The session the tools act for, set in this server's env with its caller token.
pub const SESSION_ENV: &str = "ACPMUX_SESSION_ID";
/// How long `send` asks the outbox to wait for the delivery to settle before it answers that the
/// message is on its way: well under the shortest MCP tool timeout of the harnesses (Codex: 60 s).
/// The daemon's outbox (`server/outbox.rs`) goes on delivering after that, retrying a peer that
/// is down and across a restart; nothing in this server waits on it.
const STATUS_WAIT: Duration = Duration::from_secs(5);
/// Most replies `last` returns.
const MAX_LAST: u64 = 20;

fn tools() -> Value {
    json!([
        {
            "name": "send",
            "description": "Message another agent session: a lane, a coordinator, or a chat on a peer (host/name). Use it instead of running `acpmux send` in a shell. It goes through this daemon's outbox, like `acpmux send --no-wait`: it returns within seconds with the message's promptId and delivery id, and a slow target or a peer that is down is retried; it does not wait for a reply (read one later with last). The receiver's chat shows the message as yours. By default it steers: an agent in the middle of a turn reads it at its next tool step; steer: false queues it behind that turn.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "to": {"type": "string", "description": "The session: its name, id, or host/name for a session on a peer (as ls lists them)."},
                    "text": {"type": "string", "description": "The message, self-contained."},
                    "steer": {"type": "boolean", "description": "true (default): into a running turn at its next tool step. false: queued behind the running turn."}
                },
                "required": ["to", "text"]
            }
        },
        {
            "name": "ls",
            "description": "List the agent sessions on this machine and its peers, one line each: name, state and title. Use it to find the session to message.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "status": {"type": "string", "description": "Only sessions in this state: running, ready, idle, closed or waiting."}
                }
            }
        },
        {
            "name": "last",
            "description": "Read another session's last replies, newest last: what a lane said after your message.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "The session's name, id, or host/name."},
                    "count": {"type": "integer", "minimum": 1, "maximum": MAX_LAST, "description": "How many replies (default 1)."}
                },
                "required": ["name"]
            }
        },
        {
            "name": "info",
            "description": "One session's state: whether a turn runs, what is queued, pending permissions, its folder and agent.",
            "inputSchema": {
                "type": "object",
                "properties": {"name": {"type": "string", "description": "The session's name, id, or host/name."}},
                "required": ["name"]
            }
        }
    ])
}

/// Runs the server on stdin and stdout.
pub async fn run() -> Result<()> {
    crate::secret_mcp::serve(
        SERVER_NAME,
        SESSION_ENV,
        tools(),
        None,
        |daemon, _session, params| async move { call(&daemon, &params).await },
    )
    .await
}

fn ok(text: String, structured: Value) -> Value {
    json!({"content": [{"type": "text", "text": text}], "structuredContent": structured, "isError": false})
}

fn refusal(e: anyhow::Error) -> Value {
    error_result(format!("{e:#}"))
}

fn arg<'a>(args: &'a Value, key: &str) -> Option<&'a str> {
    args.get(key).and_then(Value::as_str).map(str::trim).filter(|v| !v.is_empty())
}

pub(crate) async fn call(daemon: &Arc<Client>, params: &Value) -> Value {
    let args = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
    if !args.is_object() {
        return error_result("arguments must be an object".to_owned());
    }
    match params["name"].as_str().unwrap_or_default() {
        "send" => send(daemon, &args).await,
        "ls" => ls(daemon, &args).await,
        "last" => {
            let Some(name) = arg(&args, "name") else {
                return error_result("name is required".to_owned());
            };
            let count = args.get("count").and_then(Value::as_u64).unwrap_or(1).clamp(1, MAX_LAST);
            let id = match crate::cli::run::resolve_id(daemon, name).await {
                Ok(id) => id,
                Err(e) => return refusal(e),
            };
            match last_replies(daemon, &id, count as usize).await {
                Ok(replies) if replies.is_empty() => ok(
                    format!("{name} has not replied yet."),
                    json!({"sessionId": id, "replies": []}),
                ),
                Ok(replies) => {
                    ok(replies.join("\n\n---\n\n"), json!({"sessionId": id, "replies": replies}))
                }
                Err(e) => refusal(e),
            }
        }
        "info" => {
            let Some(name) = arg(&args, "name") else {
                return error_result("name is required".to_owned());
            };
            let id = match crate::cli::run::resolve_id(daemon, name).await {
                Ok(id) => id,
                Err(e) => return refusal(e),
            };
            match daemon.request(method::MUX_INFO, json!({"sessionId": id})).await {
                Ok(r) => ok(serde_json::to_string_pretty(&r).unwrap_or_default(), r),
                Err(e) => refusal(e),
            }
        }
        other => error_result(format!("unknown tool: {other}")),
    }
}

/// `send`: what `acpmux send --no-wait` does (`cli/run/send_async.rs`): the message goes to this
/// daemon's outbox (`_acpmux/send_queue`), which delivers it as this session (its caller token)
/// and retries a slow target or a peer that is down. It answers with the delivery once it
/// settles, or after [`STATUS_WAIT`] with the message on its way.
async fn send(daemon: &Arc<Client>, args: &Value) -> Value {
    let (Some(to), Some(text)) = (arg(args, "to"), args.get("text").and_then(Value::as_str)) else {
        return error_result("to and text are required".to_owned());
    };
    if text.trim().is_empty() {
        return error_result("text is empty".to_owned());
    }
    let steer = args.get("steer").and_then(Value::as_bool).unwrap_or(true);
    let key = match crate::cli::orchestrate::expand_session_key(to) {
        Ok(key) => key,
        Err(e) => return refusal(e),
    };
    let prompt = PromptId::new(None);
    let request = prompt.params(&key, text, steer, None);
    let queued = match daemon.request(method::MUX_SEND_QUEUE, json!({"request": request})).await {
        Ok(queued) => queued,
        Err(e) => return refusal(e),
    };
    let delivery = queued.get("deliveryId").and_then(Value::as_str).unwrap_or_default().to_owned();
    let wait = json!({"deliveryId": delivery, "waitMs": STATUS_WAIT.as_millis() as u64});
    let status = daemon.request(method::MUX_SEND_STATUS, wait).await.unwrap_or(queued);
    let state = status.get("status").and_then(Value::as_str).unwrap_or("queued").to_owned();
    // A refusal the target gave at once (its folder's trust, a paused agent pair) is this
    // send's error, as `acpmux send --no-wait` says it.
    if matches!(state.as_str(), "failed" | "held") {
        let error = status.get("error").and_then(Value::as_str).unwrap_or("delivery failed");
        return error_result(format!("Not sent to {to} (delivery {delivery}): {error}"));
    }
    let accepted = status.get("accepted").cloned().unwrap_or(Value::Null);
    let prompt_id = prompt.id.clone();
    let session_id = accepted.get("sessionId").cloned().unwrap_or_else(|| json!(key));
    let mut structured = json!({"deliveryId": delivery, "target": key, "sessionId": session_id,
        "promptId": prompt_id, "status": state, "accepted": accepted});
    if state != "delivered" {
        structured["delivery"] = json!("sending");
        return ok(
            format!(
                "On its way to {to} (delivery {delivery}, promptId {prompt_id}): this daemon keeps \
delivering it, retrying while the target is slow or its peer is down. Do not send it again; info \
{to} shows it once it arrives."
            ),
            structured,
        );
    }
    let steered = accepted.get("steer") == Some(&json!(true));
    let waits = accepted.get("queued") == Some(&json!(true));
    let (how_id, how) = if steered {
        ("next_step", "steered into its running turn: it reads it at its next tool step")
    } else if waits {
        ("queued", "queued behind its running turn: it reads it when that turn ends")
    } else {
        ("started", "it started a turn with it")
    };
    structured["delivery"] = json!(how_id);
    ok(format!("Sent to {to}: {how} (promptId {prompt_id})."), structured)
}

/// `ls`: `acpmux ls` as one line per session.
async fn ls(daemon: &Arc<Client>, args: &Value) -> Value {
    let all = match daemon.request(method::MUX_SESSIONS, json!({})).await {
        Ok(v) => v,
        Err(e) => return refusal(e),
    };
    let status = arg(args, "status");
    let rows: Vec<Value> = all["sessions"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|s| status.is_none_or(|want| s["status"].as_str() == Some(want)))
        .cloned()
        .collect();
    if rows.is_empty() {
        return ok("No sessions.".to_owned(), json!({"sessions": []}));
    }
    let field = |s: &Value, k: &str| s[k].as_str().unwrap_or_default().to_owned();
    let lines: Vec<String> = rows
        .iter()
        .map(|s| {
            let name = match (s["peer"].as_str(), field(s, "name")) {
                (Some(peer), name) if !peer.is_empty() && !name.contains('/') => {
                    format!("{peer}/{name}")
                }
                (_, name) => name,
            };
            let title = s["title"].as_str().filter(|t| !t.is_empty());
            match title {
                Some(title) => format!("{name}  [{}]  {title}", field(s, "status")),
                None => format!("{name}  [{}]", field(s, "status")),
            }
        })
        .collect();
    ok(lines.join("\n"), json!({"sessions": rows}))
}

#[cfg(test)]
#[path = "acpmux_mcp_tests.rs"]
mod tests;
