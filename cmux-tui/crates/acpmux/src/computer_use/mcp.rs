//! `acpmux computer-use-mcp`: cmux Computer Use as an agent's MCP stdio
//! server (`cmux-computer-use`).
//!
//! It always starts and answers `initialize` and `tools/list` itself, from
//! the tool catalog compiled into this binary, so an agent has its tools
//! whether or not the worker runs, is restarting, or Computer Use is off
//! (then each call says so). `tools/call` goes through [`Caller`]: a call id
//! per request, the session key for the whole session, the endpoint from the
//! cmux-tui daemon, and retries of the same call id across a worker restart.
//! A worker result, refusals included, reaches the agent unchanged.
//!
//! When the agent closes the pipe the server ends its session on the worker
//! (`session/end`), which drops the session's approvals and cursor.

use std::sync::Arc;

use anyhow::Result;
use cmux_computer_use::tools;
use serde_json::{Value, json};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::mpsc;

use super::client::{Caller, Daemon, SocketDaemon};

/// The MCP server name agents see.
pub const SERVER_NAME: &str = tools::SERVER_NAME;
/// The acpmux command word (`acpmux computer-use-mcp`).
pub const COMMAND: &str = "computer-use-mcp";
/// The agent session this server calls for, set in its own env (`agent_tools.rs`).
pub const SESSION_ENV: &str = "ACPMUX_COMPUTER_USE_SESSION";
/// What the person sees as the caller ("Claude Code", "Codex").
pub const LABEL_ENV: &str = "ACPMUX_COMPUTER_USE_LABEL";

/// The session key when the env names none (a server started by hand): one
/// per process, so two such servers never share approvals.
fn fallback_session() -> String {
    format!("unbound-{}", uuid::Uuid::now_v7().simple())
}

/// Runs the server on stdin and stdout.
pub async fn run() -> Result<()> {
    let var = |name: &str| std::env::var(name).ok().filter(|v| !v.trim().is_empty());
    // `cmux computer-use mcp` started by an agent's own config: its session
    // is the one cmux names in the agent's env.
    let session = var(SESSION_ENV)
        .or_else(|| var(crate::agent_tools::AGENT_SESSION_ENV))
        .unwrap_or_else(fallback_session);
    let label = var(LABEL_ENV).unwrap_or_else(|| "An agent".to_owned());
    crate::parent_watch::exit_with_parent();
    let caller = Arc::new(Caller::new(SocketDaemon::from_env(), session, label));
    serve(caller, tokio::io::BufReader::new(tokio::io::stdin()), tokio::io::stdout()).await
}

/// Whether the client is an agent with its own Computer Use that people
/// usually prefer (Codex: Codex Computer Use). Then cmux Computer Use is the
/// second choice, used only when the person asks for it.
pub fn defers_to_own_computer_use(params: &Value) -> bool {
    params
        .pointer("/clientInfo/name")
        .and_then(Value::as_str)
        .is_some_and(|name| name.to_ascii_lowercase().contains("codex"))
}

/// What an agent that has its own Computer Use is told.
pub const DEFER_INSTRUCTIONS: &str = "You have your own Computer Use (Codex Computer Use); use it for anything on this computer's screen. These cmux-computer-use tools are a second option: use them only when the person asks for cmux Computer Use (or names these tools), never by default. When the person does ask, work in the background as cmux Computer Use does: list_windows, then screenshot or get_ui_tree a window, then act on element ids or screenshot pixels.";

/// The prefix of each tool's description for such an agent (also the folded
/// `cu_*` tools of `cmux mcp serve` when its client is Codex).
pub const DEFER_PREFIX: &str =
    "cmux Computer Use: only when the person asks for it; otherwise use your own Computer Use. ";

/// The `initialize` result.
pub fn initialize(params: &Value) -> Value {
    let instructions =
        if defers_to_own_computer_use(params) { DEFER_INSTRUCTIONS } else { tools::INSTRUCTIONS };
    json!({
        "protocolVersion": crate::secret_mcp::protocol_version(params),
        "capabilities": {"tools": {"listChanged": false}},
        "serverInfo": {"name": SERVER_NAME, "version": env!("CARGO_PKG_VERSION")},
        "instructions": instructions,
    })
}

/// The `tools/list` result, each description marked second choice for an
/// agent with its own Computer Use.
pub fn tools_list(defer: bool) -> Value {
    let mut list = tools::mcp_list();
    if defer && let Some(items) = list.get_mut("tools").and_then(Value::as_array_mut) {
        for tool in items {
            if let Some(description) = tool.get("description").and_then(Value::as_str) {
                let marked = format!("{DEFER_PREFIX}{description}");
                tool["description"] = Value::String(marked);
            }
        }
    }
    list
}

