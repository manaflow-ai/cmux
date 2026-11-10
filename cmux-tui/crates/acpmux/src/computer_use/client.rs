//! The one client of the Computer Use worker: the agent bridge
//! (`acpmux computer-use-mcp`) and the `cmux computer-use` CLI both call
//! through [`Caller`].
//!
//! It never reads a file to find the worker. It asks the cmux-tui daemon
//! (`computer-use-endpoint`, which starts the host when needed) for the
//! socket and the per-launch secret, connects, and sends the call with its
//! `call_id`. On any connection failure (the worker restarted, the secret
//! changed, the socket is gone) it asks the daemon again and resends the
//! SAME `call_id`, with backoff, for up to [`RETRY_BUDGET`]: the worker runs a
//! call id once, so a retried call never acts twice. Only a worker that stays
//! away for the whole budget reaches the agent, as a tool error that says so.

use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use cmux_computer_use::ToolOutput;
use cmux_computer_use::wire::{self, CallRequest};
use serde_json::{Value, json};

/// How long a call keeps retrying a worker that is restarting.
pub const RETRY_BUDGET: Duration = Duration::from_secs(30);
const FIRST_BACKOFF: Duration = Duration::from_millis(100);
const MAX_BACKOFF: Duration = Duration::from_secs(2);
/// One daemon request (the endpoint, the machine list).
const DAEMON_WAIT: Duration = Duration::from_secs(10);
/// The worker's hello after the secret.
const HELLO_WAIT: Duration = Duration::from_secs(10);
/// The longest daemon reply line.
const MAX_DAEMON_REPLY: u64 = 1 << 20;

/// The daemon command that names the worker (lane `worker` serves it).
pub const ENDPOINT_CMD: &str = "computer-use-endpoint";

/// Where the worker serves, from the daemon.
#[derive(Clone, PartialEq, Eq)]
pub struct Endpoint {
    pub socket: String,
    pub secret: String,
    pub pid: Option<u32>,
}

impl std::fmt::Debug for Endpoint {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never print the secret.
        f.debug_struct("Endpoint").field("socket", &self.socket).field("pid", &self.pid).finish()
    }
}

/// The daemon's `computer-use-endpoint` answer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EndpointState {
    Ready(Endpoint),
    /// The host is starting the worker: ask again shortly.
    Starting(String),
    /// `computerUse.mode` is off on this machine.
    Off(String),
    /// No worker can run here now (no display, no permission, an old host).
    Unavailable(String),
}

impl EndpointState {
    pub fn parse(data: &Value) -> Self {
        let reason = data["reason"].as_str().unwrap_or_default().to_owned();
        match data["state"].as_str() {
            Some("ready") => match (data["socket"].as_str(), data["secret"].as_str()) {
                (Some(socket), Some(secret)) if !socket.is_empty() && !secret.is_empty() => {
                    EndpointState::Ready(Endpoint {
                        socket: socket.to_owned(),
                        secret: secret.to_owned(),
                        pid: data["pid"].as_u64().and_then(|p| u32::try_from(p).ok()),
                    })
                }
                _ => EndpointState::Unavailable("the daemon named no worker socket".into()),
            },
            Some("starting") => EndpointState::Starting(reason),
            Some("off") => EndpointState::Off(reason),
            Some("unavailable") => EndpointState::Unavailable(reason),
            other => EndpointState::Unavailable(format!("unknown endpoint state {other:?}")),
        }
    }
}

/// The daemons a call needs. A trait so tests put fakes behind it.
pub trait Daemon: Send + Sync {
    /// The cmux-tui daemon's `computer-use-endpoint` answer (it starts the
    /// host when needed).
    fn endpoint(&self) -> Result<Value, DaemonError>;
    /// One call on another of the person's machines, through this machine's
    /// acpmux daemon and its authenticated peer link
    /// (`_acpmux/computer_use_call`, `server/computer_use_relay.rs`).
    fn remote_call(&self, params: Value) -> Result<Value, DaemonError>;
    /// The person's other machines (`_acpmux/computer_use_machines`).
    fn machines(&self) -> Result<Value, DaemonError>;
    /// The name of the cmux workspace `id` (the daemon's `list-workspaces`), the agent cursor's
    /// default tag; None when the daemon does not know it.
    fn workspace_name(&self, _id: &str) -> Option<String> {
        None
    }
}

