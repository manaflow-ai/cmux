//! The daemon's Auto methods (the design's "Daemon surface"), as the Mac app and the web UI
//! call them:
//!
//! - `_acpmux/auto_session/set {sessionId, auto, keepInCloud?}` -> `{autoSession}`: the chat's
//!   row field after the switch, answered once the store answered. A refusal is the request's
//!   error: `auto: false` is refused `auto.held_in_cloud` while the Cloud holds something no
//!   laptop has. With no answer from the store, `auto: true` answers the row as it is (Auto on,
//!   not in the Cloud yet) and the daemon goes on asking.
//! - `_acpmux/auto_session/leftover {sessionId, action}`: `show` -> `{files, patch?}`; `apply`
//!   and `discard` -> `{autoSession}`. `apply` that meets a conflict is refused
//!   `auto.leftover_conflict` and changes nothing.
//! - `_acpmux/auto_session/wake` (no params): the system woke.
//!
//! Who may call them is `server/auto_gate.rs`.

use std::sync::Arc;

use serde_json::{Value, json};

use super::export::leftover as patch;
use super::record::AutoRecord;
use crate::hub::{Hub, Session};
use crate::rpc::RpcError;

/// What a method answers on a daemon whose holder loop is not running.
fn not_running() -> RpcError {
    RpcError::new(-32000, "auto.unavailable: Auto mode is not running on this machine")
        .with_data(json!({"reason": "auto.unavailable"}))
}

fn row_of(hub: &Hub, session: &Session) -> Value {
    json!({ "autoSession": AutoRecord::row_of(hub.auto_record(session).as_ref()) })
}

/// One of the two methods that name a chat: `set`, or `leftover`.
pub(crate) async fn chat(
    hub: &Arc<Hub>,
    session: &Arc<Session>,
    params: &Value,
    set_auto: bool,
) -> Result<Value, RpcError> {
    if set_auto { set(hub, session, params).await } else { leftover(hub, session, params).await }
}

/// `_acpmux/auto_session/set`.
async fn set(hub: &Arc<Hub>, session: &Arc<Session>, params: &Value) -> Result<Value, RpcError> {
    let auto = params
        .get("auto")
        .and_then(Value::as_bool)
        .ok_or_else(|| RpcError::invalid_params("auto must be true or false"))?;
    let keep = match params.get("keepInCloud") {
        None | Some(Value::Null) => None,
        Some(Value::Bool(keep)) => Some(*keep),
        Some(_) => return Err(RpcError::invalid_params("keepInCloud must be true or false")),
    };
    let Some(holder) = hub.auto_holder.get() else {
        // With no loop no chat has Auto on: off is how it is, on is not to be had.
        return if auto { Err(not_running()) } else { Ok(row_of(hub, session)) };
    };
    let row = holder.set_auto(&session.id, auto, keep).await?;
    Ok(json!({ "autoSession": row }))
}

/// `_acpmux/auto_session/leftover`: the changes this machine kept aside when the Cloud took
/// the chat. They go into the folder only when the person says `apply`.
///
/// `apply` and `discard` take the folder's turn (`turns.rs`) before they read what is kept:
/// two requests for one chat settle it one after the other, and the second finds it settled.
async fn leftover(
    hub: &Arc<Hub>,
    session: &Arc<Session>,
    params: &Value,
) -> Result<Value, RpcError> {
    let action = params.get("action").and_then(Value::as_str).unwrap_or_default();
    if !matches!(action, "show" | "apply" | "discard") {
        return Err(RpcError::invalid_params("action must be show, apply or discard"));
    }
    let _turn = match action {
        "show" => None,
        _ => Some(hub.auto_turns.take(&session.id).await),
    };
    let kept = hub.auto_record(session).and_then(|record| record.leftover);
    let Some(kept) = kept else {
        return match action {
            "show" => Ok(json!({ "files": [] })),
            _ => Ok(row_of(hub, session)),
        };
    };
    match action {
        "show" => return Ok(patch::show(&kept).await),
        "apply" => patch::apply(&kept).await.map_err(|error| {
            RpcError::new(-32000, format!("auto.leftover_conflict: {error}"))
                .with_data(json!({"reason": "auto.leftover_conflict"}))
        })?,
        _ => patch::discard(&kept).await,
    }
    // Settled: the record forgets this patch, and only this one.
    hub.update_auto_record(session, |old| {
        let mut record = old?;
        if record.leftover.as_ref() == Some(&kept) {
            record.leftover = None;
        }
        (!record.spent()).then_some(record)
    });
    Ok(row_of(hub, session))
}

/// `_acpmux/auto_session/wake`: every Auto chat stops and asks the store before it goes on.
pub(crate) fn wake(hub: &Hub) -> Value {
    if let Some(holder) = hub.auto_holder.get() {
        holder.wake();
    }
    json!({})
}
