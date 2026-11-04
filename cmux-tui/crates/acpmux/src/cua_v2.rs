//! The cmux Computer Use helper v2 bridge (`acpmux cua-mcp`).
//!
//! With `computerUse.driver = "upstream"` the cmux app runs the helper v2,
//! which loads upstream Cua Driver in process and serves a Unix socket. That
//! socket admits a peer only when (1) it runs as this user, (2) its code is
//! this acpmux build (cdhash, checked with the peer's audit token), (3) an
//! acpmux daemon the app registered is one of its ancestors, and (4) it
//! presents the per-launch secret. So an agent reaches the helper only
//! through this bridge, which runs as the agent's MCP stdio server, a
//! descendant of this daemon.
//!
//! The app names the endpoint folder in [`ENDPOINT_DIR_ENV`] when it spawns
//! this daemon; `endpoint.json` there (0600 in a 0700 folder) holds the
//! socket path and the secret while the helper v2 runs, and is gone
//! otherwise. Sessions get this bridge instead of `cmux-cua mcp` only while
//! the file exists (agent_tools.rs). The bridge reads the file when it
//! connects, never from argv or its env.
//!
//! A host crash leaves `endpoint.json` behind: [`active_dir`] checks that
//! its helper still runs and removes a stale file ([`liveness`], cx-zgk0).
//!
//! Windows (docs/cmux-remote.md, "Windows and Linux"): the cmux Remote host's
//! Computer Use worker serves the named pipe `\\.\pipe\cmux-remote-<leaf>-cu`
//! (owner-only DACL, remote clients rejected) and writes `endpoint.json`
//! (`socket` is that pipe name, `secret`, `pid`, `start`: the worker's
//! creation time). The bridge reads the file only when it is private to this
//! user by its handle's owner and DACL (instead of `fstat` uid and mode),
//! accepts only a local pipe name, connects with identification-only QoS
//! (waiting a bounded time while every instance is busy) and sends the
//! secret only after the pipe's server process runs as this user ([`pipe`]).
//! The worker admits the bridge as on Linux: this build's acpmux image, a
//! descendant of an acpmux daemon the host registered, the secret.
//!
//! Before every tool action, the admitted helper answers `machine/consent`
//! with `{consentRequired: bool, consent: {screen, control}}`, each state
//! `none` or `granted`. The helper obtains this from its established app-owned
//! daemon connection; a child environment or request never picks the authority.
//! Missing support, malformed replies and a two-second timeout deny the action.
//!
//! After admission the bridge sends `session/hello` with the session's
//! display labels ([`Labels`]: agent, workspace, client), which acpmux set
//! in the bridge's env when it spawned the session; never authority. A call
//! the worker refuses with `approval_timeout`, `approval_denied` or
//! `approval_pending` becomes a tool error that says the person was asked
//! ([`ApprovalRefusal`]); the connection, and with it the session's grants,
//! stays open (docs/computer-use-approvals.md).
//!
//! Tool names and arguments stay upstream-shaped. The trusted bridge adds
//! the session's target allow-list to the helper envelope, outside model
//! arguments; the Swift host resolves targets and enforces the policy.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow, bail};
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt, BufReader};
#[cfg(unix)]
use tokio::net::UnixStream;
#[cfg(windows)]
use tokio::net::windows::named_pipe::NamedPipeClient;

mod approval;
pub mod cli_bridge;
pub mod labels;
mod liveness;
#[cfg(windows)]
mod pipe;

pub use approval::{ApprovalRefusal, WorkerError};
pub use labels::Labels;

pub use liveness::Owner;
#[cfg(target_os = "macos")]
pub(crate) use liveness::start_time;

/// The helper v2 endpoint folder the app exports to this daemon.
pub const ENDPOINT_DIR_ENV: &str = "CMUX_NEXT_CUA_V2_DIR";
/// The endpoint file in [`ENDPOINT_DIR_ENV`].
pub const ENDPOINT_FILE: &str = "endpoint.json";
/// The MCP server name agents see (the same as the legacy server).
pub const SERVER_NAME: &str = "cmux-cua";

/// `endpoint.json`.
#[derive(Clone, PartialEq, Eq)]
pub struct Endpoint {
    pub socket: PathBuf,
    pub secret: String,
    /// The helper process, when the app recorded it.
    pub owner: Option<Owner>,
}

impl std::fmt::Debug for Endpoint {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never print the secret.
        f.debug_struct("Endpoint").field("socket", &self.socket).finish_non_exhaustive()
    }
}

