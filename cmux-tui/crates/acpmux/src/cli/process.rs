//! `acpmux process list|show|kill|background`: the background processes an agent left
//! running (a dev server, a watcher, a long test run), from the command line
//! (`docs/background-processes.md`, `plans/cmux-next/background-task-terminal-DESIGN.md`).
//!
//! - `list`: `_acpmux/process/list`, one line per process.
//! - `show`: the process as a terminal shows it: a header (command, folder,
//!   start, output file), then every byte it printed from the first one, raw,
//!   so its colors reach the terminal, then how it ended. `--follow` keeps
//!   reading while it runs. On a terminal, `k` stops it (after a y/N) and `q`
//!   closes the view; nothing typed reaches the process. cmux opens this in a
//!   tab beside a chat when a background task row is clicked.
//! - `kill`: `_acpmux/process/kill`.
//! - `background`: `_acpmux/process/background`, Ctrl-B from the command
//!   line: a Claude Code chat's running work goes to the background.
//!
//! Output is read with `_acpmux/process/tail` in pages from byte 0;
//! `process/watch` is not built yet, so `--follow` asks for new bytes every
//! 200 ms, backing off to 1 s while nothing new comes.

use std::io::Write;
use std::time::Duration;

use anyhow::{Result, anyhow};
use clap::Subcommand;
use serde_json::{Value, json};
use tokio::sync::mpsc;

use crate::cli::output::print_json;
use crate::client::Client;
use crate::rpc::method;
use cmux_json::JsonSet as _;

#[derive(Subcommand, Debug, PartialEq, Eq)]
pub enum ProcessCmd {
    /// Background processes agents started, with their state.
    #[command(alias = "ls")]
    List {
        /// Only this chat's processes (a session name or id).
        #[arg(long)]
        session: Option<String>,
    },
    /// Everything a background process printed, with its command, folder,
    /// start and end. Also `tail`.
    #[command(alias = "tail")]
    Show {
        /// The process id from `process list` (`<session>/<task>`).
        process: Option<String>,
        /// With --tool-call: the chat (or subagent) whose tool call started it.
        #[arg(long)]
        session: Option<String>,
        /// The id of the tool call that started it.
        #[arg(long = "tool-call")]
        tool_call: Option<String>,
        /// Keep printing new output until the process ends.
        #[arg(long, short)]
        follow: bool,
    },
    /// Stop a background process.
    #[command(alias = "stop")]
    Kill {
        /// The process id from `process list`.
        process: String,
    },
    /// Move a Claude Code chat's running work to the background (Ctrl-B).
    #[command(alias = "bg")]
    Background {
        /// The chat (a session name or id).
        session: String,
        /// Only the task this tool call started (default: every foreground task).
        #[arg(long = "tool-call")]
        tool_call: Option<String>,
    },
}

/// The most one `process/tail` reads (the daemon's own ceiling).
const PAGE: u64 = 1 << 20;
/// The first wait between two reads while following, and the longest.
const PAUSE_MIN: Duration = Duration::from_millis(200);
const PAUSE_MAX: Duration = Duration::from_secs(1);

