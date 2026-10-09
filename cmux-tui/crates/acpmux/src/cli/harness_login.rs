//! `cmux harness login ID` (cx-1785): sign in to a harness through the
//! Agent Client Protocol's own sign-in, the same way for every ACP harness.
//!
//! The harness starts in a private temp folder (like doctor) and answers
//! `initialize` with its `authMethods`. `--status` only tries `session/new`:
//! an answer means signed in, error -32000 means sign-in is required. A
//! login runs one method:
//! - `agent` (the default type): `authenticate {methodId}`; the agent does
//!   the sign-in itself (it usually opens the browser) and answers when done;
//! - `terminal`: the harness's command line runs again with the method's
//!   arguments and env added, in this terminal, for an interactive sign-in;
//! - `env_var`: nothing runs; the command prints how to store the variable
//!   in the Keychain (`cmux harness secret set`).
//!
//! Claude Code (acpmux's own adapter) has no ACP sign-in: its login runs
//! `claude auth login` in this terminal.
//!
//! Sign-in types and the terminal hand-off follow the ACP auth methods that
//! t3code's ACP Registry auth uses (apps/server/src/provider/acp/
//! AcpRegistryAuth.ts). Portions adapted from t3code, Copyright (c) 2026
//! T3 Tools Inc., MIT License (https://github.com/pingdotgg/t3code; see
//! THIRD_PARTY_LICENSES.md).

use std::collections::BTreeMap;
use std::time::Duration;

use anyhow::{Result, anyhow, bail};
use serde::Serialize;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, BufReader};

use super::harness::wire::{TempFolder, Wire};
use crate::config::profiles;
use crate::config::{Config, HarnessKind, HarnessProfile};

/// ACP's "authentication required" error code.
pub const AUTH_REQUIRED: i64 = -32000;

/// One sign-in method a harness offers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthMethod {
    pub id: String,
    pub name: String,
    /// `agent`, `terminal` or `env_var`.
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<String>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub env: BTreeMap<String, String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub var_name: Option<String>,
}

/// The `authMethods` of an `initialize` result; unusable entries are left out.
pub fn auth_methods(init: &Value) -> Vec<AuthMethod> {
    let _ = init;
    Vec::new() // red: no ACP sign-in yet
}

/// Whether a harness is signed in.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "state", rename_all = "camelCase")]
pub enum AuthState {
    SignedIn {
        methods: Vec<AuthMethod>,
    },
    Required {
        methods: Vec<AuthMethod>,
        message: String,
    },
    /// No ACP sign-in to check (Claude Code's own adapter, a terminal harness).
    NotAcp {
        hint: String,
    },
}

/// A started harness: its process, the wire, its temp folder and its
/// `initialize` result. Dropping it stops the harness's process group.
struct Started {
    child: tokio::process::Child,
    wire: Wire,
    folder: TempFolder,
    init: Value,
}

impl Drop for Started {
    fn drop(&mut self) {
        if let Some(pid) = self.child.id() {
            unsafe {
                libc::killpg(pid as libc::pid_t, libc::SIGKILL);
            }
        }
    }
}

fn profile<'a>(cfg: &'a Config, id: &str) -> Result<&'a HarnessProfile> {
    cfg.harnesses.get(id).ok_or_else(|| anyhow!("no harness {id:?}; see `cmux harness list`"))
}

/// The profile with its env references resolved (Keychain, login env).
fn resolved(profile: &HarnessProfile) -> Result<HarnessProfile> {
    let mut spawn = profile.clone();
    profiles::resolve_env_refs(
        &mut spawn.env,
        &|var| std::env::var(var).ok(),
        &profiles::keychain_lookup,
    )
    .map_err(|e| anyhow!("env: {e}"))?;
    Ok(spawn)
}