/// The endpoint folder from this daemon's env, when the app set one.
pub fn dir_from_env() -> Option<PathBuf> {
    std::env::var_os(ENDPOINT_DIR_ENV).filter(|v| !v.is_empty()).map(PathBuf::from)
}

/// The folder, when the helper v2 runs now: its `endpoint.json` exists, the
/// helper it names is alive and its socket accepts a connection. A file a
/// host crash left behind (its helper gone) is removed, and sessions get the
/// legacy server; a live helper's file stays when its socket refuses once.
/// A file the bridge would refuse (not private, not JSON) keeps the folder,
/// so the agent's tool call reports why.
pub fn active_dir(dir: Option<PathBuf>) -> Option<PathBuf> {
    let dir = dir.filter(|d| d.join(ENDPOINT_FILE).is_file())?;
    if let Ok((endpoint, text)) = read_endpoint_text(&dir)
        && let Err(stale) = liveness::check(endpoint.owner, &endpoint.socket)
    {
        tracing::warn!(?stale, dir = %dir.display(), "Computer Use helper v2 endpoint not usable");
        if stale.removable() {
            liveness::remove_if_unchanged(&dir.join(ENDPOINT_FILE), &text);
        }
        return None;
    }
    Some(dir)
}

/// Reads `endpoint.json` in `dir`. The file must be a regular file of this
/// user that no other user can read or write, checked on the opened file,
/// not by path (`fstat` uid and mode on Unix; the handle's owner and DACL on
/// Windows): another local user (fleet Macs run several slot users) must not
/// be able to point the bridge, and its secret, at a socket of theirs.
pub fn read_endpoint(dir: &Path) -> Result<Endpoint> {
    read_endpoint_text(dir).map(|(endpoint, _)| endpoint)
}

/// [`read_endpoint`] and the file's text.
fn read_endpoint_text(dir: &Path) -> Result<(Endpoint, String)> {
    let path = dir.join(ENDPOINT_FILE);
    let text = read_private_text(&path)?;
    let endpoint = parse_endpoint(&text)?;
    #[cfg(windows)]
    if !is_local_pipe_name(&endpoint.socket.to_string_lossy()) {
        bail!(
            "{} names {}, not a local named pipe; refusing it",
            path.display(),
            endpoint.socket.display()
        );
    }
    Ok((endpoint, text))
}

fn not_running(path: &Path) -> anyhow::Error {
    anyhow!("the Computer Use helper v2 is not running ({} is missing)", path.display())
}

#[cfg(unix)]
fn read_private_text(path: &Path) -> Result<String> {
    use std::io::Read;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                not_running(path)
            } else {
                anyhow!("cannot open {}: {e}", path.display())
            }
        })?;
    let meta = file.metadata().context("cannot stat endpoint.json")?;
    // SAFETY: geteuid has no preconditions.
    let me = unsafe { libc::geteuid() };
    if !meta.file_type().is_file() || meta.uid() != me || meta.mode() & 0o077 != 0 {
        bail!(
            "{} is not private to this user (owner uid {}, mode {:o}); refusing it",
            path.display(),
            meta.uid(),
            meta.mode() & 0o777
        );
    }
    let mut text = String::new();
    file.read_to_string(&mut text).context("cannot read endpoint.json")?;
    Ok(text)
}

/// Windows: the owner and every granting DACL entry must be this user (or
/// SYSTEM, Administrators: they can read any file, as root can on Unix);
/// a reparse point, a folder or a wider file is refused, never narrowed.
#[cfg(windows)]
fn read_private_text(path: &Path) -> Result<String> {
    use std::io::Read;
    let mut file = crate::owner_only::open_private_existing(path).map_err(|e| {
        if e.kind() == std::io::ErrorKind::NotFound {
            not_running(path)
        } else {
            anyhow!("cannot use {}: {e}; refusing it", path.display())
        }
    })?;
    let mut text = String::new();
    file.read_to_string(&mut text).context("cannot read endpoint.json")?;
    Ok(text)
}

/// The fields of `endpoint.json`: `socket`, `secret`, and the helper's
/// `pid` with its start time when the writer recorded them.
fn parse_endpoint(text: &str) -> Result<Endpoint> {
    let value: Value = serde_json::from_str(text).context("endpoint.json is not JSON")?;
    let socket = value["socket"].as_str().ok_or_else(|| anyhow!("endpoint.json has no socket"))?;
    let secret = value["secret"].as_str().ok_or_else(|| anyhow!("endpoint.json has no secret"))?;
    if socket.is_empty() || secret.is_empty() {
        bail!("endpoint.json has an empty socket or secret");
    }
    Ok(Endpoint {
        socket: PathBuf::from(socket),
        secret: secret.to_owned(),
        owner: Owner::from_json(&value),
    })
}