pub async fn run(cmd: ProcessCmd, json_out: bool) -> Result<()> {
    // Never starts a daemon: a process lives in the daemon that started it.
    let client = crate::daemon::connect(false).await?;
    match cmd {
        ProcessCmd::List { session } => {
            // A chat's list is read whole, page by page. Every chat's at once cannot page: the
            // daemon sends the newest that fit one reply, and how many older it left out.
            let (v, omitted) = match session.as_deref() {
                Some(s) => (list(&client, Some(s)).await?, 0),
                None => {
                    let reply = client.request(method::MUX_PROCESS_LIST, json!({})).await?;
                    let omitted = reply.get("omitted").and_then(Value::as_u64).unwrap_or(0);
                    (rows(&reply), omitted)
                }
            };
            if json_out {
                let mut out = json!({"processes": v});
                if omitted > 0 {
                    out.set("omitted", json!(omitted));
                }
                print_json(&out);
                return Ok(());
            }
            if omitted > 0 {
                eprintln!("{omitted} older processes not shown");
            }
            let now = now_ms();
            for p in &v {
                println!(
                    "{}  {}  {}",
                    text(p, "id"),
                    state_word(p, now),
                    one_line(text(p, "command"))
                );
            }
            Ok(())
        }
        ProcessCmd::Kill { process } => {
            client.request(method::MUX_PROCESS_KILL, json!({"processId": process})).await?;
            if json_out {
                print_json(&json!({"ok": true}));
            }
            Ok(())
        }
        ProcessCmd::Background { session, tool_call } => {
            let mut params = json!({"sessionId": session});
            if let Some(tool) = tool_call {
                params.set("toolCallId", json!(tool));
            }
            let v = client.request(method::MUX_PROCESS_BACKGROUND, params).await?;
            if json_out {
                print_json(&v);
            } else if v.get("backgrounded").and_then(Value::as_bool) == Some(true) {
                println!("moved to the background");
            } else {
                println!("nothing was running in the foreground");
            }
            Ok(())
        }
        ProcessCmd::Show { process, session, tool_call, follow } => {
            if process.is_none() && tool_call.is_none() {
                return Err(anyhow!("name a process id, or --session and --tool-call"));
            }
            let source = DaemonSource { client, session: session.clone() };
            let all = source.list_all(process.as_deref()).await?;
            let found =
                find_process(&all, process.as_deref(), session.as_deref(), tool_call.as_deref())
                    .cloned()
                    .ok_or_else(|| {
                        anyhow!(
                            "no background process {}",
                            process.or(tool_call).unwrap_or_default()
                        )
                    })?;
            let id = text(&found, "id").to_owned();
            let style = Style::detect();
            let interactive = follow && style.terminal;
            let mut out = std::io::stdout();
            if interactive {
                // OSC 2: the tab is titled with what the process is for (`title`).
                let _ = write!(out, "\x1b]2;{}\x07", one_line(&title(&found)));
            }
            let _ = out.write_all(header(&found, style).as_bytes());
            let _ = out.flush();
            let keys = if interactive { Keys::start() } else { None };
            let (_raw, mut rx) = match keys {
                Some((guard, rx)) => (Some(guard), rx),
                None => (None, mpsc::channel(1).1),
            };
            let opts =
                ReplayOpts { follow, interactive, pause_min: PAUSE_MIN, pause_max: PAUSE_MAX };
            let outcome = replay(&source, &found, &mut out, opts, &mut rx).await?;
            let last = source.get(&id).await.ok().flatten().unwrap_or(found);
            let _ = out.write_all(footer(&last, now_ms(), style, outcome).as_bytes());
            if interactive && outcome == Outcome::Ended {
                let _ = out.write_all(style.dim("Press q to close.\r\n").as_bytes());
                let _ = out.flush();
                while let Some(key) = rx.recv().await {
                    if key == Input::Quit {
                        break;
                    }
                }
            }
            let _ = out.flush();
            Ok(())
        }
    }
}

/// A process list reply's rows.
fn rows(reply: &Value) -> Vec<Value> {
    reply.get("processes").and_then(Value::as_array).cloned().unwrap_or_default()
}

/// Rows a page of a chat's process list asks for: the daemon's most (`process_page_params`).
const LIST_PAGE: u64 = 1_000;

/// The processes of `session`, every one, read page by page with `limit` and the `nextCursor`
/// of the rest; with no session, the newest of every chat that fit one reply (that list does
/// not page). One unpaged reply of a chat holds only its newest processes, so an older one was
/// "no background process" to `process show`.
async fn list(client: &Client, session: Option<&str>) -> Result<Vec<Value>> {
    let Some(session) = session else {
        return Ok(rows(&client.request(method::MUX_PROCESS_LIST, json!({})).await?));
    };
    let mut params = json!({"sessionId": session, "limit": LIST_PAGE});
    let (mut all, mut read) = (Vec::new(), std::collections::HashSet::new());
    loop {
        let page = client.request(method::MUX_PROCESS_LIST, params.clone()).await?;
        all.extend(rows(&page));
        let Some(cursor) = page.get("nextCursor").and_then(Value::as_str) else {
            return Ok(all);
        };
        if !read.insert(cursor.to_owned()) {
            return Err(anyhow!("process list: the daemon gave cursor {cursor:?} twice"));
        }
        params.set("cursor", json!(cursor));
    }
}

