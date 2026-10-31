//! `acpmux cli-agent -- PROGRAM [ARGS]` (also `cmux acp cli-agent`): an ACP
//! agent on stdin and stdout that answers each prompt by running a plain
//! command line program once. It makes any CLI that reads a prompt and
//! prints a reply (`unii`, `llm`, `ollama run`, a shell script) an acpmux
//! harness, so everything that drives harnesses (chats, the Chief, `acpmux
//! run`) can use it unchanged. A harness profile points at it:
//!
//! ```toml
//! protocol = "acp"
//! command = "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux"
//! args = ["cli-agent", "--last-block", "--after-echo", "--", "/Users/me/.local/bin/unii"]
//! ```
//!
//! Each `session/prompt` runs the program in the session's folder with the
//! prompt text on stdin (or as its last argument with `--prompt-arg`) and
//! streams its stdout as `agent_message_chunk` updates. `session/cancel`
//! kills it. The program has no tools, permissions or MCP servers of its
//! own as far as ACP is concerned: whatever it does, it does itself.
//!
//! Sessions: `session/load` and `session/resume` accept any id. A program
//! that keeps its own memory (unii keeps one chat per sign-in) resumes by
//! itself; one that does not starts each prompt fresh, so `--last-block` is
//! only right for the first kind.

use anyhow::Result;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::process::Stdio;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{Mutex, mpsc, oneshot};

/// How `cli-agent` turns a prompt into a program run and its output into a
/// reply (the command line flags).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Options {
    /// The program and its arguments.
    pub command: Vec<String>,
    /// Send only the prompt's last text block: the new messages of a Chief
    /// turn (the earlier blocks are the view), for a program with its own
    /// memory.
    pub last_block: bool,
    /// Pass the prompt as the last argument instead of on stdin.
    pub prompt_arg: bool,
    /// Drop the output up to the frame that echoes the prompt (a chat CLI
    /// that prints its recent history and the prompt before the reply, as
    /// unii does when its input is a pipe).
    pub after_echo: bool,
    /// Put the session folder's `AGENTS.md` (the instructions acpmux and the
    /// Chief write for a non-Claude harness) before the prompt.
    pub instructions: bool,
    /// Run the program with a terminal as its stdout and controlling
    /// terminal (stdin stays the prompt pipe), for a program that prints
    /// only to a terminal.
    pub tty: bool,
}

/// The text one prompt sends to the program: its text blocks, or with
/// `last_block` only the last one the person typed. A paste cmux's composer
/// sent as its own block (`_meta.cmux.pasted`) always goes with it, after a
/// blank line, so the typed question never reaches the agent without it nor
/// the paste without the question.
pub fn prompt_text(blocks: &[Value], last_block: bool) -> String {
    let texts = blocks
        .iter()
        .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|b| Some((b.get("text").and_then(Value::as_str)?, is_pasted(b))));
    let (pasted, typed): (Vec<_>, Vec<_>) = texts.partition(|(_, pasted)| *pasted);
    let mut text = if last_block {
        typed.last().map(|(t, _)| (*t).to_owned()).unwrap_or_default()
    } else {
        typed.iter().map(|(t, _)| *t).collect()
    };
    for (paste, _) in pasted {
        if !text.is_empty() {
            text.push_str("\n\n");
        }
        text.push_str(paste);
    }
    text
}

/// Whether a text block is a paste cmux's composer sent apart from the typed
/// text (`_meta.cmux.pasted`).
pub fn is_pasted(block: &Value) -> bool {
    block.pointer("/_meta/cmux/pasted").and_then(Value::as_bool) == Some(true)
}

/// `text` without terminal escape sequences (CSI and OSC) or carriage returns.
pub fn strip_ansi(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\u{1b}' => match chars.peek() {
                Some('[') => {
                    chars.next();
                    for c in chars.by_ref() {
                        if ('@'..='~').contains(&c) {
                            break;
                        }
                    }
                }
                Some(']') => {
                    chars.next();
                    while let Some(c) = chars.next() {
                        if c == '\u{7}' {
                            break;
                        }
                        if c == '\u{1b}' && chars.peek() == Some(&'\\') {
                            chars.next();
                            break;
                        }
                    }
                }
                _ => {
                    chars.next();
                }
            },
            '\r' => {}
            c => out.push(c),
        }
    }
    out
}

/// The reply part of a program's output. Without `after_echo` every line is
/// reply and streams at once. With it, the output is kept until it ends
/// (a chat CLI such as unii prints its recent history, then the prompt in a
/// box frame `╭ … ╰`, then the reply, all at the end); the reply is what
/// follows the LAST frame whose text starts like the prompt (the history can
/// hold the same prompt), without the indent its lines share. With no such
/// frame the whole output is the reply, so nothing is lost.
#[derive(Debug)]
pub struct ReplyFilter {
    after_echo: bool,
    needle: String,
    lines: Vec<String>,
}

