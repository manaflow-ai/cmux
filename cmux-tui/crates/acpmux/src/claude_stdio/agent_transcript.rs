//! A subagent's transcript as the updates a pane draws (`_acpmux/subagent_transcript`,
//! `hub/subagent_transcript.rs`): Claude Code's lines replayed through a fresh translator as one
//! subagent's whole lines (its text, thinking, tool calls and results). Every line before the
//! page is replayed too, with its updates dropped, so a call on an older page still pairs with
//! its result on this one (a Write's diff, a nested agent).

use super::*;
use crate::no_panic::JsonExt;

/// The subagent the replayed lines stream as.
const READ: &str = "read";

/// The updates of each of `lines[from..]`, in order, every line before `from` replayed first. With
/// `prompt`, `lines` start at the transcript's first line, the agent's prompt, which is also the
/// person's message.
pub async fn replay(lines: &[Value], from: usize, prompt: bool) -> Vec<Vec<Value>> {
    let reader = Translator::new(READ.to_owned(), "default", "default", "default");
    reader.subagents.lock().await.insert(READ.to_owned(), READ.to_owned());
    let mut out = Vec::with_capacity(lines.len().saturating_sub(from));
    for (at, line) in lines.iter().enumerate() {
        let mut line = line.clone();
        line.set("parent_tool_use_id", json!(READ));
        let msgs = reader.inbound(&line).await;
        if at < from {
            continue;
        }
        let mut updates = Vec::new();
        if prompt
            && at == 0
            && let Some(text) = prompt_text(&line)
        {
            updates.push(json!({"sessionUpdate": "user_message_chunk",
                "content": {"type": "text", "text": text}}));
        }
        for msg in msgs {
            if let Message::Notification { method: m, params: Some(params) } = msg
                && m == method::SESSION_UPDATE
                && let Some(update) = params.get("update")
            {
                updates.push(update.clone());
            }
        }
        out.push(updates);
    }
    out
}

/// A user line's text: its content when that is text, else its text blocks.
fn prompt_text(line: &Value) -> Option<String> {
    if line.get("type").and_then(Value::as_str) != Some("user") {
        return None;
    }
    let content = line.pointer("/message/content")?;
    if let Some(text) = content.as_str() {
        return Some(text.to_owned());
    }
    let text: Vec<&str> = content
        .as_array()?
        .iter()
        .filter(|block| block.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|block| block.get("text").and_then(Value::as_str))
        .collect();
    (!text.is_empty()).then(|| text.join("\n"))
}
