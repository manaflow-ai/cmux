//! `acpmux acpmux-mcp`: the `acpmux` MCP stdio server every local agent session gets
//! (`agent_tools.rs`), the same on every harness: message another session (a lane, a
//! coordinator, a chat on a peer) and read the sessions, instead of piping text into `acpmux
//! send` in a shell, which a chat draws as a command block. Behind the `cmux` server its tools
//! are `acpmux_send`, `acpmux_ls`, `acpmux_last`, `acpmux_info` and the Labs-gated
//! team mailbox tools (`team_send`, `team_inbox`, `team_ack`). It also runs the chat's
//! background tasks under the daemon (`bg_start`, `bg_list`, `bg_output`, `bg_stop`,
//! `acpmux_mcp_bg.rs`), so they outlive a hibernated agent.
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
/// What every chat with this server is told about background work: the Codex steer (its
/// unified exec background terminals end when the agent hibernates, and only the whole feature
/// can be turned off), and Claude Code's, behind the PreToolUse hook (`bg_hook.rs`).
const BG_STEER: &str = "Long-running commands (a dev server, a watcher, a long build or test \
run): start them with bg_start, not as a background shell or terminal of your own. This chat's \
agent hibernates after 2 idle minutes and its own background shells end with it; a bg_start task \
keeps running, and bg_list and bg_output read it later by its id.";
/// Most replies `last` returns.
const MAX_LAST: u64 = 20;

#[path = "acpmux_mcp_bg.rs"]
mod bg;
#[path = "acpmux_mcp_send.rs"]
mod send;

fn tools() -> Value {
    let mut all = base_tools();
    if let Some(list) = all.as_array_mut() {
        list.extend(bg::tools());
    }
    all
}

fn base_tools() -> Value {
    let mut all = json!([
        {
            "name": "inbox_read",
            "description": "Read this chat's inbox: other agents' messages, in threads. They never take a turn of yours and need none: a notice lists threads with new messages at your next tool step; act on one when it bears on your work, answer it with inbox_reply, or leave it for later. With thread, that thread's messages whole, newest first, marked read; without it, every thread with its unread count.",
            "inputSchema": {
                "type": "object",
                "properties": {"thread": {"type": "string", "description": "A threadId, as the notice or the list names it."}}
            }
        },
        {
            "name": "inbox_reply",
            "description": "Answer in an inbox thread: the message goes to the thread's newest sender, into their inbox under the same thread, and takes no turn of theirs.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "thread": {"type": "string", "description": "The threadId."},
                    "text": {"type": "string", "description": "The answer, self-contained."}
                },
                "required": ["thread", "text"]
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
        },
        {
            "name": "team_send",
            "description": "Send an information message to a teammate's agent or a team role. Addresses are team-scoped (for example @lawrence/coordinator or @team/reviewer). The receipt includes the hub's resolution and whether the message may start work; a normal message never starts work automatically.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "to": {"type": "string", "description": "A team address such as @member/agent or @team/role."},
                    "body": {"type": "string", "description": "The information to deliver."}
                },
                "required": ["to", "body"]
            }
        },
        {
            "name": "team_inbox",
            "description": "List durable messages addressed to this agent's team address. Messages are information by default and are delivered when the agent reaches its next turn boundary.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "unreadOnly": {"type": "boolean", "description": "Only messages that have not been read or acknowledged (default true)."},
                    "before": {"type": "integer", "minimum": 0, "description": "Continue from a previous response's next cursor."}
                }
            }
        },
        {
            "name": "team_ack",
            "description": "Acknowledge a team message after reading it. The acknowledgement is recorded by the team hub.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "id": {"type": "string", "description": "The hub message id from team_inbox."}
                },
                "required": ["id"]
            }
        }
    ]);
    if let Some(list) = all.as_array_mut() {
        list.insert(0, send::tool());
    }
    all
}

/// Runs the server on stdin and stdout.
pub async fn run() -> Result<()> {
    crate::secret_mcp::serve(
        SERVER_NAME,
        SESSION_ENV,
        tools(),
        Some(BG_STEER.to_owned()),
        |daemon, session, params| async move {
            let name = params.get("name").and_then(Value::as_str).unwrap_or_default();
            let args = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
            if bg::TOOLS.contains(&name) {
                return bg::call(&daemon, &session, name, &args).await;
            }
            if matches!(name, "inbox_read" | "inbox_reply") {
                return inbox_tool(&daemon, &session, name, &args).await;
            }
            call(&daemon, &params).await
        },
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
        "send" => send::send(daemon, &args).await,
        "team_send" => team_send(daemon, &args).await,
        "team_inbox" => team_inbox(daemon, &args).await,
        "team_ack" => team_ack(daemon, &args).await,
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
        other => {
            error_result(crate::mcp_hint::unknown_tool(other, crate::mcp_hint::names(&tools())))
        }
    }
}

