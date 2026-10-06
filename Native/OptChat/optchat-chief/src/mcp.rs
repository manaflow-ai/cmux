//! `optchat-chief mcp --socket PATH`: a stdio MCP server with the two memory
//! tools, which forwards each call to the running host (tools.rs). The tool
//! descriptions are the spec's, verbatim (section 7.1), and the list never
//! changes, so the turn's tool list stays byte-identical (section 7.2).

use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use crate::prompt::{DATE_DESCRIPTION, SPAWN_DESCRIPTION, TELL_DESCRIPTION, ZOOM_DESCRIPTION};
use crate::tools::{self, Call};

/// The MCP revision this server speaks when the client names none it knows.
const PROTOCOL: &str = "2025-06-18";
const KNOWN: [&str; 4] = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"];

/// The Chief's tools: zoom, date, spawn and tell (section 9).
pub fn tool_list() -> Value {
    tools_for(false)
}

/// A subagent gets zoom and date, not spawn (section 9); the Chief all four.
pub fn tools_for(subagent: bool) -> Value {
    let int = json!({"type": "integer", "minimum": 0});
    let text = json!({"type": "string", "minLength": 1});
    let mut list = vec![
        json!({"name": "zoom", "description": ZOOM_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {"id": int, "n": int}, "required": ["id", "n"], "additionalProperties": false}}),
        json!({"name": "date", "description": DATE_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {"id": int}, "required": ["id"], "additionalProperties": false}}),
    ];
    if !subagent {
        list.push(json!({"name": "spawn", "description": SPAWN_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {"tasks": {"type": "array", "items": text, "minItems": 1}}, "required": ["tasks"], "additionalProperties": false}}));
        list.push(json!({"name": "tell", "description": TELL_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {"id": text, "message": text}, "required": ["id", "message"], "additionalProperties": false}}));
    }
    Value::Array(list)
}

/// How a tool call reaches the memory: the host socket, or a test memory.
pub trait Backend {
    fn call(&self, call: Call) -> Result<String, String>;
    /// A subagent's server: zoom and date only.
    fn subagent(&self) -> bool {
        false
    }
}

/// The host socket; `subagent` marks a subagent's server (no spawn, tell).
pub struct SocketBackend(pub PathBuf, pub bool);

impl Backend for SocketBackend {
    fn call(&self, call: Call) -> Result<String, String> {
        tools::ask_as(&self.0, call, self.1)
    }

    fn subagent(&self) -> bool {
        self.1
    }
}

/// The answer to one JSON-RPC message, or None for a notification.
pub fn handle(message: &Value, backend: &dyn Backend) -> Option<Value> {
    let id = message.get("id").cloned()?;
    let method = message.get("method").and_then(Value::as_str).unwrap_or("");
    let params = message.get("params").cloned().unwrap_or(Value::Null);
    let result = match method {
        "initialize" => {
            let asked = params
                .get("protocolVersion")
                .and_then(Value::as_str)
                .unwrap_or("");
            let version = if KNOWN.contains(&asked) {
                asked
            } else {
                PROTOCOL
            };
            Ok(json!({
                "protocolVersion": version,
                "capabilities": {"tools": {"listChanged": false}},
                "serverInfo": {"name": "optchat", "version": env!("CARGO_PKG_VERSION")},
            }))
        }
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({"tools": tools_for(backend.subagent())})),
        "tools/call" => {
            let name = params.get("name").and_then(Value::as_str).unwrap_or("");
            let args = params.get("arguments").cloned().unwrap_or(json!({}));
            let answer = Call::parse(name, &args).and_then(|call| match call {
                Call::Spawn { .. } | Call::Tell { .. } if backend.subagent() => {
                    Err(format!("unknown tool {name}"))
                }
                call => backend.call(call),
            });
            Ok(match answer {
                Ok(text) => json!({"content": [{"type": "text", "text": text}], "isError": false}),
                Err(error) => {
                    json!({"content": [{"type": "text", "text": error}], "isError": true})
                }
            })
        }
        _ => Err(json!({"code": -32601, "message": format!("method not found: {method}")})),
    };
    Some(match result {
        Ok(result) => json!({"jsonrpc": "2.0", "id": id, "result": result}),
        Err(error) => json!({"jsonrpc": "2.0", "id": id, "error": error}),
    })
}

/// Serves newline-delimited JSON-RPC on `input` and `output` until EOF.
pub fn serve(
    input: impl BufRead,
    mut output: impl Write,
    backend: &dyn Backend,
) -> std::io::Result<()> {
    for line in input.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let answer = match serde_json::from_str::<Value>(&line) {
            Ok(message) => handle(&message, backend),
            Err(e) => Some(
                json!({"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": e.to_string()}}),
            ),
        };
        if let Some(answer) = answer {
            writeln!(output, "{answer}")?;
            output.flush()?;
        }
    }
    Ok(())
}

/// The `mcp` subcommand (`--subagent`: a subagent's server).
pub fn run(socket: &Path, subagent: bool) -> std::io::Result<()> {
    let stdin = std::io::stdin();
    serve(
        stdin.lock(),
        std::io::stdout().lock(),
        &SocketBackend(socket.to_owned(), subagent),
    )
}
