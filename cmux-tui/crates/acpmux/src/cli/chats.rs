//! `acpmux chats list|open|roots` (also `cmux chats …`): the device-wide
//! chat index (ALL-CHATS-ON-DEVICE C7) from the command line.
//!
//! - `list`: one page of `_acpmux/chats`, newest first. Titles and folders
//!   are user data: they go to stdout only, never to a log.
//! - `roots`: `_acpmux/chat_roots`, with the refused roots and their reasons.
//! - `open KEY [--cwd DIR]`: `_acpmux/chat_open`. An `adopt` plan creates the
//!   daemon session (`session/new` with the plan's params) and attaches to
//!   it. A `terminal` or `readOnly` plan is printed: `cmux chats open`
//!   (the cmux binary) opens it in a new tab through [`resolve_blocking`].
//!   A plan that needs a folder fails with exit 2 and the reason; the home
//!   folder is never a fallback.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::Result;
use clap::Subcommand;
use serde_json::{Value, json};

use crate::cli::errors::{AppError, Code};
use crate::cli::output::print_json;
use crate::client::Client;
use crate::rpc::method;

#[derive(Subcommand, Debug, PartialEq, Eq)]
pub enum ChatsCmd {
    /// Chats on this device from every harness, newest first.
    #[command(alias = "ls")]
    List {
        /// Only this harness: claude-code, codex, opencode, pi, gemini, cursor-agent, amp.
        #[arg(long)]
        harness: Option<String>,
        /// Only chats in this folder or a folder inside it.
        #[arg(long)]
        folder: Option<String>,
        /// Only chats of this account (a subrouter account home, for example).
        #[arg(long)]
        account: Option<String>,
        /// Text in the title or the folder.
        #[arg(long, short)]
        query: Option<String>,
        /// The most chats to print.
        #[arg(long, short = 'n', default_value_t = 50)]
        limit: usize,
    },
    /// Open a chat again: KEY is `<harness>:<session id>` from `chats list`.
    Open {
        key: String,
        /// The folder to open in when the chat's own folder is gone or unknown.
        #[arg(long)]
        cwd: Option<PathBuf>,
    },
    /// The folders the index reads, and the folders it refuses with the reason.
    Roots,
}

/// What opening a chat comes to, after the daemon planned it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OpenOutcome {
    /// The chat runs in this daemon session now (an adopted Claude/Codex chat).
    Session { session_id: String },
    /// Run `argv` with `env` added, in `cwd`.
    Terminal { argv: Vec<String>, env: BTreeMap<String, String>, cwd: PathBuf },
    /// No resume path: show this transcript file.
    ReadOnly { path: PathBuf },
}

/// A `_acpmux/chat_open` plan before any daemon call: an adopt plan still
/// needs its `session/new`.
#[derive(Debug, Clone, PartialEq)]
pub enum Planned {
    Adopt { session_new: Value },
    Ready(OpenOutcome),
}

/// The `_acpmux/chats` params of `list`.
pub fn list_params(
    harness: Option<&str>,
    folder: Option<&str>,
    account: Option<&str>,
    query: Option<&str>,
    limit: usize,
) -> Value {
    let mut params = json!({ "limit": limit.max(1) });
    for (key, value) in
        [("harness", harness), ("folder", folder), ("account", account), ("query", query)]
    {
        if let Some(value) = value.filter(|value| !value.is_empty()) {
            params[key] = json!(value);
        }
    }
    params
}

/// The `_acpmux/chat_open` params; `cwd` must be an absolute folder.
pub fn open_params(key: &str, cwd: Option<&Path>) -> Result<Value, AppError> {
    if crate::chats::parse_key(key).is_none() {
        return Err(AppError::usage(format!(
            "{key:?} is not a chat key; use `<harness>:<session id>` from `chats list`"
        )));
    }
    let mut params = json!({ "key": key });
    if let Some(cwd) = cwd {
        if !cwd.is_absolute() {
            return Err(AppError::usage(format!("--cwd {} must be absolute", cwd.display())));
        }
        params["cwd"] = json!(cwd);
    }
    Ok(params)
}

