//! `acpmux acpmux-mcp`: the `acpmux` MCP stdio server every local agent session gets
//! (`agent_tools.rs`), the same on every harness: message another session (a lane, a
//! coordinator, a chat on a peer) and read the sessions, instead of piping text into a shell,
//! which a chat draws as a command block. The public CLI front door is `cmux agent`; the acpmux
//! engine and its aliases remain available. Behind the `cmux` server its tools
//! are `acpmux_send`, `acpmux_ls`, `acpmux_last`, `acpmux_info`, `acpmux_search` (a
//! session's messages holding some words, `session_search.rs`) and the team mailbox tools
//! (`team_send`, `team_inbox`, `team_ack`, `team_listen`). It also runs the chat's
//! background tasks under the daemon (`bg_start`, `bg_list`, `bg_output`, `bg_stop`,
//! `acpmux_mcp_bg.rs`), so they outlive a hibernated agent, and reads a pull request's state
//! in one condensed call (`pr_state`, `acpmux_mcp_pr.rs`), and ends a turn with the next-step
//! box the person sees under the answer (`wrap_up`, `acpmux_mcp_wrap_up.rs`), and keeps the chat's
//! goal and its done-when on any harness (`goal_set`, `goal_update`, `goal_get`,
//! `acpmux_mcp_goal.rs`), and wakes it when other sessions are done or blocked (`watch_add`,
//! `watch_ls`, `watch_rm`, `acpmux_mcp_watch.rs`), and waits on or stops another session's turn,
//! any session, not only its own sub-sessions (`wait`, `cancel`, `acpmux_mcp_control.rs`).
//! `github_status` names the GitHub account cmux can see, never a token (`github_status.rs`). With a cmux sign-in it also saves,
//! searches, lists and reads the person's cmux artifacts (`artifact_*`, `acpmux_mcp_artifacts.rs`).
//!
//! Each tool is the request the agent's own `acpmux` CLI makes, over a connection that carries
//! the session's caller token from this server's env (`hub/person.rs` (a)), on this daemon's
//! socket only. So it can do nothing that CLI cannot, and the daemon records a message it sends
//! as that session's (`session_message`, `prompt_provenance.rs`), never as the person's words.
//! `pr_state` and `pr_wait` read through the daemon's one GitHub poller for the machine
//! (`pr_poller.rs`); `pr_state` falls back to the agent's own `gh` (one `gh pr view`), with this
//! server's environment, which the agent gave it, when the daemon cannot answer.
//! A remote-origin session gets no tools at all (`agent_tools::left_out`). An app outside
//! acpmux (Claude desktop, Claude Code, Codex) linked with `acpmux desktop link` runs it in guest
//! mode (`acpmux_mcp_guest.rs`): the tools that need no session, plus `machines` and `new`.

use std::sync::Arc;
use std::time::Duration;

use crate::cli::output::{PromptId, last_replies};
use crate::client::Client;
use crate::rpc::method;
use crate::secret_mcp::error_result;
use anyhow::Result;
use serde_json::{Value, json};

pub use crate::acpmux_mcp_names::{SERVER_NAME, SESSION_ENV};
/// How long `send` asks the outbox to wait for the delivery to settle before it answers that the
/// message is on its way: well under the shortest MCP tool timeout of the harnesses (Codex: 60 s).
/// The daemon's outbox (`server/outbox.rs`) goes on delivering after that, retrying a peer that
/// is down and across a restart; nothing in this server waits on it.
const STATUS_WAIT: Duration = Duration::from_secs(5);
/// What every chat with this server is told about background work: the Codex steer (its
/// unified exec background terminals end when the agent hibernates, and only the whole feature
/// can be turned off), and Claude Code's, behind the PreToolUse hook (`bg_hook.rs`).
const BG_STEER: &str = "Start long-running commands (dev servers, watchers, long builds or tests) \
with bg_start, not a background shell of your own, which ends when this chat's agent hibernates \
after 2 idle minutes; bg_output reads it later.";
/// How every chat with the background tools is asked to pace its work: the reads and searches a
/// task already needs go out as one batch, and a bg_start task runs while the agent goes on.
/// Some chats did read early and concurrently and others went one call at a time on the same
/// model (Leo, 2026-11-04); the harness prompts allow both, so cmux says which it wants.
const PARALLEL_STEER: &str = "Run the reads and searches you already know you need as one batch \
of independent tool calls, and keep working while a bg_start task runs.";
/// Most replies `last` returns.
const MAX_LAST: u64 = 20;
/// How many sessions `ls` lists unless asked for another `limit`, and the most it lists: a fleet
/// holds thousands of sessions (8,636 on one Mac, 29 MB as whole rows), and a reply that large
/// closed the MCP connection of every harness that asked for it.
const LS_DEFAULT_LIMIT: usize = 100;
const LS_MAX_LIMIT: usize = 500;
/// The fields of a session `ls` answers with in `structuredContent`; `info` has the rest.
const LS_FIELDS: &[&str] = &[
    "name",
    "status",
    "title",
    "peer",
    "sessionId",
    "harness",
    "cwd",
    "updatedAt",
    "asOfMs",
    "via",
];

