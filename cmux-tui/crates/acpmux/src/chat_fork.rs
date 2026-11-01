//! `_acpmux/chat_fork {harness, agentSessionId, cwd?}` -> `{harness, agentSessionId}`: Fork
//! Conversation of a chat a terminal runs, for an agent whose own CLI has no fork (Muse:
//! `muse resume` only, though its ACP agent serves `session/fork`). The harness's ACP agent
//! starts once, without acpmux's session machinery: `initialize`, then `session/fork` of the
//! terminal's session, and it ends as soon as the answer arrives (or at [`FORK_TIMEOUT`]). The
//! fork is the agent's own new session in its own store; the app resumes it in a new terminal
//! by the agent's CLI. No acpmux session is made and the terminal's chat is not touched.
//!
//! Only the local unix socket asks (`server/chats.rs`): it runs the person's agent with their
//! login.

use crate::config::{Config, HarnessKind, HarnessProfile};
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::Path;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;

/// Start to answer. An agent forks in well under a few seconds once it runs; this bounds a hung
/// one or one that waits for a sign-in.
pub const FORK_TIMEOUT: Duration = Duration::from_secs(40);

/// The ACP profile that runs `harness`: the profile of that name, else the first ACP profile of
/// that family. None when no ACP profile here runs it.
pub fn profile_for<'c>(cfg: &'c Config, harness: &str) -> Option<(&'c str, &'c HarnessProfile)> {
    let acp = |p: &HarnessProfile| p.kind == HarnessKind::Acp && !p.argv.is_empty();
    if let Some((name, p)) = cfg.harnesses.get_key_value(harness).filter(|(_, p)| acp(p)) {
        return Some((name.as_str(), p));
    }
    cfg.harnesses
        .iter()
        .find(|(name, p)| acp(p) && crate::config::derive_family(name, p) == harness)
        .map(|(name, p)| (name.as_str(), p))
}

/// Forks session `id` of the agent `profile` runs, in folder `cwd`; the fork's session id.
pub async fn fork(
    harness: &str,
    family: &str,
    profile: &HarnessProfile,
    id: &str,
    cwd: &Path,
) -> Result<String, RpcError> {
    if !crate::adopt::is_bare_id(id) {
        return Err(RpcError::invalid_params("agentSessionId must be one plain session id"));
    }
    match tokio::time::timeout(FORK_TIMEOUT, run(harness, family, profile, id, cwd)).await {
        Ok(forked) => forked,
        Err(_) => Err(RpcError::internal(format!(
            "{harness} did not fork the chat within {} s",
            FORK_TIMEOUT.as_secs()
        ))),
    }
}

async fn run(
    harness: &str,
    family: &str,
    profile: &HarnessProfile,
    id: &str,
    cwd: &Path,
) -> Result<String, RpcError> {
    let (program, rest) =
        profile.argv.split_first().ok_or_else(|| RpcError::internal("no program"))?;
    let mut cmd = Command::new(program);
    // The daemon starter's turn values are not this agent's (config::TURN_SCOPED_ENV).
    for k in crate::config::inherited_caller_scoped_keys() {
        cmd.env_remove(k);
    }
    // The app the daemon follows is not the harness's (`daemon/owner_exit.rs`).
    cmd.env_remove(crate::daemon::owner_exit::OWNER_APP_PID_ENV);
    let env: &BTreeMap<String, String> = &profile.env;
    // As `agent.rs` spawns: never on stale or revoked delivered secrets.
    if !crate::login_env::machine_env_fresh_before_spawn().await {
        return Err(RpcError::internal("machine environment changed; login env refresh failed"));
    }
    crate::login_env::apply_tokio_for(&mut cmd, Some(family), Some(env));
    crate::config::scrub_nested_claude_env_tokio_for(&mut cmd, Some(family));
    cmd.args(rest)
        .envs(env)
        .current_dir(cwd)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true);
    let mut child =
        cmd.spawn().map_err(|e| RpcError::internal(format!("cannot start {harness}: {e}")))?;
    let mut stdin =
        child.stdin.take().ok_or_else(|| RpcError::internal("the agent has no stdin"))?;
    let stdout =
        child.stdout.take().ok_or_else(|| RpcError::internal("the agent has no stdout"))?;
    let mut lines = BufReader::new(stdout).lines();
    let gone = |e: std::io::Error| RpcError::internal(format!("{harness} stopped: {e}"));
    let mut ask = async |rid: u64, method: &str, params: Value| -> Result<Value, RpcError> {
        let mut line = serde_json::to_vec(
            &json!({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}),
        )
        .map_err(|e| RpcError::internal(e.to_string()))?;
        line.push(b'\n');
        stdin.write_all(&line).await.map_err(gone)?;
        stdin.flush().await.map_err(gone)?;
        loop {
            let line = lines.next_line().await.map_err(gone)?.ok_or_else(|| {
                RpcError::internal(format!("{harness} exited before it answered {method}"))
            })?;
            let Ok(msg) = serde_json::from_str::<Value>(&line) else { continue };
            // Notifications and the agent's own requests (none is answered: the fork asks nothing).
            if msg.get("method").is_some() || msg.get("id") != Some(&json!(rid)) {
                continue;
            }
            if let Some(error) = msg.get("error") {
                let text = error.get("message").and_then(Value::as_str).unwrap_or("error");
                return Err(RpcError::invalid_params(format!(
                    "{harness} could not fork the chat: {text}"
                )));
            }
            return Ok(msg.get("result").cloned().unwrap_or(Value::Null));
        }
    };
    let hello = ask(
        1,
        crate::rpc::method::INITIALIZE,
        json!({"protocolVersion": 1, "clientCapabilities": {"fs": {"readTextFile": false, "writeTextFile": false}, "terminal": false}}),
    )
    .await?;
    // An agent that does not offer session/fork (Kimi, DeepSeek) answers it with a bare
    // internal error: refuse with the reason instead (as `hub/fork.rs`).
    if !crate::hub::offers_fork(hello.get("agentCapabilities")) {
        let _ = child.kill().await;
        return Err(RpcError::invalid_params(format!(
            "{harness} cannot fork a chat: its agent does not offer session/fork"
        )));
    }
    let forked = ask(
        2,
        crate::rpc::method::SESSION_FORK,
        json!({"sessionId": id, "cwd": cwd, "mcpServers": []}),
    )
    .await;
    let _ = child.kill().await;
    forked?
        .get("sessionId")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| RpcError::internal(format!("{harness} answered the fork with no sessionId")))
}
