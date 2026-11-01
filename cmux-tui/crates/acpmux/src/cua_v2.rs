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
//! Before every tool action, the admitted helper answers `machine/consent`
//! with `{consentRequired: bool, consent: {screen, control}}`, each state
//! `none` or `granted`. The helper obtains this from its established app-owned
//! daemon connection; a child environment or request never picks the authority.
//! Missing support, malformed replies and a two-second timeout deny the action.
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

mod liveness;

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
    #[cfg(unix)]
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
/// user that no other user can read or write (checked with `fstat` on the
/// opened descriptor, not by path): another local user (fleet Macs run
/// several slot users) must not be able to point the bridge, and its
/// secret, at a socket of theirs.
#[cfg(unix)]
pub fn read_endpoint(dir: &Path) -> Result<Endpoint> {
    read_endpoint_text(dir).map(|(endpoint, _)| endpoint)
}

/// [`read_endpoint`] and the file's text.
#[cfg(unix)]
fn read_endpoint_text(dir: &Path) -> Result<(Endpoint, String)> {
    use std::io::Read;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    let path = dir.join(ENDPOINT_FILE);
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&path)
        .map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                anyhow!("the Computer Use helper v2 is not running ({} is missing)", path.display())
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
    let value: Value = serde_json::from_str(&text).context("endpoint.json is not JSON")?;
    let socket = value["socket"].as_str().ok_or_else(|| anyhow!("endpoint.json has no socket"))?;
    let secret = value["secret"].as_str().ok_or_else(|| anyhow!("endpoint.json has no secret"))?;
    let endpoint = Endpoint {
        socket: PathBuf::from(socket),
        secret: secret.to_owned(),
        owner: Owner::from_json(&value),
    };
    Ok((endpoint, text))
}

/// Windows port: the owner check (`fstat` uid and mode) needs the owner-only
/// ACL check of a later landing; the endpoint is refused until then.
#[cfg(not(unix))]
pub fn read_endpoint(dir: &Path) -> Result<Endpoint> {
    let _ = dir;
    Err(crate::platform::unsupported("the Computer Use helper v2 endpoint"))
}

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
        // One request at a time, so the next reply is ours.
        let reply = self.receive().await?;
        if reply["id"] != json!(id) {
            bail!("the Computer Use helper answered request {} for {id}", reply["id"]);
        }
        if reply["ok"] == json!(true) {
            Ok(reply.get("result").cloned().unwrap_or(Value::Null))
        } else {
            bail!("{}", reply["error"].as_str().unwrap_or("the Computer Use helper failed"))
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

/// `acpmux cua-mcp`: an MCP stdio server that forwards to the helper v2.
#[cfg(not(unix))]
pub async fn run_bridge() -> Result<()> {
    Err(crate::platform::unsupported("the Computer Use bridge (its helper socket)"))
}

#[cfg(unix)]
pub async fn run_bridge() -> Result<()> {
    let dir = dir_from_env().ok_or_else(|| anyhow!("{ENDPOINT_DIR_ENV} is not set"))?;
    let stdin = BufReader::new(tokio::io::stdin());
    let stdout = tokio::io::stdout();
    serve(stdin, stdout, || async { Helper::connect(&read_endpoint(&dir)?).await }).await
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
                "protocolVersion": crate::secret_mcp::protocol_version(&message["params"]),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": SERVER_NAME, "version": env!("CARGO_PKG_VERSION")},
            })),
            "ping" => Ok(json!({})),
            "tools/list" => forward(&mut helper, &connect, "tools/list", None, Value::Null)
                .await
                .map(tools_list_result),
            "tools/call" => {
                let name = message["params"]["name"].as_str().unwrap_or_default().to_owned();
                let arguments =
                    message["params"].get("arguments").cloned().unwrap_or_else(|| json!({}));
                Ok(
                    match forward(&mut helper, &connect, "tools/call", Some(&name), arguments).await
                    {
                        Ok(result) => call_result(result),
                        Err((_, text)) => {
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

/// Forwards one request, connecting on first use and once more after a
/// dropped connection (the helper restarts with a new socket and secret).
async fn forward<S, C, F>(
    helper: &mut Option<Helper<S>>,
    connect: &C,
    method: &str,
    name: Option<&str>,
    arguments: Value,
) -> Result<Value, (i64, String)>
where
    S: tokio::io::AsyncRead + AsyncWrite + Unpin,
    C: Fn() -> F,
    F: std::future::Future<Output = Result<Helper<S>>>,
{
    for attempt in 0..2 {
        if helper.is_none() {
            *helper = Some(connect().await.map_err(|e| (-32000, format!("{e:#}")))?);
        }
        let Some(current) = helper.as_mut() else { continue };
        match current.request(method, name, arguments.clone()).await {
            Ok(result) => return Ok(result),
            Err(e) => {
                if e.to_string() == crate::cli::cloud_join::CONSENT_REQUIRED {
                    return Err((-32020, crate::cli::cloud_join::CONSENT_REQUIRED.to_owned()));
                }
                *helper = None;
                if attempt == 1 || !is_connection_error(&e) {
                    return Err((-32000, format!("{e:#}")));
                }
            }
        }
    }
    Err((-32000, "the Computer Use helper is unavailable".into()))
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
