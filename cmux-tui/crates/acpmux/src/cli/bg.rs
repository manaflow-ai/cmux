//! `acpmux bg start|list`: the command-line spelling of the
//! session-owned background task RPCs used by the acpmux MCP server.
//!
//! The daemon remains the authority for caller identity and task ownership.
//! This client only supplies the current session id, so a command run from an
//! agent keeps the same checks as `bg_start` and `bg_list` in
//! `acpmux_mcp_bg.rs`.

use anyhow::{Result, anyhow};
use clap::Subcommand;
use serde_json::{Value, json};

use crate::cli::errors::AppError;
use crate::cli::output::print_json;
use crate::client::Client;
use crate::rpc::method;

#[derive(Subcommand, Debug, Clone, PartialEq, Eq)]
pub enum BgCmd {
    /// Start a shell command under this session's background-task owner.
    Start {
        /// One shell command string. Quote it once when it contains spaces.
        #[arg(required = true, trailing_var_arg = true, allow_hyphen_values = true)]
        command: Vec<String>,
        /// Treat the positional values as argv and quote each for the daemon's shell.
        #[arg(long)]
        argv: bool,
        /// The folder in which to run it.
        #[arg(long)]
        cwd: Option<String>,
        /// A short title shown in `bg list` and the completion notice.
        #[arg(long)]
        description: Option<String>,
        /// Ask the daemon to notify this session when the task ends.
        #[arg(long, default_value_t = true, action = clap::ArgAction::Set)]
        notify: bool,
    },
    /// List this session's background tasks.
    List {
        /// Include tasks started by other subagents or the lead.
        #[arg(long)]
        all: bool,
    },
}

fn current_session() -> Result<String> {
    std::env::var(crate::acpmux_mcp::SESSION_ENV)
        .ok()
        .filter(|id| !id.trim().is_empty())
        .ok_or_else(|| {
            AppError::usage(
                "bg commands need the current agent session (ACPMUX_SESSION_ID is not set)",
            )
            .into()
        })
}

fn text<'a>(v: &'a Value, key: &str) -> &'a str {
    v.get(key).and_then(Value::as_str).unwrap_or_default()
}

fn print_task(v: &Value) {
    let id = text(v, "id");
    let state = text(v, "state");
    let title = v
        .get("description")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| text(v, "command"));
    println!("{id}  [{state}]  {title}");
}

fn shell_quote(word: &str) -> String {
    if !word.is_empty()
        && word.bytes().all(|b| b.is_ascii_alphanumeric() || b"_@%+=:,./-".contains(&b))
    {
        word.to_owned()
    } else {
        format!("'{}'", word.replace('\'', "'\\''"))
    }
}

pub async fn run(client: &Client, cmd: BgCmd, json_out: bool) -> Result<()> {
    let session = current_session()?;
    let caller_subagent =
        crate::cli::sender::sending_as_on(client, None).await.subagent.map(|s| s.to_value());
    let (method, params) = match cmd {
        BgCmd::Start { command, argv, cwd, description, notify } => {
            if command.is_empty() {
                return Err(anyhow!("bg start needs COMMAND"));
            }
            let command = if argv {
                command.iter().map(|word| shell_quote(word)).collect::<Vec<_>>().join(" ")
            } else if command.len() == 1 {
                command[0].clone()
            } else {
                return Err(anyhow!(
                    "bg start takes one shell COMMAND string; pass --argv to quote multiple argv values"
                ));
            };
            (
                method::MUX_BG_START,
                json!({
                    "sessionId": session,
                    "command": command,
                    "cwd": cwd,
                    "description": description,
                    "notify": notify,
                    "callerSubagent": caller_subagent,
                }),
            )
        }
        BgCmd::List { all } => (
            method::MUX_BG_LIST,
            json!({
                "sessionId": session,
                "all": all,
                "callerSubagent": caller_subagent,
            }),
        ),
    };
    let reply = client.request(method, params).await?;
    if json_out {
        print_json(&reply);
        return Ok(());
    }
    match method {
        method::MUX_BG_LIST => {
            let tasks = reply.get("tasks").and_then(Value::as_array).cloned().unwrap_or_default();
            if tasks.is_empty() {
                println!("No background tasks.");
            } else {
                for task in &tasks {
                    print_task(task);
                }
            }
        }
        _ => print_task(&reply),
    }
    Ok(())
}

#[cfg(test)]
#[path = "bg_tests.rs"]
mod tests;
