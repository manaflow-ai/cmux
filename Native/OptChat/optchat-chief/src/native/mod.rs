//! The native engine: the Chief's turn loop on the Messages API, in the
//! host (section 9 allows "your own agent loop"). It is the engine that
//! keeps sections 7 and 8 whole, which a turn through acpmux and Claude Code
//! cannot:
//!
//! - Request layout and breakpoints (section 8): constant tools, then the
//!   constant system prompt, then the view cut at its marks with a
//!   breakpoint on each of the first three pieces, then the new messages;
//!   the top-level automatic `cache_control` is the fourth breakpoint, at the
//!   end of each request, so every step reads what the previous one wrote.
//! - A human message sent while the turn works interrupts it at once
//!   (decision 2026-10-04): a streaming step (thinking or text) is dropped
//!   at the next streamed event and the model is called again with the
//!   message; a running tool call finishes first and its result goes with
//!   the message. Delivered messages are logged as `user` (section 7).
//!   Children's reports are delivered between tool calls without one.
//! - Model outputs go back verbatim (thinking blocks and signatures).
//! - Every tool result is capped at CAP before it is logged and before it is
//!   sent back (section 7).
//!
//! Tools: Anthropic's `bash` and text editor (client-executed, approve-all
//! like the acpmux engine's policy), plus `zoom` and `date` answered from
//! the live memory. Subagents run through `chief agents` from bash.

mod api;
mod editor;
mod shell;
mod sse;

pub use api::{CallError, ChatModel, HttpModel};

use crate::prompt::CacheTtl;
pub use shell::Shell;
pub use sse::Assembler;
pub use sse::read_until;

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use optchat_core::Kind;
use optchat_host::{OptChat, cap_tool_result};
use serde_json::{Value, json};

use crate::fold::{Usage, stop_error};
use crate::prompt::{DATE_DESCRIPTION, ZOOM_DESCRIPTION};
use crate::tools::Call;
use crate::turn::{TurnOutcome, TurnStart, usage_line};

/// The result of a local tool call in a remote-origin turn on this engine.
const REMOTE_REFUSED: &str = "Refused: this turn started from a paired device, and running commands or editing files then needs the user's approval, which this engine cannot ask for. Say what you would run; the user can approve it from the Mac.";

/// Tries per model call (parity item 8). A transient failure waits the
/// server's `retry-after` when it gives one, else `Native::retry` doubled
/// each try (1, 2, 4 ... times), capped at `MAX_WAIT`.
const TRIES: u32 = 8;

/// The longest wait between two tries.
const MAX_WAIT: Duration = Duration::from_secs(120);

/// The native engine's base wait between tries: busy and rate-limited
/// calls clear in seconds, and the user waits on the turn.
pub const RETRY_BASE: Duration = Duration::from_secs(1);

/// How the native engine runs.
#[derive(Clone, Debug)]
pub struct NativeConfig {
    /// Model id (default `claude-opus-5-5`).
    pub model: String,
    /// `output_config.effort`.
    pub effort: Option<String>,
    pub max_tokens: u32,
    /// Send `fallbacks: "default"` (the beta header goes with it in `HttpModel`).
    pub server_fallback: bool,
    /// The system prompt (`prompt::claude_md`), constant for the host's life.
    pub system: String,
    /// Where the bash tool starts each turn.
    pub cwd: PathBuf,
    /// Env over the host's for the bash tool (MUX_HOME, PATH with `chief`, ...).
    pub env: BTreeMap<String, String>,
    /// Longest one bash command may run.
    pub bash_timeout: Duration,
    /// Where the bash tool records each command's final directory.
    pub pwd_file: PathBuf,
}

pub struct Native {
    config: NativeConfig,
    model: Arc<dyn ChatModel>,
    retry: Duration,
    trace: crate::trace::Trace,
    /// The TTL of every cache mark (5 minutes unless set).
    cache_ttl: CacheTtl,
}

impl Native {
    pub fn new(config: NativeConfig, model: Arc<dyn ChatModel>, retry: Duration) -> Native {
        Native {
            config,
            model,
            retry,
            trace: crate::trace::Trace::off(),
            cache_ttl: CacheTtl::FiveMinutes,
        }
    }

    /// Every cache mark of its requests with this TTL (`OPTCHAT_CACHE_TTL`
    /// or the Chief's `cache.ttl` at host start; default 5 minutes).
    pub fn with_cache_ttl(mut self, ttl: CacheTtl) -> Native {
        self.cache_ttl = ttl;
        self
    }

    /// Traces every model request and tool call of each turn.
    pub fn with_trace(mut self, trace: crate::trace::Trace) -> Native {
        self.trace = trace;
        self
    }

