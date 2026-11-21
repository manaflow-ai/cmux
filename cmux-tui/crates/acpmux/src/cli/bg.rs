//! `acpmux bg start|list|output`: the command-line spelling of the
//! session-owned background task RPCs used by the acpmux MCP server.
//!
//! `output` is here because the MCP server is the surface that fails: its port is per session,
//! and a daemon restart leaves it stale for the rest of that session, while this CLI keeps
//! working (2026-11-21: `acpmux (ECONNREFUSED)` for a whole session, `bg list` fine throughout,
//! and no way at all to read what a task had printed). It is the same `_acpmux/bg/output` read
//! the MCP `bg_output` tool makes, rendered by the same `bg_run::output_text`, with a line bound
//! on top.
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
        /// Ask the daemon to notify this session when the task ends (`--notify=false` to not).
        ///
        /// A bare `--notify` is the on form everyone types; with ArgAction::Set alone clap read it
        /// as a missing value and refused the whole call with "[possible values: true, false]",
        /// which costs the caller a re-run of a call that said exactly what it wanted.
        #[arg(long, default_value_t = true, default_missing_value = "true", num_args = 0..=1,
              require_equals = true, action = clap::ArgAction::Set)]
        notify: bool,
        /// No message to the chat when it ends, the spelling `process start` takes.
        #[arg(long, conflicts_with = "notify")]
        no_notify: bool,
    },
    /// List this session's background tasks.
    List {
        /// Include tasks started by other subagents or the lead.
        #[arg(long)]
        all: bool,
    },
    /// Read a background task's output: by default its last lines, the same read the MCP
    /// `bg_output` tool makes.
    ///
    /// A task's output is whatever the command printed, which for an agent task is its whole
    /// transcript (a Claude Code subagent's is an `agent-*.jsonl` of every step it took, many
    /// thousands of lines). The line bound is the point: this output is read into a caller's
    /// context. `--json` prints the daemon's whole reply, the read entire, as the MCP tool's
    /// structured result does.
    Output {
        /// The task's id, as `bg start` or `bg list` gave it.
        #[arg(required = true)]
        id: String,
        /// Show only the last N lines of what was read (default 40). A task that printed a
        /// subagent's transcript prints thousands; raise this deliberately.
        #[arg(long, default_value_t = crate::bg_run::OUTPUT_TAIL_LINES, value_parser = clap::value_parser!(u64).range(1..))]
        tail: u64,
        /// Show every line that was read, with no line bound (the byte bounds still hold).
        #[arg(long, conflicts_with = "tail")]
        no_tail: bool,
        /// Read from this byte of the task's whole output; pass the previous read's
        /// `next fromByte` to see only what is new.
        #[arg(long)]
        from_byte: Option<u64>,
        /// At most this many bytes (default 65536, the most 1048576). The daemon keeps each
        /// task's newest 8 MiB.
        #[arg(long)]
        max_bytes: Option<u64>,
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
    // How many lines of a read `output` prints: its `--tail`, or every line read for `--no-tail`.
    let mut tail: Option<u64> = None;
    let caller_subagent =
        crate::cli::sender::sending_as_on(client, None).await.subagent.map(|s| s.to_value());
    let (method, params) = match cmd {
        BgCmd::Start { command, argv, cwd, description, notify, no_notify } => {
            if command.is_empty() {
                return Err(anyhow!("bg start needs COMMAND"));
            }
            // `--notify` takes its value through `=`, so a space-separated one would fall through
            // to COMMAND and run `false ...` as the task. Say so instead of running the wrong thing.
            if matches!(command[0].as_str(), "true" | "false") {
                return Err(anyhow!(
                    "bg start: `--notify {0}` left {0:?} as the COMMAND; write it as --notify={0}",
                    command[0]
                ));
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
                    "notify": notify && !no_notify,
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
        BgCmd::Output { ref id, tail: t, no_tail, from_byte, max_bytes } => {
            tail = (!no_tail).then_some(t);
            (
                method::MUX_BG_OUTPUT,
                json!({
                    "sessionId": session,
                    "id": id,
                    "fromByte": from_byte,
                    "maxBytes": max_bytes,
                    "callerSubagent": caller_subagent,
                }),
            )
        }
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
        // One judged value, one rendering: the same `bg_run::output_text` the MCP `bg_output`
        // tool prints, with this command's line bound.
        method::MUX_BG_OUTPUT => println!("{}", crate::bg_run::output_text(&reply, tail)),
        method::MUX_BG_START => {
            print_task(&reply);
            // A next step the caller of this CLI can take, since it may have no MCP server, or
            // a stale port to one (`bg_hook::read_call`).
            if let Some(id) = reply.get("id").and_then(Value::as_str) {
                println!("next: read its output with {}", crate::bg_hook::cli_read_call(id));
            }
        }
        _ => print_task(&reply),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{BgCmd, shell_quote};
    use clap::Parser as _;

    /// `bg output <id>` parses, and its line bound is on by default: a task's output can be a
    /// whole subagent transcript, so an unbounded read is never what a bare call does.
    #[test]
    fn bg_output_parses_and_is_bounded_by_default() {
        #[derive(clap::Parser)]
        struct Cli {
            #[command(subcommand)]
            bg: BgCmd,
        }
        let of =
            |words: &[&str]| Cli::parse_from(std::iter::once("bg").chain(words.iter().copied())).bg;
        assert_eq!(
            of(&["output", "bg-1"]),
            BgCmd::Output {
                id: "bg-1".to_owned(),
                tail: crate::bg_run::OUTPUT_TAIL_LINES,
                no_tail: false,
                from_byte: None,
                max_bytes: None,
            }
        );
        let BgCmd::Output { tail, from_byte, max_bytes, .. } =
            of(&["output", "bg-1", "--tail", "5", "--from-byte", "7", "--max-bytes", "99"])
        else {
            panic!("not an output command");
        };
        assert_eq!((tail, from_byte, max_bytes), (5, Some(7), Some(99)));
        assert!(matches!(
            of(&["output", "bg-1", "--no-tail"]),
            BgCmd::Output { no_tail: true, .. }
        ));
        // --tail 0 would print nothing: refused, not silently treated as "everything".
        let mut words = vec!["bg", "output", "bg-1", "--tail", "0"];
        assert!(Cli::try_parse_from(words.clone()).is_err());
        words.pop();
        words.pop();
        assert!(Cli::try_parse_from(words).is_ok());
    }

    /// A bare `--notify` means on. It used to be refused for a missing value, so a caller who
    /// said what it wanted got nothing but a usage dump and spent a second call saying it again.
    #[test]
    fn a_bare_notify_flag_means_on() {
        #[derive(clap::Parser)]
        struct Cli {
            #[command(subcommand)]
            bg: BgCmd,
        }
        let notify = |words: &[&str]| {
            let BgCmd::Start { notify, .. } =
                Cli::parse_from(std::iter::once("bg").chain(words.iter().copied())).bg
            else {
                panic!("not a start command");
            };
            notify
        };
        assert!(notify(&["start", "--notify", "echo hi"]));
        assert!(notify(&["start", "echo hi"]));
        assert!(notify(&["start", "--notify=true", "echo hi"]));
        assert!(!notify(&["start", "--notify=false", "echo hi"]));
        // `process start` spells off as --no-notify; both spellings work here rather than one
        // being refused for being the other command's word.
        assert!(matches!(
            Cli::parse_from(["bg", "start", "--no-notify", "echo hi"]).bg,
            BgCmd::Start { no_notify: true, .. }
        ));
        // The value comes through `=` only, so a space-separated one stays in COMMAND, where the
        // handler names it rather than running `false` as the task.
        let BgCmd::Start { notify, command, .. } =
            Cli::parse_from(["bg", "start", "--notify", "false", "echo hi"]).bg
        else {
            panic!("not a start command");
        };
        assert!(notify);
        assert_eq!(command, ["false", "echo hi"]);
    }

    #[test]
    fn argv_mode_quotes_shell_metacharacters_and_single_quotes() {
        assert_eq!(shell_quote("cargo"), "cargo");
        assert_eq!(shell_quote("hello world"), "'hello world'");
        assert_eq!(shell_quote("it's"), "'it'\\''s'");
        assert_eq!(shell_quote("$(touch /tmp/nope)"), "'$(touch /tmp/nope)'");
    }
}
