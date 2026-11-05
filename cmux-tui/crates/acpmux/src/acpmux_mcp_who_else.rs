//! The `acpmux` MCP server's `who_else` tool: who else is working on these files, in one call,
//! for every harness acpmux runs (`_acpmux/who_else`, `hub/touched.rs`). It answers the same as
//! `acpmux who-else --json`: the other live and recent sessions, here and on peers, that read or
//! edited the files, share the chat's worktree or branch, or work on the topic, best first. Its
//! text is one line per session; `structuredContent` is the daemon's answer whole, which the
//! agent pane draws as a card (`webviews/.../conversation/whoElseCalls.ts`).

use super::{arg, error_result, ok, refusal};
use crate::client::Client;
use crate::rpc::method;
use serde_json::{Value, json};
use std::sync::Arc;

pub(super) const NAME: &str = "who_else";

/// The instruction the server gives with the tool.
pub(super) const STEER: &str = "Before you change files another agent may be working on, or when \
you wonder who owns an area, call who_else (with the files, a topic, or nothing for what you \
edited) instead of digging through git log, plans or PR lists: it lists the live sessions on every \
harness and machine that touch them, with their branch and pull request.";

pub(super) fn tool() -> Value {
    json!({
        "name": NAME,
        "description": "Who else is working on these files: the other live and recent agent sessions (any harness, this machine and its peers) that read or edited them, sit in this chat's worktree or on its branch, or work on the topic. Each row: name, harness, host, branch, its pull requests, the files in common (edited or read) and how recent. With no files and no topic, the files this chat edited lately. Message one with the send tool.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "files": {"type": "array", "items": {"type": "string"}, "description": "Paths, absolute or relative to this chat's folder."},
                "topic": {"type": "string", "description": "Words a session's name, title or prompt should share."},
                "since": {"type": "string", "description": "How far back a touch counts: 30m, 6h, 2d (default 1d)."},
                "description": {"type": "string", "description": "A few words on why you look, shown as this call's title."}
            }
        }
    })
}

/// The request params for a call from session `session`.
pub(super) fn params(session: &str, args: &Value) -> Result<Value, String> {
    let mut p = json!({"sessionId": session});
    if let Some(files) = args.get("files") {
        let files: Vec<&str> = files
            .as_array()
            .ok_or("files must be an array of paths")?
            .iter()
            .filter_map(Value::as_str)
            .filter(|f| !f.trim().is_empty())
            .collect();
        if !files.is_empty() {
            p["files"] = json!(files);
        }
    }
    if let Some(topic) = arg(args, "topic") {
        p["topic"] = json!(topic);
    }
    if let Some(since) = arg(args, "since") {
        let ms = crate::cli::who_else::duration_ms(since).map_err(|e| e.to_string())?;
        p["sinceMs"] = json!(ms);
    }
    Ok(p)
}

pub(super) async fn call(daemon: &Arc<Client>, session: &str, args: &Value) -> Value {
    if session.is_empty() {
        return error_result("who_else needs the chat's session (ACPMUX_SESSION_ID)".to_owned());
    }
    let p = match params(session, args) {
        Ok(p) => p,
        Err(e) => return error_result(e),
    };
    match daemon.request(method::MUX_WHO_ELSE, p).await {
        Ok(answer) => {
            let lines: Vec<&str> = answer["lines"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .collect();
            let text = if lines.is_empty() {
                "No other session works on these.".to_owned()
            } else {
                lines.join("\n")
            };
            ok(text, answer)
        }
        Err(e) => refusal(e),
    }
}
