//! `acpmux desktop link | unlink | status`: give the Claude desktop app, Claude Code and Codex
//! this machine's acpmux tools (`desktop_link.rs`), take them back, or show which have them.

use anyhow::Result;
use clap::Subcommand;
use serde_json::{Value, json};

use crate::desktop_link::{self, Env, Row, State};

#[derive(Subcommand)]
pub enum DesktopCmd {
    /// Give an app (default: every one installed here) the cmux MCP server: its chats can then
    /// list the machines and sessions cmux reaches, start a session on one, read it and message
    /// it. An entry named cmux that cmux did not write is left alone.
    Link {
        /// claude-desktop, claude-code, codex, or all (default).
        #[arg(long)]
        app: Option<String>,
        /// Say what would change; change nothing.
        #[arg(long)]
        dry_run: bool,
    },
    /// Remove the entry `link` wrote (and only that one).
    Unlink {
        /// claude-desktop, claude-code, codex, or all (default).
        #[arg(long)]
        app: Option<String>,
        #[arg(long)]
        dry_run: bool,
    },
    /// Which apps are here and which have the cmux server. Reads only.
    Status,
}

pub fn run(cmd: DesktopCmd, json_out: bool) -> Result<()> {
    let env = Env::current()?;
    let (rows, verb) = match cmd {
        DesktopCmd::Link { app, dry_run } => {
            let rows: Vec<Row> = desktop_link::apps(app.as_deref())
                .map_err(|e| crate::cli::errors::AppError::usage(e.to_string()))?
                .into_iter()
                .map(|a| desktop_link::link(&env, a, dry_run))
                .collect();
            (rows, "link")
        }
        DesktopCmd::Unlink { app, dry_run } => {
            let rows: Vec<Row> = desktop_link::apps(app.as_deref())
                .map_err(|e| crate::cli::errors::AppError::usage(e.to_string()))?
                .into_iter()
                .map(|a| desktop_link::unlink(&env, a, dry_run))
                .collect();
            (rows, "unlink")
        }
        DesktopCmd::Status => {
            (desktop_link::App::ALL.into_iter().map(|a| desktop_link::status(&env, a)).collect(), "status")
        }
    };
    if json_out {
        let apps: Vec<Value> = rows.iter().map(Row::to_json).collect();
        crate::cli::output::print_json(&json!({"apps": apps}));
    } else {
        for row in &rows {
            println!("{}", line(row));
        }
    }
    // A link that wrote nothing where it was asked to, by name, is a failure the caller sees.
    let failed = rows.iter().any(|r| {
        verb == "link"
            && r.state != State::Linked
            && r.state != State::NotInstalled
            && r.state != State::Foreign
            && !r.note.as_deref().is_some_and(|n| n.starts_with("would "))
    });
    if failed {
        let why = rows
            .iter()
            .filter(|r| r.state != State::Linked)
            .filter_map(|r| r.note.as_deref())
            .next_back()
            .unwrap_or("not linked");
        anyhow::bail!("{why}");
    }
    Ok(())
}

/// One app's line: `Claude desktop  linked  (note)`.
fn line(row: &Row) -> String {
    let state = row.state.id();
    match &row.note {
        Some(note) => format!("{:<22} {state:<14} {note}", row.app.label()),
        None => format!("{:<22} {state:<14} {}", row.app.label(), row.config.display()),
    }
}
