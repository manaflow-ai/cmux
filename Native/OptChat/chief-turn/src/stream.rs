//! Claude Code's stream-json lines (`--output-format stream-json --verbose
//! --include-partial-messages`) as typed values. The Mac host gets the same
//! lines through acpmux (event kind `claude.<type>`, the line as its message);
//! the cloud runner reads them from `claude -p`'s stdout.

use serde_json::Value;

/// One stream-json line, by what a turn does with it.
#[derive(Debug, PartialEq)]
pub enum Line<'a> {
    /// The turn's end: `{"type":"result", ...}`, the whole line.
    Result(&'a Value),
    /// A user line Claude Code read: the tool results it holds, and whether
    /// it is Claude Code's echo of a line it already read (`isReplay`).
    User {
        tool_results: Vec<ToolResult>,
        replay: bool,
    },
    /// An assistant line (one per content block of a message, each with the
    /// message so far).
    Assistant(&'a Value),
    /// One event of the model's stream.
    Stream(StreamEvent),
    /// Anything else (`system`, unknown types).
    Other,
}

/// A tool result in a user line.
#[derive(Debug, PartialEq, Eq)]
pub struct ToolResult {
    pub id: String,
    pub error: bool,
}

/// One Anthropic streaming event (`stream_event` lines' `event`).
#[derive(Debug, PartialEq)]
pub enum StreamEvent {
    MessageStart { id: String },
    MessageStop,
    BlockStart { index: Option<u64>, block: Block },
    BlockDelta { index: Option<u64>, delta: Delta },
    BlockStop { index: Option<u64> },
    Other,
}

/// A content block's kind as it starts.
#[derive(Debug, PartialEq, Eq)]
pub enum Block {
    Text,
    Thinking,
    Tool { id: String, name: String },
    Other,
}

/// A content block delta.
#[derive(Debug, PartialEq, Eq)]
pub enum Delta {
    Text(String),
    Thinking(String),
    InputJson(String),
    Other,
}

/// A JSON value as JS `String(x)` gives it for the ids and names Claude Code
/// sends (strings as they are, anything else as its JSON text).
fn text(v: Option<&Value>) -> String {
    match v {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Null) | None => "undefined".to_owned(),
        Some(other) => other.to_string(),
    }
}

impl<'a> Line<'a> {
    /// The line by its `type`.
    pub fn parse(line: &'a Value) -> Line<'a> {
        match line.get("type").and_then(Value::as_str) {
            Some("result") => Line::Result(line),
            Some("assistant") => Line::Assistant(line),
            Some("user") => {
                let tool_results = line
                    .pointer("/message/content")
                    .and_then(Value::as_array)
                    .map(|content| {
                        content
                            .iter()
                            .filter(|c| {
                                c.get("type").and_then(Value::as_str) == Some("tool_result")
                            })
                            .map(|c| ToolResult {
                                id: text(c.get("tool_use_id")),
                                error: c.get("is_error") == Some(&Value::Bool(true)),
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                Line::User {
                    tool_results,
                    replay: line.get("isReplay") == Some(&Value::Bool(true)),
                }
            }
            Some("stream_event") => Line::Stream(StreamEvent::parse(line.get("event"))),
            _ => Line::Other,
        }
    }
}

/// A line of a subagent Claude Code runs (its `parent_tool_use_id`): its
/// text, results and usage are not the turn's.
pub fn is_subagent(line: &Value) -> bool {
    matches!(line.get("parent_tool_use_id"), Some(Value::String(_)))
}

/// [`is_subagent`] for a line held as a JSON object (acpmux's event message).
pub fn is_subagent_of(line: &serde_json::Map<String, Value>) -> bool {
    matches!(line.get("parent_tool_use_id"), Some(Value::String(_)))
}

impl StreamEvent {
    /// A `stream_event` line's `event` object.
    pub fn parse(event: Option<&Value>) -> StreamEvent {
        let Some(e) = event else {
            return StreamEvent::Other;
        };
        let index = e.get("index").and_then(Value::as_u64);
        let s = |v: Option<&Value>| v.and_then(Value::as_str).unwrap_or("").to_owned();
        match e.get("type").and_then(Value::as_str) {
            Some("message_start") => StreamEvent::MessageStart {
                id: s(e.pointer("/message/id")),
            },
            Some("message_stop") => StreamEvent::MessageStop,
            Some("content_block_start") => {
                let b = e.get("content_block");
                let block = match b.and_then(|b| b.get("type")).and_then(Value::as_str) {
                    Some("text") => Block::Text,
                    Some("thinking") => Block::Thinking,
                    Some("tool_use") => Block::Tool {
                        id: text(b.and_then(|b| b.get("id"))),
                        name: text(b.and_then(|b| b.get("name"))),
                    },
                    _ => Block::Other,
                };
                StreamEvent::BlockStart { index, block }
            }
            Some("content_block_delta") => {
                let d = e.get("delta");
                let delta = match d.and_then(|d| d.get("type")).and_then(Value::as_str) {
                    Some("text_delta") => Delta::Text(s(d.and_then(|d| d.get("text")))),
                    Some("thinking_delta") => Delta::Thinking(s(d.and_then(|d| d.get("thinking")))),
                    Some("input_json_delta") => {
                        Delta::InputJson(s(d.and_then(|d| d.get("partial_json"))))
                    }
                    _ => Delta::Other,
                };
                StreamEvent::BlockDelta { index, delta }
            }
            Some("content_block_stop") => StreamEvent::BlockStop { index },
            _ => StreamEvent::Other,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn user_line_lists_tool_results() {
        let l = json!({"type":"user","message":{"content":[
            {"type":"tool_result","tool_use_id":"toolu_1","is_error":true},
            {"type":"text","text":"x"},
            {"type":"tool_result","tool_use_id":"toolu_2"}]}});
        assert_eq!(
            Line::parse(&l),
            Line::User {
                tool_results: vec![
                    ToolResult {
                        id: "toolu_1".into(),
                        error: true
                    },
                    ToolResult {
                        id: "toolu_2".into(),
                        error: false
                    }
                ],
                replay: false
            }
        );
    }

    #[test]
    fn stream_events_parse() {
        let ev = |e: Value| match Line::parse(&json!({"type":"stream_event","event":e})) {
            Line::Stream(s) => s,
            other => panic!("{other:?}"),
        };
        assert_eq!(
            ev(json!({"type":"message_start","message":{"id":"msg_1"}})),
            StreamEvent::MessageStart { id: "msg_1".into() }
        );
        assert_eq!(
            ev(
                json!({"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_9","name":"Bash"}})
            ),
            StreamEvent::BlockStart {
                index: Some(2),
                block: Block::Tool {
                    id: "toolu_9".into(),
                    name: "Bash".into()
                }
            }
        );
        assert_eq!(
            ev(
                json!({"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hm"}})
            ),
            StreamEvent::BlockDelta {
                index: Some(0),
                delta: Delta::Thinking("hm".into())
            }
        );
        assert_eq!(ev(json!({"type":"ping"})), StreamEvent::Other);
    }

    #[test]
    fn subagent_lines() {
        assert!(is_subagent(&json!({"parent_tool_use_id":"toolu_1"})));
        assert!(!is_subagent(&json!({"parent_tool_use_id":null})));
    }
}