/// The daemon as a [`Source`]: `session` (the chat) makes the daemon read
/// that chat's processes before listing them.
struct DaemonSource {
    client: std::sync::Arc<Client>,
    session: Option<String>,
}

impl DaemonSource {
    /// The chat's processes, those of the chat `process` (`<sessionId>/<taskId>`) names, then
    /// every process this daemon has read: a subagent's process is recorded under its parent
    /// chat. The chats' lists are read whole, page by page; the last holds only the newest.
    async fn list_all(&self, process: Option<&str>) -> Result<Vec<Value>> {
        let owner = process.and_then(|id| id.split_once('/')).map(|(sid, _)| sid);
        let mut all = Vec::new();
        for chat in [self.session.as_deref(), owner.filter(|o| Some(*o) != self.session.as_deref())]
            .into_iter()
            .flatten()
        {
            for p in list(&self.client, Some(chat)).await.unwrap_or_default() {
                if !all.iter().any(|q: &Value| q.get("id") == p.get("id")) {
                    all.push(p);
                }
            }
        }
        for p in list(&self.client, None).await? {
            if !all.iter().any(|q| q.get("id") == p.get("id")) {
                all.push(p);
            }
        }
        Ok(all)
    }
}

impl Source for DaemonSource {
    async fn tail(&self, id: &str, from: u64) -> Result<Chunk, TailError> {
        use base64::Engine;
        let v = self
            .client
            .request(
                method::MUX_PROCESS_TAIL,
                json!({"processId": id, "fromByte": from, "maxBytes": PAGE}),
            )
            .await
            .map_err(|e| {
                let m = e.to_string();
                if m.contains("only for now") {
                    TailError::Unsupported
                } else {
                    TailError::Other(e)
                }
            })?;
        let data = v
            .get("data")
            .and_then(Value::as_str)
            .map(|d| base64::engine::general_purpose::STANDARD.decode(d))
            .transpose()
            .map_err(|e| TailError::Other(anyhow!("bad output from the daemon: {e}")))?
            .unwrap_or_default();
        Ok(Chunk {
            next: v.get("nextByte").and_then(Value::as_u64).unwrap_or(from + data.len() as u64),
            eof: v.get("eof").and_then(Value::as_bool).unwrap_or(false),
            data,
        })
    }

    async fn get(&self, id: &str) -> Result<Option<Value>> {
        Ok(self.list_all(Some(id)).await?.into_iter().find(|p| text(p, "id") == id))
    }

    async fn kill(&self, id: &str) -> Result<()> {
        self.client.request(method::MUX_PROCESS_KILL, json!({"processId": id})).await.map(|_| ())
    }
}

/// Where the process's output and record come from: the daemon, or a test's
/// stand-in.
pub(crate) trait Source {
    async fn tail(&self, id: &str, from: u64) -> Result<Chunk, TailError>;
    async fn get(&self, id: &str) -> Result<Option<Value>>;
    async fn kill(&self, id: &str) -> Result<()>;
}

/// One page of output.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Chunk {
    pub data: Vec<u8>,
    pub next: u64,
    /// The process ended and `next` is its output's end.
    pub eof: bool,
}

#[derive(Debug)]
pub(crate) enum TailError {
    /// The harness does not share its output (Codex, for now).
    Unsupported,
    Other(anyhow::Error),
}

/// A key the viewer acts on; anything else typed is dropped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Input {
    Quit,
    Kill,
    Yes,
    No,
}

