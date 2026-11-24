//! Claude’s repo, session-tool and repeated-stop callbacks on its existing control stream.
//! Unknown callbacks retain the empty success output Claude expects.
use super::*;

#[cfg(unix)]
pub(super) const SYNC_CALLBACK: &str = "cmux-repo-sync";

pub(super) const STOP_CALLBACK: &str = "cmux-repeat-stop";
pub(super) const TOOL_CALLBACK: &str = "cmux-session-tools";

pub(super) fn add_tool_hooks(request: &mut Value) {
    let mcp = crate::bg_hook::mcp_matcher();
    let matcher = format!("Bash|{mcp}");
    for (event, tools) in [
        ("PreToolUse", Some(matcher.as_str())),
        ("PostToolUse", Some(matcher.as_str())),
        ("PostToolUseFailure", Some(mcp.as_str())),
        ("SubagentStop", None),
    ] {
        let mut entry = json!({"hookCallbackIds": [TOOL_CALLBACK], "timeout": 10});
        if let Some(tools) = tools {
            entry.set("matcher", json!(tools));
        }
        if let Some(existing) =
            request.get_mut("hooks").and_then(|h| h.get_mut(event)).and_then(Value::as_array_mut)
        {
            existing.push(entry);
        } else {
            request.set_path(&["hooks", event], json!([entry]));
        }
    }
}

impl Translator {
    pub(super) async fn answer_hook_callback(&self, rid: &str, req: &Value) {
        let id = req.get("callback_id").and_then(Value::as_str);
        let output = if id == Some(STOP_CALLBACK)
            && self.stop_condition.load(std::sync::atomic::Ordering::Relaxed)
            && req["input"]["hook_event_name"].as_str() == Some("Stop")
        {
            crate::hub::stop_condition::repeat_stop(&req["input"])
        } else if id == Some(TOOL_CALLBACK)
            // A lead's post-tool payload can contain its entire tool result. It has no notices
            // or subagent call to finish, so answer without copying it or waking a worker.
            && (req["input"]["agent_id"].is_string()
                || req["input"]["hook_event_name"] == "PreToolUse" && req["input"]["tool_name"] == "Bash")
            && let Some(home) = self.plugin_hook_home.get().cloned()
        {
            let session = self.acp_session_id.clone();
            let input = req.get("input").cloned().unwrap_or(Value::Null);
            tokio::task::spawn_blocking(move || crate::bg_hook::answer(&home, &session, input))
                .await
                .ok()
                .flatten()
                .unwrap_or_else(|| json!({}))
        } else {
            Self::hook_callback_output(req).await
        };
        self.stdin_replies.lock().await.push(json!({
            "type": "control_response",
            "response": {"subtype": "success", "request_id": rid, "response": output}
        }));
    }

    async fn hook_callback_output(req: &Value) -> Value {
        #[cfg(not(unix))]
        let output = {
            let _ = req;
            json!({})
        };
        #[cfg(unix)]
        let mut output = json!({});
        #[cfg(unix)]
        if req.get("callback_id").and_then(Value::as_str) == Some(SYNC_CALLBACK) {
            let input = req.get("input").cloned().unwrap_or(Value::Null);
            let result = tokio::task::spawn_blocking(move || {
                cmux_git::native_hook::wait(
                    "claude",
                    "PreToolUse",
                    &input,
                    cmux_git::native_hook::WAIT,
                )
            })
            .await;
            output = match result {
                Ok(Ok(())) => json!({}),
                Ok(Err(error)) => cmux_git::native_hook::denial(&error.to_string()),
                Err(error) => cmux_git::native_hook::denial(&error.to_string()),
            };
        }
        output
    }
}
