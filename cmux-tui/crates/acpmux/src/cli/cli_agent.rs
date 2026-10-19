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
}

/// The text one prompt sends to the program.
pub fn prompt_text(blocks: &[Value], last_block: bool) -> String {
    let texts: Vec<&str> = blocks
        .iter()
        .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|b| b.get("text").and_then(Value::as_str))
        .collect();
    if last_block {
        return texts.last().map(|t| (*t).to_owned()).unwrap_or_default();
    }
    texts.join("")
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

/// The reply part of a program's output, line by line. Without `after_echo`
/// every line is reply. With it, lines are held back until a box frame
/// (`╭ … ╰`) whose text starts like the prompt has closed; the lines after it
/// are the reply, without the indent they share. When the output ends and
/// no such frame came, everything held back is the reply, so nothing is lost.
#[derive(Debug)]
pub struct ReplyFilter {
    after_echo: bool,
    needle: String,
    held: Vec<String>,
    in_frame: bool,
    frame_text: String,
    replying: bool,
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
        ReplyFilter {
            after_echo,
            needle: echo_needle(prompt),
            held: Vec::new(),
            in_frame: false,
            frame_text: String::new(),
            replying: !after_echo,
        }
    }

    /// One output line (without its newline): the reply text it releases,
    /// each piece ending in a newline.
    pub fn push(&mut self, line: &str) -> Option<String> {
        let line = strip_ansi(line);
        if self.replying {
            let line = if self.after_echo { dedent(&line) } else { &line };
            return Some(format!("{line}\n"));
        }
        self.held.push(line.clone());
        let t = line.trim_start();
        if t.starts_with('╭') {
            self.in_frame = true;
            self.frame_text.clear();
        } else if self.in_frame && t.starts_with('╰') {
            self.in_frame = false;
            let text = self.frame_text.split_whitespace().collect::<Vec<_>>().join(" ");
            if !self.needle.is_empty() && text.starts_with(&self.needle) {
                self.replying = true;
                self.held.clear();
            }
        } else if self.in_frame {
            self.frame_text.push(' ');
            self.frame_text.push_str(frame_inner(&line));
        }
        None
    }

    /// The output ended: whatever is still held back, when no echo came.
    pub fn finish(&mut self) -> Option<String> {
        if !self.after_echo || self.held.is_empty() {
            return None;
        }
        let text: String = self.held.drain(..).map(|l| format!("{l}\n")).collect();
        Some(text)
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
    anyhow::ensure!(!options.command.is_empty(), "cli-agent needs a program: cli-agent -- PROGRAM [ARGS]");
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
    let _ = tx.send(json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}));
}

async fn handle(msg: Value, options: &Arc<Options>, state: &Arc<Mutex<State>>, tx: &Out) {
    let method = msg.get("method").and_then(Value::as_str).unwrap_or("").to_owned();
    let params = msg.get("params").cloned().unwrap_or(Value::Null);
    let id = msg.get("id").cloned();
    let session_of = |p: &Value| p.get("sessionId").and_then(Value::as_str).unwrap_or("").to_owned();
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
            let blocks = params.get("prompt").and_then(Value::as_array).cloned().unwrap_or_default();
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
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    if options.prompt_arg {
        cmd.arg(&prompt).stdin(Stdio::null());
    } else {
        cmd.stdin(Stdio::piped());
    }
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("starting {}: {e}", options.command[0]))?;
    if let Some(mut stdin) = child.stdin.take() {
        let text = prompt.clone();
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
        let text = strip_ansi(&String::from_utf8_lossy(&buf));
        let tail: String = text.chars().rev().take(600).collect::<Vec<_>>().into_iter().rev().collect();
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
    let mut filter = ReplyFilter::new(&prompt, options.after_echo);
    let mut lines = BufReader::new(child.stdout.take().expect("piped stdout")).lines();
    loop {
        tokio::select! {
            _ = &mut cancel => {
                let _ = child.kill().await;
                return Ok("cancelled");
            }
            line = lines.next_line() => match line {
                Ok(Some(line)) => {
                    if let Some(text) = filter.push(&line) {
                        chunk(text);
                    }
                }
                Ok(None) | Err(_) => break,
            }
        }
    }
    if let Some(text) = filter.finish() {
        chunk(text);
    }
    let status = tokio::select! {
        _ = &mut cancel => {
            let _ = child.kill().await;
            return Ok("cancelled");
        }
        status = child.wait() => status.map_err(|e| format!("waiting for {}: {e}", options.command[0]))?,
    };
    if !status.success() {
        let tail = stderr_tail.await.unwrap_or_default();
        return Err(format!("{} exited with {status}: {tail}", options.command[0]));
    }
    Ok("end_turn")
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

    #[test]
    fn strips_escapes() {
        assert_eq!(strip_ansi("\u{1b}[1mPONG\u{1b}[0m\r"), "PONG");
        assert_eq!(strip_ansi("a\u{1b}]8;;http://x\u{7}b"), "ab");
    }

    #[test]
    fn after_echo_keeps_only_the_reply() {
        let out = [
            "  ╭─ result ───╮",
            "  │ 1 5536+0|user: earlier │",
            "  ╰──────────────╯",
            "  An earlier answer.",
            "  ╭──────────────────────╮",
            "  │ Reply with exactly:  │",
            "  │ PONG                 │",
            "  ╰──────────────────────╯",
            "",
            "  PONG",
        ];
        let mut f = ReplyFilter::new("Reply with exactly: PONG", true);
        let got: String = out.iter().filter_map(|l| f.push(l)).collect();
        assert_eq!(got, "\nPONG\n");
        assert_eq!(f.finish(), None);
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