impl Input {
    fn of(byte: u8) -> Option<Input> {
        match byte {
            b'q' | b'Q' | 0x03 | 0x04 => Some(Input::Quit),
            b'k' | b'K' => Some(Input::Kill),
            b'y' | b'Y' => Some(Input::Yes),
            b'n' | b'N' | b'\r' | b'\n' | 0x1b => Some(Input::No),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct ReplayOpts {
    pub follow: bool,
    /// Keys are read: the footer names them and a kill asks first.
    pub interactive: bool,
    pub pause_min: Duration,
    pub pause_max: Duration,
}

/// How the replay stopped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Outcome {
    /// The process ended and every byte it printed was written.
    Ended,
    /// The person closed the view; the process keeps running.
    Closed,
    /// Without --follow: what it had printed so far.
    Snapshot,
}

/// Writes every byte process `p` printed to `out`, from the first, page by
/// page; with `follow`, keeps reading until it ends or a `Quit` arrives.
pub(crate) async fn replay<S: Source>(
    src: &S,
    p: &Value,
    out: &mut impl Write,
    opts: ReplayOpts,
    keys: &mut mpsc::Receiver<Input>,
) -> Result<Outcome> {
    let id = text(p, "id").to_owned();
    let mut from = 0u64;
    let mut pause = opts.pause_min;
    let mut asking = false;
    let mut told_unsupported = false;
    let mut keys_open = true;
    let style = Style { color: false, terminal: opts.interactive };
    if opts.interactive && text(p, "state") == "running" {
        write_now(out, style.dim("k stop · q close\r\n").as_bytes())?;
    }
    loop {
        match src.tail(&id, from).await {
            Ok(chunk) => {
                let got = chunk.data.len() as u64;
                write_now(out, &chunk.data)?;
                from = chunk.next.max(from + got);
                if chunk.eof {
                    return Ok(Outcome::Ended);
                }
                if got >= PAGE {
                    continue;
                }
                if got > 0 {
                    pause = opts.pause_min;
                    if !opts.follow {
                        continue;
                    }
                } else {
                    if !opts.follow {
                        return Ok(Outcome::Snapshot);
                    }
                    pause = (pause * 2).min(opts.pause_max);
                }
            }
            Err(TailError::Unsupported) => {
                if !told_unsupported {
                    told_unsupported = true;
                    write_now(
                        out,
                        b"This agent does not share a background process's output yet.\r\n",
                    )?;
                }
                let running = src.get(&id).await?.is_some_and(|q| text(&q, "state") == "running");
                if !running {
                    return Ok(Outcome::Ended);
                }
                if !opts.follow {
                    return Ok(Outcome::Snapshot);
                }
                pause = opts.pause_max;
            }
            Err(TailError::Other(e)) => return Err(e),
        }
        let sleep = tokio::time::sleep(pause);
        tokio::pin!(sleep);
        loop {
            tokio::select! {
                _ = &mut sleep => break,
                key = keys.recv(), if keys_open => match key {
                    None => keys_open = false,
                    Some(Input::Quit) => return Ok(Outcome::Closed),
                    Some(Input::Kill) if !asking => {
                        asking = true;
                        write_now(out, b"\r\nStop this process? [y/N] ")?;
                    }
                    Some(Input::Yes) if asking => {
                        asking = false;
                        write_now(out, b"y\r\nStopping\xe2\x80\xa6\r\n")?;
                        if let Err(e) = src.kill(&id).await {
                            write_now(out, format!("Could not stop it: {e}\r\n").as_bytes())?;
                        }
                        break;
                    }
                    Some(Input::No | Input::Kill) if asking => {
                        asking = false;
                        write_now(out, b"n\r\n")?;
                    }
                    Some(_) => {}
                },
            }
        }
    }
}

fn write_now(out: &mut impl Write, bytes: &[u8]) -> Result<()> {
    if bytes.is_empty() {
        return Ok(());
    }
    out.write_all(bytes)?;
    out.flush()?;
    Ok(())
}

/// The process whose id is `id`, else the latest one started by tool call
/// `tool_call` in chat (or subagent) `session`.
pub(crate) fn find_process<'a>(
    list: &'a [Value],
    id: Option<&str>,
    session: Option<&str>,
    tool_call: Option<&str>,
) -> Option<&'a Value> {
    if let Some(id) = id {
        return list.iter().find(|p| text(p, "id") == id);
    }
    let tool_call = tool_call?;
    let in_session = |p: &Value| match session {
        None => true,
        Some(s) => text(p, "sessionId") == s || text(p, "subagentSessionId") == s,
    };
    list.iter()
        .filter(|p| text(p, "toolCallId") == tool_call && in_session(p))
        .max_by_key(|p| p.get("startedAt").and_then(Value::as_u64).unwrap_or(0))
}