/// Where a workspace named `id` sits in a `list-workspaces` answer: its `name`.
pub fn workspace_name_in(tree: &Value, id: &str) -> Option<String> {
    tree.get("workspaces")?
        .as_array()?
        .iter()
        .find(|w| {
            ["id", "uuid", "workspace_id"]
                .iter()
                .any(|key| w.get(*key).and_then(Value::as_str).is_some_and(|v| v.eq_ignore_ascii_case(id)))
        })
        .and_then(|w| w.get("name").or_else(|| w.get("title")))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .map(str::to_owned)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DaemonError {
    /// The daemon could not be reached or closed early: worth a retry.
    Unreachable(String),
    /// The daemon answered with a refusal (an old daemon without the
    /// command, a refused machine). `code` `unreachable` means the peer link
    /// is down: worth a retry too.
    Refused { code: String, message: String },
}

impl std::fmt::Display for DaemonError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DaemonError::Unreachable(why) => write!(f, "the cmux daemon is not reachable: {why}"),
            DaemonError::Refused { code, message } => write!(f, "{message} ({code})"),
        }
    }
}

/// The env naming the cmux-tui daemon socket (acpmux passes its own to the bridge).
pub const DAEMON_SOCKET_ENV: &str = "CMUX_TUI_SOCKET";

/// The real daemons: the cmux-tui daemon on its local socket
/// (`CMUX_TUI_SOCKET`, else the `main` session's default socket) and this
/// user's acpmux daemon (`ACPMUX_SOCKET` / `ACPMUX_HOME`).
pub struct SocketDaemon {
    pub path: PathBuf,
}

impl SocketDaemon {
    pub fn from_env() -> Self {
        let path =
            cmux::raw::env_socket_path().unwrap_or_else(|| cmux::raw::default_socket_path("main"));
        Self { path }
    }

    #[cfg(unix)]
    fn connect(&self) -> io::Result<std::os::unix::net::UnixStream> {
        let stream = std::os::unix::net::UnixStream::connect(&self.path)?;
        stream.set_read_timeout(Some(DAEMON_WAIT))?;
        stream.set_write_timeout(Some(DAEMON_WAIT))?;
        Ok(stream)
    }

    #[cfg(windows)]
    fn connect(&self) -> io::Result<cmux::local_socket::Stream> {
        let stream = cmux::local_socket::connect_same_user(&self.path)?;
        stream.set_read_timeout(Some(DAEMON_WAIT))?;
        stream.set_write_timeout(Some(DAEMON_WAIT))?;
        Ok(stream)
    }

    /// `{"cmd": cmd, ...params}` on a new connection; the reply's `data`.
    pub fn request(&self, cmd: &str, params: Value) -> Result<Value, DaemonError> {
        let unreachable = |e: io::Error| DaemonError::Unreachable(e.to_string());
        let mut stream = self.connect().map_err(unreachable)?;
        let id = format!("cu-{}", uuid::Uuid::now_v7().simple());
        let mut request = match params {
            Value::Object(map) => map,
            _ => serde_json::Map::new(),
        };
        request.insert("id".into(), json!(id));
        request.insert("cmd".into(), json!(cmd));
        let mut line = Value::Object(request).to_string();
        line.push('\n');
        stream.write_all(line.as_bytes()).map_err(unreachable)?;
        stream.flush().map_err(unreachable)?;
        let mut reader = BufReader::new((&mut stream).take(MAX_DAEMON_REPLY));
        loop {
            let mut reply = String::new();
            if reader.read_line(&mut reply).map_err(unreachable)? == 0 {
                return Err(DaemonError::Unreachable("the daemon closed the connection".into()));
            }
            let Ok(reply) = serde_json::from_str::<Value>(&reply) else { continue };
            if reply["id"] != json!(id) {
                continue; // an event or another answer
            }
            return daemon_reply(&reply);
        }
    }
}