    /// The tool list: constant, the head of every cached prefix (section 7.2).
    pub fn tools() -> Value {
        let integer = json!({"type": "integer", "minimum": 0});
        json!([
            {"type": "bash_20250124", "name": "bash"},
            {"type": "text_editor_20250728", "name": "str_replace_based_edit_tool"},
            {
                "name": "zoom",
                "description": ZOOM_DESCRIPTION,
                "input_schema": {
                    "type": "object",
                    "properties": {"id": integer, "n": integer},
                    "required": ["id", "n"],
                    "additionalProperties": false
                }
            },
            {
                "name": "date",
                "description": DATE_DESCRIPTION,
                "input_schema": {
                    "type": "object",
                    "properties": {"id": integer},
                    "required": ["id"],
                    "additionalProperties": false
                }
            }
        ])
    }

    /// The turn's first user message: the view in blocks of 4 lines with one
    /// breakpoint on the last whole block (spec 3.3, gist 3c190e0), then the
    /// new messages, as `turn_blocks` cut them. The system prompt and the
    /// request's end carry the other two.
    pub fn first_message(blocks: &[Value]) -> Value {
        Native::first_message_with(blocks, CacheTtl::FiveMinutes)
    }

    /// `first_message` with marks of `ttl`.
    pub fn first_message_with(blocks: &[Value], ttl: CacheTtl) -> Value {
        // The view's last piece is the one that closes it.
        let last_view = blocks
            .iter()
            .position(|b| b["text"].as_str().is_some_and(|t| t.ends_with("</chat>")));
        let content: Vec<Value> = blocks
            .iter()
            .enumerate()
            .map(|(i, block)| {
                if block["type"] == "image" {
                    return api_block(block);
                }
                let mut block = block.clone();
                if last_view.is_some_and(|v| v > 0 && i + 1 == v) {
                    block["cache_control"] = ttl.cache_control();
                }
                block
            })
            .collect();
        json!({"role": "user", "content": content})
    }

    /// One step's request body.
    pub fn body(&self, messages: &[Value]) -> Value {
        let mut body = json!({
            "model": self.config.model,
            "max_tokens": self.config.max_tokens,
            "stream": true,
            // Marked: compactions send the same system prompt and tools, so
            // they read them from this entry (spec 4).
            "system": [{"type": "text", "text": self.config.system, "cache_control": self.cache_ttl.cache_control()}],
            "tools": Native::tools(),
            "messages": messages,
            // The end of each request: the next step reads it (section 8).
            "cache_control": self.cache_ttl.cache_control(),
        });
        if let Some(effort) = &self.config.effort {
            body["output_config"] = json!({"effort": effort});
        }
        if self.config.server_fallback {
            body["fallbacks"] = json!("default");
        }
        body
    }

    fn call(
        &self,
        body: &Value,
        key: &str,
        log: &dyn Fn(&str),
        stop: &dyn Fn() -> bool,
    ) -> Result<Value, CallError> {
        let mut tries = 0;
        loop {
            tries += 1;
            match self.model.send(body, stop) {
                Ok(message) => return Ok(message),
                Err(e) if e.retry && tries < TRIES && !stop() => {
                    let backoff = self.retry.saturating_mul(1 << (tries - 1));
                    let wait = e.retry_after.unwrap_or(backoff).min(MAX_WAIT);
                    log(&format!(
                        "turn {key}: model call failed ({}); try {} of {TRIES} in {:.1} s{}",
                        e.message,
                        tries + 1,
                        wait.as_secs_f64(),
                        if e.retry_after.is_some() {
                            " (retry-after)"
                        } else {
                            ""
                        }
                    ));
                    std::thread::sleep(wait);
                }
                Err(e) if e.retry && stop() => return Err(CallError::interrupted()),
                Err(e) => return Err(e),
            }
        }
    }

    /// Runs one turn to its end. `mailbox` is called between tool calls and
    /// after an interrupt, and returns the messages the brain logged for
    /// delivery; `interrupted` says a human message waits (checked after
    /// every streamed event).
    pub fn run(
        &self,
        chat: &OptChat,
        start: &TurnStart,
        log: &dyn Fn(&str),
        mailbox: &dyn Fn() -> Vec<Value>,
        interrupted: &dyn Fn() -> bool,
    ) -> TurnOutcome {
        self.run_gated(chat, start, log, mailbox, interrupted, &|| false)
    }

