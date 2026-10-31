//! `optchat-chief mcp --socket PATH`: a stdio MCP server with the two memory
//! tools, which forwards each call to the running host (tools.rs). The tool
//! descriptions are the spec's, verbatim (section 7.1), and the list never
//! changes, so the turn's tool list stays byte-identical (section 7.2).

use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

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
    tools_granted(subagent, &crate::chief_profile::Grant::all())
}

/// The list for a Chief whose person granted `grant` (chief_profile.rs):
/// zoom and date always, then spawn, tell, profile and chiefs when granted,
/// then react and reply (a Chief's own conversation, always).
pub fn tools_granted(subagent: bool, grant: &crate::chief_profile::Grant) -> Value {
    chief_kernel::tools::tool_list(subagent, &|tool| grant.allows(tool))
}

/// How a tool call reaches the memory: the host socket, or a test memory.
pub trait Backend {
    fn call(&self, call: Call) -> Result<String, String>;
    /// A subagent's server: zoom and date only.
    fn subagent(&self) -> bool {
        false
    }
    /// The Chief home this server belongs to (the move tool), if known.
    fn home(&self) -> Option<PathBuf> {
        None
    }
    /// The model tools this Chief may use (asked of the host at tools/list).
    fn grant(&self) -> crate::chief_profile::Grant {
        crate::chief_profile::Grant::all()
    }
    /// The `version` tool's answer (version_tool.rs). It runs here, in the
    /// MCP server, never through the host: it only reads.
    fn version(&self) -> Result<String, String> {
        Ok(crate::version_tool::answer(&crate::paths::mux_home()))
    }
}

/// The host socket; `subagent` marks a subagent's server (no spawn, tell).
pub struct SocketBackend(pub PathBuf, pub bool);

impl Backend for SocketBackend {
    fn call(&self, call: Call) -> Result<String, String> {
        tools::ask_as(&self.0, tools::with_turn_key(call), self.1)
    }

    fn subagent(&self) -> bool {
        self.1
    }

    /// `<home>/optchat/tools.sock`: the home is two levels up.
    fn home(&self) -> Option<PathBuf> {
        self.0.parent()?.parent().map(Path::to_path_buf)
    }

    /// The live host's grant. A host that does not answer the question (an
    /// older host) grants what it always did; one that cannot be reached
    /// answers no tool call either, so zoom and date alone are listed.
    fn grant(&self) -> crate::chief_profile::Grant {
        match tools::ask_grant(&self.0) {
            Ok(value) => crate::chief_profile::Grant::from_mcp_value(Some(&value)),
            Err(e) if e.contains("unknown tool") => crate::chief_profile::Grant::all(),
            Err(_) => crate::chief_profile::Grant::from_mcp_value(Some("none")),
        }
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
        "tools/list" => Ok(json!({"tools": if backend.subagent() {
            tools_for(true)
        } else {
            tools_granted(false, &backend.grant())
        }})),
        "tools/call" => {
            let name = params.get("name").and_then(Value::as_str).unwrap_or("");
            let args = params.get("arguments").cloned().unwrap_or(json!({}));
            let answer = if name == "version" {
                backend.version()
            } else if name == "move" {
                match (backend.subagent(), backend.home()) {
                    (true, _) => Err(format!("unknown tool {name}")),
                    (false, None) => Err("move: this server does not know its Chief home".into()),
                    (false, Some(home)) => move_call(&home, &args),
                }
            } else {
                Call::parse(name, &args).and_then(|call| match call {
                    Call::Spawn { .. }
                    | Call::React { .. }
                    | Call::Reply { .. }
                    | Call::Send(_)
                    | Call::Transcript { .. }
                    | Call::Stop
                    | Call::Sleep(_)
                    | Call::Watch(_)
                    | Call::Remember { .. }
                    | Call::Control(_)
                    | Call::CloudWorkspace(_)
                    | Call::Profile { .. }
                    | Call::Chiefs { .. }
                        if backend.subagent() =>
                    {
                        Err(format!("unknown tool {name}"))
                    }
                    call => backend.call(call),
                })
            };
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

/// The `move` tool (plans/cmux-next/chief-migration-DESIGN.md section 8):
/// the Chief moves itself. `dry_run` checks the target and answers at once;
/// a real move runs `optchat-chief move --detach`, which waits for this turn
/// to end, stops the host, and writes its report to `state/move.json`.
/// `status` reads that report, `reach` probes what this home reached before
/// a move, `rollback` lets the old copy answer again.
pub use chief_kernel::tools::{MOVE_DESCRIPTION, move_tool};

/// Runs the move tool for the Chief of `home` with this binary.
pub fn move_call(home: &Path, args: &Value) -> Result<String, String> {
    let action = args["action"].as_str().unwrap_or("move");
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let mut argv: Vec<String> = vec!["move".into()];
    match action {
        "status" => {
            return std::fs::read_to_string(home.join("state").join("move.json"))
                .map_err(|_| "no move has run from this home".to_owned());
        }
        "reach" => argv.push("reach".into()),
        "rollback" => argv.push("rollback".into()),
        "move" => {
            let to = args["to"].as_str().ok_or("move needs `to`")?;
            argv.extend(["--to".into(), to.into()]);
            argv.push(
                if args["dry_run"] == true {
                    "--dry-run"
                } else {
                    "--detach"
                }
                .into(),
            );
            if args["without_transcripts"] == true {
                argv.push("--without-transcripts".into());
            }
            if let Some(name) = args["name"].as_str() {
                argv.extend(["--name".into(), name.into()]);
            }
        }
        other => return Err(format!("unknown move action {other}")),
    }
    for (key, flag) in [
        ("remote_bin", "--remote-bin"),
        ("session_token_file", "--session-token-file"),
    ] {
        if let Some(v) = args[key].as_str() {
            argv.extend([flag.into(), v.into()]);
        }
    }
    argv.extend(["--home".into(), home.to_string_lossy().into_owned()]);
    let out = std::process::Command::new(exe)
        .args(&argv)
        .stdin(std::process::Stdio::null())
        .output()
        .map_err(|e| e.to_string())?;
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    if out.status.success() {
        Ok(text)
    } else {
        Err(text)
    }
}
