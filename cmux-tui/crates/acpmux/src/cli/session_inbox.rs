//! `acpmux session inbox SESSION [--thread T [--mark-read]]`: a chat's inbox (`hub/inbox.rs`),
//! other agents' messages in threads. Without `--thread` it lists the threads
//! (`_acpmux/inbox_threads`); with it, that thread's messages whole, newest first
//! (`_acpmux/inbox_thread`). The MCP tool `inbox_read` reads the same, as text from
//! [`describe`].

use crate::cli::output::print_json;
use crate::cli::run::resolve_id;
use crate::client::Client;
use crate::rpc::method;
use anyhow::Result;
use serde_json::{Value, json};

pub async fn run(
    client: &Client,
    session: &str,
    thread: Option<&str>,
    mark_read: bool,
    json_out: bool,
) -> Result<()> {
    let id = resolve_id(client, session).await?;
    let reply = match thread {
        Some(thread) => {
            let params = json!({"sessionId": id, "threadId": thread, "markRead": mark_read});
            client.request(method::MUX_INBOX_THREAD, params).await?
        }
        None => client.request(method::MUX_INBOX_THREADS, json!({"sessionId": id})).await?,
    };
    if json_out {
        print_json(&reply);
    } else {
        println!("{}", describe(&reply));
    }
    Ok(())
}

/// A reply of `_acpmux/inbox_threads`, `_acpmux/inbox_thread` or `_acpmux/inbox_reply` as text.
pub fn describe(reply: &Value) -> String {
    let s = |v: &Value| v.as_str().unwrap_or_default().to_owned();
    if let Some(threads) = reply.get("threads").and_then(Value::as_array) {
        if threads.is_empty() {
            return "The inbox is empty.".to_owned();
        }
        let from = |t: &Value| {
            let names = t["from"].as_array().cloned().unwrap_or_default();
            names.iter().map(s).collect::<Vec<_>>().join(", ")
        };
        let lines: Vec<String> = threads
            .iter()
            .map(|t| {
                format!(
                    "{} ({}): {} unread of {}, from {}; newest: {} [thread {}]",
                    s(&t["label"]),
                    s(&t["class"]),
                    t["unread"],
                    t["count"],
                    from(t),
                    s(&t["newestPreview"]),
                    s(&t["threadId"]),
                )
            })
            .collect();
        return lines.join("\n");
    }
    if let Some(messages) = reply.get("messages").and_then(Value::as_array) {
        let mut text =
            format!("Thread {} ({}), newest first:", s(&reply["label"]), s(&reply["threadId"]));
        if messages.is_empty() {
            text.push_str(" no messages.");
        }
        for m in messages {
            text.push_str(&format!(
                "\n\n[{}] from {}, promptId {}:\n{}",
                s(&m["kind"]),
                s(&m["from"]),
                s(&m["promptId"]),
                s(&m["text"])
            ));
        }
        return text;
    }
    format!("Sent into thread {} (promptId {}).", s(&reply["threadId"]), s(&reply["promptId"]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn describe_lists_threads_and_messages() {
        assert_eq!(describe(&json!({"threads": []})), "The inbox is empty.");
        let threads = json!({"threads": [{"threadId": "pr:12", "label": "#12", "class": "action", "unread": 2, "count": 3, "from": ["lane-a", "lane-b"], "newestPreview": "merged"}]});
        assert_eq!(
            describe(&threads),
            "#12 (action): 2 unread of 3, from lane-a, lane-b; newest: merged [thread pr:12]"
        );
        let thread = json!({"threadId": "pr:12", "label": "#12", "messages": [{"kind": "blocker", "from": "lane-a", "promptId": "p1", "text": "rebase"}]});
        assert_eq!(
            describe(&thread),
            "Thread #12 (pr:12), newest first:\n\n[blocker] from lane-a, promptId p1:\nrebase"
        );
    }
}
