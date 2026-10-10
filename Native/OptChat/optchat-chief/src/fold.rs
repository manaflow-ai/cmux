//! Folds one turn session's acpmux events into OptChat log entries (section 7:
//! "everything the agent does is logged as it happens"): each finished reply
//! is `talk`, each tool call `tool` (its name and JSON input), each tool
//! result `echo`. Thoughts are never logged (section 2). Pure; the runner
//! feeds it events in seq order and appends what it returns.

use std::collections::HashMap;

use cmux_chief::acp::AcpmuxEvent;
use optchat_core::Kind;
use serde_json::Value;

/// One log entry.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub kind: Kind,
    pub text: String,
}

/// How the turn ended, once it did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Ended {
    pub error: Option<String>,
}

#[derive(Debug, Default)]
struct Tool {
    name: String,
    input: Value,
    /// When acpmux recorded the call (ms), for the trace's duration.
    started: Option<u64>,
    /// The `tool` entry is in the log.
    logged: bool,
    /// The `echo` entry is in the log.
    done: bool,
}

/// Token counts of one Messages API response (or a turn's sum), as Claude
/// Code reports them. Section 8 says to verify caching with these: each
/// request should read what the previous one wrote.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Usage {
    /// Uncached input tokens (full price).
    pub input: u64,
    pub cache_read: u64,
    pub cache_write: u64,
    pub output: u64,
}

impl Usage {
    /// The Anthropic `usage` object; None when it has no token counts.
    pub fn parse(usage: &Value) -> Option<Usage> {
        let n = |k: &str| usage.get(k).and_then(Value::as_u64);
        let input = n("input_tokens")?;
        Some(Usage {
            input,
            cache_read: n("cache_read_input_tokens").unwrap_or(0),
            cache_write: n("cache_creation_input_tokens").unwrap_or(0),
            output: n("output_tokens").unwrap_or(0),
        })
    }
}

/// The token use a prompt's answer reports, and what it covers: Claude
/// Code's `_meta.claude.usage` (the whole turn, "turn total"), else the ACP
/// `usage` field codex-acp fills from the turn's last model request ("last
/// request").
pub fn answer_usage(answer: &Value) -> Option<(Usage, &'static str)> {
    if let Some(u) = answer.pointer("/_meta/claude/usage").and_then(Usage::parse) {
        return Some((u, "turn total"));
    }
    let usage = answer.get("usage")?;
    let n = |k: &str| usage.get(k).and_then(Value::as_u64);
    Some((
        Usage {
            input: n("inputTokens")?,
            cache_read: n("cachedReadTokens").unwrap_or(0),
            cache_write: n("cachedWriteTokens").unwrap_or(0),
            output: n("outputTokens").unwrap_or(0),
        },
        "last request",
    ))
}

/// One finished tool call, for the trace: its name, input, result size,
/// outcome and duration (from acpmux's event times).
#[derive(Clone, Debug, PartialEq)]
pub struct ToolTrace {
    pub id: String,
    pub name: String,
    pub input: Value,
    pub result_bytes: usize,
    pub ok: bool,
    /// The failed call's result text.
    pub error: Option<String>,
    pub ms: Option<u64>,
}

/// One model request of the turn (Claude Code's raw assistant lines of one
/// message id), with the token use it reported.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Request {
    pub id: String,
    pub model: Option<String>,
    pub usage: Usage,
    /// From what started the request (the prompt, or the tool result Claude
    /// Code answers) to the model's `message_start`, in ms of acpmux's event
    /// times. None: the start or the stream was not seen.
    pub headers_ms: Option<u64>,
    /// From the same start to the request's first content delta: its time
    /// to first token.
    pub ttft_ms: Option<u64>,
}

/// The model stream of the request in flight (Claude Code's
/// `stream_event` lines, `--include-partial-messages`).
#[derive(Debug, Default)]
struct Stream {
    id: String,
    headers_ms: Option<u64>,
    ttft_ms: Option<u64>,
    /// When the request started (event time, ms).
    start: Option<u64>,
}