#[path = "acpmux_mcp_artifacts.rs"]
pub(crate) mod artifacts;
#[path = "acpmux_mcp_bg.rs"]
pub(crate) mod bg;
#[path = "acpmux_mcp_bg_list.rs"]
mod bg_list;
#[path = "acpmux_mcp_bridge.rs"]
pub(crate) mod bridge;
#[path = "acpmux_mcp_goal.rs"]
mod goal;
#[path = "acpmux_mcp_guest.rs"]
mod guest;
#[path = "acpmux_mcp_pr.rs"]
pub(crate) mod pr;
/// `pr_state`'s parse of a pull request, which the daemon's poller reads too (`pr_poller.rs`).
pub(crate) use pr::pr_state;
#[path = "acpmux_mcp_control.rs"]
mod control;
#[path = "acpmux_mcp_machine.rs"]
mod machine;
#[path = "acpmux_mcp_race.rs"]
mod race;
#[path = "acpmux_mcp_send.rs"]
mod send;
#[path = "acpmux_mcp_send_status.rs"]
mod send_status;
#[path = "acpmux_mcp_watch.rs"]
mod watch;
#[path = "acpmux_mcp_who_else.rs"]
mod who_else;
#[path = "acpmux_mcp_wrap_up.rs"]
mod wrap_up;
/// The most facts a wrap-up offers, and the longest one (`memory_inbox.rs`).
pub(crate) use wrap_up::{MAX_FACT as WRAP_UP_MAX_FACT, MAX_LEARNED as WRAP_UP_MAX_LEARNED};

pub(crate) fn tools() -> Value {
    let mut all = base_tools();
    if let Some(list) = all.as_array_mut() {
        list.extend(bg::tools());
        list.push(pr::tool());
        list.push(pr::wait_tool());
        list.push(wrap_up::tool());
        list.push(who_else::tool());
        list.extend(goal::tools());
        list.extend(watch::tools());
        list.extend(race::tools());
        list.push(send_status::tool());
        list.extend(control::tools());
        list.extend(machine::tools());
        for tool in list.iter_mut() {
            let named = tool.get("name").and_then(Value::as_str);
            if named.is_some_and(|n| ALWAYS_LOADED.contains(&n)) {
                tool["_meta"] = json!({"anthropic/alwaysLoad": true});
            }
        }
    }
    all
}