/// A pipe on this machine (`\\.\pipe\NAME`), never a remote server's
/// (`\\HOST\pipe\NAME`) or a file path.
#[cfg_attr(not(windows), allow(dead_code))]
fn is_local_pipe_name(name: &str) -> bool {
    const PREFIX: &str = r"\\.\pipe\";
    name.len() > PREFIX.len()
        && name.is_char_boundary(PREFIX.len())
        && name[..PREFIX.len()].eq_ignore_ascii_case(PREFIX)
        && !name[PREFIX.len()..].contains('\0')
}

/// The id of `session/hello`; requests count from 1.
const HELLO_ID: u64 = 0;

/// One admitted connection to the helper socket (JSON lines).
pub struct Helper<S> {
    stream: BufReader<S>,
    next_id: u64,
}

#[cfg(unix)]
impl Helper<UnixStream> {
    /// Connects and presents the secret.
    pub async fn connect(endpoint: &Endpoint) -> Result<Self> {
        let stream = UnixStream::connect(&endpoint.socket)
            .await
            .with_context(|| format!("cannot connect to {}", endpoint.socket.display()))?;
        // The secret goes only to a helper of this user (kernel peer uid).
        let peer = stream.peer_cred().context("cannot read the helper socket's peer uid")?.uid();
        // SAFETY: geteuid has no preconditions.
        let me = unsafe { libc::geteuid() };
        if peer != me {
            bail!(
                "{} is served by uid {peer}, not this user (uid {me}); the secret was not sent",
                endpoint.socket.display()
            );
        }
        Helper::admit(stream, &endpoint.secret).await
    }
}

#[cfg(windows)]
impl Helper<NamedPipeClient> {
    /// Connects to the worker's pipe and presents the secret, only after
    /// the pipe's server process is shown to run as this user.
    pub async fn connect(endpoint: &Endpoint) -> Result<Self> {
        let stream = pipe::connect(&endpoint.socket).await?;
        pipe::require_same_user_server(&stream, &endpoint.socket)?;
        Helper::admit(stream, &endpoint.secret).await
    }
}

impl<S: tokio::io::AsyncRead + AsyncWrite + Unpin> Helper<S> {
    /// Sends the secret and reads the helper's answer.
    pub async fn admit(stream: S, secret: &str) -> Result<Self> {
        let mut helper = Helper { stream: BufReader::new(stream), next_id: 1 };
        helper.send(&json!({ "secret": secret })).await?;
        let hello = helper.receive().await?;
        if hello["ok"] != json!(true) {
            bail!(
                "the Computer Use helper refused this connection ({})",
                hello["reason"].as_str().unwrap_or("no reason")
            );
        }
        Ok(helper)
    }

    /// `tools/list` or `tools/call`; returns the helper's `result`.
    pub async fn request(
        &mut self,
        method: &str,
        name: Option<&str>,
        arguments: Value,
    ) -> Result<Value> {
        if method == "tools/call" {
            // Only the admitted host can select the machine's consent authority.
            // Never consult this agent descendant's HOME, ACPMUX_HOME or socket env.
            let status = tokio::time::timeout(
                std::time::Duration::from_secs(2),
                self.exchange("machine/consent", None, Value::Null),
            )
            .await
            .ok()
            .and_then(Result::ok)
            .ok_or_else(|| anyhow!(crate::cli::cloud_join::CONSENT_REQUIRED))?;
            // Only the admitted driver's inventory can classify an operation.
            // Refresh when a screen-only grant needs that distinction: tool names
            // and model-supplied annotations are never an authority.
            let read_only = if status["consentRequired"] == true
                && status["consent"]["screen"] == "granted"
                && status["consent"]["control"] == "none"
            {
                let inventory = tokio::time::timeout(
                    std::time::Duration::from_secs(2),
                    self.exchange("tools/list", None, Value::Null),
                )
                .await
                .ok()
                .and_then(Result::ok);
                inventory.as_ref().is_some_and(|inventory| {
                    let tools = inventory.as_array().or_else(|| inventory["tools"].as_array());
                    let mut matching =
                        tools.into_iter().flatten().filter(|tool| tool["name"].as_str() == name);
                    let declared = matching
                        .next()
                        .is_some_and(|tool| tool["annotations"]["readOnlyHint"] == true);
                    declared && matching.next().is_none()
                })
            } else {
                false
            };
            require_tool_consent(read_only, &status)?;
        }
        self.exchange(method, name, arguments).await
    }

