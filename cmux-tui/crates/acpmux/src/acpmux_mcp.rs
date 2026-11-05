//! `acpmux acpmux-mcp`: the `acpmux` MCP stdio server every local agent session gets
//! (`agent_tools.rs`), the same on every harness: message another session (a lane, a
//! coordinator, a chat on a peer) and read the sessions, instead of piping text into `acpmux
//! send` in a shell, which a chat draws as a command block. Behind the `cmux` server its tools
//! are `acpmux_send`, `acpmux_ls`, `acpmux_last`, `acpmux_info`, `acpmux_search` (a
//! session's messages holding some words, `session_search.rs`) and the team mailbox tools
//! (`team_send`, `team_inbox`, `team_ack`). It also runs the chat's
//! background tasks under the daemon (`bg_start`, `bg_list`, `bg_output`, `bg_stop`,
//! `acpmux_mcp_bg.rs`), so they outlive a hibernated agent, and reads a pull request's state
//! in one condensed call (`pr_state`, `acpmux_mcp_pr.rs`), and ends a turn with the next-step
//! box the person sees under the answer (`wrap_up`, `acpmux_mcp_wrap_up.rs`). `github_status` names the GitHub
//! account cmux can see, never a token (`github_status.rs`). With a cmux sign-in it also saves,
//! searches, lists and reads the person's cmux artifacts (`artifact_*`, `acpmux_mcp_artifacts.rs`).
//!
//! Each tool is the request the agent's own `acpmux` CLI makes, over a connection that carries
//! the session's caller token from this server's env (`hub/person.rs` (a)), on this daemon's
//! socket only. So it can do nothing that CLI cannot, and the daemon records a message it sends
//! as that session's (`session_message`, `prompt_provenance.rs`), never as the person's words.
//! `pr_state` alone is not a daemon request: it runs the agent's own `gh` (one `gh pr view`),
//! with this server's environment, which the agent gave it.
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
/// How every chat with the background tools is asked to pace its work: the reads and searches a
/// task already needs go out as one batch, and a bg_start task runs while the agent goes on.
/// Some chats did read early and concurrently and others went one call at a time on the same
/// model (Leo, 2026-11-04); the harness prompts allow both, so cmux says which it wants.
const PARALLEL_STEER: &str = "Work in parallel: at the start of a task, read the files and run \
the searches you already know you need as one batch of independent tool calls, not one after \
another, and while a bg_start task runs, go on with the parts that do not need its result.";
/// Most replies `last` returns.
const MAX_LAST: u64 = 20;
/// How many sessions `ls` lists unless asked for another `limit`, and the most it lists: a fleet
/// holds thousands of sessions (8,636 on one Mac, 29 MB as whole rows), and a reply that large
/// closed the MCP connection of every harness that asked for it.
const LS_DEFAULT_LIMIT: usize = 100;
const LS_MAX_LIMIT: usize = 500;
/// The fields of a session `ls` answers with in `structuredContent`; `info` has the rest.
const LS_FIELDS: &[&str] =
    &["name", "status", "title", "peer", "sessionId", "harness", "cwd", "updatedAt"];

#[path = "acpmux_mcp_artifacts.rs"]
pub(crate) mod artifacts;
#[path = "acpmux_mcp_bg.rs"]
mod bg;
#[path = "acpmux_mcp_pr.rs"]
mod pr;
#[path = "acpmux_mcp_send.rs"]
mod send;
#[path = "acpmux_mcp_who_else.rs"]
mod who_else;
#[path = "acpmux_mcp_wrap_up.rs"]
mod wrap_up;

fn tools() -> Value {
    let mut all = base_tools();
    if let Some(list) = all.as_array_mut() {
        list.extend(bg::tools());
        list.push(pr::tool());
        list.push(wrap_up::tool());
        list.push(who_else::tool());
    }
    all
}

/// What `tools/list` answers: [`tools`], and the artifact tools when this daemon has a cmux
/// sign-in for them (`artifacts::advertised`).
fn tools_with_artifacts(artifacts: bool) -> Value {
    let mut all = tools();
    if artifacts && let Some(list) = all.as_array_mut() {
        list.extend(artifacts::definitions());
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
            "description": "List the agent sessions on this machine and its peers, one line each: name, state and title, newest first. Closed sessions are left out unless status is closed, and the list stops at limit and says how many more match. Use it to find the session to message.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "status": {"type": "string", "description": "Only sessions in this state: running, ready, idle, waiting, disconnected or closed."},
                    "query": {"type": "string", "description": "Only sessions whose name, title or peer contains this text (any case)."},
                    "limit": {"type": "integer", "minimum": 1, "maximum": LS_MAX_LIMIT, "description": "Most sessions to list (default 100)."}
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
        },
        {
            "name": "search",
            "description": "Find a session's messages (prompts, replies, tool titles) holding every word of a query, newest first, from acpmux's index of its log: use it instead of grepping a transcript. Your own session unless name says another; role assistant finds what you yourself wrote earlier.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "The words to find, in any case and order, within one message."},
                    "name": {"type": "string", "description": "The session's name, id, or host/name (default: this chat)."},
                    "role": {"type": "string", "enum": ["user", "assistant", "tool"], "description": "Only prompts, replies or tool titles."},
                    "limit": {"type": "integer", "minimum": 1, "maximum": crate::session_search::MAX_LIMIT, "description": "At most this many hits (default 20)."}
                },
                "required": ["query"]
            }
        }
    ]);
    if let Some(list) = all.as_array_mut() {
        list.insert(0, send::tool());
        list.push(crate::github_status::definition());
    }
    all
}

