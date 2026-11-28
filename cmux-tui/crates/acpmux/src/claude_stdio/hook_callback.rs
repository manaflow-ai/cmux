//! Claude’s repo, session-tool and repeated-stop callbacks on its existing control stream.
//! Unknown callbacks retain the empty success output Claude expects.
//!
//! Claude Code registers the repo-sync callback with a 90 s timeout (`outbound.rs`) and drops
//! the tool call when no answer comes by then. So its answer is worked out off the stdout
//! reader, which answers every other line meanwhile, and within [`SYNC_BUDGET`]; the answer
//! goes into the stdin replies and wakes the reader's writer ([`Translator::replies_ready`]).
//! A budget that runs out with no marker saying "syncing" lets the tool run (`{}`); a real
//! marker that says syncing or failed keeps its denial, and a check stalled past
//! [`SYNC_HARD_BOUND`] fails closed.
use super::*;
use std::time::Duration;

#[cfg(unix)]
pub(super) const SYNC_CALLBACK: &str = "cmux-repo-sync";

/// How long the readiness check may wait on locks and a running sync: a third of the 90 s
/// Claude Code waits for the answer.
#[cfg(unix)]
pub(super) const SYNC_BUDGET: std::time::Duration = cmux_git::native_hook::WAIT;

/// Past this the answer goes out whatever the check is doing (a path stuck in the kernel):
/// [`SYNC_BUDGET`] and a margin, still well under the 90 s.
#[cfg(unix)]
pub(super) const SYNC_HARD_BOUND: std::time::Duration =
    std::time::Duration::from_secs(SYNC_BUDGET.as_secs() + 5);

use super::policy_gate::hook_reply;

pub(super) const STOP_CALLBACK: &str = "cmux-repeat-stop";
pub(super) const TOOL_CALLBACK: &str = "cmux-session-tools";

/// The timeout (seconds) Claude Code gives each callback at `initialize`. Past it Claude says "A
/// hook didn't answer in time", so each answer is computed under [`deadline`] of it.
pub(super) const STOP_TIMEOUT_S: u64 = 5;
pub(super) const TOOL_TIMEOUT_S: u64 = 10;
#[cfg(unix)]
pub(super) const SYNC_TIMEOUT_S: u64 = 90;
#[cfg(unix)]
const _: () = assert!(SYNC_HARD_BOUND.as_millis() < deadline(SYNC_TIMEOUT_S).as_millis());

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
    #[cfg(not(unix))]
    let pre_matcher = format!("{matcher}|{}", crate::model_router::SUBAGENT_TOOLS.join("|"));
    for (event, tools) in [
        // Unix already registers a repo-sync callback for every tool. Its successful
        // reply carries the plugin decision too, for the same Bash/MCP matcher.
        #[cfg(not(unix))]
        ("PreToolUse", Some(pre_matcher.as_str())),
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
        #[cfg(unix)]
        if req.get("callback_id").and_then(Value::as_str) == Some(SYNC_CALLBACK) {
            let input = req.get("input").cloned().unwrap_or(Value::Null);
            let (rid, replies, ready) =
                (rid.to_owned(), self.stdin_replies.clone(), self.replies_ready.clone());
            let (home, session) =
                (self.plugin_hook_home.get().cloned(), self.acp_session_id.clone());
            #[cfg(test)]
            let hard = DEADLINE.try_with(|d| *d).unwrap_or(SYNC_HARD_BOUND);
            #[cfg(not(test))]
            let hard = SYNC_HARD_BOUND;
            let started = tokio::time::Instant::now();
            // Ends within SYNC_HARD_BOUND; its blocking check ends by SYNC_BUDGET.
            self.scope.spawn_until_cancelled("repo-sync-hook-answer", async move {
                let check = input.clone();
                let mut output = bounded_sync_answer(hard, move || {
                    cmux_git::native_hook::check("claude", "PreToolUse", &check, SYNC_BUDGET)
                })
                .await;
                // The tool runs: the same reply carries the plugin decision, for the same
                // Bash/MCP matcher the session-tool callback has elsewhere.
                if output == json!({}) {
                    let tool = input["tool_name"].as_str().unwrap_or("");
                    let tool_callback = input["hook_event_name"] == "PreToolUse"
                        && (tool == "Bash"
                            || crate::bg_hook::MCP_CALLS.contains(&tool)
                            || crate::model_router::SUBAGENT_TOOLS.contains(&tool));
                    output = plugin_answer(tool_callback, home, &session, &input).await;
                }
                crate::gauges::hook_answers().answered(started.elapsed());
                replies.lock().await.push(hook_reply(&rid, output));
                ready.notify_one();
            });
            return;
        }
        let started = tokio::time::Instant::now();
        let output = self.hook_callback_output(req).await;
        let id = req.get("callback_id").and_then(Value::as_str);
        if id == Some(STOP_CALLBACK) || id == Some(TOOL_CALLBACK) {
            crate::gauges::hook_answers().answered(started.elapsed());
        }
        self.stdin_replies.lock().await.push(hook_reply(rid, output));
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
        let home = self.plugin_hook_home.get().cloned();
        plugin_answer(id == Some(TOOL_CALLBACK), home, &self.acp_session_id, input).await
    }
}

/// The session-tool plugin's answer to a tool callback, or no decision (`{}`).
async fn plugin_answer(
    tool_callback: bool,
    home: Option<std::path::PathBuf>,
    session: &str,
    input: &Value,
) -> Value {
    // A lead's post-tool payload can contain its entire tool result. It has no notices
    // or subagent call to finish, so answer without copying it or waking a worker.
    if tool_callback
        && (input["agent_id"].is_string()
            || input["hook_event_name"] == "PreToolUse" && input["tool_name"] == "Bash"
            || crate::model_router::starts_subagent(input))
        && let Some(home) = home
    {
        let session = session.to_owned();
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

/// The repo-sync callback's output from `check`, run on a blocking thread, by `hard` at the
/// latest. A check that ran out of its own budget undecided lets the tool run; one stalled past
/// `hard` fails closed, as the barrier's error does: the tool never runs on a repository that
/// may still be mid-sync.
#[cfg(unix)]
pub(super) async fn bounded_sync_answer(
    hard: std::time::Duration,
    check: impl FnOnce() -> cmux_git::native_hook::Readiness + Send + 'static,
) -> Value {
    use cmux_git::native_hook::{Readiness, denial};
    let check = async { Some(tokio::task::spawn_blocking(check).await) };
    match within(hard, check, None).await {
        Some(Ok(Readiness::Ready)) => json!({}),
        Some(Ok(Readiness::NotReady(reason))) => denial(&reason),
        Some(Ok(Readiness::Undecided(reason))) => {
            tracing::warn!(%reason, "repo-sync hook: no marker decided within its budget; the tool runs");
            json!({})
        }
        Some(Err(error)) => denial(&error.to_string()),
        None => {
            tracing::warn!(
                ?hard,
                "repo-sync hook: the readiness check passed its bound; the tool is denied"
            );
            denial("it did not finish inside the hook's timeout")
        }
    }
}