/// Reads a `_acpmux/chat_open` plan. A plan without a folder is a usage
/// error with the daemon's reason: the person passes `--cwd`.
pub fn read_plan(plan: &Value) -> Result<Planned, AppError> {
    let text = |value: &Value| value.as_str().map(str::to_owned);
    if let Some(reason) = plan.pointer("/needsFolder/reason").and_then(text) {
        return Err(AppError::new(
            Code::Usage,
            "needs_folder",
            format!("{reason}; pass --cwd DIR to open it in another folder"),
        ));
    }
    let cwd = plan.get("cwd").and_then(text).map(PathBuf::from);
    let bad = |what: &str| AppError::new(Code::Runtime, "bad_plan", format!("open plan: {what}"));
    match plan.get("kind").and_then(Value::as_str) {
        Some("adopt") => {
            let session_new = plan.get("sessionNew").filter(|v| v.is_object());
            Ok(Planned::Adopt {
                session_new: session_new.ok_or_else(|| bad("no sessionNew"))?.clone(),
            })
        }
        Some("terminal") => {
            let argv: Vec<String> = plan
                .pointer("/terminal/argv")
                .and_then(Value::as_array)
                .map(|argv| argv.iter().filter_map(text).collect())
                .unwrap_or_default();
            if argv.is_empty() {
                return Err(bad("empty argv"));
            }
            let env: BTreeMap<String, String> = plan
                .pointer("/terminal/env")
                .and_then(Value::as_object)
                .map(|env| env.iter().filter_map(|(k, v)| Some((k.clone(), text(v)?))).collect())
                .unwrap_or_default();
            let cwd = cwd.filter(|cwd| cwd.is_absolute()).ok_or_else(|| bad("no folder"))?;
            Ok(Planned::Ready(OpenOutcome::Terminal { argv, env, cwd }))
        }
        Some("readOnly") => {
            let path = plan.pointer("/readOnly/path").and_then(text).map(PathBuf::from);
            Ok(Planned::Ready(OpenOutcome::ReadOnly { path: path.ok_or_else(|| bad("no path"))? }))
        }
        other => Err(bad(&format!("unknown kind {other:?}"))),
    }
}

/// Plans `key` and, for an adopt plan, creates its daemon session.
pub async fn resolve(client: &Client, key: &str, cwd: Option<&Path>) -> Result<OpenOutcome> {
    let plan = client.request("_acpmux/chat_open", open_params(key, cwd)?).await?;
    match read_plan(&plan)? {
        Planned::Ready(outcome) => Ok(outcome),
        Planned::Adopt { session_new } => {
            let created = client.request(method::SESSION_NEW, session_new).await?;
            let session_id = created
                .get("sessionId")
                .and_then(Value::as_str)
                .filter(|id| !id.is_empty())
                .ok_or_else(|| anyhow::anyhow!("session/new returned no sessionId"))?;
            Ok(OpenOutcome::Session { session_id: session_id.to_owned() })
        }
    }
}

/// [`resolve`] for a caller without a runtime (the cmux binary's
/// `cmux chats open`). `home` is the acpmux home of a tagged build.
pub fn resolve_blocking(
    key: &str,
    cwd: Option<&Path>,
    home: Option<PathBuf>,
) -> Result<OpenOutcome> {
    if let Some(home) = home {
        crate::config::set_home_override(home);
    }
    tokio::runtime::Builder::new_current_thread().enable_all().build()?.block_on(async {
        let client = crate::daemon::connect(true).await?;
        resolve(&client, key, cwd).await
    })
}