/// Runs `fut` to completion from a blocking thread: on the current tokio
/// runtime when there is one (the bridge's calls run in `spawn_blocking`),
/// else on a small runtime of its own (the CLI).
fn block_on<T>(
    fut: impl std::future::Future<Output = Result<T, DaemonError>>,
) -> Result<T, DaemonError> {
    match tokio::runtime::Handle::try_current() {
        Ok(handle) => handle.block_on(fut),
        Err(_) => match tokio::runtime::Builder::new_current_thread().enable_all().build() {
            Ok(runtime) => runtime.block_on(fut),
            Err(e) => {
                Err(DaemonError::Unreachable(format!("no runtime for the acpmux daemon: {e}")))
            }
        },
    }
}

/// One acpmux daemon request; an `RpcError`'s `data.code` becomes the code.
pub fn acpmux_request(method: &str, params: Value) -> Result<Value, DaemonError> {
    block_on(async move {
        let client = crate::daemon::connect(false)
            .await
            .map_err(|e| DaemonError::Unreachable(format!("{e:#}")))?;
        client.request(method, params).await.map_err(|e| {
            match e.downcast_ref::<crate::client::DaemonError>() {
                Some(crate::client::DaemonError(rpc)) => DaemonError::Refused {
                    code: rpc
                        .data
                        .as_ref()
                        .and_then(|d| d["code"].as_str())
                        .unwrap_or("refused")
                        .to_owned(),
                    message: rpc.message.clone(),
                },
                None => DaemonError::Unreachable(format!("{e:#}")),
            }
        })
    })
}

impl Daemon for SocketDaemon {
    fn endpoint(&self) -> Result<Value, DaemonError> {
        self.request(ENDPOINT_CMD, json!({}))
    }

    fn remote_call(&self, params: Value) -> Result<Value, DaemonError> {
        acpmux_request(crate::rpc::method::MUX_COMPUTER_USE_CALL, params)
    }

    fn machines(&self) -> Result<Value, DaemonError> {
        acpmux_request(crate::rpc::method::MUX_COMPUTER_USE_MACHINES, json!({}))
    }

    fn workspace_name(&self, id: &str) -> Option<String> {
        workspace_name_in(&self.request("list-workspaces", json!({})).ok()?, id)
    }
}

/// The `data` of a cmux-tui daemon reply, or why it refused (classic
/// `{ok:false, error, error_code}`).
pub fn daemon_reply(reply: &Value) -> Result<Value, DaemonError> {
    if reply["ok"] == json!(true) {
        return Ok(reply.get("data").cloned().unwrap_or(Value::Null));
    }
    let error = &reply["error"];
    let message = match error {
        Value::String(text) => text.clone(),
        Value::Object(_) => error["message"].as_str().unwrap_or("the daemon refused").to_owned(),
        _ => "the daemon refused".to_owned(),
    };
    let code = reply["error_code"]
        .as_str()
        .or_else(|| error["code"].as_str())
        .unwrap_or("refused")
        .to_owned();
    Err(DaemonError::Refused { code, message })
}

/// Why one attempt to reach the worker failed.
#[derive(Debug)]
enum Attempt {
    /// The connection failed or closed: ask the daemon again, resend.
    Transport(String),
    /// The worker answered the request with an error (not a tool result).
    Worker(String),
}

trait Duplex: Read + Write {}
impl<T: Read + Write> Duplex for T {}

/// A connection to the worker, and how to lift the hello's read timeout
/// once admitted (a call may wait on the person's approval).
struct Conn {
    stream: Box<dyn Duplex>,
    unbounded: Box<dyn FnOnce()>,
}