/// Bold and dim when the output is a terminal that takes colors.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Style {
    pub color: bool,
    /// Lines end with CR LF: the terminal's own newline handling may be off.
    pub terminal: bool,
}

impl Style {
    fn detect() -> Style {
        use std::io::IsTerminal;
        let terminal = std::io::stdout().is_terminal();
        Style { color: terminal && std::env::var_os("NO_COLOR").is_none(), terminal }
    }
    fn wrap(self, code: &str, s: &str) -> String {
        if self.color { format!("\x1b[{code}m{s}\x1b[0m") } else { s.to_owned() }
    }
    fn bold(self, s: &str) -> String {
        self.wrap("1", s)
    }
    fn dim(self, s: &str) -> String {
        self.wrap("2", s)
    }
}

/// The lines above the output: the command, the agent's name for it, what a
/// timer waits for, its folder, its start, the harness and how it went to the
/// background, and its output file.
pub(crate) fn header(p: &Value, style: Style) -> String {
    let mut s = String::new();
    let command = text(p, "command");
    s.push_str(&style.bold(&format!("$ {command}")));
    s.push('\n');
    let row = |s: &mut String, label: &str, value: &str| {
        if !value.is_empty() {
            s.push_str(&style.dim(&format!("  {label:<8} ")));
            s.push_str(value);
            s.push('\n');
        }
    };
    // The agent's own name for it (Claude's `description`, "hold"), when the
    // command is not just that name again.
    let description = text(p, "description").trim();
    if description != command.trim() {
        row(&mut s, "named", description);
    }
    // A timer an agent set to wake itself (`sleep 840; echo t`) prints
    // nothing until it ends: say so (Leo, 2026-11-05, on a view reading only
    // "$ hold": "what are you even holding for?"). No end time: `startedAt`
    // is when it reached the background, which may be after its launch.
    if let Some(secs) = timer_secs(command) {
        row(
            &mut s,
            "waits",
            &format!("{}, then wakes the agent; it runs nothing else", span(secs)),
        );
    }
    row(&mut s, "folder", &tilde(text(p, "cwd")));
    let started = p.get("startedAt").and_then(Value::as_u64).map(local_time).unwrap_or_default();
    let harness = match text(p, "harness") {
        "claude" => "Claude Code",
        "codex" => "Codex",
        other => other,
    };
    let origin = match text(p, "origin") {
        "auto_backgrounded" => "moved to the background",
        "user_backgrounded" => "sent to the background by you",
        "background" => "background",
        other => other,
    };
    let when: Vec<&str> =
        [started.as_str(), harness, origin].into_iter().filter(|x| !x.is_empty()).collect();
    row(&mut s, "started", &when.join(" · "));
    row(&mut s, "log", &tilde(text(p, "outputFile")));
    s.push_str(&style.dim(&"─".repeat(48)));
    s.push('\n');
    lines(s, style)
}

/// The lines under the output: how the process stands or ended, after how
/// long, and the harness's own words on its end.
pub(crate) fn footer(p: &Value, now: u64, style: Style, outcome: Outcome) -> String {
    let started = p.get("startedAt").and_then(Value::as_u64).unwrap_or(now);
    let ended = p.get("endedAt").and_then(Value::as_u64);
    let took = human(ended.unwrap_or(now).saturating_sub(started));
    let exit = p.get("exitCode").and_then(Value::as_i64);
    let signal = match text(p, "signal") {
        "" => String::new(),
        s => format!(" (signal {s})"),
    };
    let line = match text(p, "state") {
        "running" => match outcome {
            Outcome::Closed => format!("● Still running after {took}; closed the view"),
            _ => format!("● Running for {took}"),
        },
        "exited" if exit.unwrap_or(0) == 0 => format!("✓ Completed after {took}"),
        "exited" | "failed" => match exit {
            Some(code) => format!("✗ Failed (exit {code}) after {took}{signal}"),
            None => format!("✗ Failed after {took}{signal}"),
        },
        "killed" => {
            let by = match text(p, "reason") {
                "person" => "Stopped by you",
                "agent" => "Stopped by the agent",
                "harness_time_limit" => "Stopped at its time limit",
                "budget_memory" => "Stopped: over its memory budget",
                _ => "Stopped",
            };
            format!("■ {by} after {took}{signal}")
        }
        "lost" => "? Lost: its agent exited before it ended".to_owned(),
        other => format!("{other} after {took}"),
    };
    let mut s = String::new();
    s.push('\n');
    s.push_str(&style.dim(&"─".repeat(48)));
    s.push('\n');
    s.push_str(&style.bold(&line));
    s.push('\n');
    let detail = text(p, "detail");
    if !detail.is_empty() {
        s.push_str(&style.dim(&format!("  {}", one_line(detail))));
        s.push('\n');
    }
    lines(s, style)
}