#[derive(Debug, Default)]
pub struct TurnFold {
    last_seq: u64,
    /// Every model request seen, in order (Claude harnesses only).
    requests: Vec<Request>,
    /// Finished tool calls not yet taken by the trace.
    traces: Vec<ToolTrace>,
    /// Finished tool calls, and how many of them failed.
    tools_done: usize,
    tools_failed: usize,
    /// Usage of the turn's first model request: the only one that can read a
    /// cache entry another turn wrote, so it shows whether the view is cached.
    first_usage: Option<Usage>,
    /// Reply text since the last tool call.
    talk: String,
    tools: HashMap<String, Tool>,
    /// The last finished reply: what the turn posts.
    last_talk: Option<String>,
    /// Answers Claude Code finished (`result`) before a steered message
    /// made it go on in the same prompt: the post holds them first.
    answered: Vec<String>,
    ended: Option<Ended>,
    /// The last raw Claude Code line came from one of its own subagents
    /// (Task/Agent): the translated updates that follow it are that
    /// subagent's steps, which stay out of the log (section 9).
    in_subagent: bool,
    /// The event time of what started the next model request: the last
    /// line sent to the harness, or the last tool result Claude Code read.
    request_start: Option<u64>,
    /// The request streaming now.
    stream: Option<Stream>,
    /// The reply segment the talk buffer belongs to (drafts, `draft.rs`).
    segment: u64,
    /// Segments finished since the drafts last took them: (segment, text).
    closed: Vec<(u64, String)>,
}

impl TurnFold {
    pub fn new() -> TurnFold {
        TurnFold::default()
    }

    /// A fold that resumes after event `seq` (an orphaned turn's rest: what
    /// it did before is already in the log).
    pub fn after(seq: u64) -> TurnFold {
        TurnFold {
            last_seq: seq,
            ..TurnFold::default()
        }
    }

    pub fn first_usage(&self) -> Option<Usage> {
        self.first_usage
    }

    /// The turn's model requests so far (Claude Code's assistant messages).
    pub fn requests(&self) -> &[Request] {
        &self.requests
    }

    /// Tool calls finished in this fold, and how many failed.
    pub fn tool_counts(&self) -> (usize, usize) {
        (self.tools_done, self.tools_failed)
    }

    /// The tool calls finished since the last call, for the trace.
    pub fn take_tool_traces(&mut self) -> Vec<ToolTrace> {
        std::mem::take(&mut self.traces)
    }

    /// Highest seq folded; the next fetch asks for the events after it.
    pub fn seq(&self) -> u64 {
        self.last_seq
    }

    pub fn ended(&self) -> Option<&Ended> {
        self.ended.as_ref()
    }

    /// A tool call started and has no result yet. Claude Code's interrupt
    /// (what `session/cancel` sends) aborts a running tool, so a stop for a
    /// newer message waits for this to clear.
    pub fn tool_running(&self) -> bool {
        self.ended.is_none() && self.tools.values().any(|t| !t.done)
    }

    /// The turn's final assistant text: its last finished reply.
    pub fn final_text(&self) -> Option<String> {
        let parts: Vec<&str> = self
            .answered
            .iter()
            .map(String::as_str)
            .chain(self.last_talk.as_deref())
            .collect();
        (!parts.is_empty()).then(|| parts.join("\n\n"))
    }

