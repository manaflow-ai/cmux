//! `acpmux bg start|list`: command-line access to the daemon's background-task MCP tools.

use crate::cli::output::print_json;
use crate::client::Client;
use anyhow::{Result, anyhow};
use clap::{Args, Subcommand};
use serde_json::{Value, json};
use std::sync::Arc;

#[derive(Args, Debug, Clone)]
pub struct BgArgs {
    #[command(subcommand)]
    pub command: BgCommand,
}

#[derive(Subcommand, Debug, Clone)]
pub enum BgCommand {
    /// Run a shell command under the daemon and keep it alive while the agent is idle.
    Start { command: Vec<String> },
    /// List this session's background tasks.
    List {
        #[arg(long)]
        all: bool,
    },
}

pub async fn run(client: Arc<Client>, args: BgArgs, json_out: bool) -> Result<()> {
    let session = client
        .proven_caller_session()
        .map(str::to_owned)
        .or_else(|| std::env::var("ACPMUX_SESSION_ID").ok())
        .filter(|id| !id.trim().is_empty())
        .ok_or_else(|| anyhow!("no current session: run this inside an acpmux agent session"))?;
    let (name, params) = match args.command {
        BgCommand::Start { command } if command.is_empty() => {
            return Err(anyhow!("bg start needs a command"));
        }
        BgCommand::Start { command } => {
            let command = command.join(" ");
            ("bg_start", json!({"command": command, "description": command, "notify": true}))
        }
        BgCommand::List { all } => ("bg_list", json!({"all": all})),
    };
    let value = crate::acpmux_mcp::call_bg(&client, &session, name, &params).await;
    if json_out {
        print_json(&value);
        return Ok(());
    }
    if value.get("isError").and_then(Value::as_bool) == Some(true) {
        let text = value
            .pointer("/content/0/text")
            .and_then(Value::as_str)
            .unwrap_or("background task failed");
        return Err(anyhow!(text.to_owned()));
    }
    if let Some(text) = value.pointer("/content/0/text").and_then(Value::as_str) {
        println!("{text}");
    } else {
        println!("{}", value.get("structuredContent").unwrap_or(&value));
    }
    Ok(())
}