/// The tools a session may use here: every one, or under a `CMUX_MCP_TOOLS` allowlist (a
/// Chief turn's, `agent_tools::scoped`) only those it names as `acpmux_<tool>`, the name the
/// folding `cmux` server gives each. Folded, `cmux` applies the same list; standalone (cmux
/// off or missing) this is the only filter, so `bg_*` and `team_*` reach no turn that does not
/// list them, whatever the harness.
fn allowed(all: Value, allow: Option<&str>) -> Value {
    let Some(allow) = allow else { return all };
    let allow: Vec<String> = allow.split(',').map(|t| t.trim().to_owned()).collect();
    let keep = |tool: &Value| {
        tool["name"].as_str().is_some_and(|n| allow.contains(&format!("{SERVER_NAME}_{n}")))
    };
    Value::Array(all.as_array().into_iter().flatten().filter(|t| keep(t)).cloned().collect())
}

/// The server's instructions: the background and parallel steers where the background tools are
/// listed, and the GitHub one where `github_status` is.
fn instructions(tools: &Value) -> Option<String> {
    let mut parts = Vec::new();
    if crate::mcp_hint::names(tools).any(|n| bg::TOOLS.contains(&n)) {
        parts.push(BG_STEER);
        parts.push(PARALLEL_STEER);
    }
    if crate::mcp_hint::names(tools).any(|n| n == crate::github_status::TOOL) {
        parts.push(crate::github_status::STEER);
    }
    if crate::mcp_hint::names(tools).any(|n| n == wrap_up::NAME) {
        parts.push(wrap_up::STEER);
    }
    if crate::mcp_hint::names(tools).any(|n| n == who_else::NAME) {
        parts.push(who_else::STEER);
    }
    (!parts.is_empty()).then(|| parts.join(" "))
}

