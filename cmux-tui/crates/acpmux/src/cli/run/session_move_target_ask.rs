//! Asking the target before a move begins. A dry run, and a real move before it freezes or
//! copies anything, sends the target daemon `_acpmux/transfer_preflight` with what the source
//! knows of the chat by then; the target answers with `transfer_receive`'s own check
//! (`hub/transfer_in.rs` `receive_admission`), so a refusal it can give without the bytes (its
//! harness is not configured there, the chat is there already, a stale epoch, the schema) reaches
//! the person with the same code and text, and the chat is never frozen for a move that cannot
//! land.
use super::*;

/// The schemas `transfer_begin` gives a bundle (`hub/transfer_out.rs`): the durable one for
/// cmux-harness, else v1.
const TRANSFER_SCHEMA: &str = "acpmux.transfer.v1";
const DURABLE_TRANSFER_SCHEMA: &str = "acpmux.transfer.v2";

/// A client of the target's daemon: the ssh forward that carries it (none for this machine's
/// own daemon, `--machine local`), and the daemon's `initialize` reply on it.
pub(super) struct Opened {
    pub(super) forward: Option<Forward>,
    pub(super) dst: std::sync::Arc<Client>,
    pub(super) init: Value,
}

impl Opened {
    pub(super) async fn close(self) {
        if let Some(forward) = self.forward {
            forward.close().await;
        }
    }
}

pub(super) async fn open(target: &Target, remote: &RemoteDaemon) -> Result<Opened> {
    let (forward, dst, init) = super::transfer::connect_target(&target.ssh, &remote.socket).await?;
    Ok(Opened { forward, dst, init })
}

/// The manifest `transfer_begin` would answer, as far as the chat's `_acpmux/info` tells it
/// before the freeze: its id, harness and schema, and the epoch the move would carry (one past
/// the chat's own; a source that does not report it sends none, and the target then does not
/// judge the epoch).
pub(super) fn manifest(id: &str, info: &Value) -> Value {
    let harness = info.get("harness").and_then(Value::as_str).unwrap_or_default();
    let schema = if harness == "cmux-harness" { DURABLE_TRANSFER_SCHEMA } else { TRANSFER_SCHEMA };
    let mut manifest = json!({"schema": schema, "sessionId": id, "session": {"harness": harness}});
    if let Some(epoch) = info.get("ownershipEpoch").and_then(Value::as_u64) {
        manifest.set("epoch", json!(epoch + 1));
    }
    // The agent its harness runs, when the chat's info says: the target names its own harness
    // for the same agent in a refusal, and checks `--as` against it.
    if let Some(family) = info.get("family").and_then(Value::as_str).filter(|f| !f.is_empty()) {
        manifest.set("harnessFamily", json!(family));
    }
    manifest
}

/// What the target said of the chat.
#[derive(Debug, PartialEq)]
pub(super) enum Answer {
    /// It would take it.
    Takes,
    /// Its acpmux is older than the question: it could not be asked.
    Unasked,
}

/// Asks the target. `Err`: its refusal, as `transfer_receive` would give it.
/// `as_harness`: the move's `--as`, which the target checks as `transfer_receive` will.
pub(super) async fn ask(
    dst: &Client,
    id: &str,
    info: &Value,
    as_harness: Option<&str>,
) -> Result<Answer> {
    let mut params = json!({"manifest": manifest(id, info)});
    if let Some(name) = as_harness {
        params.set("asHarness", json!(name));
    }
    match dst.request("_acpmux/transfer_preflight", params).await {
        Ok(_) => Ok(Answer::Takes),
        Err(e) if unasked(&e) => Ok(Answer::Unasked),
        Err(e) => Err(e),
    }
}

/// Whether the error is a daemon that does not know the request (JSON-RPC method not found).
fn unasked(e: &anyhow::Error) -> bool {
    e.downcast_ref::<crate::client::DaemonError>().is_some_and(|e| e.0.code == -32601)
}

/// The receipt's `errorCode` for a target's refusal: the daemon's own code, the `transfer.WHAT`
/// its message begins with.
pub(super) fn refusal_code(e: &anyhow::Error) -> Option<&'static str> {
    let message = e.downcast_ref::<crate::client::DaemonError>()?.0.message.as_str();
    [
        "transfer.harness",
        "transfer.exists",
        "transfer.stale_epoch",
        "transfer.epoch_unreadable",
        "transfer.schema",
        "transfer.approved_prompts",
    ]
    .into_iter()
    .find(|code| message.strip_prefix(code).is_some_and(|rest| rest.starts_with(':')))
}

#[cfg(test)]
#[path = "session_move_target_ask_tests.rs"]
mod tests;