/// The tools a chat calls in most turns, marked `_meta["anthropic/alwaysLoad"]` so Claude Code
/// puts their schemas in the prompt instead of deferring them behind ToolSearch. Measured on
/// fs-agent-lane-7 in the 24 h to 2026-11-23T11:00Z: 147 ToolSearch calls, each a whole round
/// trip, and these six were 107 of the names they loaded (wrap_up 35, bg_output 21, who_else 20,
/// bg_start 16, inbox_read 11, inbox_reply 4). Their schemas cost a few KB of cached prompt.
pub(crate) const ALWAYS_LOADED: [&str; 6] =
    [wrap_up::NAME, who_else::NAME, "bg_start", "bg_output", "inbox_read", "inbox_reply"];

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
            "description": "List inbox threads with unread counts. Pass thread to read its messages newest first and mark them read. Notices arrive at the next tool step and can wait.",
            "inputSchema": {
                "type": "object",
                "properties": {"thread": {"type": "string", "description": "threadId from a notice or the thread list."}}
            }
        },
        {
            "name": "inbox_reply",
            "description": "Reply to the thread's newest sender in their inbox without starting a turn.",
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
            "name": "machine_info",
            "description": "Report what this machine can do from acpmux's current state: machine and workspace identity, repository, running background work, ports and previews, browser/display support, the environment's verify command, and secret names with status. Secret values are never returned; unavailable capabilities include the next action to take.",
            "inputSchema": {
                "type": "object",
                "properties": {}
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
            "name": "team_listen",
            "description": "Listen on a teammate's agent address (@member/agent) and read what it receives, once its owner granted your user. op open starts a listen (ttlSeconds 60..604800, the hub's default without it), ls lists yours and others' on your addresses, close ends one by id, read pages the messages the address received (newest first; before continues from next).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "op": {"type": "string", "enum": ["open", "ls", "close", "read"]},
                    "to": {"type": "string", "description": "The address, @member/agent (open, read)."},
                    "ttlSeconds": {"type": "integer", "minimum": 60, "maximum": 604800, "description": "How long the listen stays open (open)."},
                    "id": {"type": "string", "description": "The listen id, lsn_... (close)."},
                    "before": {"type": "integer", "minimum": 0, "description": "Continue from a previous read's next cursor (read)."}
                },
                "required": ["op"]
            }
        },
        {
            "name": "search",
            "description": "Find a session's messages (prompts, replies, tool titles) holding every word of a query, newest first, from the acpmux engine's index of its log: use it instead of grepping a transcript. For every authorized session on this host and its peers, use the `cmux agent search` front door. This MCP tool searches your own session unless name says another; role assistant finds what you yourself wrote earlier.",
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
    if crate::mcp_hint::names(tools).any(|n| goal::TOOLS.contains(&n)) {
        parts.push(goal::STEER);
    }
    if crate::mcp_hint::names(tools).any(|n| n == "watch_add") {
        parts.push(watch::STEER);
    }
    (!parts.is_empty()).then(|| parts.join(" "))
}

/// The instructions [`served`] gives with the env [`crate::tool_env`] reads: its tool allowlist
/// decides them (the artifact tools add none), so they are known without the server.
pub(crate) fn env_instructions() -> Option<String> {
    let allow = crate::tool_env::var(crate::agent_tools::MCP_TOOLS_ENV);
    instructions(&allowed(tools_with_artifacts(false), allow.as_deref()))
}

/// Runs the server on stdin and stdout.
pub async fn run() -> Result<()> {
    // Read once: a sign-in or `artifacts.enabled` change reaches the next chat's server.
    let artifacts = artifacts::from_config();
    // An app outside acpmux that `acpmux desktop link` gave this server (`acpmux_mcp_guest.rs`).
    if let Some(app) = std::env::var(crate::desktop_link::GUEST_ENV)
        .ok()
        .map(|a| a.trim().to_owned())
        .filter(|a| !a.is_empty())
    {
        return guest::run(app, artifacts).await;
    }
    crate::tools_mcp::serve(vec![served_with(&Arc::default(), artifacts)?]).await
}

/// The server for the session in its env, its calls on `daemon`'s connection
/// (`tools_mcp.rs`: one process serves it with acpmux's other servers).
pub(crate) fn served(daemon: &Arc<crate::tools_mcp::Daemon>) -> Result<crate::tools_mcp::Served> {
    served_with(daemon, artifacts::from_config())
}