fn open(socket: &str) -> io::Result<Conn> {
    #[cfg(windows)]
    if socket.starts_with(r"\\.\pipe\") {
        // A named pipe has no read timeout; the hello waits on the worker.
        let pipe = std::fs::OpenOptions::new().read(true).write(true).open(socket)?;
        return Ok(Conn { stream: Box::new(pipe), unbounded: Box::new(|| {}) });
    }
    #[cfg(unix)]
    let stream = std::os::unix::net::UnixStream::connect(socket)?;
    #[cfg(windows)]
    let stream = cmux::local_socket::connect_same_user(std::path::Path::new(socket))?;
    stream.set_write_timeout(Some(HELLO_WAIT))?;
    stream.set_read_timeout(Some(HELLO_WAIT))?;
    let handle = stream.try_clone()?;
    Ok(Conn {
        stream: Box::new(stream),
        unbounded: Box::new(move || {
            let _ = handle.set_read_timeout(None);
        }),
    })
}

/// One connection: the secret, the hello, then `request`'s answer.
fn exchange(endpoint: &Endpoint, request: &Value) -> Result<Value, Attempt> {
    let transport = |e: io::Error| Attempt::Transport(e.to_string());
    let Conn { stream, unbounded } = open(&endpoint.socket).map_err(transport)?;
    let mut reader = BufReader::new(stream);
    let mut hello = json!({"secret": endpoint.secret}).to_string();
    hello.push('\n');
    reader.get_mut().write_all(hello.as_bytes()).map_err(transport)?;
    let answer = read_json(&mut reader).map_err(transport)?;
    if answer["ok"] != json!(true) {
        // A stale secret after a worker restart: ask the daemon again.
        let reason = answer["reason"].as_str().unwrap_or("refused");
        return Err(Attempt::Transport(format!("the worker refused this connection: {reason}")));
    }
    unbounded();
    let mut line = request.to_string();
    line.push('\n');
    reader.get_mut().write_all(line.as_bytes()).map_err(transport)?;
    reader.get_mut().flush().map_err(transport)?;
    loop {
        let reply = read_json(&mut reader).map_err(transport)?;
        if reply["id"] != request["id"] {
            continue;
        }
        if reply["ok"] == json!(true) {
            return Ok(reply.get("result").cloned().unwrap_or(Value::Null));
        }
        let error = reply["error"].as_str().unwrap_or("error");
        let reason = reply["reason"].as_str().unwrap_or_default();
        return Err(Attempt::Worker(if reason.is_empty() {
            error.to_owned()
        } else {
            format!("{error}: {reason}")
        }));
    }
}

fn read_json(reader: &mut BufReader<Box<dyn Duplex>>) -> io::Result<Value> {
    let mut total = 0usize;
    let mut buf = Vec::new();
    loop {
        let available = match reader.fill_buf() {
            Ok(bytes) => bytes,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };
        if available.is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "the worker closed the connection",
            ));
        }
        let (used, done) = match available.iter().position(|b| *b == b'\n') {
            Some(at) => (at + 1, true),
            None => (available.len(), false),
        };
        buf.extend_from_slice(&available[..used]);
        reader.consume(used);
        total += used;
        if total > wire::MAX_LINE {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "the worker's answer is too long",
            ));
        }
        if done {
            return serde_json::from_slice(&buf)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e.to_string()));
        }
    }
}

/// What a call ended with.
#[derive(Clone, Debug, PartialEq)]
pub enum Outcome {
    /// The worker's result, refusals included (`is_error` as returned).
    Output(ToolOutput),
    /// Computer Use is off on the machine.
    Off(String),
    /// No worker answered within the budget, or the request was refused.
    Failed { code: String, message: String },
}

impl Outcome {
    /// The MCP `tools/call` result.
    pub fn to_mcp(&self) -> Value {
        match self {
            Outcome::Output(out) => out.to_mcp(),
            Outcome::Off(reason) => ToolOutput::error(
                "computer_use_off",
                if reason.is_empty() {
                    "Computer Use is off on this machine. The person can turn it on in Settings > Computer Use.".to_owned()
                } else {
                    format!("Computer Use is off: {reason}. The person can turn it on in Settings > Computer Use.")
                },
            )
            .to_mcp(),
            Outcome::Failed { code, message } => ToolOutput::error(code, message.clone()).to_mcp(),
        }
    }
}

/// A new call id; a retry of the same call reuses it.
pub fn new_call_id() -> String {
    uuid::Uuid::now_v7().to_string()
}