/// Runs the server on stdin and stdout.
pub async fn run() -> Result<()> {
    // Read once: a sign-in or `artifacts.enabled` change reaches the next chat's server.
    let artifacts = artifacts::from_config();
    let allow = std::env::var(crate::agent_tools::MCP_TOOLS_ENV).ok();
    let tools = allowed(tools_with_artifacts(artifacts.is_some()), allow.as_deref());
    // Under an allowlist, a call outside it is refused like an unknown tool.
    let names: Option<Arc<Vec<String>>> = allow
        .is_some()
        .then(|| Arc::new(crate::mcp_hint::names(&tools).map(str::to_owned).collect()));
    // The background steer only where the background tools are listed.
    let steer = instructions(&tools);
    crate::secret_mcp::serve(
        SERVER_NAME,
        SESSION_ENV,
        tools,
        steer,
        move |daemon, session, params| {
            let artifacts = artifacts.clone();
            let names = names.clone();
            async move {
                let name = params.get("name").and_then(Value::as_str).unwrap_or_default();
                if let Some(names) = &names
                    && !names.iter().any(|n| n == name)
                {
                    return error_result(crate::mcp_hint::unknown_tool(
                        name,
                        names.iter().map(String::as_str),
                    ));
                }
                let args = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
                if artifacts::TOOLS.contains(&name) {
                    return match (&artifacts, args.is_object()) {
                        (_, false) => error_result("arguments must be an object".to_owned()),
                        (Some(client), true) => artifacts::call(client, name, &args).await,
                        (None, true) => error_result(
                            "the artifact tools need a cmux sign-in on this daemon (meshRelay), and artifacts.enabled not false".to_owned(),
                        ),
                    };
                }
                if bg::TOOLS.contains(&name) {
                    return bg::call(&daemon, &session, name, &args).await;
                }
                if name == pr::NAME {
                    return pr::call(&daemon, &session, &args).await;
                }
                if name == wrap_up::NAME {
                    return wrap_up::call(&args);
                }
                if name == who_else::NAME {
                    return who_else::call(&daemon, &session, &args).await;
                }
                if name == crate::github_status::TOOL {
                    let sources = crate::github_status::Sources::current();
                    let status = crate::github_status::resolve(&sources).await;
                    return crate::github_status::result(&status);
                }
                if matches!(name, "inbox_read" | "inbox_reply") {
                    return inbox_tool(&daemon, &session, name, &args).await;
                }
                if name == "search" {
                    return search_tool(&daemon, &session, &args).await;
                }
                call(&daemon, &params).await
            }
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
/// caller token and team-messaging gate, so this MCP surface cannot bypass either one.
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

/// `search`: one session's messages holding every word of `query` (`session_search.rs`), this
/// server's own chat unless `name` names another.
pub(crate) async fn search_tool(daemon: &Arc<Client>, session: &str, args: &Value) -> Value {
    let Some(query) = arg(args, "query") else {
        return error_result("query is required".to_owned());
    };
    let id = match arg(args, "name") {
        Some(name) => match crate::cli::run::resolve_id(daemon, name).await {
            Ok(id) => id,
            Err(e) => return refusal(e),
        },
        None if session.is_empty() => {
            return error_result("this server runs in no acpmux chat: name a session".to_owned());
        }
        None => session.to_owned(),
    };
    let params = json!({
        "sessionId": id,
        "query": query,
        "role": args.get("role"),
        "limit": args.get("limit"),
    });
    match daemon.request(method::MUX_SESSION_SEARCH, params).await {
        Ok(r) => {
            let hits = r.get("hits").and_then(Value::as_array).cloned().unwrap_or_default();
            let text = if hits.is_empty() {
                "No message holds every word.".to_owned()
            } else {
                hits.iter()
                    .map(|h| {
                        format!(
                            "seq {} ({}): {}",
                            h.get("seq").and_then(Value::as_u64).unwrap_or(0),
                            h.get("role").and_then(Value::as_str).unwrap_or(""),
                            h.get("snippet").and_then(Value::as_str).unwrap_or(""),
                        )
                    })
                    .collect::<Vec<_>>()
                    .join("\n")
            };
            ok(text, r)
        }
        Err(e) => refusal(e),
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
    // Closed sessions are most of a fleet's list; the daemon leaves them out unless asked for.
    let params = match arg(args, "status") {
        Some("closed") => json!({}),
        _ => json!({"excludeStatus": ["closed"]}),
    };
    match daemon.whole_list(method::MUX_SESSIONS, params).await {
        Ok(mut all) => {
            // The other machines' sessions a host with no peer to them lists through its send
            // relay (`cli/send_relay.rs` lsArgv), as `acpmux ls` does.
            let far = crate::cli::send_relay::relay_rows(true).await;
            if !far.is_empty()
                && let Some(rows) = all.get_mut("sessions").and_then(Value::as_array_mut)
            {
                crate::cli::send_relay::merge_rows(rows, far);
            }
            ls_result(&all, args)
        }
        Err(e) => refusal(e),
    }
}

/// What `ls` answers for the daemon's whole list: the sessions `status` and `query` keep (closed
/// ones only when `status` asks for them), newest first, at most `limit`, each as its
/// [`LS_FIELDS`], and how many more there were.
fn ls_result(all: &Value, args: &Value) -> Value {
    let status = arg(args, "status");
    let query = arg(args, "query").map(str::to_lowercase);
    let limit = args
        .get("limit")
        .and_then(Value::as_u64)
        .map_or(LS_DEFAULT_LIMIT, |n| (n as usize).clamp(1, LS_MAX_LIMIT));
    let field = |s: &Value, k: &str| s[k].as_str().unwrap_or_default().to_owned();
    let mut rows: Vec<&Value> = all["sessions"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|s| match status {
            Some(want) => s["status"].as_str() == Some(want),
            None => s["status"].as_str() != Some("closed"),
        })
        .filter(|s| {
            query.as_deref().is_none_or(|q| {
                ["name", "title", "peer"].iter().any(|k| field(s, k).to_lowercase().contains(q))
            })
        })
        .collect();
    if rows.is_empty() {
        return ok("No sessions.".to_owned(), json!({"sessions": [], "more": 0}));
    }
    rows.sort_by_key(|s| std::cmp::Reverse(s["updatedAt"].as_u64().unwrap_or(0)));
    let more = rows.len().saturating_sub(limit);
    rows.truncate(limit);
    let mut lines: Vec<String> = rows
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
    if more > 0 {
        lines.push(format!(
            "… {more} more: raise limit (up to {LS_MAX_LIMIT}), narrow with query, or pass status (closed lists the closed ones)."
        ));
    }
    let slim: Vec<Value> = rows
        .iter()
        .map(|s| {
            let row: serde_json::Map<String, Value> = LS_FIELDS
                .iter()
                .filter_map(|k| {
                    s.get(*k).filter(|v| !v.is_null()).map(|v| ((*k).to_owned(), v.clone()))
                })
                .collect();
            Value::Object(row)
        })
        .collect();
    ok(lines.join("\n"), json!({"sessions": slim, "more": more}))
}

#[cfg(test)]
#[path = "acpmux_mcp_tests.rs"]
mod tests;
