//! `cmux computer-use tools|call|screenshot`: the CLI's way to the Computer
//! Use worker, through the same admission and approvals as an agent.
//!
//! The worker admits only acpmux code whose ancestors include an acpmux
//! daemon the host registered, presenting the per-launch secret from
//! `endpoint.json` (`cua_v2.rs`). A shell is not such a process, and the CLI
//! must not get the secret. So the CLI asks this daemon
//! (`_acpmux/computer_use_mcp`, local Unix socket only), and the daemon runs
//! one `acpmux cua-mcp` bridge child of its own, as it would for an agent
//! session: the worker's checks are unchanged, and the session is labelled
//! `cli` on the approval card.
//!
//! The child is one long-lived session for every CLI caller of this daemon:
//! "Allow for This Session" from the card covers later `cmux computer-use`
//! calls, and a late Allow after `approval_timeout` lets the next call run,
//! as for an agent. It ends with the daemon, when it exits, or when the
//! worker ends the session (its idle timeout); the next call starts a new
//! one. Calls run one at a time; a call that waits for the person (2
//! minutes at most) holds the next. Only `tools/list` and `tools/call`
//! reach it; this daemon owns `initialize`.

use std::process::Stdio;
use std::time::Duration;

use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{Child, ChildStdin, ChildStdout};

use super::{ENDPOINT_DIR_ENV, Labels, active_dir, dir_from_env, labels};
use crate::rpc::RpcError;

/// The agent label of the CLI's session on the approval card.
pub const CLI_AGENT: &str = "cmux computer-use";
/// The bridge's own start (`initialize`).
const START_TIMEOUT: Duration = Duration::from_secs(15);
/// One call: the worker's 2-minute wait for the person, and slack.
const CALL_TIMEOUT: Duration = Duration::from_secs(150);

struct Bridge {
    child: Child,
    stdin: ChildStdin,
    lines: Lines<BufReader<ChildStdout>>,
    next_id: u64,
}

static BRIDGE: tokio::sync::Mutex<Option<Bridge>> = tokio::sync::Mutex::const_new(None);

/// The MCP methods the CLI may send.
pub fn admit(message: &Value) -> Result<(), RpcError> {
    match message["method"].as_str() {
        Some("tools/list" | "tools/call") if message.get("id").is_some() => Ok(()),
        Some(other) if other != "tools/list" && other != "tools/call" => {
            Err(RpcError::invalid_params(format!(
                "only tools/list and tools/call reach Computer Use, not {other}"
            )))
        }
        _ => {
            Err(RpcError::invalid_params("message must be an MCP request with an id and a method"))
        }
    }
}

/// Answers one MCP request (`params.message`) through this daemon's CLI
/// bridge: the MCP response, with the caller's id.
pub async fn request(params: &Value) -> Result<Value, RpcError> {
    let message = &params["message"];
    admit(message)?;
    let mut slot = BRIDGE.lock().await;
    // A bridge that exited (its worker restarted, the session ended) starts again.
    if slot.as_mut().is_some_and(|bridge| !matches!(bridge.child.try_wait(), Ok(None))) {
        *slot = None;
    }
    if slot.is_none() {
        *slot = Some(start().await?);
    }
    let Some(bridge) = slot.as_mut() else {
        return Err(RpcError::internal("the Computer Use bridge did not start"));
    };
    let reply = match exchange(bridge, &message["method"], &message["params"], CALL_TIMEOUT).await {
        Ok(reply) => reply,
        Err(error) => {
            // No answer: this session is lost; the next call starts another.
            *slot = None;
            return Err(error);
        }
    };
    let mut response = json!({"jsonrpc": "2.0", "id": message["id"]});
    for key in ["result", "error"] {
        if let Some(value) = reply.get(key) {
            response.set(key, value.clone());
        }
    }
    Ok(response)
}

