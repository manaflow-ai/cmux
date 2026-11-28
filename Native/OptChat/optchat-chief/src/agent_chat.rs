//! `zoom("a<N>")`: a subagent's whole chat, read from its acpmux session and
//! rendered as the reference client renders an agent's log, one
//! `i|kind: text` line per entry (newlines kept), in pages: the task and
//! every later prompt (`user`), its replies (`talk`), its tool calls
//! (`tool`) and their results (`echo`). The view it got with its task stays
//! out: the Chief has it already.

use cmux_chief::acp::AcpmuxEvent;
use serde_json::Value;

use crate::fold::{Entry, TurnFold};
use optchat_core::Kind;

/// Characters of one page.
pub const PAGE: u64 = 30_000;

/// The entries of a subagent's session, oldest first.
pub fn entries(events: &[AcpmuxEvent]) -> Vec<Entry> {
    let mut out = Vec::new();
    let mut fold = TurnFold::new();
    for event in events {
        if event.dir == "mux" && event.kind == "user_message" {
            out.extend(fold.finish(None));
            fold = TurnFold::after(event.seq);
            let text = prompt_text(&event.msg);
            if !text.is_empty() {
                out.push(Entry {
                    kind: Kind::User,
                    text,
                });
            }
            continue;
        }
        out.extend(fold.apply(event));
    }
    out.extend(fold.finish(None));
    out
}

/// A prompt's text; the host's first prompt to a subagent (the view, then
/// its task) gives only its task.
fn prompt_text(msg: &serde_json::Map<String, Value>) -> String {
    if let Some(text) = msg.get("text").and_then(Value::as_str) {
        return task_of(text).to_owned();
    }
    let blocks: Vec<&str> = msg
        .get("prompt")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|b| b.get("text").and_then(Value::as_str))
        .collect();
    match blocks.iter().rev().find(|t| t.starts_with(TASK_HEAD)) {
        Some(task) => (*task).to_owned(),
        None => blocks.join("\n"),
    }
}

const TASK_HEAD: &str = "Your task:";

/// The task part of one text that holds the view and the task.
fn task_of(text: &str) -> &str {
    match text.rfind(TASK_HEAD) {
        Some(k) if text.starts_with("<chat>") => &text[k..],
        _ => text,
    }
}

/// The whole chat as lines.
pub fn render(entries: &[Entry]) -> String {
    entries
        .iter()
        .enumerate()
        .map(|(i, e)| format!("{i}|{}: {}", e.kind.as_str(), e.text))
        .collect::<Vec<_>>()
        .join("\n")
}

/// One page of `text` from character `at`, at most `page` characters,
/// saying where to go on.
pub fn page(id: &str, text: &str, at: u64, page: u64) -> String {
    let total = text.chars().count() as u64;
    if at >= total {
        return format!("(the chat of {id} has {total} characters; nothing from {at} on)");
    }
    let end = at.saturating_add(page).min(total);
    let body: String = text
        .chars()
        .skip(at as usize)
        .take((end - at) as usize)
        .collect();
    if end < total {
        format!("{body}\n(more: zoom(\"{id}\", at={end}) of {total} characters)")
    } else {
        body
    }
}

/// The report line naming the subagent's full chat (the reference client's).
pub fn footer(id: &str) -> String {
    format!("Full chat: zoom(\"{id}\")")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pages_say_where_to_go_on() {
        let text = "abcdefghij";
        assert_eq!(
            page("a1", text, 0, 4),
            "abcd\n(more: zoom(\"a1\", at=4) of 10 characters)"
        );
        assert_eq!(page("a1", text, 8, 4), "ij");
        assert!(page("a1", text, 10, 4).contains("nothing from 10"));
    }

    #[test]
    fn the_first_prompt_gives_only_its_task() {
        assert_eq!(
            task_of("<chat>\n0|x\n</chat>\nYour task:\n\ndo it"),
            "Your task:\n\ndo it"
        );
        assert_eq!(task_of("more: please"), "more: please");
    }
}