/// Serves MCP on `input`/`output` until `input` closes, then ends the
/// session on the worker.
pub async fn serve<D, R, W>(caller: Arc<Caller<D>>, input: R, mut output: W) -> Result<()>
where
    D: Daemon + 'static,
    R: AsyncBufRead + Unpin,
    W: AsyncWrite + Unpin + Send + 'static,
{
    let (tx, mut rx) = mpsc::channel::<Value>(64);
    let writer = tokio::spawn(async move {
        while let Some(message) = rx.recv().await {
            let mut line = message.to_string();
            line.push('\n');
            if output.write_all(line.as_bytes()).await.is_err() || output.flush().await.is_err() {
                break;
            }
        }
    });
    let mut calls = tokio::task::JoinSet::new();
    let mut lines = input.lines();
    let mut defer = false;
    while let Some(line) = lines.next_line().await? {
        let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
        let Some(id) = message.get("id").cloned() else { continue }; // a notification
        let params = message.get("params").cloned().unwrap_or(Value::Null);
        let result = match message["method"].as_str().unwrap_or_default() {
            "initialize" => {
                // The agent's own name for the person's cards, unless the env named it.
                if std::env::var_os(LABEL_ENV).is_none()
                    && let Some(name) = params.pointer("/clientInfo/name").and_then(Value::as_str)
                    && name != "cmux"
                {
                    caller.set_label(name);
                }
                defer = defers_to_own_computer_use(&params);
                initialize(&params)
            }
            "ping" => json!({}),
            "tools/list" => tools_list(defer),
            "tools/call" if !known_tool(&params) => unknown_tool(&params),
            "tools/call" => {
                let (tx, caller) = (tx.clone(), caller.clone());
                // A call may wait on the person or on a worker restart: the
                // next request is read meanwhile.
                calls.spawn(async move {
                    let result = tokio::task::spawn_blocking(move || call(&caller, &params))
                        .await
                        .unwrap_or_else(|e| {
                            crate::secret_mcp::error_result(format!("the call stopped: {e}"))
                        });
                    let _ = tx.send(json!({"jsonrpc": "2.0", "id": id, "result": result})).await;
                });
                continue;
            }
            other => {
                let error =
                    json!({"code": -32601, "message": format!("method not found: {other}")});
                let _ = tx.send(json!({"jsonrpc": "2.0", "id": id, "error": error})).await;
                continue;
            }
        };
        let _ = tx.send(json!({"jsonrpc": "2.0", "id": id, "result": result})).await;
    }
    // The agent closed the pipe: answers still on their way reach no one.
    calls.abort_all();
    drop(tx);
    writer.abort();
    let end = caller.clone();
    let _ = tokio::task::spawn_blocking(move || end.end_session()).await;
    Ok(())
}

fn known_tool(params: &Value) -> bool {
    params["name"].as_str().and_then(tools::find).is_some()
}

/// The answer to a call of no catalog tool, with the names it may have meant.
fn unknown_tool(params: &Value) -> Value {
    let Some(name) = params["name"].as_str() else {
        return crate::secret_mcp::error_result("tools/call needs a tool name".into());
    };
    let names = tools::TOOLS.iter().map(|t| t.name);
    crate::secret_mcp::error_result(crate::mcp_hint::unknown_tool(name, names))
}

/// One `tools/call`: a new call id, the tool run by [`Caller`].
pub fn call<D: Daemon>(caller: &Caller<D>, params: &Value) -> Value {
    if !known_tool(params) {
        return unknown_tool(params);
    }
    let name = params["name"].as_str().unwrap_or_default();
    let arguments = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
    caller.call(name, &arguments, &super::client::new_call_id()).to_mcp()
}

#[cfg(test)]
mod defer_tests {
    use super::*;

    #[test]
    fn codex_is_told_its_own_computer_use_comes_first() {
        let codex = json!({"clientInfo": {"name": "codex-mcp-client", "version": "1"}});
        assert!(defers_to_own_computer_use(&codex));
        assert_eq!(initialize(&codex)["instructions"], DEFER_INSTRUCTIONS);
        let listed = tools_list(true);
        for tool in listed["tools"].as_array().unwrap() {
            assert!(tool["description"].as_str().unwrap().starts_with(DEFER_PREFIX));
        }
        let claude = json!({"clientInfo": {"name": "claude-code", "version": "2"}});
        assert!(!defers_to_own_computer_use(&claude));
        assert_eq!(initialize(&claude)["instructions"], tools::INSTRUCTIONS);
        assert!(
            !tools_list(false)["tools"][0]["description"]
                .as_str()
                .unwrap()
                .starts_with(DEFER_PREFIX)
        );
    }
}