    /// Folds one event; events at or below the last seq are replays.
    pub fn apply(&mut self, event: &AcpmuxEvent) -> Vec<Entry> {
        if !event.valid {
            return Vec::new();
        }
        if event.seq > 0 {
            if event.seq <= self.last_seq {
                return Vec::new();
            }
            self.last_seq = event.seq;
        }
        let mut out = Vec::new();
        if self.ended.is_some() {
            return out;
        }
        let update = event.msg.get("params").and_then(|p| p.get("update"));
        // Anything sent to the harness (the prompt, a permission answer)
        // starts its next request.
        if event.dir == "out" && event.at.is_some() {
            self.request_start = event.at;
        }
        if event.kind.starts_with("claude.") {
            // Claude Code's raw stream-json line; acpmux records it just before
            // the updates it translates into, and its translator ignores
            // `parent_tool_use_id`, so this is where a subagent's steps show.
            self.in_subagent =
                matches!(event.msg.get("parent_tool_use_id"), Some(Value::String(_)));
            if !self.in_subagent && event.dir != "out" {
                self.time_request(event);
            }
            // Claude Code finished an answer; with a steered message it goes
            // on in this prompt, and the next answer is posted after it.
            if !self.in_subagent && event.kind.starts_with("claude.result") {
                let mut out = Vec::new();
                self.finish_talk(&mut out);
                if let Some(text) = self.last_talk.take() {
                    self.answered.push(text);
                }
                return out;
            }
            if event.kind == "claude.assistant" && !self.in_subagent {
                let message = event.msg.get("message");
                let usage = message.and_then(|m| m.get("usage")).and_then(Usage::parse);
                if self.first_usage.is_none() {
                    self.first_usage = usage;
                }
                if let Some(usage) = usage {
                    let id = message
                        .and_then(|m| m.get("id"))
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_owned();
                    let model = message
                        .and_then(|m| m.get("model"))
                        .and_then(Value::as_str)
                        .map(str::to_owned);
                    // Claude Code writes one line per content block of a
                    // message, each with the message's usage so far.
                    match self.requests.last_mut() {
                        Some(last) if !id.is_empty() && last.id == id => last.usage = usage,
                        _ => {
                            let stream = self.stream.take_if(|s| s.id == id).unwrap_or_default();
                            self.requests.push(Request {
                                id,
                                model,
                                usage,
                                headers_ms: stream.headers_ms,
                                ttft_ms: stream.ttft_ms,
                            });
                        }
                    }
                }
            }
            return out;
        }
        if self.in_subagent
            && matches!(
                event.kind.as_str(),
                "agent_message_chunk" | "agent_thought_chunk" | "tool_call" | "tool_call_update"
            )
        {
            return out;
        }
        match (event.dir.as_str(), event.kind.as_str()) {
            (_, "agent_message_chunk") => {
                if let Some(content) = update.and_then(|u| u.get("content"))
                    && content.get("type").and_then(Value::as_str) == Some("text")
                    && let Some(text) = content.get("text").and_then(Value::as_str)
                {
                    self.talk.push_str(text);
                }
            }
            (_, "tool_call") => {
                self.finish_talk(&mut out);
                if let Some(update) = update {
                    self.tool_call(update, event.at, &mut out);
                }
            }
            (_, "tool_call_update") => {
                if let Some(update) = update {
                    self.tool_update(update, event.at, &mut out);
                }
            }
            ("mux", kind @ ("turn_end" | "turn_error")) => {
                self.finish_talk(&mut out);
                // The shared rule (cmux_chief::acp::turn_error_text): the same
                // text the TypeScript brain posts; an empty error is none.
                let error = if kind == "turn_error" {
                    cmux_chief::acp::turn_error_text(&event.msg)
                } else {
                    event
                        .msg
                        .get("stopReason")
                        .and_then(Value::as_str)
                        .and_then(stop_error)
                };
                self.ended = Some(Ended { error });
            }
            _ => {}
        }
        out
    }

