//! `acpmux task new|done|blocked|failed|ls` (`hub/tasks.rs`): give a session on this daemon a
//! task, end one with its typed result in one call, and list the tasks a chat gave. Inside an
//! agent session the CLI carries the session's caller token (`client.rs`), so the daemon knows
//! which chat gives, ends or lists. Also `acpmux briefs`, the briefs a task is.

use anyhow::Result;
use clap::{Args, Subcommand};
use serde_json::{Value, json};

use crate::cli::output::{arg_or_stdin, print_json};
use crate::rpc::method;
use cmux_json::JsonSet as _;

#[derive(Subcommand)]
pub enum TaskCmd {
    /// Give SESSION a task: it gets the brief with the task id first, and ends it with
    /// `acpmux task done ID`, which brings its result back to this chat as one card.
    New {
        /// The session (name or id) on this daemon.
        session: String,
        /// One line: what is to be done.
        title: String,
        /// When it is done, e.g. "#24961 is merged".
        #[arg(long)]
        stop: Option<String>,
        /// The tracker bead it is (`acpmux bead`): SESSION is linked to it; repeat for more.
        #[arg(long = "bead", value_name = "ID")]
        beads: Vec<String>,
        /// The brief; default the title. `-` reads stdin.
        brief: Vec<String>,
    },
    /// End task ID as done: its result goes to the chat that gave it, and is your whole reply.
    Done(ResultArgs),
    /// End task ID as blocked, with --why.
    Blocked(ResultArgs),
    /// End task ID as failed, with --why.
    Failed(ResultArgs),
    /// The tasks this chat gave, open ones first (outside a session: every task here).
    #[command(alias = "list")]
    Ls {
        /// The tasks another chat gave.
        #[arg(long, conflicts_with = "all")]
        from: Option<String>,
        /// Every task on this daemon.
        #[arg(long)]
        all: bool,
        /// Only the tasks still running.
        #[arg(long)]
        open: bool,
        #[arg(long, default_value_t = 100)]
        limit: usize,
    },
}

#[derive(Args)]
pub struct ResultArgs {
    pub id: String,
    /// One line: what happened.
    #[arg(long)]
    pub summary: String,
    /// A PR's URL; repeat for more.
    #[arg(long = "pr")]
    pub prs: Vec<String>,
    /// A commit SHA; repeat for more.
    #[arg(long = "sha")]
    pub shas: Vec<String>,
    /// What stops it (blocked or failed).
    #[arg(long)]
    pub why: Option<String>,
}

#[derive(Subcommand)]
/// Task briefs that coordinate work across sessions.
pub enum BriefsCmd {
    /// List briefs: id, status, title.
    #[command(alias = "list")]
    Ls {
        /// Only briefs with this status.
        #[arg(long)]
        status: Option<String>,
        /// At most this many.
        #[arg(long, default_value_t = 100)]
        limit: usize,
    },
    /// Send more instructions to the session working a brief.
    Steer {
        brief_id: String,
        /// The text, or `-` to read it from stdin.
        text: Vec<String>,
    },
    /// Report a brief's result.
    Report {
        brief_id: String,
        /// The summary, or `-` to read it from stdin.
        summary: Vec<String>,
        /// The brief's new status.
        #[arg(long, default_value = "reported")]
        status: String,
    },
}

pub async fn run(cmd: TaskCmd, json_out: bool) -> Result<()> {
    // The session a new task's beads link.
    let mut beads = None;
    let (m, params) = match cmd {
        TaskCmd::New { session, title, stop, beads: ids, brief } => {
            crate::beads::checked(&ids)?;
            beads = Some((session.clone(), ids));
            let mut params = json!({"sessionId": session, "title": title, "stopCondition": stop});
            if !brief.is_empty() {
                params.set("brief", json!(arg_or_stdin(&brief)?));
            }
            if let Some(from) = crate::cli::sender::of_this_process() {
                params.set("_meta", json!({"acpmux": {"fromAgent": from}}));
            }
            (method::MUX_TASK_NEW, params)
        }
        TaskCmd::Done(r) => report("done", r),
        TaskCmd::Blocked(r) => report("blocked", r),
        TaskCmd::Failed(r) => report("failed", r),
        TaskCmd::Ls { from, all, open, limit } => {
            (method::MUX_TASKS, json!({"from": from, "all": all, "open": open, "limit": limit}))
        }
    };
    let client = crate::daemon::connect(true).await?;
    // Linked before the task is given, so the agent never starts on it unlinked, and a failed
    // link gives no task. A failed task leaves only the link, which a retry sets again.
    if let Some((session, ids)) = beads {
        crate::cli::beads::link(&client, &session, &ids).await?;
    }
    let reply = client.request(m, params).await?;
    if json_out {
        print_json(&reply);
    } else if let Some(rows) = reply["tasks"].as_array() {
        if rows.is_empty() {
            println!("No tasks.");
        }
        rows.iter().for_each(|row| println!("{}", line(row)));
    } else if let Some(row) = reply.get("task") {
        println!("{}", line(row));
    } else {
        let brief = &reply["brief"];
        let replayed = if reply["replayed"] == true { " (already reported)" } else { "" };
        println!("{} {}{replayed}", brief["briefId"].as_str().unwrap_or("?"), brief["status"]);
    }
    Ok(())
}

fn report(state: &str, r: ResultArgs) -> (&'static str, Value) {
    let params = json!({"briefId": r.id, "status": state, "summary": r.summary, "prs": r.prs,
                        "shas": r.shas, "why": r.why});
    (method::MUX_REPORT, params)
}

/// One task: id, state, its lane and the lane's state now (and how long it has stalled), the
/// title, and the result's summary.
fn line(row: &Value) -> String {
    let s = |v: &Value| v.as_str().unwrap_or("?").to_owned();
    let mut lane =
        row["lane"]["state"].as_str().map_or_else(|| s(&row["sessionStatus"]), str::to_owned);
    if let Some(since) = row["lane"]["stalledSince"].as_u64() {
        let minutes = crate::store::now_ms().saturating_sub(since) / 60_000;
        lane.push_str(&format!(", stalled {minutes}m"));
    }
    let mut text = format!(
        "{:<11} {:<8} {} ({lane})  {}",
        s(&row["taskId"]),
        s(&row["status"]),
        s(&row["to"]),
        s(&row["title"])
    );
    if let Some(summary) = row["result"]["summary"].as_str() {
        text.push_str(&format!("\n            {summary}"));
    }
    if let Some(why) = row["result"]["undelivered"].as_str() {
        text.push_str(&format!("\n            not delivered to its chat: {why}"));
    }
    text
}