/// The tab's title: a timer as "Waiting 14m · hold", else the agent's name
/// for the process, else its command.
pub(crate) fn title(p: &Value) -> String {
    let command = text(p, "command");
    let description = text(p, "description").trim();
    match timer_secs(command) {
        Some(secs) if description.is_empty() || description == command.trim() => {
            format!("Waiting {}", span(secs))
        }
        Some(secs) => format!("Waiting {} · {description}", span(secs)),
        None if !description.is_empty() => description.to_owned(),
        None => command.to_owned(),
    }
}

/// How long a command that only waits sleeps, in seconds: `sleep N` (with
/// an `s`, `m`, `h` or `d` unit), then at most `echo`, `printf`, `true` or
/// `:` steps joined by `;` or `&&`. None for a command that does anything else.
pub(crate) fn timer_secs(command: &str) -> Option<u64> {
    let mut steps = command.split([';', '\n']).flat_map(|s| s.split("&&")).map(str::trim);
    let mut sleep = steps.next()?.split_whitespace();
    if sleep.next()? != "sleep" {
        return None;
    }
    let arg = sleep.next()?;
    if sleep.next().is_some() {
        return None;
    }
    let (digits, unit) = arg.split_at(arg.find(|c: char| !c.is_ascii_digit()).unwrap_or(arg.len()));
    let n: u64 = digits.parse().ok()?;
    let secs = match unit {
        "" | "s" => n,
        "m" => n * 60,
        "h" => n * 3600,
        "d" => n * 86_400,
        _ => return None,
    };
    steps
        .filter(|step| !step.is_empty())
        .all(|step| {
            matches!(step.split_whitespace().next(), Some("echo" | "printf" | "true" | ":"))
                && !step.contains(['|', '&', '>', '<', '`', '$'])
        })
        .then_some(secs)
}

/// A timer's length as written: `14m`, `2h`, `90s`, else as `human` reads it.
fn span(secs: u64) -> String {
    match secs {
        0..60 => format!("{secs}s"),
        _ if secs.is_multiple_of(3600) => format!("{}h", secs / 3600),
        _ if secs.is_multiple_of(60) => format!("{}m", secs / 60),
        _ => human(secs * 1000),
    }
}

/// LF as CR LF for a terminal whose newline handling may be off.
fn lines(s: String, style: Style) -> String {
    if style.terminal { s.replace('\n', "\r\n") } else { s }
}

fn state_word(p: &Value, now: u64) -> String {
    let started = p.get("startedAt").and_then(Value::as_u64).unwrap_or(now);
    let ended = p.get("endedAt").and_then(Value::as_u64).unwrap_or(now);
    format!("{} {}", text(p, "state"), human(ended.saturating_sub(started)))
}

fn text<'a>(p: &'a Value, key: &str) -> &'a str {
    p.get(key).and_then(Value::as_str).unwrap_or("")
}

