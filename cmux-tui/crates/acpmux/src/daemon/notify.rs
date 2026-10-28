//! The daemon's `notify_command` (`config.rs`): a shell command run on the transitions a
//! person may want to hear about while no client shows the chat.

use crate::hub::Hub;
use crate::no_panic::JsonExt;
use serde_json::Value;
use std::sync::Arc;

/// Run `notify_command` from the config on three transitions only: a
/// permission request, a turn that ended while no client was attached, and an
/// agent pair the runaway guard paused (`hub/agent_pairs.rs`).
pub(super) async fn notify_loop(hub: Arc<Hub>) {
    let mut rx = hub.subscribe();
    loop {
        let ev = match rx.recv().await {
            Ok(e) => e,
            Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
            Err(_) => break,
        };
        let kind = ev.record.kind.as_str();
        if !matches!(kind, "permission_request" | "turn_result" | "agent_pair_paused") {
            continue;
        }
        let Some(cmd) = hub.config.read().await.notify_command.clone() else { continue };
        let Ok(session) = hub.resolve(&ev.session_id) else { continue };
        let summary = hub.session_summary(&session);
        // A chat some client shows needs no notification (`hub/seen.rs`).
        if kind == "turn_result" && *summary.field("shown") == true {
            continue;
        }
        let name = summary.get("name").and_then(Value::as_str).unwrap_or("").to_owned();
        let text = match kind {
            "permission_request" => permission_text(&name, ev.record.msg.field("request")),
            "agent_pair_paused" => {
                let peer = ev
                    .record
                    .msg
                    .get("peerName")
                    .and_then(Value::as_str)
                    .unwrap_or("another agent");
                match ev.record.msg.get("reason").and_then(Value::as_str) {
                    Some("cap") => format!("{name} paused: too many messages with {peer}"),
                    Some("release_failed") => {
                        format!("{name} paused: a held message with {peer} failed")
                    }
                    _ => format!("{name} paused: it kept messaging {peer} without progress"),
                }
            }
            _ => format!(
                "{name} finished ({})",
                ev.record.msg.get("status").and_then(Value::as_str).unwrap_or("completed")
            ),
        };
        let mut c = tokio::process::Command::new("sh");
        // The daemon starter's turn values are not this command's (config::TURN_SCOPED_ENV).
        for k in crate::config::inherited_caller_scoped_keys() {
            c.env_remove(k);
        }
        crate::login_env::apply_tokio(&mut c);
        c.arg("-c")
            .arg(&cmd)
            .env("ACPMUX_EVENT", kind)
            .env("ACPMUX_SESSION_ID", &ev.session_id)
            .env("ACPMUX_SESSION_NAME", &name)
            .env("ACPMUX_TEXT", &text);
        crate::config::scrub_nested_claude_env_tokio(&mut c);
        let _ = c
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
    }
}

/// The notification for a pending permission request. An agent's question
/// (AskUserQuestion, a Codex user-input request) reads as a question, never
/// as a permission (Leo 2026-10-21).
fn permission_text(name: &str, request: &Value) -> String {
    if crate::hub::is_question(request) {
        return match crate::hub::question_prompt(request) {
            Some(prompt) => format!("{name} asks: {prompt}"),
            None => format!("{name} asks a question"),
        };
    }
    let title = request.pointer("/toolCall/title").and_then(Value::as_str).unwrap_or("tool");
    format!("{name} needs a permission: {title}")
}

#[cfg(test)]
#[path = "notify_tests.rs"]
mod tests;
