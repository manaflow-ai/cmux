//! `optchat-chief integrations serve`: the person's saved MCP servers for an
//! agent chat cmux starts (acpmux's `cmux-mcp` upstream of `cmux mcp serve`,
//! so the agent sees one tool, `mcp_servers`). The same hub as the Chief's
//! `mcp`, on the machine's shared store, as the chat's viewer: it lists and
//! uses only the servers the person's scope on the connect card gives this
//! chat (`cmux_mcp_connect::shared::visible`), and never adds or removes one.

use std::io::{BufRead, Write};
use std::path::PathBuf;
use std::sync::Arc;

use serde_json::{Value, json};

use super::{AGENT_ACTIONS, Caller, McpHub, Viewer, store};

/// Where acpmux names the chat (`agent_tools::AGENT_SESSION_ENV`).
pub const SESSION_ENV: &str = "CMUX_AGENT_SESSION";
/// The acpmux session's name, in every harness's env: a Chief's subagent is
/// `optchat-sub-<home id>-<id>`, so it also sees what that Chief's scope gives.
pub const SESSION_NAME_ENV: &str = "ACPMUX_SESSION_NAME";
/// The tool's name before `cmux mcp serve` adds the upstream's prefix (`mcp_`).
pub const TOOL: &str = "servers";

const PROTOCOL: &str = "2025-06-18";
const KNOWN: [&str; 4] = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"];

const DESCRIPTION: &str = "The MCP servers the person connected for this chat (Linear, Slack, GitHub and others they approved on a connect card or in Settings > MCP Servers), in code mode. Start with action list. Then search (query) finds tools, describe (server, tool) gives a tool's TypeScript declaration, call (server, tool, args) runs one, and run (code) runs a TypeScript script where `await mcp.<server>.<tool>({...})` calls tools, so loop and filter there and return only what you need. signin (server) gives a page the person opens to sign in again. To get a server that is not listed, ask with connect_mcp_server: only the person adds servers.";
const INSTRUCTIONS: &str = "The person's own MCP servers (their connected services), shared by their agents on this machine. Use mcp_servers with action list to see them.";

/// The tool `cmux mcp serve` lists as `mcp_servers`.
pub fn tool() -> Value {
    json!({"name": TOOL, "description": DESCRIPTION,
     "inputSchema": {"type": "object", "properties": {
        "action": {"type": "string", "enum": AGENT_ACTIONS},
        "server": {"type": "string", "minLength": 1},
        "tool": {"type": "string", "minLength": 1},
        "args": {"type": "object", "description": "call: the tool's arguments; prompt: the prompt's."},
        "code": {"type": "string", "minLength": 1, "description": "run: TypeScript; top-level await; `return` a value or console.log; no imports."},
        "query": {"type": "string"},
        "name": {"type": "string", "minLength": 1, "description": "prompt: the prompt's name."},
        "id": {"type": "string", "minLength": 1, "description": "task: t<N>."},
        "op": {"type": "string", "enum": ["status", "wait", "cancel"]},
        "uri": {"type": "string", "minLength": 1},
        "timeout_seconds": {"type": "integer", "minimum": 1},
        "wait_seconds": {"type": "integer", "minimum": 1}},
      "required": ["action"], "additionalProperties": false},
     "annotations": {"readOnlyHint": false, "destructiveHint": false, "openWorldHint": true}})
}

/// The chat's viewer from its env: its session, and the Chief it works for.
pub fn viewer_from(env: &dyn Fn(&str) -> Option<String>) -> Option<Viewer> {
    let session = env(SESSION_ENV).filter(|s| !s.is_empty())?;
    let chief = env(SESSION_NAME_ENV)
        .as_deref()
        .and_then(cmux_mcp_connect::shared::chief_of_session)
        .map(str::to_owned);
    Some(Viewer::Agent { session, chief })
}

/// The hub for `viewer`: the machine's store, a private folder of its own
/// for its tasks (gone with the process's temp folder).
pub fn hub(shared: PathBuf, viewer: Viewer) -> McpHub {
    let own_name = match &viewer {
        Viewer::Agent { session, .. } => format!("agent-{}", super::clean_name(session)),
        _ => "agent".into(),
    };
    McpHub::for_viewer(
        std::env::temp_dir().join("cmux-mcp-serve").join(own_name),
        shared,
        None,
        // No way to wake an agent: results come back in the call.
        Arc::new(|_| {}),
        Arc::new(|k: &str| std::env::var(k).ok()),
        viewer,
    )
}

/// The answer to one JSON-RPC message, or None for a notification.
pub fn handle(hub: &McpHub, message: &Value) -> Option<Value> {
    let id = message.get("id").cloned()?;
    let method = message.get("method").and_then(Value::as_str).unwrap_or("");
    let params = message.get("params").cloned().unwrap_or(Value::Null);
    let result = match method {
        "initialize" => {
            let asked = params
                .get("protocolVersion")
                .and_then(Value::as_str)
                .unwrap_or("");
            Ok(json!({
                "protocolVersion": if KNOWN.contains(&asked) { asked } else { PROTOCOL },
                "capabilities": {"tools": {"listChanged": false}},
                "serverInfo": {"name": "cmux-mcp", "version": env!("CARGO_PKG_VERSION")},
                "instructions": INSTRUCTIONS,
            }))
        }
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({"tools": [tool()]})),
        "tools/call" => {
            let name = params.get("name").and_then(Value::as_str).unwrap_or("");
            let (text, error) = if name == TOOL {
                let args = params.get("arguments").cloned().unwrap_or(json!({}));
                match hub.handle(&args, &Caller::Chief) {
                    Ok(text) => (text, false),
                    Err(text) => (text, true),
                }
            } else {
                (
                    format!("unknown tool {name:?}; the one tool is {TOOL}"),
                    true,
                )
            };
            Ok(
                json!({"content": [{"type": "text", "text": super::redact(&text)}], "isError": error}),
            )
        }
        _ => Err(json!({"code": -32601, "message": format!("method not found: {method}")})),
    };
    Some(match result {
        Ok(result) => json!({"jsonrpc": "2.0", "id": id, "result": result}),
        Err(error) => json!({"jsonrpc": "2.0", "id": id, "error": error}),
    })
}

/// Runs the server on stdin and stdout until stdin closes.
pub fn run() -> i32 {
    let Some(viewer) = viewer_from(&|k| std::env::var(k).ok()) else {
        eprintln!("optchat-chief integrations serve: {SESSION_ENV} names no chat");
        return 2;
    };
    let hub = hub(store::shared_dir(), viewer);
    let stdin = std::io::stdin();
    let mut out = std::io::stdout().lock();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let answer = match serde_json::from_str::<Value>(&line) {
            Ok(message) => handle(&hub, &message),
            Err(e) => Some(json!({"jsonrpc": "2.0", "id": null,
                "error": {"code": -32700, "message": format!("parse error: {e}")}})),
        };
        if let Some(answer) = answer
            && (writeln!(out, "{answer}").is_err() || out.flush().is_err())
        {
            break;
        }
    }
    hub.stop();
    0
}