fn one_line(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// `path` with the home folder written `~`.
fn tilde(path: &str) -> String {
    if let Some(home) = dirs::home_dir().and_then(|h| h.to_str().map(str::to_owned))
        && !home.is_empty()
        && let Some(rest) = path.strip_prefix(&home)
        && (rest.is_empty() || rest.starts_with('/'))
    {
        return format!("~{rest}");
    }
    path.to_owned()
}

/// A duration as a person reads it: `4s`, `3m 12s`, `2h 05m`.
pub(crate) fn human(ms: u64) -> String {
    let s = ms / 1000;
    match s {
        0 => format!("{ms}ms"),
        1..60 => format!("{s}s"),
        60..3600 => format!("{}m {:02}s", s / 60, s % 60),
        _ => format!("{}h {:02}m", s / 3600, (s % 3600) / 60),
    }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Unix ms as this machine's local date and time, `Oct 20 14:03:11`.
fn local_time(ms: u64) -> String {
    let secs = (ms / 1000) as i64;
    let offset = local_offset(secs);
    let t = secs + offset;
    let days = t.div_euclid(86_400);
    let rem = t.rem_euclid(86_400);
    let (_, month, day) = civil(days);
    const MONTHS: [&str; 12] =
        ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    format!(
        "{} {} {:02}:{:02}:{:02}",
        MONTHS[(month - 1) as usize],
        day,
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

#[cfg(unix)]
fn local_offset(secs: i64) -> i64 {
    let t: libc::time_t = secs;
    // SAFETY: tm is plain C data; all zeroes is a valid value that localtime_r overwrites.
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    // SAFETY: localtime_r reads `t` and writes only into `tm`, both owned by this frame.
    if unsafe { libc::localtime_r(&t, &mut tm) }.is_null() {
        return 0;
    }
    tm.tm_gmtoff
}

#[cfg(not(unix))]
fn local_offset(_secs: i64) -> i64 {
    0
}

/// Days since 1970-01-01 as (year, month, day) (Howard Hinnant's algorithm).
fn civil(days: i64) -> (i64, i64, i64) {
    let (year, month, day) = crate::server::civil_from_days(days);
    (year, i64::from(month), i64::from(day))
}

/// The viewer's keys: the terminal stops echoing and stops waiting for
/// Return (and Ctrl-C arrives as a key), restored when the guard drops.
struct Keys {
    #[cfg(unix)]
    saved: libc::termios,
}

impl Keys {
    #[cfg(unix)]
    fn start() -> Option<(Keys, mpsc::Receiver<Input>)> {
        use std::io::{IsTerminal, Read};
        if !std::io::stdin().is_terminal() {
            return None;
        }
        // SAFETY: termios is plain C data; all zeroes is a valid value that tcgetattr overwrites.
        let mut saved: libc::termios = unsafe { std::mem::zeroed() };
        // SAFETY: tcgetattr writes only into `saved`, which this frame owns.
        if unsafe { libc::tcgetattr(0, &mut saved) } != 0 {
            return None;
        }
        let mut raw = saved;
        raw.c_lflag &= !(libc::ICANON | libc::ECHO | libc::ISIG);
        raw.c_cc[libc::VMIN] = 1;
        raw.c_cc[libc::VTIME] = 0;
        // SAFETY: tcsetattr reads `raw`, which this frame owns.
        if unsafe { libc::tcsetattr(0, libc::TCSANOW, &raw) } != 0 {
            return None;
        }
        let (tx, rx) = mpsc::channel(16);
        // A thread: a blocking read of stdin that ends with the process.
        std::thread::spawn(move || {
            let mut byte = [0u8; 1];
            let mut stdin = std::io::stdin();
            while let Ok(1) = stdin.read(&mut byte) {
                if let Some(key) = Input::of(byte[0])
                    && tx.blocking_send(key).is_err()
                {
                    break;
                }
            }
        });
        Some((Keys { saved }, rx))
    }

    #[cfg(not(unix))]
    fn start() -> Option<(Keys, mpsc::Receiver<Input>)> {
        None
    }
}

impl Drop for Keys {
    #[cfg(unix)]
    fn drop(&mut self) {
        // SAFETY: restores the attributes `start` read, from a termios this guard owns.
        unsafe {
            libc::tcsetattr(0, libc::TCSANOW, &self.saved);
        }
    }

    #[cfg(not(unix))]
    fn drop(&mut self) {}
}

#[cfg(test)]
#[path = "process_tests.rs"]
mod tests;
