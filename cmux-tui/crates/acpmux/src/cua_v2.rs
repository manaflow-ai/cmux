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
//! Phase 1 forwards `tools/list` and `tools/call` unchanged (upstream tool
//! names and arguments). Argument mapping, per-session scope and the
//! activity log are phase 2.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow, bail};
use serde_json::{Value, json};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

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

/// The folder, when the helper v2 runs now (its `endpoint.json` exists).
pub fn active_dir(dir: Option<PathBuf>) -> Option<PathBuf> {
    // RED STUB (commit 1)
    let _ = dir;
    None
}

/// Reads `endpoint.json` in `dir`.
pub fn read_endpoint(dir: &Path) -> Result<Endpoint> {
    let path = dir.join(ENDPOINT_FILE);
    let text = std::fs::read_to_string(&path)
        .with_context(|| format!("the Computer Use helper v2 is not running ({} is missing)", path.display()))?;
    let value: Value = serde_json::from_str(&text).context("endpoint.json is not JSON")?;
    let socket = value["socket"].as_str().ok_or_else(|| anyhow!("endpoint.json has no socket"))?;
    let secret = value["secret"].as_str().ok_or_else(|| anyhow!("endpoint.json has no secret"))?;
    Ok(Endpoint { socket: PathBuf::from(socket), secret: secret.to_owned() })
}

/// One admitted connection to the helper socket (JSON lines).
pub struct Helper<S> {
    stream: BufReader<S>,
    next_id: u64,
}

impl Helper<UnixStream> {
    /// Connects and presents the secret.
    pub async fn connect(endpoint: &Endpoint) -> Result<Self> {
        let stream = UnixStream::connect(&endpoint.socket)
            .await
            .with_context(|| format!("cannot connect to {}", endpoint.socket.display()))?;
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
    pub async fn request(&mut self, method: &str, name: Option<&str>, arguments: Value) -> Result<Value> {
        let id = self.next_id;
        self.next_id += 1;
        let mut message = json!({ "id": id, "method": method });
        if let Some(name) = name {
            message["name"] = json!(name);
            message["arguments"] = arguments;
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
    // RED STUB (commit 1): answers nothing.
    let _ = (&mut output, &connect);
    if true {
        drop(input);
        return Ok(());
    }
    let mut lines = input.lines();
    let mut helper: Option<Helper<S>> = None;
    while let Some(line) = lines.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }
        let Ok(message) = serde_json::from_str::<Value>(&line) else {
            write_line(&mut output, &json!({"jsonrpc": "2.0", "id": null,
                "error": {"code": -32700, "message": "parse error"}}))
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
                .map(tools_list_result),
            "tools/call" => {
                let name = message["params"]["name"].as_str().unwrap_or_default().to_owned();
                let arguments = message["params"].get("arguments").cloned().unwrap_or_else(|| json!({}));
                Ok(match forward(&mut helper, &connect, "tools/call", Some(&name), arguments).await {
                    Ok(result) => call_result(result),
                    Err((_, text)) => json!({"content": [{"type": "text", "text": text}], "isError": true}),
                })
            }
            _ => Err((-32601, format!("method not found: {method}"))),
        };
        let response = match reply {
            Ok(result) => json!({"jsonrpc": "2.0", "id": id, "result": result}),
            Err((code, text)) => json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": text}}),
        };
        write_line(&mut output, &response).await?;
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

#[cfg(test)]
#[path = "cua_v2_tests.rs"]
mod tests;