pub(crate) async fn run(cmd: ChatsCmd, json_out: bool) -> Result<()> {
    let client = crate::daemon::connect(true).await?;
    match cmd {
        ChatsCmd::List { harness, folder, account, query, limit } => {
            let params = list_params(
                harness.as_deref(),
                folder.as_deref(),
                account.as_deref(),
                query.as_deref(),
                limit,
            );
            let page = client.request("_acpmux/chats", params).await?;
            if json_out {
                print_json(&page);
            } else {
                print!("{}", list_text(&page, now_ms()));
            }
            Ok(())
        }
        ChatsCmd::Roots => {
            let view = client.request("_acpmux/chat_roots", json!({})).await?;
            if json_out {
                print_json(&view);
            } else {
                print!("{}", roots_text(&view));
            }
            Ok(())
        }
        ChatsCmd::Open { key, cwd } => {
            let outcome = resolve(&client, &key, cwd.as_deref()).await?;
            match outcome {
                OpenOutcome::Session { session_id } if !json_out => {
                    crate::tui::run(client, Some(session_id)).await
                }
                outcome => {
                    if json_out {
                        print_json(&outcome_value(&outcome));
                    } else {
                        print!("{}", outcome_text(&outcome));
                    }
                    Ok(())
                }
            }
        }
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
}

/// The `list` table: key, harness, age, title, folder; one chat per line.
pub fn list_text(page: &Value, now_ms: i64) -> String {
    let chats = page.get("chats").and_then(Value::as_array).cloned().unwrap_or_default();
    let mut out = String::new();
    if page.get("enabled").and_then(Value::as_bool) == Some(false) {
        out.push_str("chats are turned off (agents.chats.enabled)\n");
        return out;
    }
    if page.get("ready").and_then(Value::as_bool) == Some(false) {
        out.push_str("the chat index is still scanning; try again in a moment\n");
    }
    if chats.is_empty() {
        out.push_str("no chats\n");
        return out;
    }
    let field = |chat: &Value, key: &str| {
        chat.get(key).and_then(Value::as_str).map(one_line).unwrap_or_default()
    };
    let rows: Vec<[String; 5]> = chats
        .iter()
        .map(|chat| {
            let updated = chat.get("updatedMs").and_then(Value::as_i64).unwrap_or(0);
            let title = field(chat, "title");
            [
                field(chat, "key"),
                field(chat, "harness"),
                age(now_ms.saturating_sub(updated)),
                if title.is_empty() { "(untitled)".to_owned() } else { title },
                field(chat, "cwd"),
            ]
        })
        .collect();
    let width = |i: usize| rows.iter().map(|row| row[i].chars().count()).max().unwrap_or(0);
    let (w0, w1, w2) = (width(0), width(1), width(2));
    for [key, harness, age, title, cwd] in rows {
        let line = format!("{key:<w0$}  {harness:<w1$}  {age:>w2$}  {title}  {cwd}");
        out.push_str(line.trim_end());
        out.push('\n');
    }
    if let Some(next) = page.get("nextCursor").and_then(Value::as_str) {
        out.push_str(&format!("(more: {next} shown; raise --limit)\n"));
    }
    out
}

/// Control characters (a title with a newline or an escape) become spaces,
/// so a title never moves the cursor or breaks the table.
fn one_line(text: &str) -> String {
    text.chars().map(|c| if c.is_control() { ' ' } else { c }).collect()
}

fn age(ms: i64) -> String {
    let s = ms.max(0) / 1000;
    match s {
        0..60 => format!("{s}s"),
        60..3600 => format!("{}m", s / 60),
        3600..86_400 => format!("{}h", s / 3600),
        _ => format!("{}d", s / 86_400),
    }
}

/// The `roots` text: each root with its harness and source, then the refused ones.
pub fn roots_text(view: &Value) -> String {
    let mut out = String::new();
    let list = |key: &str| view.get(key).and_then(Value::as_array).cloned().unwrap_or_default();
    let field = |v: &Value, key: &str| v.get(key).and_then(Value::as_str).unwrap_or("").to_owned();
    if view.pointer("/settings/enabled").and_then(Value::as_bool) == Some(false) {
        out.push_str("chats are turned off (agents.chats.enabled)\n");
    }
    for root in list("roots") {
        let accounts: Vec<String> = root
            .get("accounts")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect())
            .unwrap_or_default();
        let accounts = if accounts.is_empty() {
            String::new()
        } else {
            format!("  ({})", accounts.join(", "))
        };
        out.push_str(&format!(
            "{}  {}  [{}]{accounts}\n",
            field(&root, "harness"),
            field(&root, "path"),
            field(&root, "source")
        ));
    }
    let refused: Vec<Value> = list("refused").into_iter().chain(list("settingsRefused")).collect();
    if !refused.is_empty() {
        out.push_str("refused:\n");
        for root in refused {
            out.push_str(&format!("  {}: {}\n", field(&root, "path"), field(&root, "reason")));
        }
    }
    for error in list("watchErrors") {
        out.push_str(&format!("watch error: {}\n", error.as_str().unwrap_or("")));
    }
    out
}

fn outcome_value(outcome: &OpenOutcome) -> Value {
    match outcome {
        OpenOutcome::Session { session_id } => json!({"kind": "session", "sessionId": session_id}),
        OpenOutcome::Terminal { argv, env, cwd } => {
            json!({"kind": "terminal", "argv": argv, "env": env, "cwd": cwd})
        }
        OpenOutcome::ReadOnly { path } => json!({"kind": "readOnly", "path": path}),
    }
}

fn outcome_text(outcome: &OpenOutcome) -> String {
    match outcome {
        OpenOutcome::Session { session_id } => format!("session {session_id}\n"),
        OpenOutcome::Terminal { argv, env, cwd } => {
            let mut out = format!("folder: {}\n", cwd.display());
            for (key, value) in env {
                out.push_str(&format!("env: {key}={value}\n"));
            }
            out.push_str(&format!("run: {}\n", argv.join(" ")));
            out.push_str("(`cmux chats open` opens it in a new tab)\n");
            out
        }
        OpenOutcome::ReadOnly { path } => {
            format!("read-only transcript: {}\n(no harness can resume this chat)\n", path.display())
        }
    }
}

#[cfg(test)]
#[path = "chats_tests.rs"]
mod tests;