    /// `session/hello` with the session's display labels, sent once after
    /// admission. Its answer (id 0) is skipped by later requests, so an
    /// older worker that refuses the method is still usable.
    pub async fn hello(&mut self, labels: &Labels) -> Result<()> {
        self.send(&json!({"id": HELLO_ID, "method": "session/hello", "params": labels.params()}))
            .await
    }

    async fn exchange(
        &mut self,
        method: &str,
        name: Option<&str>,
        arguments: Value,
    ) -> Result<Value> {
        let id = self.next_id;
        self.next_id += 1;
        let mut message = json!({ "id": id, "method": method });
        if let Some(name) = name {
            message.set("name", json!(name));
            message.set("arguments", arguments);
            // The helper owns target policy. This process's env is caller-controlled.
        }
        self.send(&message).await?;
        // One request at a time, so the next reply is ours (or the hello's).
        let mut reply = self.receive().await?;
        while reply["id"] == json!(HELLO_ID) {
            reply = self.receive().await?;
        }
        if reply["id"] != json!(id) {
            bail!("the Computer Use helper answered request {} for {id}", reply["id"]);
        }
        if reply["ok"] == json!(true) {
            Ok(reply.get("result").cloned().unwrap_or(Value::Null))
        } else {
            // The worker answered: a refusal, not a broken connection.
            Err(WorkerError::from_reply(&reply).into())
        }
    }

    async fn send(&mut self, value: &Value) -> Result<()> {
        let mut line = serde_json::to_vec(value)?;
        line.push(b'\n');
        self.stream.get_mut().write_all(&line).await?;
        Ok(())
    }

    async fn receive(&mut self) -> Result<Value> {
        let mut line = String::new();
        if self.stream.read_line(&mut line).await? == 0 {
            bail!("the Computer Use helper closed the connection");
        }
        Ok(serde_json::from_str(&line)?)
    }
}

/// `acpmux cua-mcp`: an MCP stdio server that forwards to the helper v2
/// (a Unix socket, or the worker's named pipe on Windows).
pub async fn run_bridge() -> Result<()> {
    let dir = dir_from_env().ok_or_else(|| anyhow!("{ENDPOINT_DIR_ENV} is not set"))?;
    let stdin = BufReader::new(tokio::io::stdin());
    let stdout = tokio::io::stdout();
    // Set by acpmux when it spawned this session (agent_tools.rs), never by the agent.
    let labels = Labels::from_env(|key| std::env::var(key).ok());
    serve(stdin, stdout, || async {
        let mut helper = Helper::connect(&read_endpoint(&dir)?).await?;
        helper.hello(&labels).await?;
        Ok(helper)
    })
    .await
}

/// The MCP loop, generic over the transport and the helper connection.
pub async fn serve<R, W, S, C, F>(input: R, mut output: W, connect: C) -> Result<()>
where
    R: AsyncBufRead + Unpin,
    W: AsyncWrite + Unpin,
    S: tokio::io::AsyncRead + AsyncWrite + Unpin,
    C: Fn() -> F,
    F: std::future::Future<Output = Result<Helper<S>>>,
{
    let mut lines = input.lines();
    let mut helper: Option<Helper<S>> = None;
    while let Some(line) = lines.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }
        let Ok(message) = serde_json::from_str::<Value>(&line) else {
            write_line(
                &mut output,
                &json!({"jsonrpc": "2.0", "id": null,
                "error": {"code": -32700, "message": "parse error"}}),
            )
            .await?;
            continue;
        };
        let Some(id) = message.get("id").cloned() else { continue }; // a notification
        let method = message["method"].as_str().unwrap_or_default();
        let reply = match method {
            "initialize" => Ok(json!({
                "protocolVersion": message["params"]["protocolVersion"].as_str().unwrap_or("2025-06-18"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": SERVER_NAME, "version": env!("CARGO_PKG_VERSION")},
            })),
            "ping" => Ok(json!({})),
            "tools/list" => forward(&mut helper, &connect, "tools/list", None, Value::Null)
                .await
                .map(tools_list_result)
                .map_err(Failure::into_rpc),
            "tools/call" => {
                let name = message["params"]["name"].as_str().unwrap_or_default().to_owned();
                let arguments =
                    message["params"].get("arguments").cloned().unwrap_or_else(|| json!({}));
                Ok(
                    match forward(&mut helper, &connect, "tools/call", Some(&name), arguments).await
                    {
                        Ok(result) => call_result(result),
                        Err(Failure::Approval(refusal, app)) => refusal.tool_result(app.as_deref()),
                        Err(Failure::Rpc(_, text)) => {
                            json!({"content": [{"type":"text", "text":text}], "isError":true})
                        }
                    },
                )
            }
            _ => Err((-32601, format!("method not found: {method}"))),
        };
        let response = match reply {
            Ok(result) => json!({"jsonrpc": "2.0", "id": id, "result": result}),
            Err((code, text)) => {
                json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": text}})
            }
        };
        write_line(&mut output, &response).await?;
    }
    Ok(())
}

