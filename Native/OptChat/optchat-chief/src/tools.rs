//! The memory tools `zoom` and `date` (section 7.1), answered by the host from
//! the live memory on a Unix socket in `$MUX_HOME/optchat/`. The `mcp`
//! subcommand, which the turn session runs as its MCP server, forwards each
//! call here, so the answers always come from the one process that owns the
//! chat. Wire: one JSON line per request and per answer.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use optchat_host::OptChat;
use serde_json::{Value, json};

/// What the tools read.
pub trait Memory: Send + Sync {
    fn zoom(&self, id: u64, n: u64) -> String;
    fn date(&self, id: u64) -> String;
    /// The whole memory as one HTML page (`optchat-chief browse`).
    fn browse(&self) -> String {
        "browsing is not available".to_owned()
    }
}

impl Memory for OptChat {
    fn zoom(&self, id: u64, n: u64) -> String {
        // A bad address answers "No line id+n." (section 7.1), not an error.
        OptChat::zoom(self, id, n).unwrap_or_else(|e| e.to_string())
    }

    fn date(&self, id: u64) -> String {
        OptChat::date(self, id).unwrap_or_else(|| format!("No message {id}."))
    }

    fn browse(&self) -> String {
        crate::browse::html(self)
    }
}

/// Section 9's subagent tools, answered by the host (subagents.rs).
pub trait Orchestrator: Send + Sync {
    /// Starts one subagent per task; answers their ids.
    fn spawn(&self, tasks: Vec<String>) -> Result<String, String>;
    /// Sends `message` to subagent `id`.
    fn tell(&self, id: &str, message: &str) -> Result<String, String>;
}

/// One tool call.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Call {
    Zoom { id: u64, n: u64 },
    Date { id: u64 },
    Spawn { tasks: Vec<String> },
    Tell { id: String, message: String },
}

impl Call {
    /// The call named `tool` with JSON `args`.
    pub fn parse(tool: &str, args: &Value) -> Result<Call, String> {
        let num = |key: &str| {
            args.get(key)
                .and_then(|v| {
                    v.as_u64()
                        .or_else(|| v.as_str().and_then(|s| s.trim().parse().ok()))
                })
                .ok_or_else(|| format!("{tool}: `{key}` must be a non-negative integer"))
        };
        match tool {
            "zoom" => Ok(Call::Zoom {
                id: num("id")?,
                n: num("n")?,
            }),
            "date" => Ok(Call::Date { id: num("id")? }),
            "spawn" => {
                let tasks: Vec<String> = match args.get("tasks") {
                    Some(Value::Array(items)) => items
                        .iter()
                        .filter_map(|t| t.as_str().map(str::trim).map(str::to_owned))
                        .filter(|t| !t.is_empty())
                        .collect(),
                    Some(Value::String(one)) if !one.trim().is_empty() => {
                        vec![one.trim().to_owned()]
                    }
                    _ => Vec::new(),
                };
                if tasks.is_empty() {
                    return Err("spawn: `tasks` must be a list of task texts".into());
                }
                Ok(Call::Spawn { tasks })
            }
            "tell" => {
                let text = |key: &str| {
                    args.get(key)
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .filter(|t| !t.is_empty())
                        .map(str::to_owned)
                        .ok_or_else(|| format!("tell: `{key}` must be a non-empty text"))
                };
                Ok(Call::Tell {
                    id: text("id")?,
                    message: text("message")?,
                })
            }
            other => Err(format!("unknown tool {other}")),
        }
    }

    /// The memory tools' answer (spawn and tell go to an `Orchestrator`).
    pub fn answer(self, memory: &dyn Memory) -> String {
        match self {
            Call::Zoom { id, n } => memory.zoom(id, n),
            Call::Date { id } => memory.date(id),
            Call::Spawn { .. } | Call::Tell { .. } => {
                "spawn and tell are served by the Chief host".to_owned()
            }
        }
    }

    fn to_json(&self) -> Value {
        match self {
            Call::Zoom { id, n } => json!({"tool": "zoom", "id": id, "n": n}),
            Call::Date { id } => json!({"tool": "date", "id": id}),
            Call::Spawn { tasks } => json!({"tool": "spawn", "tasks": tasks}),
            Call::Tell { id, message } => json!({"tool": "tell", "id": id, "message": message}),
        }
    }
}

/// What the tools socket serves: the memory, and the subagent tools when
/// the host runs them.
#[derive(Clone)]
pub struct Served {
    pub memory: Arc<dyn Memory>,
    pub orchestrator: Option<Arc<dyn Orchestrator>>,
}

