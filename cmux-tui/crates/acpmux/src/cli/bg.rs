//! `acpmux bg start|list|output|stop`: the command-line spelling of the
//! session-owned background task RPCs used by the acpmux MCP server.
//!
//! The daemon remains the authority for caller identity and task ownership.
//! This client only supplies the current session id, so a command run from an
//! agent keeps the same checks as `bg_start`, `bg_list`, `bg_output` and
//! `bg_stop` in `acpmux_mcp_bg.rs`.
//!
//! `output` and `stop` are here because the MCP server is not the only thing that can be down.
//! 2026-11-21 on big-red the `acpmux` MCP server would not connect (ECONNREFUSED dialing its
//! endpoint) while the daemon served the CLI fine, and with no `bg output` there was no route at
//! all to a finished task's result: every backgrounded test sweep, push or CI wait had to be run
//! again. A task's output and its stop reach the same daemon either way, so the shell is the
//! route that survives a dead MCP front (`bg_hook::read_call` names it).

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
    /// Print a background task's output (the same read as the `bg_output` MCP tool).
    Output {
        /// The task's id, as `bg start` or `bg list` gave it.
        id: String,
        /// Print only this many of the last lines read (default 200; 0 prints every line read).
        #[arg(long, default_value_t = OUTPUT_TAIL_LINES)]
        tail: usize,
    },
    /// Stop a background task this session started (the same stop as the `bg_stop` MCP tool).
    Stop {
        /// The task's id, as `bg start` or `bg list` gave it.
        id: String,
        /// Stop it even though another subagent or the lead started it; only when its owner
        /// asked you to or is gone, never as cleanup.
        #[arg(long)]
        force_other_owner: bool,
    },
}

/// How many of the last lines `bg output` prints when the call names no `--tail`. The daemon
/// reads the task's last 64 KiB (`hub::bg_tasks::OUTPUT_DEFAULT`); a terminal and an agent's
/// transcript both do better with a bounded tail of it than with every line of that window, and
/// `--tail 0` prints the whole window.
pub(crate) const OUTPUT_TAIL_LINES: usize = 200;

/// The last `tail` lines of `text` (every line when `tail` is 0), and how many lines `text` held.
fn tail_lines(text: &str, tail: usize) -> (String, usize) {
    let lines: Vec<&str> = text.lines().collect();
    let total = lines.len();
    let kept = if tail == 0 { lines.as_slice() } else { &lines[total.saturating_sub(tail)..] };
    (kept.join("\n"), total)
}

/// What `bg output` prints: the task's own line, its output's tail, and a last line placing that
/// tail in the task's output (so a reader knows when lines were left out, and what is left).
fn output_text(v: &Value, tail: usize) -> String {
    let num = |k: &str| v.get(k).and_then(Value::as_u64);
    let (from, next, total) = (num("fromByte"), num("nextByte"), num("totalBytes"));
    let (shown, lines) = tail_lines(v.get("text").and_then(Value::as_str).unwrap_or_default(), tail);
    let cut = if tail > 0 && lines > tail {
        format!("last {tail} of {lines} lines; ")
    } else {
        String::new()
    };
    let bytes = match (from, next, total) {
        (Some(from), Some(next), Some(total)) => format!("bytes {from}..{next} of {total}"),
        _ => "bytes unknown".to_owned(),
    };
    let (head, shown) = (task_line(v), shown.trim_end());
    format!("{head}\n{shown}\n[{cut}{bytes}]")
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

fn task_line(v: &Value) -> String {
    let id = text(v, "id");
    let state = text(v, "state");
    let title = v
        .get("description")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| text(v, "command"));
    format!("{id}  [{state}]  {title}")
}