/// The leading text of `prompt` an echo frame is matched by: its first
/// non-empty line, whitespace collapsed, at most 24 characters (a frame
/// wraps long lines).
fn echo_needle(prompt: &str) -> String {
    let first = prompt.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or("");
    first.split_whitespace().collect::<Vec<_>>().join(" ").chars().take(24).collect()
}

/// The text inside one frame line `│ text │`.
fn frame_inner(line: &str) -> &str {
    line.trim().trim_start_matches('│').trim_end_matches('│').trim()
}

impl ReplyFilter {
    pub fn new(prompt: &str, after_echo: bool) -> ReplyFilter {
        ReplyFilter { after_echo, needle: echo_needle(prompt), lines: Vec::new() }
    }

    /// One output line (without its newline): the reply text it releases
    /// now, ending in a newline (only without `after_echo`).
    pub fn push(&mut self, line: &str) -> Option<String> {
        let line = strip_ansi(line);
        if !self.after_echo {
            return Some(format!("{line}\n"));
        }
        self.lines.push(line);
        None
    }

    /// The output ended: the reply still kept back.
    pub fn finish(&mut self) -> Option<String> {
        if !self.after_echo || self.lines.is_empty() {
            return None;
        }
        let lines = std::mem::take(&mut self.lines);
        let mut start = 0;
        let mut frame: Option<String> = None;
        for (i, line) in lines.iter().enumerate() {
            let t = line.trim_start();
            if t.starts_with('╭') {
                frame = Some(String::new());
            } else if t.starts_with('╰') {
                if let Some(text) = frame.take() {
                    let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
                    if !self.needle.is_empty() && text.starts_with(&self.needle) {
                        start = i + 1;
                    }
                }
            } else if let Some(text) = frame.as_mut() {
                text.push(' ');
                text.push_str(frame_inner(line));
            }
        }
        let echoed = start > 0;
        let text: String = lines[start..]
            .iter()
            .map(|l| format!("{}\n", if echoed { dedent(l) } else { l }))
            .collect();
        let text = if echoed { text.trim_start_matches('\n').to_owned() } else { text };
        (!text.is_empty()).then_some(text)
    }
}

/// A reply line without the two-space indent unii prints it with.
fn dedent(line: &str) -> &str {
    line.strip_prefix("  ").unwrap_or(line)
}

type Out = mpsc::UnboundedSender<Value>;

#[derive(Default)]
struct State {
    /// Session id -> its folder.
    sessions: HashMap<String, String>,
    /// Session id -> the running prompt's cancel signal.
    running: HashMap<String, oneshot::Sender<()>>,
    next: u64,
}

/// Serves ACP on stdin and stdout until stdin closes.
pub async fn run(options: Options) -> Result<()> {
    anyhow::ensure!(
        !options.command.is_empty(),
        "cli-agent needs a program: cli-agent -- PROGRAM [ARGS]"
    );
    // A program that exits without reading its prompt closes the pipe the
    // prompt goes to: that write must fail, not end this agent.
    #[cfg(unix)]
    // SAFETY: setting a signal's disposition to ignore has no preconditions.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
    }
    let (tx, mut rx) = mpsc::unbounded_channel::<Value>();
    let writer = tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        while let Some(v) = rx.recv().await {
            let mut line = v.to_string();
            line.push('\n');
            if stdout.write_all(line.as_bytes()).await.is_err() || stdout.flush().await.is_err() {
                break;
            }
        }
    });
    let state = Arc::new(Mutex::new(State::default()));
    let options = Arc::new(options);
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    while let Some(line) = lines.next_line().await? {
        let Ok(msg) = serde_json::from_str::<Value>(&line) else { continue };
        handle(msg, &options, &state, &tx).await;
    }
    drop(tx);
    let _ = writer.await;
    Ok(())
}

fn reply(tx: &Out, id: &Value, result: Value) {
    let _ = tx.send(json!({"jsonrpc": "2.0", "id": id, "result": result}));
}

fn error(tx: &Out, id: &Value, code: i64, message: String) {
    let _ =
        tx.send(json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}));
}

