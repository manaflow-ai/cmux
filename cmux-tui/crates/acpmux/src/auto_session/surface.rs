//! The daemon's Auto methods (the design's "Daemon surface"), as the Mac app and the web UI
//! call them:
//!
//! - `_acpmux/auto_session/set {sessionId, auto, keepInCloud?}` -> `{autoSession}`: the chat's
//!   row field after the switch, answered once the store answered. A refusal is the request's
//!   error: `auto: false` is refused `auto.held_in_cloud` while the Cloud holds something no
//!   laptop has. With no answer from the store, `auto: true` answers the row as it is (Auto on,
//!   not in the Cloud yet) and the daemon goes on asking.
//! - `_acpmux/auto_session/set {sessionId, mode}` with `mode` one of `local`, `auto`, `cloud`:
//!   the same switch in the place picker's three states (`set_mode`). `cloud` for a chat that
//!   cannot be moved there is refused as a move is, and a chat that had Auto off has it off
//!   again (`to_cloud`).
//! - `_acpmux/auto_session/move {sessionId, to}` with `to` one of `cloud`, `local` ->
//!   `{autoSession}`: the chat moves now, also in the middle of a turn. Answered once the
//!   Cloud took the move; a refusal is the request's error, one plain sentence with the
//!   Cloud's code as `data.reason`, and changes nothing.
//! - `_acpmux/auto_session/leftover {sessionId, action}`: `show` -> `{files, patch?}`; `apply`
//!   and `discard` -> `{autoSession}`. `apply` that meets a conflict is refused
//!   `auto.leftover_conflict` and changes nothing.
//! - `_acpmux/auto_session/wake` (no params): the system woke.
//! - `_acpmux/auto_session/transcript {sessionId, after?, version?}` -> `{version, projection,
//!   events, more}`: while another holder runs the chat, the Cloud's events after seq `after`
//!   as a read-only projection (`runtime/projection.rs`); `projection: null` while the chat is
//!   held here. A `version` past the one served is refused `auto.transcript_version`, so a
//!   newer client reads the chat's own log, as it does from a daemon without this read.
//!
//! Who may call them is `server/auto_gate.rs`.

use std::sync::Arc;

use cmux_auto_session::wire::MoveTo;
use serde_json::{Value, json};

use super::HolderHandle;
use super::export::leftover as patch;
use super::record::{AutoRecord, Mode};
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

/// Which of the methods that name a chat a request is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Ask {
    Set,
    Move,
    Leftover,
}

/// One of the three methods that name a chat: `set`, `move` or `leftover`.
pub(crate) async fn chat(
    hub: &Arc<Hub>,
    session: &Arc<Session>,
    params: &Value,
    ask: Ask,
) -> Result<Value, RpcError> {
    match ask {
        Ask::Set => set(hub, session, params).await,
        Ask::Move => move_now(hub, session, params).await,
        Ask::Leftover => leftover(hub, session, params).await,
    }
}

/// The word a request names a place or a mode with: `params[key]` as one of `known`'s.
fn word<T>(
    params: &Value,
    key: &str,
    known: &str,
    parse: impl FnOnce(&str) -> Option<T>,
) -> Result<Option<T>, RpcError> {
    let refusal = || RpcError::invalid_params(format!("{key} must be {known}"));
    match params.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(named)) => parse(named).map(Some).ok_or_else(refusal),
        Some(_) => Err(refusal()),
    }
}

