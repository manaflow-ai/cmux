//! The move's read-only preflight and its bounded wait for the turn the person chose.

use super::{Client, Result, Value, anyhow, json, method, plan};
use serde::Serialize;
use std::time::Duration;

/// Present even on refusal, so a caller can ask about the turn and checkout together.
/// Unknown dirt stays null when the checkout could not be inspected.
#[derive(Default, Serialize)]
pub(super) struct Preflight {
    pub running: bool,
    pub dirty: Option<bool>,
}

pub(super) fn session_refusal_code(info: &Value, interrupt: bool) -> Option<&'static str> {
    (plan::refusal(info, true).is_none() && plan::running(info) && !interrupt)
        .then_some("running_turn")
}

const TURN_WAIT: Duration = Duration::from_secs(15 * 60);

/// One daemon condition wait, bound to the original turn. Its reply is not permission to
/// interrupt another turn: the caller re-runs the normal refusal and transfer_begin still
/// checks under the turn lock. Nothing mutates the queue, history, or held prompts here.
pub(super) async fn after_turn(client: &Client, id: &str, info: &Value) -> Result<Value> {
    wait_with_limit(client, id, info, TURN_WAIT).await
}

async fn wait_with_limit(
    client: &Client,
    id: &str,
    info: &Value,
    limit: Duration,
) -> Result<Value> {
    let timeout = || {
        anyhow!(
            "the turn did not finish before the move's deadline; the chat stayed here: try --after-turn again, or --interrupt to move now"
        )
    };
    let mut params = json!({
        "sessions": [id], "until": ["ready", "closed"], "all": true,
        "timeoutMs": u64::try_from(limit.as_millis()).unwrap_or(u64::MAX),
    });
    if let Some(turn) =
        info.get("turn").filter(|t| t.get("turnId").and_then(Value::as_str).is_some())
    {
        cmux_json::JsonSet::set(&mut params, "turnEnded", turn.clone());
    }
    tokio::time::timeout(limit, async {
        let waited = client.request(method::MUX_WAIT, params).await?;
        if waited.get("timedOut").and_then(Value::as_bool) == Some(true) {
            return Err(timeout());
        }
        // Never trust the wait snapshot for a mutation; the next turn may already have begun.
        client.request(method::MUX_INFO, json!({"sessionId": id})).await
    })
    .await
    .map_err(|_| timeout())?
}

#[cfg(test)]
#[path = "session_move_preflight_tests.rs"]
mod tests;
