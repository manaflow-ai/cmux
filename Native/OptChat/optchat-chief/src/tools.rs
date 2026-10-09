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
    /// Starts one subagent per task, in `cwd` when it exists on this host;
    /// answers their ids, each one's workspace (or why it has none) and the
    /// directory they run in.
    fn spawn(&self, tasks: Vec<String>, cwd: Option<String>) -> Result<String, String>;
    /// Sends `message` to subagent `id`.
    fn tell(&self, id: &str, message: &str) -> Result<String, String>;
    /// Subagent `id`'s whole chat (`zoom("a<N>")`), one page from
    /// character `at`.
    fn agent_chat(&self, id: &str, at: u64) -> Result<String, String>;
}

/// What `chief zoom|date|spawn|tell WORDS` asks: the tool call, its usage
/// asked for (`--help`, `-h`), or its usage for words that do not fit.
#[derive(Debug, PartialEq)]
pub enum Command {
    Call(Call),
    Help(String),
    Usage(String),
}

/// The command line form of the memory and subagent tools.
pub fn command(tool: &str, args: &[&str]) -> Result<Command, String> {
    // A flag is never a task or a message: asking for help starts nothing.
    if args.iter().any(|a| matches!(*a, "--help" | "-h")) {
        return Ok(Command::Help(usage(tool)));
    }
    let call = match (tool, args) {
        ("zoom", [id]) if agent_id(id) => Call::parse("zoom", &serde_json::json!({"id": id})),
        ("zoom", [id, at]) if agent_id(id) => {
            Call::parse("zoom", &serde_json::json!({"id": id, "at": at}))
        }
        ("zoom", [id, n]) => Call::parse("zoom", &serde_json::json!({"id": id, "n": n})),
        ("date", [id]) => Call::parse("date", &serde_json::json!({"id": id})),
        ("spawn", ["--cwd", dir, tasks @ ..]) if !tasks.is_empty() => {
            Call::parse("spawn", &serde_json::json!({"tasks": tasks, "cwd": dir}))
        }
        ("spawn", tasks) if !tasks.is_empty() && tasks[0] != "--cwd" => {
            Call::parse("spawn", &serde_json::json!({"tasks": tasks}))
        }
        ("tell", [id, message @ ..]) if !message.is_empty() => Call::parse(
            "tell",
            &serde_json::json!({"id": id, "message": message.join(" ")}),
        ),
        _ => return Ok(Command::Usage(usage(tool))),
    };
    call.map(Command::Call)
}

/// `usage: optchat-chief TOOL ARGS`.
pub fn usage(tool: &str) -> String {
    format!(
        "usage: optchat-chief {tool} {}",
        match tool {
            "zoom" => "ID N | SUBAGENT [AT]",
            "date" => "ID",
            "spawn" => "[--cwd DIR] \"task\" [\"task\" ...]",
            _ => "ID \"message\"",
        }
    )
}

/// A subagent id (`a<N>`) where zoom takes a message id: it starts with a letter.
pub fn agent_id(id: &str) -> bool {
    id.trim().starts_with(|c: char| c.is_ascii_alphabetic())
}