async fn handle(msg: Value, options: &Arc<Options>, state: &Arc<Mutex<State>>, tx: &Out) {
    let method = msg.get("method").and_then(Value::as_str).unwrap_or("").to_owned();
    let params = msg.get("params").cloned().unwrap_or(Value::Null);
    let id = msg.get("id").cloned();
    let session_of =
        |p: &Value| p.get("sessionId").and_then(Value::as_str).unwrap_or("").to_owned();
    match (method.as_str(), id) {
        ("initialize", Some(id)) => reply(
            tx,
            &id,
            json!({
                "protocolVersion": 1,
                "agentCapabilities": {
                    "loadSession": true,
                    "promptCapabilities": {"image": false, "audio": false, "embeddedContext": false},
                    "mcpCapabilities": {"http": false, "sse": false}
                },
                "agentInfo": {"name": "acpmux-cli-agent", "version": env!("CARGO_PKG_VERSION")},
                "authMethods": []
            }),
        ),
        ("session/new", Some(id)) => {
            let mut s = state.lock().await;
            s.next += 1;
            let sid = format!("cli-{}-{}", std::process::id(), s.next);
            let cwd = params.get("cwd").and_then(Value::as_str).unwrap_or(".").to_owned();
            s.sessions.insert(sid.clone(), cwd);
            reply(tx, &id, json!({"sessionId": sid}));
        }
        ("session/load" | "session/resume", Some(id)) => {
            let sid = session_of(&params);
            let cwd = params.get("cwd").and_then(Value::as_str).unwrap_or(".").to_owned();
            state.lock().await.sessions.insert(sid, cwd);
            reply(tx, &id, json!({}));
        }
        ("session/prompt", Some(id)) => {
            let sid = session_of(&params);
            let blocks =
                params.get("prompt").and_then(Value::as_array).cloned().unwrap_or_default();
            let (cancel_tx, cancel_rx) = oneshot::channel();
            let cwd = {
                let mut s = state.lock().await;
                let Some(cwd) = s.sessions.get(&sid).cloned() else {
                    error(tx, &id, -32602, format!("no session {sid}"));
                    return;
                };
                s.running.insert(sid.clone(), cancel_tx);
                cwd
            };
            let (options, state, tx) = (options.clone(), state.clone(), tx.clone());
            tokio::spawn(async move {
                let outcome = run_prompt(&options, &sid, &cwd, &blocks, cancel_rx, &tx).await;
                state.lock().await.running.remove(&sid);
                match outcome {
                    Ok(stop) => reply(&tx, &id, json!({"stopReason": stop})),
                    Err(e) => error(&tx, &id, -32603, e),
                }
            });
        }
        ("session/cancel", _) => {
            if let Some(cancel) = state.lock().await.running.remove(&session_of(&params)) {
                let _ = cancel.send(());
            }
        }
        ("session/set_mode" | "session/set_model" | "session/set_config_option", Some(id)) => {
            reply(tx, &id, json!({}))
        }
        (_, Some(id)) => error(tx, &id, -32601, format!("cli-agent has no method {method}")),
        (_, None) => {}
    }
}