/// A trusted inventory readOnlyHint requires screen consent; unknown and action
/// tools require both independent grants, including their post-action captures.
fn require_tool_consent(read_only: bool, status: &Value) -> Result<()> {
    let denied = || anyhow!(crate::cli::cloud_join::CONSENT_REQUIRED);
    let required = status["consentRequired"].as_bool().ok_or_else(denied)?;
    let screen = status["consent"]["screen"].as_str().ok_or_else(denied)?;
    let control = status["consent"]["control"].as_str().ok_or_else(denied)?;
    if !matches!(screen, "none" | "granted") || !matches!(control, "none" | "granted") {
        return Err(denied());
    }
    if !required {
        return Ok(());
    }
    if screen != "granted" {
        return Err(denied());
    }
    if !read_only && control != "granted" {
        return Err(denied());
    }
    Ok(())
}

/// Why a forwarded request has no result.
enum Failure {
    /// A JSON-RPC error code and its text.
    Rpc(i64, String),
    /// The worker asked the person and has no answer to run on (yet), with
    /// the app's name when the worker gave it.
    Approval(ApprovalRefusal, Option<String>),
}

impl Failure {
    fn into_rpc(self) -> (i64, String) {
        match self {
            Failure::Rpc(code, text) => (code, text),
            Failure::Approval(refusal, app) => (-32021, refusal.message(app.as_deref())),
        }
    }
}

/// Forwards one request, connecting on first use and once more after a
/// dropped connection (the helper restarts with a new socket and secret).
/// A refusal the worker answered keeps the connection: it is the session,
/// and closing it would revoke the session's grants (a late Allow included).
async fn forward<S, C, F>(
    helper: &mut Option<Helper<S>>,
    connect: &C,
    method: &str,
    name: Option<&str>,
    arguments: Value,
) -> Result<Value, Failure>
where
    S: tokio::io::AsyncRead + AsyncWrite + Unpin,
    C: Fn() -> F,
    F: std::future::Future<Output = Result<Helper<S>>>,
{
    for attempt in 0..2 {
        if helper.is_none() {
            *helper = Some(connect().await.map_err(|e| Failure::Rpc(-32000, format!("{e:#}")))?);
        }
        let Some(current) = helper.as_mut() else { continue };
        match current.request(method, name, arguments.clone()).await {
            Ok(result) => return Ok(result),
            Err(e) => {
                if e.to_string() == crate::cli::cloud_join::CONSENT_REQUIRED {
                    return Err(Failure::Rpc(
                        -32020,
                        crate::cli::cloud_join::CONSENT_REQUIRED.to_owned(),
                    ));
                }
                if let Some(refused) = e.downcast_ref::<WorkerError>() {
                    return Err(match refused.approval() {
                        Some(refusal) => Failure::Approval(refusal, refused.app.clone()),
                        None => Failure::Rpc(-32000, refused.message.clone()),
                    });
                }
                *helper = None;
                if attempt == 1 || !is_connection_error(&e) {
                    return Err(Failure::Rpc(-32000, format!("{e:#}")));
                }
            }
        }
    }
    Err(Failure::Rpc(-32000, "the Computer Use helper is unavailable".into()))
}

fn is_connection_error(e: &anyhow::Error) -> bool {
    e.downcast_ref::<std::io::Error>().is_some() || e.to_string().contains("closed the connection")
}

/// `tools/list` result: upstream's inventory as `{"tools": [...]}`.
pub fn tools_list_result(inventory: Value) -> Value {
    match inventory {
        Value::Array(tools) => json!({ "tools": tools }),
        Value::Object(ref map) if map.contains_key("tools") => inventory,
        other => json!({ "tools": [], "_inventory": other }),
    }
}

/// `tools/call` result: upstream's MCP-shaped result as is, anything else as text.
pub fn call_result(result: Value) -> Value {
    if result.get("content").is_some() {
        result
    } else {
        json!({"content": [{"type": "text", "text": result.to_string()}], "structuredContent": result})
    }
}

async fn write_line<W: AsyncWrite + Unpin>(output: &mut W, value: &Value) -> Result<()> {
    let mut line = serde_json::to_vec(value)?;
    line.push(b'\n');
    output.write_all(&line).await?;
    output.flush().await?;
    Ok(())
}

#[cfg(test)]
#[path = "cua_v2/endpoint_tests.rs"]
mod endpoint_tests;