    /// `run`, with `gated` saying whether the turn's local effects need an
    /// approval (a remote-origin turn): then the bash and editor tools are
    /// refused, since this engine cannot ask the Chief chat yet; the memory
    /// tools still answer.
    pub fn run_gated(
        &self,
        chat: &OptChat,
        start: &TurnStart,
        log: &dyn Fn(&str),
        mailbox: &dyn Fn() -> Vec<Value>,
        interrupted: &dyn Fn() -> bool,
        gated: &dyn Fn() -> bool,
    ) -> TurnOutcome {
        let deadline = start.limit.map(|limit| Instant::now() + limit);
        let shell = Shell::new(
            &self.config.cwd,
            self.config.env.clone(),
            self.config.pwd_file.clone(),
        );
        let append = |kind: Kind, text: &str| {
            if let Err(e) = chat.append(kind, text) {
                log(&format!("logging a {} entry failed: {e}", kind.as_str()));
            }
        };
        let mut messages = vec![Native::first_message_with(&start.blocks, self.cache_ttl)];
        let mut reply: Option<String> = None;
        let mut first_usage = None;
        let mut totals = Usage::default();
        let scope = json!({"turn": start.key});
        let mut requests = Vec::new();
        let (mut tools, mut tool_errors) = (0, 0);
        let error = loop {
            if deadline.is_some_and(|d| Instant::now() >= d) {
                break Some(limit_text(start.limit));
            }
            // A message that arrived since the last call goes with this one.
            if interrupted() {
                deliver(&mut messages, mailbox());
            }
            let message = match self.call(&self.body(&messages), &start.key, log, interrupted) {
                Ok(m) => m,
                Err(e) if e.interrupted => {
                    // The step is dropped whole: its thinking is never
                    // logged, and its unfinished text is not a reply.
                    log(&format!(
                        "turn {}: a new message arrived; the model was interrupted",
                        start.key
                    ));
                    deliver(&mut messages, mailbox());
                    continue;
                }
                Err(e) => break Some(e.message),
            };
            if let Some(usage) = message.get("usage").and_then(Usage::parse) {
                requests.push(crate::fold::Request {
                    id: message
                        .get("id")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_owned(),
                    model: Some(self.config.model.clone()),
                    usage,
                    ..crate::fold::Request::default()
                });
                crate::trace::requests(&self.trace, &scope, &requests[requests.len() - 1..]);
                first_usage.get_or_insert(usage);
                totals.input += usage.input;
                totals.cache_read += usage.cache_read;
                totals.cache_write += usage.cache_write;
                totals.output += usage.output;
            }
            let content = message.get("content").cloned().unwrap_or(json!([]));
            let blocks = content.as_array().cloned().unwrap_or_default();
            // Section 7: each reply is `talk`, each call `tool`; thoughts never.
            for block in &blocks {
                match block.get("type").and_then(Value::as_str) {
                    Some("text") => {
                        let text = block
                            .get("text")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .trim();
                        if !text.is_empty() {
                            append(Kind::Talk, text);
                            reply = Some(text.to_owned());
                        }
                    }
                    Some("tool_use") => {
                        let name = block.get("name").and_then(Value::as_str).unwrap_or("tool");
                        let input = block.get("input").cloned().unwrap_or(json!({}));
                        append(Kind::Tool, &format!("{name} {input}"));
                    }
                    _ => {}
                }
            }
            messages.push(json!({"role": "assistant", "content": content}));
            let stop = message
                .get("stop_reason")
                .and_then(Value::as_str)
                .unwrap_or("");
            match stop {
                "tool_use" => {
                    let mut results = Vec::new();
                    for block in blocks.iter().filter(|b| b["type"] == "tool_use") {
                        let began = Instant::now();
                        let local = matches!(
                            block.get("name").and_then(Value::as_str),
                            Some("bash" | "str_replace_based_edit_tool")
                        );
                        let (text, is_error) = if local && gated() {
                            (REMOTE_REFUSED.to_owned(), true)
                        } else {
                            self.run_tool(block, chat, &shell, deadline)
                        };
                        tools += 1;
                        tool_errors += usize::from(is_error);
                        crate::trace::tools(
                            &self.trace,
                            &scope,
                            vec![crate::fold::ToolTrace {
                                id: block["id"].as_str().unwrap_or("").to_owned(),
                                name: block["name"].as_str().unwrap_or("tool").to_owned(),
                                input: block.get("input").cloned().unwrap_or(json!({})),
                                result_bytes: text.len(),
                                ok: !is_error,
                                error: is_error.then(|| text.clone()),
                                ms: Some(began.elapsed().as_millis() as u64),
                            }],
                        );
                        let text = cap_tool_result(&text).into_owned();
                        append(
                            Kind::Echo,
                            &if is_error {
                                format!("error: {text}")
                            } else {
                                text.clone()
                            },
                        );
                        let mut result = json!({"type": "tool_result", "tool_use_id": block["id"], "content": text});
                        if is_error {
                            result["is_error"] = json!(true);
                        }
                        results.push(result);
                    }
                    messages.push(json!({"role": "user", "content": results}));
                    // Messages sent meanwhile, already logged as `user` by the brain.
                    deliver(&mut messages, mailbox());
                }
                // A paused server turn: send it back as it is to continue.
                "pause_turn" => {}
                "end_turn" | "stop_sequence" => break None,
                other => {
                    break stop_error(other)
                        .or_else(|| Some("the response had no stop reason".into()));
                }
            }
        };
        log(&usage_line(
            &start.key,
            first_usage,
            Some((totals, "turn total")),
        ));
        TurnOutcome {
            reply,
            error,
            orphan: None,
            cancelled: false,
            stats: crate::turn::TurnStats {
                first: first_usage,
                totals: Some((totals, "turn total")),
                cost: None,
                requests: requests.len(),
                tools,
                tool_errors,
                ..crate::turn::TurnStats::default()
            },
            // The Messages API, no acpmux harness.
            harness: None,
            refused: false,
            done_draft: None,
        }
    }