/// Runs the program once for one prompt, streaming its reply; the stop
/// reason, or why it failed.
async fn run_prompt(
    options: &Options,
    session: &str,
    cwd: &str,
    blocks: &[Value],
    mut cancel: oneshot::Receiver<()>,
    tx: &Out,
) -> Result<&'static str, String> {
    let mut prompt = prompt_text(blocks, options.last_block);
    if options.instructions
        && let Ok(text) = std::fs::read_to_string(std::path::Path::new(cwd).join("AGENTS.md"))
        && !text.trim().is_empty()
    {
        prompt = format!("{text}\n\n{prompt}");
    }
    let mut cmd = tokio::process::Command::new(&options.command[0]);
    cmd.args(&options.command[1..])
        .current_dir(cwd)
        .env("NO_COLOR", "1")
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    if options.prompt_arg {
        cmd.arg(&prompt).stdin(Stdio::null());
    } else {
        cmd.stdin(Stdio::piped());
    }
    let master = if options.tty {
        Some(attach_tty(&mut cmd).map_err(|e| format!("opening a terminal: {e}"))?)
    } else {
        cmd.stdout(Stdio::piped());
        None
    };
    let mut child = cmd.spawn().map_err(|e| format!("starting {}: {e}", options.command[0]))?;
    // The terminal's other end now lives only in the child: its exit ends the reads.
    drop(cmd);
    if let Some(mut stdin) = child.stdin.take() {
        // A line-reading program (unii) ignores input without a final newline.
        let mut text = prompt.clone();
        if !text.ends_with('\n') {
            text.push('\n');
        }
        tokio::spawn(async move {
            let _ = stdin.write_all(text.as_bytes()).await;
            let _ = stdin.shutdown().await;
        });
    }
    let mut stderr = child.stderr.take();
    let stderr_tail = tokio::spawn(async move {
        let mut buf = Vec::new();
        if let Some(e) = stderr.as_mut() {
            let _ = e.read_to_end(&mut buf).await;
        }
        let text = crate::stderr::clean_stderr_lines(&String::from_utf8_lossy(&buf))
            .into_iter()
            .filter(|line| !line.is_empty())
            .collect::<Vec<_>>()
            .join("\n");
        let tail: String =
            text.chars().rev().take(600).collect::<Vec<_>>().into_iter().rev().collect();
        tail.trim().to_owned()
    });
    let chunk = |text: String| {
        let _ = tx.send(json!({
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {"sessionId": session, "update": {
                "sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": text}
            }}
        }));
    };
    let mut lines = match master {
        Some(master) => read_lines(master),
        None => {
            let stdout = child.stdout.take().expect("piped stdout");
            let (line_tx, line_rx) = mpsc::unbounded_channel();
            tokio::spawn(async move {
                let mut lines = BufReader::new(stdout).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    if line_tx.send(line).is_err() {
                        break;
                    }
                }
            });
            line_rx
        }
    };
    // The child lives in its own task, so its exit and a cancel can both be
    // waited for while the output is read.
    let (kill_tx, kill_rx) = oneshot::channel::<()>();
    let (exit_tx, mut exit_rx) = oneshot::channel();
    tokio::spawn(async move {
        tokio::select! {
            _ = kill_rx => {
                let _ = child.kill().await;
            }
            status = child.wait() => {
                let _ = exit_tx.send(status);
            }
        }
    });
    let mut filter = ReplyFilter::new(&prompt, options.after_echo);
    let mut status = None;
    loop {
        tokio::select! {
            _ = &mut cancel => {
                let _ = kill_tx.send(());
                return Ok("cancelled");
            }
            line = lines.recv() => match line {
                Some(line) => {
                    if let Some(text) = filter.push(&line) {
                        chunk(text);
                    }
                }
                None => break,
            },
            // A program that exits while something it started keeps the
            // terminal open: read what is already written, then stop.
            exited = &mut exit_rx, if status.is_none() && options.tty => {
                status = Some(exited);
                while let Ok(Some(line)) =
                    tokio::time::timeout(TTY_DRAIN, lines.recv()).await
                {
                    if let Some(text) = filter.push(&line) {
                        chunk(text);
                    }
                }
                break;
            }
        }
    }
    if let Some(text) = filter.finish() {
        chunk(text);
    }
    let status = match status {
        Some(status) => status,
        None => tokio::select! {
            _ = &mut cancel => {
                let _ = kill_tx.send(());
                return Ok("cancelled");
            }
            status = exit_rx => status,
        },
    }
    .map_err(|_| format!("{} was stopped", options.command[0]))?
    .map_err(|e| format!("waiting for {}: {e}", options.command[0]))?;
    if !status.success() {
        let tail = stderr_tail.await.unwrap_or_default();
        return Err(format!("{} exited with {status}: {tail}", options.command[0]));
    }
    Ok("end_turn")
}

/// How long the output of an exited `--tty` program is still read: what it
/// wrote before it exited is already in the terminal's buffer.
const TTY_DRAIN: std::time::Duration = std::time::Duration::from_secs(2);