fn served_with(
    daemon: &Arc<crate::tools_mcp::Daemon>,
    artifacts: Option<Arc<artifacts::Artifacts>>,
) -> Result<crate::tools_mcp::Served> {
    let allow = crate::tool_env::var(crate::agent_tools::MCP_TOOLS_ENV);
    let tools = allowed(tools_with_artifacts(artifacts.is_some()), allow.as_deref());
    // Under an allowlist, a call outside it is refused like an unknown tool.
    let names: Option<Arc<Vec<String>>> = allow
        .is_some()
        .then(|| Arc::new(crate::mcp_hint::names(&tools).map(str::to_owned).collect()));
    // The background steer only where the background tools are listed.
    let steer = instructions(&tools);
    crate::tools_mcp::served(
        SERVER_NAME,
        SESSION_ENV,
        tools,
        steer,
        daemon,
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
                // The Claude Code subagent whose tool call this is, by its tool use id
                // (`subagent_call.rs`): a `send` names it, a `bg_start` or `run_wait` task runs as
                // it and brings its end to it. Else the subagent this server runs as: a workflow
                // runner a subagent started marks it (`cli::sender::SUBAGENT_ENV`, set by the
                // daemon in `hub/workflow_runs.rs`), as the Bash hook marks its commands. An
                // agent's own server never has it: the daemon removes every `ACPMUX_*` variable
                // of its own env from a harness's, and the mark from the harness profile's env
                // too (`agent/command.rs`), so only the runner's server can.
                let sub = crate::subagent_call::of_call(&crate::config::home(), &session, &params)
                    .or_else(|| {
                        crate::cli::sender::subagent_of_this_process().map(|s| s.to_value())
                    });
                if bg::TOOLS.contains(&name) {
                    let mut args = args;
                    // Every bg call names its caller: a start runs as it, and a list or stop
                    // acts on its own tasks (`hub::BgScope`). Never the agent's own value.
                    if let Some(fields) = args.as_object_mut() {
                        fields.remove("callerSubagent");
                        if let Some(sub) = &sub {
                            fields.insert("callerSubagent".to_owned(), sub.clone());
                        }
                    }
                    return bg::call(&daemon, &session, name, &args).await;
                }
                if name == pr::NAME {
                    return pr::call(&daemon, &session, &args).await;
                }
                if name == pr::WAIT_NAME {
                    return pr::wait(&daemon, &session, &args).await;
                }
                if name == wrap_up::NAME {
                    return wrap_up::call(&args);
                }
                if name == send_status::NAME {
                    return send_status::call(&daemon, &session, &args).await;
                }
                if name == who_else::NAME {
                    return who_else::call(&daemon, &session, &args).await;
                }
                if goal::TOOLS.contains(&name) {
                    return goal::call(&daemon, &session, name, &args).await;
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
                if name == "machine_info" {
                    return machine_info(&daemon, &session).await;
                }
                if control::TOOLS.contains(&name) {
                    return control::call(&daemon, &session, name, &args).await;
                }
                call_as(&daemon, &params, sub.as_ref()).await
            }
        },
    )
}

