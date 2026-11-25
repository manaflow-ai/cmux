//! What a hub event means to the holder loop: the chat's own work changed, and how.

use cmux_auto_session::wire::OpenTool;
use serde_json::Value;

use crate::hub::HubEvent;

/// The most of a tool call's arguments a snapshot's open turn names.
const TOOL_ARGS_MAX: usize = 4096;

/// One hub event, read for Auto mode.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Signal {
    /// A chat was made here.
    Created,
    TurnStarted,
    TurnEnded,
    /// A tool call is running: what a snapshot's open turn names.
    ToolStarted(OpenTool),
    ToolEnded,
    /// The agent sent something else while its turn runs.
    Streaming,
    /// A prompt was queued or left the queue.
    Queue,
    /// Another record of the chat's own: its work may have changed.
    Other,
}

fn cut(mut text: String) -> String {
    if text.len() > TOOL_ARGS_MAX {
        let end = (0..=TOOL_ARGS_MAX).rev().find(|&at| text.is_char_boundary(at)).unwrap_or(0);
        text.truncate(end);
    }
    text
}

/// A `tool_call` or `tool_call_update` record: the call ended, or is the one running now.
fn tool(msg: &Value) -> Signal {
    let update = msg.pointer("/params/update").unwrap_or(msg);
    match update.get("status").and_then(Value::as_str) {
        Some("completed" | "failed") => Signal::ToolEnded,
        _ => {
            let name = update
                .get("title")
                .or_else(|| update.get("kind"))
                .and_then(Value::as_str)
                .unwrap_or_default();
            if name.is_empty() {
                return Signal::Streaming;
            }
            let args = update.get("rawInput").map(Value::to_string).unwrap_or_default();
            Signal::ToolStarted(OpenTool { name: name.to_owned(), args: cut(args) })
        }
    }
}

/// What `event` says about its chat, or None when it says nothing Auto mode acts on (a peer's
/// chat, a row change with no record).
pub(super) fn read(event: &HubEvent) -> Option<Signal> {
    if event.remote.is_some() {
        return None;
    }
    let record = &event.record;
    match (record.dir.as_str(), record.kind.as_str()) {
        ("mux", "created") => Some(Signal::Created),
        ("mux", "turn_started") => Some(Signal::TurnStarted),
        ("mux", "turn_result") => Some(Signal::TurnEnded),
        (
            "mux",
            "queued" | "dequeued" | "queue_removed" | "queue_order" | "queue_paused"
            | "queue_resumed",
        ) => Some(Signal::Queue),
        ("mux", _) => Some(Signal::Other),
        ("in", "tool_call" | "tool_call_update") => Some(tool(&record.msg)),
        ("in", _) => Some(Signal::Streaming),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn a_tool_call_names_what_runs_and_its_end() {
        let running = json!({"params": {"update": {
            "sessionUpdate": "tool_call", "toolCallId": "t1", "status": "in_progress",
            "title": "Bash", "rawInput": {"command": "make test"},
        }}});
        assert_eq!(
            tool(&running),
            Signal::ToolStarted(OpenTool {
                name: "Bash".into(),
                args: r#"{"command":"make test"}"#.into()
            })
        );
        let done = json!({"params": {"update": {"toolCallId": "t1", "status": "completed"}}});
        assert_eq!(tool(&done), Signal::ToolEnded);
        let failed = json!({"params": {"update": {"toolCallId": "t1", "status": "failed"}}});
        assert_eq!(tool(&failed), Signal::ToolEnded);
        // An update that names nothing is the agent still at work.
        let nameless = json!({"params": {"update": {"toolCallId": "t1"}}});
        assert_eq!(tool(&nameless), Signal::Streaming);
    }

    #[test]
    fn long_arguments_are_cut_on_a_character() {
        let text = "é".repeat(TOOL_ARGS_MAX);
        let cut = cut(text);
        assert!(cut.len() <= TOOL_ARGS_MAX);
        assert!(cut.chars().all(|c| c == 'é'));
    }
}