/// Who calls, for every request of one session.
pub struct Caller<D: Daemon> {
    pub daemon: D,
    /// The session key (the acpmux agent session id; `cli` for the CLI).
    pub session: String,
    /// Shown to the person: "Claude Code", "Codex".
    label: Mutex<String>,
    /// Set only by a daemon that runs a call for another machine, from its
    /// authenticated peer (`server/computer_use_relay.rs`); never from a
    /// request. None: the worker treats the call as local.
    origin: Option<Value>,
    budget: Duration,
    sleep: fn(Duration),
    endpoint: Mutex<Option<Endpoint>>,
    next_id: std::sync::atomic::AtomicU64,
    /// The agent cursor's tag: the one the agent set (`cursor_tag`, kept for the session's later
    /// calls), else its cmux workspace's name, read from the daemon on the first call.
    tag: Mutex<CursorTag>,
}

/// Where the agent cursor's tag comes from.
#[derive(Default)]
struct CursorTag {
    /// Set by the agent (`cursor_tag` on a tool call).
    agent: Option<String>,
    /// The workspace the agent runs in (`CMUX_WORKSPACE_ID`), until its name is read.
    workspace: Option<String>,
    /// That workspace's name, once read (None after a read that found none).
    workspace_name: Option<Option<String>>,
}

impl<D: Daemon> Caller<D> {
    pub fn new(daemon: D, session: String, label: String) -> Self {
        Self {
            daemon,
            session,
            label: Mutex::new(label),
            origin: None,
            budget: RETRY_BUDGET,
            sleep: std::thread::sleep,
            endpoint: Mutex::new(None),
            next_id: std::sync::atomic::AtomicU64::new(1),
            tag: Mutex::new(CursorTag::default()),
        }
    }

    /// The cmux workspace the agent runs in: its name is the cursor's default tag.
    pub fn with_workspace(self, id: Option<String>) -> Self {
        if let Ok(mut tag) = self.tag.lock() {
            tag.workspace = id.filter(|id| !id.trim().is_empty());
        }
        self
    }

    /// The agent's own cursor tag (a call's `cursor_tag`): kept for the session's later calls; an
    /// empty one goes back to the workspace's name.
    pub fn set_cursor_tag(&self, tag: &str) {
        if let Ok(mut slot) = self.tag.lock() {
            slot.agent = cmux_computer_use::tools::safe_tag(tag);
        }
    }

    /// The tag a call carries now (reads the workspace's name once, on this blocking thread).
    pub fn cursor_tag(&self) -> Option<String> {
        let workspace = {
            let tag = self.tag.lock().ok()?;
            if let Some(agent) = &tag.agent {
                return Some(agent.clone());
            }
            if let Some(name) = &tag.workspace_name {
                return name.clone();
            }
            tag.workspace.clone()?
        };
        let name = self.daemon.workspace_name(&workspace).and_then(|n| cmux_computer_use::tools::safe_tag(&n));
        if let Ok(mut tag) = self.tag.lock() {
            tag.workspace_name = Some(name.clone());
        }
        name
    }

    /// The same caller for a call another machine sent: `origin` is
    /// `{"kind":"remote","machine":..,"same_account":..}` from the link.
    pub fn with_origin(mut self, origin: Value) -> Self {
        self.origin = Some(origin);
        self
    }

    /// What the person sees as the caller (the agent's MCP `clientInfo`).
    pub fn set_label(&self, label: &str) {
        let label: String = label.chars().filter(|c| !c.is_control()).take(80).collect();
        if let (false, Ok(mut slot)) = (label.trim().is_empty(), self.label.lock()) {
            *slot = label;
        }
    }

    pub fn label(&self) -> String {
        self.label.lock().map(|l| l.clone()).unwrap_or_default()
    }

    /// The same caller with another retry budget (tests).
    pub fn with_budget(mut self, budget: Duration) -> Self {
        self.budget = budget;
        self
    }

    fn id(&self) -> u64 {
        self.next_id.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    }

