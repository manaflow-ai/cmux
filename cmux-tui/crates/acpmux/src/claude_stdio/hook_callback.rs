//! Claude's synchronous PreToolUse callback waits for an existing repo sync.
//! Unknown callbacks retain the empty success output Claude expects.
//!
//! Claude Code registers the repo-sync callback with a 90 s timeout (`outbound.rs`) and drops
//! the tool call when no answer comes by then. So its answer is worked out off the stdout
//! reader, which answers every other line meanwhile, and within [`SYNC_BUDGET`]; the answer
//! goes into the stdin replies and wakes the reader's writer ([`Translator::replies_ready`]).
//! A budget that runs out with no marker saying "syncing" lets the tool run (`{}`); a real
//! marker that says syncing or failed keeps its denial.
use super::*;

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

impl Translator {
    pub(super) async fn answer_hook_callback(&self, rid: &str, req: &Value) {
        #[cfg(unix)]
        if req.get("callback_id").and_then(Value::as_str) == Some(SYNC_CALLBACK) {
            let input = req.get("input").cloned().unwrap_or(Value::Null);
            let (rid, replies, ready) =
                (rid.to_owned(), self.stdin_replies.clone(), self.replies_ready.clone());
            // Ends within SYNC_HARD_BOUND; its blocking check ends by SYNC_BUDGET.
            self.scope.spawn_until_cancelled("repo-sync-hook-answer", async move {
                let output = bounded_sync_answer(SYNC_HARD_BOUND, move || {
                    cmux_git::native_hook::check("claude", "PreToolUse", &input, SYNC_BUDGET)
                })
                .await;
                replies.lock().await.push(hook_reply(&rid, output));
                ready.notify_one();
            });
            return;
        }
        let _ = req;
        self.stdin_replies.lock().await.push(hook_reply(rid, json!({})));
    }
}

/// The repo-sync callback's output from `check`, run on a blocking thread, by `hard` at the
/// latest: past it, or when `check` ran out of its own budget undecided, the tool runs.
#[cfg(unix)]
pub(super) async fn bounded_sync_answer(
    hard: std::time::Duration,
    check: impl FnOnce() -> cmux_git::native_hook::Readiness + Send + 'static,
) -> Value {
    use cmux_git::native_hook::{Readiness, denial};
    match tokio::time::timeout(hard, tokio::task::spawn_blocking(check)).await {
        Ok(Ok(Readiness::Ready)) => json!({}),
        Ok(Ok(Readiness::NotReady(reason))) => denial(&reason),
        Ok(Ok(Readiness::Undecided(reason))) => {
            tracing::warn!(%reason, "repo-sync hook: no marker decided within its budget; the tool runs");
            json!({})
        }
        Ok(Err(error)) => denial(&error.to_string()),
        Err(_) => {
            tracing::warn!(
                ?hard,
                "repo-sync hook: the readiness check passed its bound; the tool runs"
            );
            json!({})
        }
    }
}
