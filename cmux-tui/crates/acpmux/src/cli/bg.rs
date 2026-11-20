//! The CLI for the daemon-owned background tasks also exposed by `bg_start` and `bg_list`.

use anyhow::{Result, bail};
use clap::Subcommand;
use serde_json::{Value, json};

#[derive(Subcommand)]
pub enum BgCommand {
    /// Run a shell command in this chat's environment, surviving agent hibernation.
    Start {
        /// The shell command, quoted as one argument.
        command: String,
        /// The chat whose environment and task ownership to use (default this chat).
        #[arg(long, default_value = "@")]
        session: String,
        /// The working folder (default the chat's folder).
        #[arg(long)]
        cwd: Option<String>,
        /// A few words describing the task.
        #[arg(long)]
        description: Option<String>,
        /// Omit the completion message to this chat.
        #[arg(long)]
        no_notify: bool,
    },
    /// List the daemon-owned tasks started by this caller, with their latest output.
    #[command(alias = "ls")]
    List {
        /// The chat whose tasks to list (default this chat).
        #[arg(long, default_value = "@")]
        session: String,
        /// Include tasks started by other callers of this chat.
        #[arg(long)]
        all: bool,
    },
}

pub async fn run(command: BgCommand, json_out: bool) -> Result<()> {
    let (session, tool, params) = match command {
        BgCommand::Start { command, session, cwd, description, no_notify } => (
            session,
            "bg_start",
            json!({"command": command, "cwd": cwd, "description": description, "notify": !no_notify}),
        ),
        BgCommand::List { session, all } => (session, "bg_list", json!({"all": all})),
    };
    let client = crate::daemon::connect(false).await?;
    let id = crate::cli::run::resolve_id(&client, &session).await?;
    let result = crate::acpmux_mcp::bg::call(&client, &id, tool, &params).await;
    let text = result["content"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|part| part.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n");
    if result["isError"] == true {
        bail!("{text}");
    }
    if json_out {
        crate::cli::output::print_json(&result["structuredContent"]);
    } else {
        println!("{text}");
    }
    Ok(())
}