/// `_acpmux/auto_session/set`: `mode`, or the two fields it stands for (`auto`,
/// `keepInCloud`). A request with `mode` is read by it alone.
async fn set(hub: &Arc<Hub>, session: &Arc<Session>, params: &Value) -> Result<Value, RpcError> {
    if let Some(mode) = word(params, "mode", "local, auto or cloud", Mode::parse)? {
        return set_mode(hub, session, mode).await;
    }
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

/// `set` with `mode`, the record's three states:
///
/// - `auto`: Auto on, not kept in the Cloud. A chat the Cloud machine has comes home at its
///   turn's end.
/// - `cloud`: Auto on, and the chat is moved to the Cloud now, which keeps it there from the
///   same store write. A chat with Auto off is registered as kept in the Cloud first.
/// - `local`: this machine only. A chat that is here has Auto switched off; one the Cloud has
///   is moved home, and Auto goes off once it is here.
async fn set_mode(hub: &Arc<Hub>, session: &Arc<Session>, mode: Mode) -> Result<Value, RpcError> {
    let Some(holder) = hub.auto_holder.get() else {
        // With no loop no chat has Auto on: local is how it is, the others are not to be had.
        return if mode == Mode::Local { Ok(row_of(hub, session)) } else { Err(not_running()) };
    };
    let id = session.id.as_str();
    let row = match mode {
        Mode::Auto => holder.set_auto(id, true, Some(false)).await?,
        Mode::Cloud => to_cloud(hub, holder, session).await?,
        Mode::Local => holder.set_local(id).await?,
    };
    Ok(json!({ "autoSession": row }))
}

/// `mode: "cloud"`. A chat with Auto on is moved, and a move the Cloud refuses changes nothing
/// of it. A chat with Auto off is registered as kept in the Cloud first, then moved; when it
/// is not moved after all, Auto is switched off for it again before the request answers why,
/// so the chat is as it was: not an Auto chat, and not copied to the Cloud.
async fn to_cloud(
    hub: &Arc<Hub>,
    holder: &HolderHandle,
    session: &Arc<Session>,
) -> Result<Value, RpcError> {
    let id = session.id.as_str();
    if hub.auto_record(session).is_some_and(|record| record.auto) {
        return holder.move_to(id, MoveTo::Cloud).await;
    }
    holder.set_auto(id, true, Some(true)).await?;
    // With no answer from the store the chat has Auto on and is not in the Cloud yet (the
    // record names no epoch). The store would refuse to move a chat it does not know, in words
    // that fit a chat the person never set to Cloud.
    let record = hub.auto_record(session).filter(|record| record.auto);
    let moved = if record.is_some_and(|record| record.epoch == 0) {
        Err(HolderHandle::cloud_did_not_answer())
    } else {
        holder.move_to(id, MoveTo::Cloud).await
    };
    if moved.is_err()
        && let Err(error) = holder.set_auto(id, false, None).await
    {
        let why = error.message;
        tracing::warn!(session = %id, "auto session: Auto not switched off again: {why}");
    }
    moved
}

/// `_acpmux/auto_session/move {sessionId, to}`: the chat runs in the Cloud, or on this
/// machine, from now on. Answers the row once the Cloud took the move; `autoSession.moving`
/// says where the chat is going until it is there.
async fn move_now(
    hub: &Arc<Hub>,
    session: &Arc<Session>,
    params: &Value,
) -> Result<Value, RpcError> {
    let to = word(params, "to", "cloud or local", MoveTo::parse)?
        .ok_or_else(|| RpcError::invalid_params("to must be cloud or local"))?;
    let Some(holder) = hub.auto_holder.get() else { return Err(not_running()) };
    let row = holder.move_to(&session.id, to).await?;
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

/// `_acpmux/auto_session/transcript`: reads only what the holder loop already holds; it never
/// wakes the chat, starts its agent or writes its log.
pub(crate) fn transcript(hub: &Hub, session: &Session, params: &Value) -> Result<Value, RpcError> {
    use super::runtime::projection::VERSION;
    let asked = params.get("version").and_then(Value::as_u64).unwrap_or(VERSION);
    if asked > VERSION {
        return Err(RpcError::new(
            -32000,
            format!("auto.transcript_version: this daemon serves version {VERSION}"),
        )
        .with_data(json!({"reason": "auto.transcript_version", "version": VERSION})));
    }
    let after = params.get("after").and_then(Value::as_u64).unwrap_or(0);
    let read = hub.auto_holder.get().and_then(|holder| holder.transcript(&session.id, after));
    Ok(read.unwrap_or_else(|| json!({"version": VERSION, "projection": null, "events": []})))
}

/// `_acpmux/auto_session/wake`: every Auto chat stops and asks the store before it goes on.
pub(crate) fn wake(hub: &Hub) -> Value {
    if let Some(holder) = hub.auto_holder.get() {
        holder.wake();
    }
    json!({})
}