    /// Runs tool `name` once (by `call_id`) on this machine, or on
    /// `arguments.machine` through the daemon's machine route.
    pub fn call(&self, name: &str, arguments: &Value, call_id: &str) -> Outcome {
        let mut arguments = if arguments.is_object() { arguments.clone() } else { json!({}) };
        // The agent's cursor tag is the bridge's, not the tool's: it stays for the later calls.
        if let Some(tag) =
            arguments.as_object_mut().and_then(|a| a.remove(cmux_computer_use::tools::CURSOR_TAG_ARG))
        {
            self.set_cursor_tag(tag.as_str().unwrap_or_default());
        }
        let machine = arguments
            .as_object_mut()
            .and_then(|a| a.remove("machine"))
            .and_then(|m| m.as_str().map(str::trim).map(str::to_owned))
            .filter(|m| !m.is_empty());
        if self.origin.is_some() && (machine.is_some() || name == "list_machines") {
            // A call another machine sent runs here, never one hop further.
            return Outcome::Failed {
                code: "computer_use_remote_denied".into(),
                message: "a call from another machine runs only on this one".into(),
            };
        }
        if name == "list_machines" && machine.is_none() {
            return self.list_machines();
        }
        if let Some(machine) = machine {
            return self.remote(&machine, name, &arguments, call_id);
        }
        let request = CallRequest {
            id: self.id(),
            method: "tools/call".into(),
            name: Some(name.to_owned()),
            arguments,
            session: self.session.clone(),
            label: self.label(),
            call_id: Some(call_id.to_owned()),
            tag: self.cursor_tag(),
        };
        let mut request = serde_json::to_value(&request).unwrap_or(Value::Null);
        if let (Some(origin), Some(map)) = (&self.origin, request.as_object_mut()) {
            map.insert("origin".into(), origin.clone());
        }
        match self.send(&request) {
            Ok(result) => match ToolOutput::from_json(&result) {
                Some(out) => Outcome::Output(out),
                None => Outcome::Failed {
                    code: "worker_error".into(),
                    message: "the Computer Use worker sent a result this cmux cannot read".into(),
                },
            },
            // `status` still answers with Computer Use off: that is its status.
            Err(Outcome::Off(reason)) if name == "status" => {
                Outcome::Output(ToolOutput::ok(json!({
                    "engine": "cmux Computer Use",
                    "mode": "off",
                    "reason": reason,
                    "settings": "Settings > Computer Use",
                })))
            }
            Err(outcome) => outcome,
        }
    }

    /// `method` with no tool (`status`, `session/end`) to the local worker.
    pub fn request(&self, method: &str, extra: Value) -> Result<Value, Outcome> {
        let mut request = json!({"id": self.id(), "method": method, "session": self.session});
        if let (Some(target), Value::Object(extra)) = (request.as_object_mut(), extra) {
            target.extend(extra);
        }
        self.send(&request)
    }

    /// Ends the session on the worker, once, best effort (no retry: an
    /// unreachable worker has no session state to end).
    pub fn end_session(&self) {
        let Ok(Some(endpoint)) = self.endpoint.lock().map(|e| e.clone()) else { return };
        let request = json!({"id": self.id(), "method": "session/end", "session": self.session});
        let _ = exchange(&endpoint, &request);
    }