/// Send a team-scoped message through the daemon's hub client. The daemon owns the
/// caller token and Labs gate, so this MCP surface cannot bypass either one.
async fn team_send(daemon: &Arc<Client>, args: &Value) -> Value {
    let (Some(to), Some(body)) = (arg(args, "to"), args.get("body").and_then(Value::as_str)) else {
        return error_result("to and body are required".to_owned());
    };
    if body.trim().is_empty() {
        return error_result("body is empty".to_owned());
    }
    match daemon.request(method::MUX_TEAM_SEND, json!({"to": to, "body": body})).await {
        Ok(result) => ok(team_result_text(&result), result),
        Err(e) => refusal(e),
    }
}

/// Read the durable team inbox. `unreadOnly` defaults to true so an agent does not
/// repeatedly receive old information unless it explicitly asks for all messages.
async fn team_inbox(daemon: &Arc<Client>, args: &Value) -> Value {
    let unread_only = args.get("unreadOnly").and_then(Value::as_bool).unwrap_or(true);
    let mut params = json!({"unreadOnly": unread_only});
    if let Some(before) = args.get("before").and_then(Value::as_u64) {
        params["before"] = json!(before);
    }
    match daemon.request(method::MUX_TEAM_INBOX, params).await {
        Ok(result) => ok(team_result_text(&result), result),
        Err(e) => refusal(e),
    }
}

async fn team_ack(daemon: &Arc<Client>, args: &Value) -> Value {
    let Some(id) = arg(args, "id") else {
        return error_result("id is required".to_owned());
    };
    match daemon.request(method::MUX_TEAM_ACK, json!({"id": id})).await {
        Ok(result) => ok(team_result_text(&result), result),
        Err(e) => refusal(e),
    }
}

fn team_result_text(result: &Value) -> String {
    if result.is_string() {
        result.as_str().unwrap_or_default().to_owned()
    } else {
        serde_json::to_string_pretty(result).unwrap_or_else(|_| result.to_string())
    }
}

/// `inbox_read` and `inbox_reply`, for this server's own chat (`hub/inbox.rs`).
async fn inbox_tool(daemon: &Arc<Client>, session: &str, name: &str, args: &Value) -> Value {
    if session.is_empty() {
        return error_result("this server runs in no acpmux chat".to_owned());
    }
    let thread = arg(args, "thread");
    let reply = match (name, thread) {
        ("inbox_reply", Some(thread)) => {
            let Some(text) =
                args.get("text").and_then(Value::as_str).filter(|t| !t.trim().is_empty())
            else {
                return error_result("thread and text are required".to_owned());
            };
            let params = json!({"sessionId": session, "threadId": thread, "text": text});
            daemon.request(method::MUX_INBOX_REPLY, params).await
        }
        ("inbox_reply", None) => return error_result("thread and text are required".to_owned()),
        (_, Some(thread)) => {
            let params = json!({"sessionId": session, "threadId": thread, "markRead": true});
            daemon.request(method::MUX_INBOX_THREAD, params).await
        }
        (_, None) => daemon.request(method::MUX_INBOX_THREADS, json!({"sessionId": session})).await,
    };
    match reply {
        Ok(v) => ok(crate::cli::session_inbox::describe(&v), v),
        Err(e) => refusal(e),
    }
}

/// `send`'s `class` (`prompt_class.rs`), checked here too, so a wrong one is this call's error and
/// not a failed delivery.
fn send_class(args: &Value) -> Result<Option<String>, String> {
    match args.get("class") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(c)) if crate::prompt_class::PromptClass::parse(c).is_some() => {
            Ok(Some(c.clone()))
        }
        Some(_) => Err(format!("class must be one of {}", crate::prompt_class::VALUES)),
    }
}

/// `ls`: `acpmux ls` as one line per session.
async fn ls(daemon: &Arc<Client>, args: &Value) -> Value {
    let all = match daemon.whole_list(method::MUX_SESSIONS, json!({})).await {
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
