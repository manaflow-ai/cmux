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
    pub fn final_text(&self) -> Option<&str> {
        self.last_talk.as_deref()
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

    fn finish_talk(&mut self, out: &mut Vec<Entry>) {
        let text = std::mem::take(&mut self.talk);
        let text = text.trim();
        if !text.is_empty() {
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn ev(seq: u64, dir: &str, kind: &str, msg: Value) -> AcpmuxEvent {
        serde_json::from_value(json!({"seq": seq, "dir": dir, "kind": kind, "msg": msg})).unwrap()
    }

    fn update(seq: u64, kind: &str, update: Value) -> AcpmuxEvent {
        let mut u = update;
        u["sessionUpdate"] = json!(kind);
        ev(
            seq,
            "in",
            kind,
            json!({"method": "session/update", "params": {"update": u}}),
        )
    }

    fn chunk(seq: u64, text: &str) -> AcpmuxEvent {
        update(
            seq,
            "agent_message_chunk",
            json!({"content": {"type": "text", "text": text}}),
        )
    }

    fn kinds(entries: &[Entry]) -> Vec<(Kind, &str)> {
        entries.iter().map(|e| (e.kind, e.text.as_str())).collect()
    }

    #[test]
    fn talk_tool_echo_in_order_and_no_thoughts() {
        let mut fold = TurnFold::new();
        let mut log = Vec::new();
        let events = vec![
            ev(1, "mux", "user_message", json!({"promptId": "optchat:0"})),
            ev(2, "mux", "turn_started", json!({})),
            update(
                3,
                "agent_thought_chunk",
                json!({"content": {"type": "text", "text": "secret"}}),
            ),
            chunk(4, "Let me "),
            chunk(5, "look."),
            update(
                6,
                "tool_call",
                json!({"toolCallId": "t1", "title": "Read a.rs", "rawInput": {"file_path": "a.rs"}, "_meta": {"claude": {"tool": "Read"}}}),
            ),
            update(
                7,
                "tool_call_update",
                json!({"toolCallId": "t1", "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": "fn main() {}"}}]}),
            ),
            chunk(8, "  It is empty.  "),
            ev(9, "mux", "turn_end", json!({})),
        ];
        for e in &events {
            log.extend(fold.apply(e));
        }
        assert_eq!(
            kinds(&log),
            vec![
                (Kind::Talk, "Let me look."),
                (Kind::Tool, "Read {\"file_path\":\"a.rs\"}"),
                (Kind::Echo, "fn main() {}"),
                (Kind::Talk, "It is empty."),
            ]
        );
        assert_eq!(fold.final_text(), Some("It is empty."));
        assert_eq!(fold.ended(), Some(&Ended { error: None }));
        // A replay of the same events changes nothing.
        for e in &events {
            assert!(fold.apply(e).is_empty());
        }
    }

    #[test]
    fn a_call_announced_before_its_input_is_logged_once_with_it() {
        let mut fold = TurnFold::new();
        let mut log = Vec::new();
        log.extend(fold.apply(&update(
            1,
            "tool_call",
            json!({"toolCallId": "t", "title": "Bash", "rawInput": {}}),
        )));
        assert!(log.is_empty());
        log.extend(fold.apply(&update(
            2,
            "tool_call_update",
            json!({"toolCallId": "t", "rawInput": {"command": "ls"}}),
        )));
        log.extend(fold.apply(&update(
            3,
            "tool_call_update",
            json!({"toolCallId": "t", "status": "failed", "rawOutput": "boom"}),
        )));
        assert_eq!(
            kinds(&log),
            vec![
                (Kind::Tool, "Bash {\"command\":\"ls\"}"),
                (Kind::Echo, "error: boom")
            ]
        );
    }

    #[test]
    fn an_error_ends_the_turn_and_keeps_the_last_reply() {
        let mut fold = TurnFold::new();
        fold.apply(&chunk(1, "partial"));
        let out = fold.apply(&ev(2, "mux", "turn_error", json!({"error": "overloaded"})));
        assert_eq!(kinds(&out), vec![(Kind::Talk, "partial")]);
        assert_eq!(
            fold.ended(),
            Some(&Ended {
                error: Some("overloaded".into())
            })
        );
        assert!(fold.finish(None).is_empty(), "already ended");
    }

    #[test]
    fn the_first_requests_usage_is_kept() {
        let mut fold = TurnFold::new();
        let usage = |read: u64| {
            ev(
                0,
                "in",
                "claude.assistant",
                json!({"type": "assistant", "message": {"id": "m", "usage": {"input_tokens": 3, "cache_read_input_tokens": read, "cache_creation_input_tokens": 9, "output_tokens": 4}}}),
            )
        };
        fold.apply(&usage(100));
        fold.apply(&usage(200));
        assert_eq!(
            fold.first_usage(),
            Some(Usage {
                input: 3,
                cache_read: 100,
                cache_write: 9,
                output: 4
            })
        );
    }

    /// Audit round 2: a Task/Agent subagent's stream reaches acpmux through
    /// the same translator; its raw `claude.*` line carries a
    /// `parent_tool_use_id`, and the translated updates follow it.
    #[test]
    fn a_subagents_text_and_tool_calls_stay_out_of_the_log() {
        let raw = |seq: u64, kind: &str, parent: Value| {
            ev(
                seq,
                "in",
                kind,
                json!({"type": kind.trim_start_matches("claude."), "parent_tool_use_id": parent}),
            )
        };
        let mut fold = TurnFold::new();
        let mut log = Vec::new();
        let events = vec![
            raw(1, "claude.assistant", Value::Null),
            update(
                2,
                "tool_call",
                json!({"toolCallId": "task", "rawInput": {"prompt": "find x"}, "_meta": {"claude": {"tool": "Agent"}}}),
            ),
            raw(3, "claude.stream_event", json!("task")),
            chunk(4, "Searching for x."),
            raw(5, "claude.assistant", json!("task")),
            update(
                6,
                "tool_call",
                json!({"toolCallId": "g1", "rawInput": {"pattern": "x"}, "_meta": {"claude": {"tool": "Grep"}}}),
            ),
            raw(7, "claude.user", json!("task")),
            update(
                8,
                "tool_call_update",
                json!({"toolCallId": "g1", "status": "completed", "rawOutput": "a.rs:1"}),
            ),
            raw(9, "claude.stream_event", json!("task")),
            chunk(10, "x is in a.rs."),
            raw(11, "claude.user", Value::Null),
            update(
                12,
                "tool_call_update",
                json!({"toolCallId": "task", "status": "completed", "rawOutput": "x is in a.rs."}),
            ),
            raw(13, "claude.stream_event", Value::Null),
            chunk(14, "Found it."),
            ev(15, "mux", "turn_end", json!({"stopReason": "end_turn"})),
        ];
        for e in &events {
            log.extend(fold.apply(e));
        }
        assert_eq!(
            kinds(&log),
            vec![
                (Kind::Tool, "Agent {\"prompt\":\"find x\"}"),
                (Kind::Echo, "x is in a.rs."),
                (Kind::Talk, "Found it."),
            ]
        );
        assert_eq!(fold.final_text(), Some("Found it."));
    }

    /// Audit round 2: a turn that stops early (refusal, max_tokens,
    /// cancelled) must say why, not end silently.
    #[test]
    fn a_turn_end_with_another_stop_reason_is_an_error() {
        let mut fold = TurnFold::new();
        fold.apply(&ev(1, "mux", "turn_end", json!({"stopReason": "refusal"})));
        let error = fold.ended().unwrap().error.clone();
        assert!(
            error.as_deref().is_some_and(|e| e.contains("refusal")),
            "{error:?}"
        );
        let mut fold = TurnFold::new();
        fold.apply(&ev(1, "mux", "turn_end", json!({"stopReason": "end_turn"})));
        assert_eq!(fold.ended(), Some(&Ended { error: None }));
    }

    /// Audit round 2: an orphan's fold starts with no tool map; a result for
    /// a call folded before the connection loss must not log a bogus
    /// nameless `tool` entry.
    #[test]
    fn a_result_for_a_call_folded_earlier_logs_only_its_echo() {
        let mut fold = TurnFold::after(1);
        let out = fold.apply(&update(
            2,
            "tool_call_update",
            json!({"toolCallId": "t1", "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": "ok"}}]}),
        ));
        assert_eq!(kinds(&out), vec![(Kind::Echo, "ok")]);
    }

    /// The trace: each finished tool call with its duration from acpmux's
    /// event times, and one request per Claude Code message id.
    #[test]
    fn tool_traces_and_requests_for_the_trace() {
        let at = |mut e: AcpmuxEvent, ms: u64| {
            e.at = Some(ms);
            e
        };
        let assistant = |seq: u64, id: &str, read: u64| {
            ev(
                seq,
                "in",
                "claude.assistant",
                json!({"type": "assistant", "message": {"id": id, "model": "m", "usage": {"input_tokens": 1, "cache_read_input_tokens": read, "cache_creation_input_tokens": 2, "output_tokens": 3}}}),
            )
        };
        let mut fold = TurnFold::new();
        fold.apply(&assistant(1, "m1", 10));
        fold.apply(&assistant(2, "m1", 20));
        fold.apply(&at(
            update(
                3,
                "tool_call",
                json!({"toolCallId": "t", "rawInput": {"command": "ls"}, "_meta": {"claude": {"tool": "Bash"}}}),
            ),
            1_000,
        ));
        fold.apply(&at(
            update(
                4,
                "tool_call_update",
                json!({"toolCallId": "t", "status": "failed", "rawOutput": "boom"}),
            ),
            1_250,
        ));
        fold.apply(&assistant(5, "m2", 30));
        let traces = fold.take_tool_traces();
        assert_eq!(traces.len(), 1);
        assert_eq!(traces[0].name, "Bash");
        assert_eq!(traces[0].ms, Some(250));
        assert!(!traces[0].ok);
        assert_eq!(traces[0].error.as_deref(), Some("boom"));
        assert!(fold.take_tool_traces().is_empty());
        assert_eq!(fold.tool_counts(), (1, 1));
        let reads: Vec<u64> = fold.requests().iter().map(|r| r.usage.cache_read).collect();
        assert_eq!(
            reads,
            vec![20, 30],
            "one request per message id, its last usage"
        );
    }

    #[test]
    fn finish_flushes_pending_talk() {
        let mut fold = TurnFold::new();
        fold.apply(&chunk(1, "half"));
        assert_eq!(
            kinds(&fold.finish(Some("lost".into()))),
            vec![(Kind::Talk, "half")]
        );
        assert_eq!(fold.ended().unwrap().error.as_deref(), Some("lost"));
    }
}