/// One tool call.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Call {
    Zoom {
        id: u64,
        n: u64,
    },
    /// `zoom("a<N>")`: a subagent's whole chat from character `at`.
    ZoomAgent {
        id: String,
        at: u64,
    },
    Date {
        id: u64,
    },
    Spawn {
        tasks: Vec<String>,
        /// The subagents' working directory on the Chief's host (`~` is
        /// its home); None is the default subagent directory.
        cwd: Option<String>,
    },
    Tell {
        id: String,
        message: String,
    },
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
            "zoom" if args.get("id").and_then(Value::as_str).is_some_and(agent_id) => {
                Ok(Call::ZoomAgent {
                    id: args["id"].as_str().unwrap_or_default().trim().to_owned(),
                    at: if args.get("at").is_some() {
                        num("at")?
                    } else {
                        0
                    },
                })
            }
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
                let cwd = args
                    .get("cwd")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|d| !d.is_empty())
                    .map(str::to_owned);
                Ok(Call::Spawn { tasks, cwd })
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
            Call::Spawn { .. } | Call::Tell { .. } | Call::ZoomAgent { .. } => {
                "spawn, tell and a subagent's zoom are served by the Chief host".to_owned()
            }
        }
    }

    fn to_json(&self) -> Value {
        match self {
            Call::Zoom { id, n } => json!({"tool": "zoom", "id": id, "n": n}),
            Call::ZoomAgent { id, at } => json!({"tool": "zoom", "id": id, "at": at}),
            Call::Date { id } => json!({"tool": "date", "id": id}),
            Call::Spawn { tasks, cwd: None } => json!({"tool": "spawn", "tasks": tasks}),
            Call::Spawn {
                tasks,
                cwd: Some(cwd),
            } => json!({"tool": "spawn", "tasks": tasks, "cwd": cwd}),
            Call::Tell { id, message } => json!({"tool": "tell", "id": id, "message": message}),
        }
    }
}

/// The host's per-Chief settings over the socket (`optchat-chief settings`):
/// `Some((key, value))` sets one, None shows them all. Not a model tool:
/// the MCP server never offers it, and the host refuses turning
/// `remote.autoApprove` on during remote-origin work.
pub type Control = Arc<dyn Fn(ControlRequest) -> Result<String, String> + Send + Sync>;

/// What `optchat-chief settings` and `chief agents spawn` ask the host.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ControlRequest {
    /// The per-Chief settings as JSON.
    Show,
    /// Sets one setting.
    Set(String, String),
    /// The policy floor for a child spawned now: `ask`, or empty for none.
    SpawnPolicy,
    /// chief.engine.get / chief.engine.set: answers the brain's JSON value.
    Engine(crate::brain::EngineRequest),
    /// chief.stop: answers `{"stopped": bool}`.
    Stop,
}

/// What the tools socket serves: the memory, the subagent tools when the
/// host runs them, and the host's settings control.
#[derive(Clone)]
pub struct Served {
    pub memory: Arc<dyn Memory>,
    pub orchestrator: Option<Arc<dyn Orchestrator>>,
    pub control: Option<Control>,
    /// The memory inspector's read-only API (`inspect` tool): a remote
    /// owner reaches it through the brain's daemon (`chief.inspect`).
    pub inspector: Option<Arc<crate::inspect::Inspector>>,
}

/// Serves the tools on `path` until the process ends. The host holds the
/// host lock, so a socket file left by an earlier host is stale and replaced.
pub fn serve(path: &Path, memory: Arc<dyn Memory>) -> std::io::Result<()> {
    serve_with(path, memory, None)
}

/// `serve`, with the host's settings `control`.
pub fn serve_with(
    path: &Path,
    memory: Arc<dyn Memory>,
    control: Option<Control>,
) -> std::io::Result<()> {
    serve_all(
        path,
        Served {
            memory,
            orchestrator: None,
            control,
            inspector: None,
        },
    )
}