/// Serves the tools on `path` until the process ends. The host holds the
/// host lock, so a socket file left by an earlier host is stale and replaced.
pub fn serve(path: &Path, memory: Arc<dyn Memory>) -> std::io::Result<()> {
    serve_all(
        path,
        Served {
            memory,
            orchestrator: None,
        },
    )
}

/// Serves the memory and the subagent tools on `path`.
pub fn serve_all(path: &Path, served: Served) -> std::io::Result<()> {
    let _ = std::fs::remove_file(path);
    let listener = UnixListener::bind(path)?;
    std::thread::Builder::new()
        .name("tools".into())
        .spawn(move || {
            for conn in listener.incoming().flatten() {
                let served = served.clone();
                let _ = std::thread::Builder::new()
                    .name("tools-conn".into())
                    .spawn(move || connection(conn, &served));
            }
        })?;
    Ok(())
}

fn connection(conn: UnixStream, served: &Served) {
    let memory = &*served.memory;
    let Ok(mut out) = conn.try_clone() else {
        return;
    };
    for line in BufReader::new(conn).lines() {
        let Ok(line) = line else { return };
        let answer = match serde_json::from_str::<Value>(&line) {
            Ok(req) => {
                let tool = req.get("tool").and_then(Value::as_str).unwrap_or("");
                // Not a model tool: the `browse` command asks the live host.
                if tool == "browse" {
                    let answer = json!({"text": memory.browse()});
                    if writeln!(out, "{answer}").is_err() {
                        return;
                    }
                    continue;
                }
                // A subagent's tools (its MCP server or launcher) say so:
                // section 9 gives subagents zoom and date, not spawn.
                let subagent = req.get("from").and_then(Value::as_str) == Some("subagent");
                let answer = match Call::parse(tool, &req) {
                    Ok(Call::Spawn { .. } | Call::Tell { .. }) if subagent => {
                        Err("subagents have no spawn or tell".to_owned())
                    }
                    Ok(Call::Spawn { tasks }) => match &served.orchestrator {
                        Some(o) => o.spawn(tasks),
                        None => Err("this Chief host runs no subagents".to_owned()),
                    },
                    Ok(Call::Tell { id, message }) => match &served.orchestrator {
                        Some(o) => o.tell(&id, &message),
                        None => Err("this Chief host runs no subagents".to_owned()),
                    },
                    Ok(call) => Ok(call.answer(memory)),
                    Err(e) => Err(e),
                };
                match answer {
                    Ok(text) => json!({"text": text}),
                    Err(e) => json!({"error": e}),
                }
            }
            Err(e) => json!({"error": format!("bad request: {e}")}),
        };
        if writeln!(out, "{answer}").is_err() {
            return;
        }
    }
}

/// Asks the host on `path`; Err when it does not answer.
pub fn ask(path: &Path, call: Call) -> Result<String, String> {
    ask_json(path, &call.to_json())
}

/// Asks the host on `path` as a subagent's tools (no spawn, no tell).
pub fn ask_as(path: &Path, call: Call, subagent: bool) -> Result<String, String> {
    let mut request = call.to_json();
    if subagent {
        request["from"] = json!("subagent");
    }
    ask_json(path, &request)
}

/// The browse page from the live host; Err when no host answers on `path`.
pub fn ask_browse(path: &Path) -> Result<String, String> {
    ask_json(path, &json!({"tool": "browse"}))
}

fn ask_json(path: &Path, request: &Value) -> Result<String, String> {
    let mut conn = UnixStream::connect(path)
        .map_err(|e| format!("the Chief host is not running ({}: {e})", path.display()))?;
    // spawn waits for the view to settle (subagents.rs SETTLE_LIMIT).
    conn.set_read_timeout(Some(Duration::from_secs(300)))
        .map_err(|e| e.to_string())?;
    writeln!(conn, "{request}").map_err(|e| e.to_string())?;
    let mut line = String::new();
    BufReader::new(conn)
        .read_line(&mut line)
        .map_err(|e| format!("reading the answer: {e}"))?;
    let answer: Value = serde_json::from_str(&line).map_err(|e| format!("bad answer: {e}"))?;
    match (
        answer.get("text").and_then(Value::as_str),
        answer.get("error").and_then(Value::as_str),
    ) {
        (Some(text), _) => Ok(text.to_owned()),
        (None, Some(error)) => Err(error.to_owned()),
        (None, None) => Err("empty answer".to_owned()),
    }
}