fn print_task(v: &Value) {
    println!("{}", task_line(v));
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
    // `output`'s tail is applied here, to what the daemon read; the daemon's own read window is
    // its default (the task's last 64 KiB).
    let tail = match &cmd {
        BgCmd::Output { tail, .. } => Some(*tail),
        _ => None,
    };
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
        BgCmd::Output { id, tail: _ } => (
            method::MUX_BG_OUTPUT,
            json!({
                "sessionId": session,
                "id": id,
                "callerSubagent": caller_subagent,
            }),
        ),
        BgCmd::Stop { id, force_other_owner } => (
            method::MUX_BG_STOP,
            json!({
                "sessionId": session,
                "id": id,
                "force_other_owner": force_other_owner,
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
        method::MUX_BG_OUTPUT => println!("{}", output_text(&reply, tail.unwrap_or(0))),
        _ => print_task(&reply),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{BgCmd, OUTPUT_TAIL_LINES, output_text, shell_quote, tail_lines};
    use crate::cli::command::{Cli, Command};
    use clap::Parser as _;
    use serde_json::json;

    fn parse(argv: &[&str]) -> BgCmd {
        match Cli::try_parse_from(argv).unwrap().command.unwrap() {
            Command::Bg(cmd) => cmd,
            _ => panic!("{argv:?} did not parse as a bg command"),
        }
    }

    /// `bg output ID` reads one task with the bounded default tail; `--tail` sets it, and
    /// `bg stop ID` stops one, by default only a task this caller started.
    #[test]
    fn output_and_stop_take_a_task_id() {
        assert_eq!(
            parse(&["acpmux", "bg", "output", "bg-7"]),
            BgCmd::Output { id: "bg-7".to_owned(), tail: OUTPUT_TAIL_LINES }
        );
        assert_eq!(
            parse(&["acpmux", "bg", "output", "bg-7", "--tail", "20"]),
            BgCmd::Output { id: "bg-7".to_owned(), tail: 20 }
        );
        assert_eq!(
            parse(&["acpmux", "bg", "stop", "bg-7"]),
            BgCmd::Stop { id: "bg-7".to_owned(), force_other_owner: false }
        );
        assert_eq!(
            parse(&["acpmux", "bg", "stop", "bg-7", "--force-other-owner"]),
            BgCmd::Stop { id: "bg-7".to_owned(), force_other_owner: true }
        );
        // Each needs its task: neither acts on "every task of this session".
        assert!(Cli::try_parse_from(["acpmux", "bg", "output"]).is_err());
        assert!(Cli::try_parse_from(["acpmux", "bg", "stop"]).is_err());
    }

    /// The tail keeps the last lines, and 0 keeps every line the daemon read.
    #[test]
    fn the_tail_keeps_the_last_lines() {
        let text = "a\nb\nc\nd\n";
        assert_eq!(tail_lines(text, 2), ("c\nd".to_owned(), 4));
        assert_eq!(tail_lines(text, 9), ("a\nb\nc\nd".to_owned(), 4));
        assert_eq!(tail_lines(text, 0), ("a\nb\nc\nd".to_owned(), 4));
        assert_eq!(tail_lines("", 2), (String::new(), 0));
    }

    /// `bg output`'s print: the task's line, the tail, and a last line placing that tail in the
    /// task's output, which says so when lines were left out.
    #[test]
    fn output_prints_the_task_its_tail_and_where_the_tail_came_from() {
        let view = json!({"id": "bg-7", "state": "running", "description": "cargo test",
            "command": "cargo test -p acpmux", "text": "one\ntwo\nthree\n",
            "fromByte": 0, "nextByte": 14, "totalBytes": 14});
        let all = output_text(&view, 0);
        assert_eq!(all, "bg-7  [running]  cargo test\none\ntwo\nthree\n[bytes 0..14 of 14]");
        let cut = output_text(&view, 1);
        assert_eq!(cut, "bg-7  [running]  cargo test\nthree\n[last 1 of 3 lines; bytes 0..14 of 14]");
        // A reply without the byte counts still prints its task and its lines.
        let bare = output_text(&json!({"id": "bg-7", "state": "exited", "command": "c"}), 0);
        assert_eq!(bare, "bg-7  [exited]  c\n\n[bytes unknown]");
    }

    #[test]
    fn argv_mode_quotes_shell_metacharacters_and_single_quotes() {
        assert_eq!(shell_quote("cargo"), "cargo");
        assert_eq!(shell_quote("hello world"), "'hello world'");
        assert_eq!(shell_quote("it's"), "'it'\\''s'");
        assert_eq!(shell_quote("$(touch /tmp/nope)"), "'$(touch /tmp/nope)'");
    }
}