async fn start() -> Result<Bridge, RpcError> {
    let dir = active_dir(dir_from_env()).ok_or_else(|| {
        RpcError::new(
            -32010,
            "Computer Use is not running on this machine: turn it on in cmux (Settings, Computer \
             Use), then try again",
        )
    })?;
    let me = crate::self_command::SelfCommand::current()
        .map_err(|e| RpcError::internal(format!("cannot find this acpmux binary: {e}")))?;
    let mut command = me.tokio_command(&[crate::agent_tools::CUA_BRIDGE_ARG]);
    command
        .env(ENDPOINT_DIR_ENV, dir)
        .envs(Labels::new(CLI_AGENT, "", labels::CLI_CLIENT).env())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let mut child = command
        .spawn()
        .map_err(|e| RpcError::internal(format!("cannot start acpmux cua-mcp: {e}")))?;
    let (Some(stdin), Some(stdout)) = (child.stdin.take(), child.stdout.take()) else {
        return Err(RpcError::internal("acpmux cua-mcp has no pipes"));
    };
    let mut bridge = Bridge { child, stdin, lines: BufReader::new(stdout).lines(), next_id: 1 };
    let init = json!({"protocolVersion": "2025-06-18", "capabilities": {},
        "clientInfo": {"name": "cmux computer-use", "version": env!("CARGO_PKG_VERSION")}});
    exchange(&mut bridge, &json!("initialize"), &init, START_TIMEOUT).await?;
    write(&mut bridge.stdin, &json!({"jsonrpc": "2.0", "method": "notifications/initialized"}))
        .await?;
    Ok(bridge)
}

/// One request to the bridge and its reply (`{result}` or `{error}`).
async fn exchange(
    bridge: &mut Bridge,
    method: &Value,
    params: &Value,
    timeout: Duration,
) -> Result<Value, RpcError> {
    let id = bridge.next_id;
    bridge.next_id += 1;
    let mut message = json!({"jsonrpc": "2.0", "id": id, "method": method});
    if !params.is_null() {
        message.set("params", params.clone());
    }
    write(&mut bridge.stdin, &message).await?;
    let read = async {
        while let Some(line) = bridge.lines.next_line().await.map_err(|e| e.to_string())? {
            let Ok(reply) = serde_json::from_str::<Value>(&line) else { continue };
            if reply["id"] == json!(id) {
                return Ok(reply);
            }
        }
        Err("acpmux cua-mcp exited".to_owned())
    };
    match tokio::time::timeout(timeout, read).await {
        Ok(Ok(reply)) => Ok(reply),
        Ok(Err(why)) => {
            Err(RpcError::new(-32011, format!("the Computer Use bridge failed: {why}")))
        }
        Err(_) => Err(RpcError::new(
            -32012,
            format!("the Computer Use bridge did not answer in {} s", timeout.as_secs()),
        )),
    }
}

async fn write(stdin: &mut ChildStdin, value: &Value) -> Result<(), RpcError> {
    let mut line = serde_json::to_vec(value).map_err(|e| RpcError::internal(e.to_string()))?;
    line.push(b'\n');
    stdin
        .write_all(&line)
        .await
        .map_err(|e| RpcError::new(-32011, format!("acpmux cua-mcp: {e}")))?;
    stdin.flush().await.map_err(|e| RpcError::new(-32011, format!("acpmux cua-mcp: {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_tool_requests_reach_the_bridge() {
        assert!(admit(&json!({"id": 1, "method": "tools/list"})).is_ok());
        assert!(
            admit(&json!({"id": 2, "method": "tools/call", "params": {"name": "click"}})).is_ok()
        );
        for message in [
            json!({"id": 1, "method": "initialize"}),
            json!({"id": 1, "method": "session/hello", "params": {"client": "Trusted"}}),
            json!({"id": 1, "method": "machine/consent"}),
            json!({"method": "tools/call"}),
            json!("tools/call"),
        ] {
            assert!(admit(&message).is_err(), "{message}");
        }
    }
}
