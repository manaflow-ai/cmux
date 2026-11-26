//! Claude’s repo, session-tool and repeated-stop callbacks on its existing control stream.
//! Unknown callbacks retain the empty success output Claude expects.
use super::*;
use std::time::Duration;

#[cfg(unix)]
pub(super) const SYNC_CALLBACK: &str = "cmux-repo-sync";

pub(super) const STOP_CALLBACK: &str = "cmux-repeat-stop";
pub(super) const TOOL_CALLBACK: &str = "cmux-session-tools";

/// The timeout (seconds) Claude Code gives each callback at `initialize`. Past it Claude says "A
/// hook didn't answer in time", so each answer is computed under [`deadline`] of it.
pub(super) const STOP_TIMEOUT_S: u64 = 5;
pub(super) const TOOL_TIMEOUT_S: u64 = 10;
#[cfg(unix)]
pub(super) const SYNC_TIMEOUT_S: u64 = 90;

/// When acpmux gives up on a callback's answer and sends its safe default: four fifths of its
/// timeout, the rest left for the reply's trip to Claude Code. The default is `{}` (the agent
/// carries on) for the stop and tool callbacks, and the barrier's denial for the repository sync,
/// which fails closed.
pub(super) const fn deadline(timeout_s: u64) -> Duration {
    Duration::from_millis(timeout_s.saturating_mul(800))
}

#[cfg(test)]
tokio::task_local! {
    /// A test's stand-in for every deadline: a blocking answer keeps tokio's paused clock still.
    pub(super) static DEADLINE: Duration;
}

/// `answer` within `deadline`, or `default` past it, counted in `gauges.hookAnswers.misses`. A
/// blocking task behind `answer` runs on but no longer holds the reply.
pub(super) async fn within<T>(
    deadline: Duration,
    answer: impl std::future::Future<Output = T>,
    default: T,
) -> T {
    #[cfg(test)]
    let deadline = DEADLINE.try_with(|d| *d).unwrap_or(deadline);
    match tokio::time::timeout(deadline, answer).await {
        Ok(answer) => answer,
        Err(_) => {
            crate::gauges::hook_answers().missed();
            default
        }
    }
}

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
        let mut entry = json!({"hookCallbackIds": [TOOL_CALLBACK], "timeout": TOOL_TIMEOUT_S});
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
        let started = tokio::time::Instant::now();
        let output = self.hook_callback_output(req).await;
        let id = req.get("callback_id").and_then(Value::as_str);
        #[cfg(unix)]
        let ours = id == Some(SYNC_CALLBACK);
        #[cfg(not(unix))]
        let ours = false;
        if ours || id == Some(STOP_CALLBACK) || id == Some(TOOL_CALLBACK) {
            crate::gauges::hook_answers().answered(started.elapsed());
        }
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
            let answer = async { crate::hub::stop_condition::repeat_stop(input) };
            return within(deadline(STOP_TIMEOUT_S), answer, json!({})).await;
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
            });
            match within(deadline(SYNC_TIMEOUT_S), async { Some(sync.await) }, None).await {
                Some(Ok(Ok(()))) => {}
                Some(Ok(Err(error))) => return cmux_git::native_hook::denial(&error.to_string()),
                Some(Err(error)) => return cmux_git::native_hook::denial(&error.to_string()),
                // A stalled barrier fails closed, as its error does: the tool never runs on a
                // repository that may still be mid-sync.
                None => {
                    return cmux_git::native_hook::denial(
                        "it did not finish inside the hook's timeout",
                    );
                }
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
            let answer =
                tokio::task::spawn_blocking(move || crate::bg_hook::answer(&home, &session, input));
            return within(deadline(TOOL_TIMEOUT_S), answer, Ok(None))
                .await
                .ok()
                .flatten()
                .unwrap_or_else(|| json!({}));
        }
        json!({})
    }
}