/// Serves the memory, the subagent tools and the settings control on `path`.
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
    let control = served.control.as_ref();
    let Ok(mut out) = conn.try_clone() else {
        return;
    };
    for line in BufReader::new(conn).lines() {
        let Ok(line) = line else { return };
        let answer = match serde_json::from_str::<Value>(&line) {
            Ok(req) => {
                let tool = req.get("tool").and_then(Value::as_str).unwrap_or("");
                // Not a model tool: the `browse` command asks the live host.
                if tool == "settings" || tool == "spawn_policy" {
                    let ask = match req.get("key").and_then(Value::as_str) {
                        _ if tool == "spawn_policy" => ControlRequest::SpawnPolicy,
                        Some(k) => {
                            let v = req.get("value").and_then(Value::as_str).unwrap_or("");
                            ControlRequest::Set(k.to_owned(), v.to_owned())
                        }
                        None => ControlRequest::Show,
                    };
                    let answer = match control {
                        Some(control) => match control(ask) {
                            Ok(text) => json!({"text": text}),
                            Err(e) => json!({"error": e}),
                        },
                        None => json!({"error": "settings are not served here"}),
                    };
                    if writeln!(out, "{answer}").is_err() {
                        return;
                    }
                    continue;
                }
                // chief.engine.get / chief.engine.set / chief.stop: the
                // brain's JSON value as the answer line (the daemon's
                // owner-gated chief-control forwards these lines).
                if tool == "engine" || tool == "stop" {
                    let field = |k: &str| req.get(k).and_then(Value::as_str).map(str::to_owned);
                    let ask = match (tool, field("action").as_deref()) {
                        ("stop", _) => Some(ControlRequest::Stop),
                        (_, Some("show") | None) => {
                            Some(ControlRequest::Engine(crate::brain::EngineRequest::Show))
                        }
                        (_, Some("set")) => {
                            Some(ControlRequest::Engine(crate::brain::EngineRequest::Set {
                                harness: field("harness"),
                                model: field("model"),
                                effort: field("effort"),
                            }))
                        }
                        _ => None,
                    };
                    let answer = match (ask, control) {
                        (None, _) => {
                            json!({"error": {"code": "bad_request", "message": "engine action is show or set"}})
                        }
                        (Some(_), None) => {
                            json!({"error": {"code": "unavailable", "message": "the engine control is not served here"}})
                        }
                        (Some(ask), Some(control)) => match control(ask) {
                            Ok(text) => serde_json::from_str(&text).unwrap_or_else(
                                |_| json!({"error": {"code": "internal", "message": text}}),
                            ),
                            Err(e) => json!({"error": {"code": "unavailable", "message": e}}),
                        },
                    };
                    if writeln!(out, "{answer}").is_err() {
                        return;
                    }
                    continue;
                }
                if tool == "inspect" {
                    let answer = match &served.inspector {
                        Some(inspector) => crate::inspect::tool_answer(
                            inspector,
                            &req,
                            crate::inspect::INSPECT_MAX_BYTES,
                        ),
                        None => {
                            json!({"status": 503, "error": "the inspector is off on this host"})
                        }
                    };
                    if writeln!(out, "{answer}").is_err() {
                        return;
                    }
                    continue;
                }
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
                    Ok(Call::Spawn { tasks, cwd }) => match &served.orchestrator {
                        Some(o) => o.spawn(tasks, cwd),
                        None => Err("this Chief host runs no subagents".to_owned()),
                    },
                    Ok(Call::Tell { id, message }) => match &served.orchestrator {
                        Some(o) => o.tell(&id, &message),
                        None => Err("this Chief host runs no subagents".to_owned()),
                    },
                    // A subagent may read another's chat too (the reference
                    // client gives zoom to every agent).
                    Ok(Call::ZoomAgent { id, at }) => match &served.orchestrator {
                        Some(o) => o.agent_chat(&id, at),
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

/// Shows (None) or sets (`Some((key, value))`) the live host's settings.
pub fn ask_settings(path: &Path, set: Option<(&str, &str)>) -> Result<String, String> {
    let request = match set {
        Some((key, value)) => json!({"tool": "settings", "key": key, "value": value}),
        None => json!({"tool": "settings"}),
    };
    ask_json(path, &request)
}

/// The live host's policy floor for a child spawned now (`Some("ask")`),
/// or None. Err when no host answers: the caller fails closed.
pub fn ask_spawn_policy(path: &Path) -> Result<Option<String>, String> {
    let text = ask_json(path, &json!({"tool": "spawn_policy"}))?;
    Ok((!text.is_empty()).then_some(text))
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
