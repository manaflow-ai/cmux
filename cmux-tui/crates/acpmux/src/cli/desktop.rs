//! `acpmux desktop link | unlink | status`: give the Claude desktop app, Claude Code, Codex,
//! OpenCode, Gemini CLI, Qwen Code and pi this machine's acpmux tools (`desktop_link.rs`), take them back, or show which have them.

use anyhow::Result;
use clap::Subcommand;
use serde_json::{Value, json};

use crate::desktop_link::{self, Env, Row, State};

#[derive(Subcommand)]
pub enum DesktopCmd {
    /// Give an app (default: every one installed here) the cmux MCP server (pi, which has no MCP:
    /// a cmux skill over this CLI): its chats can then list the machines and sessions cmux
    /// reaches, read one and message it. An entry named cmux that cmux did not write is left alone.
    Link {
        /// claude-desktop, claude-code, codex, opencode, gemini, qwen, pi, or all (default).
        #[arg(long)]
        app: Option<String>,
        /// Say what would change; change nothing.
        #[arg(long)]
        dry_run: bool,
    },
    /// Remove the entry `link` wrote (and only that one).
    Unlink {
        /// claude-desktop, claude-code, codex, opencode, gemini, qwen, pi, or all (default).
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
        DesktopCmd::Status => (
            desktop_link::App::ALL.into_iter().map(|a| desktop_link::status(&env, a)).collect(),
            "status",
        ),
    };
    if json_out {
        let apps: Vec<Value> = rows.iter().map(Row::to_json).collect();
        crate::cli::output::print_json(&json!({"apps": apps}));
    } else {
        for row in &rows {
            println!("{}", line(row));
        }
    }
    // A link or unlink that could not write is a failure the caller sees, with that app's own
    // reason (not another app's "not on this machine"). A foreign entry is left alone on purpose.
    let failed = |r: &&Row| {
        !r.note.as_deref().is_some_and(|n| n.starts_with("would "))
            && match verb {
                "link" => matches!(r.state, State::NotLinked | State::Stale),
                "unlink" => matches!(r.state, State::Linked | State::Stale),
                _ => false,
            }
    };
    if let Some(row) = rows.iter().find(failed) {
        anyhow::bail!("{}: {}", row.app.label(), row.note.as_deref().unwrap_or("not linked"));
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