    fn send(&self, request: &Value) -> Result<Value, Outcome> {
        let deadline = Instant::now() + self.budget;
        let mut backoff = FIRST_BACKOFF;
        let mut last = String::new();
        loop {
            let cached = self.endpoint.lock().ok().and_then(|e| e.clone());
            let endpoint = match cached {
                Some(endpoint) => Some(endpoint),
                None => match self.daemon.endpoint() {
                    Ok(data) => match EndpointState::parse(&data) {
                        EndpointState::Ready(endpoint) => {
                            if let Ok(mut slot) = self.endpoint.lock() {
                                *slot = Some(endpoint.clone());
                            }
                            Some(endpoint)
                        }
                        EndpointState::Off(reason) => return Err(Outcome::Off(reason)),
                        EndpointState::Starting(reason) => {
                            last = if reason.is_empty() {
                                "the worker is starting".into()
                            } else {
                                reason
                            };
                            None
                        }
                        EndpointState::Unavailable(reason) => {
                            last = reason;
                            None
                        }
                    },
                    Err(DaemonError::Refused { code, message }) => {
                        // A daemon without the command never gets it by waiting.
                        return Err(Outcome::Failed {
                            code: "computer_use_unavailable".into(),
                            message: format!(
                                "cmux could not start Computer Use: {message} ({code})"
                            ),
                        });
                    }
                    Err(e) => {
                        last = e.to_string();
                        None
                    }
                },
            };
            if let Some(endpoint) = endpoint {
                match exchange(&endpoint, request) {
                    Ok(result) => return Ok(result),
                    Err(Attempt::Worker(message)) => {
                        return Err(Outcome::Failed { code: "worker_error".into(), message });
                    }
                    Err(Attempt::Transport(why)) => {
                        if let Ok(mut slot) = self.endpoint.lock() {
                            *slot = None;
                        }
                        last = why;
                    }
                }
            }
            let now = Instant::now();
            if now >= deadline {
                return Err(Outcome::Failed {
                    code: "computer_use_unavailable".into(),
                    message: format!(
                        "cmux Computer Use did not answer for {} s ({last}). It restarts by itself; try again in a moment, or call status.",
                        self.budget.as_secs()
                    ),
                });
            }
            (self.sleep)(backoff.min(deadline - now));
            backoff = (backoff * 2).min(MAX_BACKOFF);
        }
    }

    /// `list_machines`: this machine's daemon knows the person's machines.
    fn list_machines(&self) -> Outcome {
        match self.daemon.machines() {
            Ok(data) => Outcome::Output(ToolOutput::ok(json!({
                "machines": data.get("machines").cloned().unwrap_or_else(|| json!([])),
            }))),
            Err(DaemonError::Refused { code, message }) => Outcome::Output(ToolOutput::ok(json!({
                "machines": [],
                "note": format!("Only this machine is reachable from here ({message}, {code})."),
            }))),
            Err(e) => {
                Outcome::Failed { code: "computer_use_unavailable".into(), message: e.to_string() }
            }
        }
    }

    /// One call on `machine`: the local daemon forwards it over the
    /// person's authenticated machine link; the remote daemon sets the
    /// origin from that link. A lost link retries the same call id.
    fn remote(&self, machine: &str, name: &str, arguments: &Value, call_id: &str) -> Outcome {
        let deadline = Instant::now() + self.budget;
        let mut backoff = FIRST_BACKOFF;
        let params = json!({
            "machine": machine,
            "name": name,
            "arguments": arguments,
            "session": self.session,
            "label": self.label(),
            "call_id": call_id,
            "tag": self.cursor_tag(),
        });
        loop {
            match self.daemon.remote_call(params.clone()) {
                Ok(data) => {
                    return match data.get("result").and_then(ToolOutput::from_json) {
                        Some(out) => Outcome::Output(out),
                        None if data["state"] == "off" => Outcome::Off(format!(
                            "on {machine}: {}",
                            data["reason"].as_str().unwrap_or("off")
                        )),
                        None => Outcome::Failed {
                            code: "worker_error".into(),
                            message: format!("{machine} sent a result this cmux cannot read"),
                        },
                    };
                }
                Err(DaemonError::Refused { code, message }) => {
                    if code != "unreachable" && code != "retry" {
                        return Outcome::Failed { code, message };
                    }
                    if Instant::now() >= deadline {
                        return Outcome::Failed { code, message };
                    }
                }
                Err(e) => {
                    if Instant::now() >= deadline {
                        return Outcome::Failed {
                            code: "computer_use_unavailable".into(),
                            message: e.to_string(),
                        };
                    }
                }
            }
            let now = Instant::now();
            (self.sleep)(backoff.min(deadline.saturating_duration_since(now)));
            backoff = (backoff * 2).min(MAX_BACKOFF);
        }
    }
}

#[cfg(test)]
#[path = "client_tests.rs"]
mod tests;