/// Gives `cmd` a new pseudo-terminal (160 by 50) as its stdout and
/// controlling terminal; the terminal's controller, to read its output.
///
/// This terminal is a protocol adapter, not one a person uses: nothing draws
/// it and nobody selects in it, and its output is parsed into ACP
/// `agent_message_chunk` updates (hence `NO_COLOR=1` above). So it sets no
/// terminal identity and is not one of the terminal child paths that apply
/// `cmux_pty::UNSET_IN_TERMINAL_CHILDREN` (cmux#22585): a Ghostty version
/// here cannot cost anyone a mouse selection, and changing what the program
/// sees would change the text this parses.
#[cfg(unix)]
fn attach_tty(cmd: &mut tokio::process::Command) -> std::io::Result<std::fs::File> {
    use std::os::fd::{FromRawFd, OwnedFd};
    let (mut master, mut slave) = (-1, -1);
    let mut size = libc::winsize { ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0 };
    // SAFETY: openpty writes two descriptors it opened; they are owned below.
    let rc = unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            // A raw pointer: macOS takes `*mut winsize`, Linux `*const`.
            std::ptr::addr_of_mut!(size),
        )
    };
    if rc != 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: both descriptors are open and nothing else owns them.
    let (master, slave) = unsafe { (OwnedFd::from_raw_fd(master), OwnedFd::from_raw_fd(slave)) };
    cmd.stdout(Stdio::from(slave));
    // SAFETY: setsid and ioctl are async-signal-safe. The child makes its
    // stdout (the terminal) its controlling terminal, so a program that
    // opens /dev/tty writes to it.
    unsafe {
        cmd.pre_exec(|| {
            if libc::setsid() < 0 || libc::ioctl(1, libc::TIOCSCTTY as _, 0) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    Ok(std::fs::File::from(master))
}

#[cfg(not(unix))]
fn attach_tty(_cmd: &mut tokio::process::Command) -> std::io::Result<std::fs::File> {
    Err(std::io::Error::other("--tty needs a Unix terminal"))
}

/// The lines of a terminal's output, read on a thread (a terminal read
/// blocks; it fails with EIO once the program and its children closed it).
fn read_lines(file: std::fs::File) -> mpsc::UnboundedReceiver<String> {
    use std::io::BufRead;
    let (tx, rx) = mpsc::unbounded_channel();
    std::thread::spawn(move || {
        let mut reader = std::io::BufReader::new(file);
        let mut buf = Vec::new();
        loop {
            buf.clear();
            match reader.read_until(b'\n', &mut buf) {
                Ok(0) | Err(_) => break,
                Ok(_) => {
                    let line = String::from_utf8_lossy(&buf);
                    let line = line.trim_end_matches(['\n', '\r']).to_owned();
                    if tx.send(line).is_err() {
                        break;
                    }
                }
            }
        }
    });
    rx
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn last_block_sends_only_the_new_messages() {
        let blocks = vec![
            json!({"type": "text", "text": "view line 1\n"}),
            json!({"type": "image", "data": "x"}),
            json!({"type": "text", "text": "hello unii"}),
        ];
        assert_eq!(prompt_text(&blocks, true), "hello unii");
        assert_eq!(prompt_text(&blocks, false), "view line 1\nhello unii");
        assert_eq!(prompt_text(&[], true), "");
    }

    /// A huge paste in cmux's composer goes as its own text block after the
    /// typed one (`_meta.cmux.pasted`): the turn is the typed text and every
    /// paste, a blank line between them, in both modes.
    #[test]
    fn a_pasted_block_goes_with_the_typed_text() {
        let pasted =
            |text: &str| json!({"type": "text", "text": text, "_meta": {"cmux": {"pasted": true}}});
        let blocks = vec![
            json!({"type": "text", "text": "view line 1\n"}),
            json!({"type": "text", "text": "why does this fail?"}),
            pasted("line 1\n\nline 3"),
            pasted("second paste"),
        ];
        assert_eq!(
            prompt_text(&blocks, true),
            "why does this fail?\n\nline 1\n\nline 3\n\nsecond paste"
        );
        assert_eq!(
            prompt_text(&blocks, false),
            "view line 1\nwhy does this fail?\n\nline 1\n\nline 3\n\nsecond paste"
        );
        assert_eq!(prompt_text(&[pasted("only a paste")], true), "only a paste");
    }

    #[test]
    fn strips_escapes() {
        assert_eq!(strip_ansi("\u{1b}[1mPONG\u{1b}[0m\r"), "PONG");
        assert_eq!(strip_ansi("a\u{1b}]8;;http://x\u{7}b"), "ab");
    }

    #[test]
    fn after_echo_keeps_only_the_reply_after_the_last_echo() {
        let out = [
            "  ╭─ result ───╮",
            "  │ 1 5536+0|user: earlier │",
            "  ╰──────────────╯",
            "  ╭──────────────────────╮",
            "  │ Reply with exactly:  │",
            "  │ PONG                 │",
            "  ╰──────────────────────╯",
            "  An earlier PONG.",
            "  ╭──────────────────────╮",
            "  │ Reply with exactly:  │",
            "  │ PONG                 │",
            "  ╰──────────────────────╯",
            "",
            "  PONG",
        ];
        let mut f = ReplyFilter::new("Reply with exactly: PONG", true);
        assert!(out.iter().all(|l| f.push(l).is_none()));
        assert_eq!(f.finish().as_deref(), Some("PONG\n"));
    }

    #[test]
    fn after_echo_without_an_echo_loses_nothing() {
        let mut f = ReplyFilter::new("hi", true);
        assert_eq!(f.push("just text"), None);
        assert_eq!(f.finish().as_deref(), Some("just text\n"));
    }

    #[test]
    fn plain_mode_streams_every_line() {
        let mut f = ReplyFilter::new("hi", false);
        assert_eq!(f.push("  hello").as_deref(), Some("  hello\n"));
        assert_eq!(f.finish(), None);
    }
}
