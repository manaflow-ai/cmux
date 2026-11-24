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
        // Unix already registers a repo-sync callback for every tool. Its successful
        // reply carries the plugin decision too, for the same Bash/MCP matcher.
        #[cfg(not(unix))]
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
        let output = self.hook_callback_output(req).await;
        self.stdin_replies.lock().await.push(json!({
            "type": "control_response",
            "response": {"subtype": "success", "request_id": rid, "response": output}
        }));
    }

    async fn hook_callback_output(&self, req: &Value) -> Value {
        let id = req.get("callback_id").and_then(Value::as_str);
        let input = &req["input"];
        if id == Some(STOP_CALLBACK)
            && self.stop_condition.load(std::sync::atomic::Ordering::Relaxed)
            && input["hook_event_name"].as_str() == Some("Stop")
        {
            return crate::hub::stop_condition::repeat_stop(input);
        }

        let tool_callback = id == Some(TOOL_CALLBACK);
        #[cfg(unix)]
        let tool_callback = if id == Some(SYNC_CALLBACK) {
            let check = input.clone();
            let sync = tokio::task::spawn_blocking(move || {
                cmux_git::native_hook::wait(
                    "claude",
                    "PreToolUse",
                    &check,
                    cmux_git::native_hook::WAIT,
                )
            })
            .await;
            match sync {
                Ok(Ok(())) => {}
                Ok(Err(error)) => return cmux_git::native_hook::denial(&error.to_string()),
                Err(error) => return cmux_git::native_hook::denial(&error.to_string()),
            }
            let tool = input["tool_name"].as_str().unwrap_or("");
            input["hook_event_name"] == "PreToolUse"
                && (tool == "Bash" || crate::bg_hook::MCP_CALLS.contains(&tool))
        } else {
            tool_callback
        };

        // A lead's post-tool payload can contain its entire tool result. It has no notices
        // or subagent call to finish, so answer without copying it or waking a worker.
        if tool_callback
            && (input["agent_id"].is_string()
                || input["hook_event_name"] == "PreToolUse" && input["tool_name"] == "Bash")
            && let Some(home) = self.plugin_hook_home.get().cloned()
        {
            let session = self.acp_session_id.clone();
            let input = input.clone();
            return tokio::task::spawn_blocking(move || {
                crate::bg_hook::answer(&home, &session, input)
            })
            .await
            .ok()
            .flatten()
            .unwrap_or_else(|| json!({}));
        }
        json!({})
    }
}