async fn machine_info(daemon: &Arc<Client>, session: &str) -> Value {
    match daemon.request(method::MUX_MACHINE_INFO, json!({"sessionId": session})).await {
        Ok(result) => {
            ok(serde_json::to_string_pretty(&result).unwrap_or_else(|_| result.to_string()), result)
        }
        Err(error) => refusal(error),
    }
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

#[cfg(test)]
pub(crate) async fn call(daemon: &Arc<Client>, params: &Value) -> Value {
    call_as(daemon, params, None).await
}

/// A tool call of the acpmux tools below; `sub` is the subagent that makes it
/// (`subagent_call.rs`), which its `send` names.
async fn call_as(daemon: &Arc<Client>, params: &Value, sub: Option<&Value>) -> Value {
    let args = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
    if !args.is_object() {
        return error_result("arguments must be an object".to_owned());
    }
    match params["name"].as_str().unwrap_or_default() {
        "send" => send::send(daemon, &args, sub).await,
        "team_send" => team_send(daemon, &args).await,
        "team_inbox" => team_inbox(daemon, &args).await,
        "team_ack" => team_ack(daemon, &args).await,
        "team_listen" => team_listen(daemon, &args).await,
        "ls" => ls(daemon, &args).await,
        name if watch::TOOLS.contains(&name) => watch::call(daemon, name, &args).await,
        name if race::TOOLS.contains(&name) => race::call(daemon, name, &args).await,
        name if machine::TOOLS.contains(&name) => machine::call(daemon, name, &args).await,
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
            match crate::cli::run::session_info(daemon, name, false).await {
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

/// `team_listen`: the daemon's `_acpmux/team/listen`, with only the params it takes.
async fn team_listen(daemon: &Arc<Client>, args: &Value) -> Value {
    let Some(op) = arg(args, "op") else {
        return error_result("op is required: open, ls, close or read".to_owned());
    };
    let mut params = serde_json::Map::new();
    params.insert("op".to_owned(), json!(op));
    for key in ["to", "ttlSeconds", "id", "before"] {
        if let Some(value) = args.get(key).filter(|value| !value.is_null()) {
            params.insert(key.to_owned(), value.clone());
        }
    }
    let params = Value::Object(params);
    match daemon.request(method::MUX_TEAM_LISTEN, params).await {
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
            match daemon.request(method::MUX_INBOX_REPLY, params).await {
                Err(e) if format!("{e:#}").contains("inbox.no_sender") => {
                    return reply_by_name(daemon, session, thread, text, e).await;
                }
                answered => answered,
            }
        }
        // A reply that names whom it answers (`to`) rather than a thread is a send to them.
        ("inbox_reply", None) if arg(args, "to").is_some() && arg(args, "text").is_some() => {
            let result = send::send(daemon, args, None).await;
            return said(result, "inbox_reply named no thread; sent with send to `to`");
        }
        ("inbox_reply", None) => return error_result("thread and text are required".to_owned()),
        (_, Some(thread)) => {
            let params = json!({"sessionId": session, "threadId": thread, "markRead": true});
            daemon.request(method::MUX_INBOX_THREAD, params).await
        }
        (_, None) => daemon.request(method::MUX_INBOX_THREADS, json!({"sessionId": session})).await,
    };
    match reply {
        Ok(mut v) => {
            // The text line is written from the whole answer, then the answer drops what it said.
            let text = crate::cli::session_inbox::describe(&v);
            trim_threads(&mut v);
            ok(text, v)
        }
        Err(e) => refusal(e),
    }
}

/// What a thread listing says twice, dropped before the reader pays for it. The daemon's
/// `_acpmux/inbox_threads` answers the chat pane too, and the pane reads the whole sender record
/// (`laneNoticeBatches.ts`, `InboxNoticeCard.tsx`); an agent reading `inbox_read` has the sender's
/// shown name in `from` already, replies by `threadId`, and the thread's own read carries each
/// message's sender when it needs more. Measured over 38 real `inbox_read` answers in this host's
/// transcripts: `key` repeats `threadId`, and `threads[].sender` is 13 fields of which most are
/// null — together with this chat's own `sessionId` and the rows left at their default, an answer
/// of 8,470 B becomes 6,344 B, a 25.1% cut (`scripts/measure/inbox-listing-bytes.py`).
fn trim_threads(answer: &mut Value) {
    let Some(o) = answer.as_object_mut() else { return };
    // Not a listing: a thread's own messages keep every sender they name.
    if !o.contains_key("threads") {
        return;
    }
    o.remove("sessionId");
    for row in o.get_mut("threads").and_then(Value::as_array_mut).into_iter().flatten() {
        let Some(row) = row.as_object_mut() else { continue };
        if row.get("key") == row.get("threadId") {
            row.remove("key");
        }
        row.remove("sender");
        // A flag that is off, a count that is none: absence says it, in no bytes.
        row.retain(|k, v| match (k.as_str(), v) {
            ("surgeHeld" | "needYou", v) => v.as_bool() != Some(false),
            ("new" | "unread", v) => v.as_u64() != Some(0),
            _ => true,
        });
    }
}

/// The names an inbox thread's newest sender goes by, newest message first: its relayed
/// `HOST/NAME`, its shown name (`from`), then the name in the thread key (`from:NAME[/pr:N]`,
/// `declared:NAME`). `thread` is `_acpmux/inbox_thread`'s answer.
fn thread_sender_names(thread_key: &str, thread: &Value) -> Vec<String> {
    let mut names: Vec<String> = Vec::new();
    let mut add = |name: Option<&str>| {
        let Some(name) = name.map(str::trim).filter(|n| !n.is_empty()) else { return };
        if !names.iter().any(|n| n == name) {
            names.push(name.to_owned());
        }
    };
    for m in thread.get("messages").and_then(Value::as_array).into_iter().flatten() {
        let relay = m.pointer("/sender/relay");
        let machine = relay.and_then(|r| r.get("machine")).and_then(Value::as_str);
        let session = relay.and_then(|r| r.get("session")).and_then(Value::as_str);
        if let (Some(machine), Some(session)) = (machine, session) {
            add(Some(&format!("{machine}/{session}")));
        }
        // `from` is the shown sender (`hub/inbox.rs` `shown_sender`): a relayed `HOST/NAME`, a
        // declared label or the session's name.
        add(m.get("from").and_then(Value::as_str));
    }
    let key = thread_key.strip_prefix("from:").or_else(|| thread_key.strip_prefix("declared:"));
    add(key.map(|k| k.rsplit_once("/pr:").map_or(k, |(name, _)| name)));
    names
}

/// `inbox_reply` to a thread whose messages name no session here (`inbox.no_sender`: a sender
/// on another machine, or one that declared only its name): the thread's sender is read from
/// the thread and the answer goes to it as `send` sends, and the result says so. The census of
/// 2026-11-23 (cmuxterm-hq docs/findings/2026-11-23-mcp-tool-error-census.md) counted 49 such
/// refusals in 48 h on one VM, 86% of inbox_reply's calls. Leo, 2026-11-21: "when you guys
/// encounter errors or whatnot, the tool itself should be improved and/or your thing should
/// also be acceptable input or rewritten to make stuff good".
async fn reply_by_name(
    daemon: &Arc<Client>,
    session: &str,
    thread: &str,
    text: &str,
    refused: anyhow::Error,
) -> Value {
    let params = json!({"sessionId": session, "threadId": thread, "markRead": false});
    let read = daemon.request(method::MUX_INBOX_THREAD, params).await.unwrap_or(Value::Null);
    let mut tried = Vec::new();
    for name in thread_sender_names(thread, &read).into_iter().take(3) {
        let result = send::send(daemon, &json!({"to": name, "text": text}), None).await;
        if result.get("isError") != Some(&Value::Bool(true)) {
            let why = format!(
                "no message in thread {thread} names a session here, so the answer went to its sender {name} as send sends it"
            );
            return said(result, &why);
        }
        tried.push(format!("{name}: {}", first_text(&result)));
    }
    match tried.is_empty() {
        true => refusal(refused),
        false => error_result(format!(
            "{refused:#}; sending to the thread's sender by name failed too ({})",
            tried.join("; ")
        )),
    }
}

/// A tool result's first text.
fn first_text(result: &Value) -> &str {
    result.pointer("/content/0/text").and_then(Value::as_str).unwrap_or_default()
}

/// `result` with `why` as its first line and its `rewritten` field: what the call was read as.
fn said(mut result: Value, why: &str) -> Value {
    if let Some(first) = result.pointer_mut("/content/0/text")
        && let Some(text) = first.as_str()
    {
        *first = json!(format!("({why})\n{text}"));
    }
    if let Some(structured) = result.get_mut("structuredContent").and_then(Value::as_object_mut) {
        structured.insert("rewritten".to_owned(), json!(why));
    }
    result
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
    ls_via(daemon, args, crate::cli::list_read::Via::daemon()).await
}

/// [`ls`], read `via` the v2 list (the live view's rows, or with `status: closed` the closed
/// rows of the whole view, each fetched as the list writes it) or the v1 list.
pub(crate) async fn ls_via(
    daemon: &Arc<Client>,
    args: &Value,
    via: crate::cli::list_read::Via,
) -> Value {
    use crate::cli::list_read;
    // Closed sessions are most of a fleet's list; the daemon leaves them out unless asked for.
    let closed = arg(args, "status") == Some("closed");
    let params = if closed { json!({}) } else { json!({"excludeStatus": ["closed"]}) };
    // The closed rows are of the whole view, which holds no other machine's closed row: v1 while
    // one is listed (decision 213).
    let local = async {
        let remote_closed = closed
            && list_read::closed_remote_listed(
                daemon.request(method::MUX_STATUS, json!({})).await.ok().as_ref(),
            );
        let source = if remote_closed { None } else { via.open(daemon).await? };
        match source {
            Some(mut source) => {
                let view = if closed {
                    acpmux_client::wire::ListView::All
                } else {
                    acpmux_client::wire::ListView::Live
                };
                let may_keep = |s: &acpmux_book::index::Summary| !closed || list_read::closed(s);
                source.rows(view, &may_keep).await.map(|rows| json!({"sessions": rows}))
            }
            None => daemon.whole_list(method::MUX_SESSIONS, params).await,
        }
    };
    let (mut all, far) =
        match tokio::try_join!(local, async { Ok(crate::cli::ls_far::relay_rows().await) }) {
            Ok(rows) => rows,
            Err(e) => return refusal(e),
        };
    if !far.is_empty()
        && let Some(rows) = all.get_mut("sessions").and_then(Value::as_array_mut)
    {
        crate::cli::send_relay::merge_rows(rows, far);
    }
    ls_result(&all, args)
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