    /// The time to first token of the turn's main requests, from Claude
    /// Code's raw lines: a tool result it reads (`user`) starts the next
    /// request, `message_start` is the answer, the first content delta its
    /// first token.
    fn time_request(&mut self, event: &AcpmuxEvent) {
        let Some(at) = event.at else { return };
        match event.kind.as_str() {
            // A tool result Claude Code read; its echo of a user line it
            // read (`isReplay`) is not a start: the line went out earlier.
            "claude.user" if event.msg.get("isReplay") != Some(&Value::Bool(true)) => {
                self.request_start = Some(at)
            }
            "claude.stream_event" => {
                let ev = event.msg.get("event");
                match ev.and_then(|e| e.get("type")).and_then(Value::as_str) {
                    Some("message_start") => {
                        let id = ev
                            .and_then(|e| e.pointer("/message/id"))
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_owned();
                        let start = self.request_start;
                        self.stream = Some(Stream {
                            id,
                            headers_ms: start.map(|s| at.saturating_sub(s)),
                            ttft_ms: None,
                            start,
                        });
                    }
                    Some("content_block_delta") => {
                        if let Some(stream) = self.stream.as_mut()
                            && stream.ttft_ms.is_none()
                        {
                            stream.ttft_ms = stream.start.map(|s| at.saturating_sub(s));
                        }
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }

    /// The turn is over without a `turn_end` (the prompt failed or the
    /// connection was lost): what is pending becomes final.
    pub fn finish(&mut self, error: Option<String>) -> Vec<Entry> {
        let mut out = Vec::new();
        if self.ended.is_none() {
            self.finish_talk(&mut out);
            self.ended = Some(Ended { error });
        }
        out
    }

    /// The reply segments finished since the last call, then the open one
    /// (its index and its text so far), for the drafts.
    pub fn take_segments(&mut self) -> (Vec<(u64, String)>, (u64, &str)) {
        (
            std::mem::take(&mut self.closed),
            (self.segment, self.talk.as_str()),
        )
    }

    fn finish_talk(&mut self, out: &mut Vec<Entry>) {
        let raw = std::mem::take(&mut self.talk);
        let text = raw.trim();
        if !text.is_empty() {
            self.closed.push((self.segment, raw.clone()));
            self.segment += 1;
            out.push(Entry {
                kind: Kind::Talk,
                text: text.to_owned(),
            });
            self.last_talk = Some(text.to_owned());
        }
    }

    fn tool_call(&mut self, update: &Value, at: Option<u64>, out: &mut Vec<Entry>) {
        let Some(id) = tool_id(update) else { return };
        let tool = self.tools.entry(id).or_default();
        tool.started = tool.started.or(at);
        tool.name = tool_name(update).unwrap_or_else(|| tool.name.clone());
        if let Some(input) = update.get("rawInput").filter(|v| has_input(v)) {
            tool.input = input.clone();
        }
        // Some adapters announce a call before its input streams in; it is
        // logged once the input is known, or at its result at the latest.
        if has_input(&tool.input) {
            log_tool(tool, out);
        }
    }

    fn tool_update(&mut self, update: &Value, at: Option<u64>, out: &mut Vec<Entry>) {
        let Some(id) = tool_id(update) else { return };
        let unknown = !self.tools.contains_key(&id);
        let tool = self.tools.entry(id.clone()).or_default();
        if unknown && tool_name(update).is_none() && !update.get("rawInput").is_some_and(has_input)
        {
            // A call folded before this fold began (an orphan's rest): its
            // `tool` entry is in the log already; only its result is new.
            tool.logged = true;
        }
        if tool.name.is_empty()
            && let Some(name) = tool_name(update)
        {
            tool.name = name;
        }
        if let Some(input) = update.get("rawInput").filter(|v| has_input(v)) {
            tool.input = input.clone();
        }
        if has_input(&tool.input) {
            log_tool(tool, out);
        }
        let status = update.get("status").and_then(Value::as_str).unwrap_or("");
        if !tool.done && matches!(status, "completed" | "failed") {
            log_tool(tool, out);
            tool.done = true;
            let text = result_text(update);
            let failed = status == "failed";
            self.tools_done += 1;
            self.tools_failed += usize::from(failed);
            self.traces.push(ToolTrace {
                id,
                name: if tool.name.is_empty() {
                    "tool".to_owned()
                } else {
                    tool.name.clone()
                },
                input: tool.input.clone(),
                result_bytes: text.len(),
                ok: !failed,
                error: failed.then(|| text.clone()),
                ms: match (tool.started, at) {
                    (Some(a), Some(b)) => Some(b.saturating_sub(a)),
                    _ => None,
                },
            });
            let text = if failed {
                format!("error: {text}")
            } else {
                text
            };
            out.push(Entry {
                kind: Kind::Echo,
                text,
            });
        }
    }
}

/// Why a turn that ended with `reason` stopped early; None for a normal end.
/// A turn that stops for a refusal or `max_tokens` before it says anything
/// would otherwise post nothing at all.
pub fn stop_error(reason: &str) -> Option<String> {
    match reason {
        "end_turn" | "" => None,
        other => Some(format!("the turn stopped early ({other})")),
    }
}

/// The turn was cancelled (the Chief stopped it for a newer message).
pub fn is_cancelled(error: Option<&str>) -> bool {
    error == stop_error("cancelled").as_deref()
}

fn log_tool(tool: &mut Tool, out: &mut Vec<Entry>) {
    if tool.logged {
        return;
    }
    tool.logged = true;
    let name = if tool.name.is_empty() {
        "tool"
    } else {
        tool.name.as_str()
    };
    out.push(Entry {
        kind: Kind::Tool,
        text: format!("{name} {}", tool.input),
    });
}

fn tool_id(update: &Value) -> Option<String> {
    match update.get("toolCallId")? {
        Value::String(id) => Some(id.clone()),
        Value::Null => None,
        other => Some(other.to_string()),
    }
}

/// The harness's own tool name (Claude Code's in `_meta.claude.tool`), else the title.
fn tool_name(update: &Value) -> Option<String> {
    update
        .pointer("/_meta/claude/tool")
        .or_else(|| update.pointer("/_meta/claudeCode/toolName"))
        .or_else(|| update.get("title"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}

fn has_input(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Object(map) => !map.is_empty(),
        _ => true,
    }
}

/// A tool result's text: its text content blocks, else its raw output.
fn result_text(update: &Value) -> String {
    let mut parts: Vec<String> = Vec::new();
    for item in update
        .get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let content = item.get("content").unwrap_or(item);
        if let Some(text) = content.get("text").and_then(Value::as_str) {
            parts.push(text.to_owned());
        } else if item.get("type").and_then(Value::as_str) == Some("diff") {
            let path = item.get("path").and_then(Value::as_str).unwrap_or("?");
            parts.push(format!("(diff of {path})"));
        }
    }
    if parts.is_empty() {
        match update.get("rawOutput") {
            Some(Value::String(text)) => return text.clone(),
            Some(Value::Null) | None => return String::new(),
            Some(other) => return other.to_string(),
        }
    }
    parts.join("\n")
}