async fn start(id: &str, profile: &HarnessProfile, timeout: Duration) -> Result<Started> {
    let folder = TempFolder::new(id)?;
    let spawn = resolved(profile)?;
    let mut cmd = crate::agent::harness_command(id, &spawn, &folder.path, None, None)?;
    // The sign-in may print to stderr (a URL); show it.
    cmd.stderr(std::process::Stdio::inherit());
    let mut child = cmd.spawn().map_err(|e| anyhow!("start {}: {e}", spawn.argv[0]))?;
    let (Some(stdin), Some(stdout)) = (child.stdin.take(), child.stdout.take()) else {
        bail!("no stdio pipes");
    };
    let wire = Wire {
        stdin,
        lines: BufReader::new(stdout).lines(),
        next: 1,
        reply: String::new(),
        noise: 0,
    };
    let mut started = Started { child, wire, folder, init: Value::Null };
    let init = json!({
        "protocolVersion": 1,
        "clientCapabilities": {
            "fs": {"readTextFile": false, "writeTextFile": false},
            "terminal": false,
            "auth": {"terminal": true},
            "_meta": {"terminal-auth": true},
        },
        "clientInfo": {"name": "cmux harness login", "version": env!("CARGO_PKG_VERSION")},
    });
    started.init = started.wire.call("initialize", init, timeout).await.map_err(|e| anyhow!(e))?;
    Ok(started)
}

/// `session/new` in the started harness: Ok(true) answered, Ok(false) sign-in
/// required (with the agent's message).
async fn session_new(started: &mut Started, timeout: Duration) -> Result<Result<(), String>> {
    let params = json!({"cwd": started.folder.path.to_string_lossy(), "mcpServers": []});
    match started.wire.call("session/new", params, timeout).await {
        Ok(_) => Ok(Ok(())),
        Err(e) if e.contains(&format!("({AUTH_REQUIRED})")) => Ok(Err(e)),
        Err(e) => Err(anyhow!(e)),
    }
}

fn not_acp(id: &str, profile: &HarnessProfile) -> Option<String> {
    match profile.kind {
        HarnessKind::Acp => None,
        HarnessKind::Terminal => Some(format!("{id} runs in a terminal tab; sign in there")),
        HarnessKind::ClaudeStdio if profile.argv.len() == 1 => {
            Some(format!("run `cmux harness login {id}` (it runs `claude auth login`)"))
        }
        HarnessKind::ClaudeStdio => Some(format!("{id} signs in through its router command")),
    }
}

/// Whether harness `id` is signed in.
pub async fn auth_state(cfg: &Config, id: &str, timeout: Duration) -> Result<AuthState> {
    let _ = (cfg, id, timeout, start, session_new, not_acp);
    bail!("red: no ACP sign-in yet")
}

/// Runs a terminal sign-in: `argv` with `env`, in this terminal; its exit code.
pub type TerminalRunner<'a> = dyn Fn(&[String], &BTreeMap<String, String>) -> Result<i32> + 'a;

/// Runs `argv` in this terminal (stdin, stdout and stderr inherited).
pub fn run_in_this_terminal(argv: &[String], env: &BTreeMap<String, String>) -> Result<i32> {
    let (program, args) = argv.split_first().ok_or_else(|| anyhow!("empty command"))?;
    let status = std::process::Command::new(program).args(args).envs(env).status()?;
    Ok(status.code().unwrap_or(1))
}

/// Signs in to harness `id` with `method` (default: its first `agent`
/// method, else its first `terminal` method). Returns what happened, in a
/// sentence.
pub async fn login(
    cfg: &Config,
    id: &str,
    method: Option<&str>,
    timeout: Duration,
    terminal: &TerminalRunner<'_>,
) -> Result<String> {
    let _ = (cfg, id, method, timeout, terminal, resolved);
    bail!("red: no ACP sign-in yet")
}

pub async fn run_cmd(
    id: &str,
    method: Option<String>,
    list: bool,
    status: bool,
    json_out: bool,
) -> Result<()> {
    let cfg = Config::load()?;
    let timeout = Duration::from_secs(300);
    if list || status {
        let state = auth_state(&cfg, id, Duration::from_secs(60)).await?;
        if json_out {
            println!("{}", serde_json::to_string_pretty(&state)?);
            return Ok(());
        }
        match &state {
            AuthState::NotAcp { hint } => println!("{hint}"),
            AuthState::SignedIn { methods } | AuthState::Required { methods, .. } => {
                let signed = matches!(state, AuthState::SignedIn { .. });
                println!("{id}: {}", if signed { "signed in" } else { "sign-in required" });
                for m in methods {
                    println!("  {:<24} {:<9} {}", m.id, m.kind, m.name);
                }
            }
        }
        return Ok(());
    }
    let outcome = login(&cfg, id, method.as_deref(), timeout, &run_in_this_terminal).await?;
    if json_out {
        println!("{}", json!({"id": id, "result": outcome}));
    } else {
        println!("{outcome}");
    }
    Ok(())
}

#[cfg(test)]
#[path = "harness_login_tests.rs"]
mod tests;