    /// One tool call: (result text, is_error).
    fn run_tool(
        &self,
        block: &Value,
        chat: &OptChat,
        shell: &Shell,
        deadline: Option<Instant>,
    ) -> (String, bool) {
        let name = block.get("name").and_then(Value::as_str).unwrap_or("");
        let input = block.get("input").cloned().unwrap_or(json!({}));
        let result = match name {
            "bash" => {
                if input.get("restart").and_then(Value::as_bool) == Some(true) {
                    shell.restart();
                    Ok("The shell was restarted.".to_owned())
                } else {
                    match input.get("command").and_then(Value::as_str) {
                        Some(command) => {
                            let left = deadline
                                .map(|d| d.saturating_duration_since(Instant::now()))
                                .unwrap_or(self.config.bash_timeout);
                            shell.run(command, left.min(self.config.bash_timeout))
                        }
                        None => Err("missing `command`".to_owned()),
                    }
                }
            }
            "str_replace_based_edit_tool" => editor::run(&input, &shell.cwd()),
            "zoom" | "date" => Call::parse(name, &input).map(|call| call.answer(chat)),
            other => Err(format!("unknown tool {other}")),
        };
        match result {
            Ok(text) => (text, false),
            Err(text) => (text, true),
        }
    }
}

/// A prompt block in the Messages API's shape: a turn image (an ACP image
/// block) becomes a base64 image source; any other block is sent as is.
fn api_block(block: &Value) -> Value {
    if block["type"] == "image" && block.get("mimeType").is_some() {
        return json!({"type": "image", "source": {
            "type": "base64", "media_type": block["mimeType"], "data": block["data"],
        }});
    }
    block.clone()
}

/// Adds delivered messages (already logged as `user` by the brain; their
/// images, then their text) to the request: at the end of the last user
/// message, else as a new one.
fn deliver(messages: &mut Vec<Value>, delivered: Vec<Value>) {
    if delivered.is_empty() {
        return;
    }
    let blocks: Vec<Value> = delivered.iter().map(api_block).collect();
    if let Some(last) = messages.last_mut()
        && last["role"] == "user"
        && let Some(content) = last["content"].as_array_mut()
    {
        content.extend(blocks);
        return;
    }
    messages.push(json!({"role": "user", "content": blocks}));
}

fn limit_text(limit: Option<Duration>) -> String {
    format!(
        "the turn ran past its limit of {} minutes and was stopped",
        limit.unwrap_or_default().as_secs() / 60
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Spec 3.3 (gist 3c190e0): the view in blocks of 4 lines, one marker on
    /// the last whole block (the request's end carries the other).
    #[test]
    fn one_view_breakpoint_on_the_last_whole_four_line_block() {
        let line = format!("{}\n", "x".repeat(99));
        let mut view = String::from("<chat>\n");
        for _ in 0..1_102 {
            view.push_str(&line);
        }
        view.push_str("</chat>");
        let blocks = crate::prompt::turn_blocks(&view, &["new".into()]);
        // 275 whole blocks, the rest (two lines and the end tag), the message.
        assert_eq!(blocks.len(), 277);
        let message = Native::first_message(&blocks);
        let marked: Vec<usize> = message["content"]
            .as_array()
            .unwrap()
            .iter()
            .enumerate()
            .filter(|(_, b)| b.get("cache_control").is_some())
            .map(|(k, _)| k)
            .collect();
        assert_eq!(marked, vec![274]);
    }
}
