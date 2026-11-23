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
    // This machine as the target (`--machine local`): its own daemon, no forward.
    let (forward, dst) = if target.ssh.is_empty() {
        (None, Client::connect(Path::new(&remote.socket)).await?)
    } else {
        let forward = Forward::open(&target.ssh, &remote.socket).await?;
        let dst = Client::connect(&forward.local).await?;
        (Some(forward), dst)
    };
    let init = dst
        .request(
            method::INITIALIZE,
            json!({"protocolVersion": 1, "clientInfo": {"name": "acpmux-move"}}),
        )
        .await?;
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
pub(super) async fn ask(dst: &Client, id: &str, info: &Value) -> Result<Answer> {
    match dst.request("_acpmux/transfer_preflight", json!({"manifest": manifest(id, info)})).await {
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
mod tests {
    use super::*;
    use crate::rpc::RpcError;

    fn daemon(code: i64, message: &str) -> anyhow::Error {
        anyhow::Error::from(crate::client::DaemonError(RpcError::new(code, message)))
    }

    #[test]
    fn the_manifest_names_the_harness_and_the_epoch_the_move_would_carry() {
        let m = manifest("s1", &json!({"harness": "claude-sr2", "ownershipEpoch": 3}));
        assert_eq!(m["schema"], TRANSFER_SCHEMA);
        assert_eq!(m["sessionId"], "s1");
        assert_eq!(m["session"]["harness"], "claude-sr2");
        assert_eq!(m["epoch"], 4);
        let durable = manifest("s2", &json!({"harness": "cmux-harness"}));
        assert_eq!(durable["schema"], DURABLE_TRANSFER_SCHEMA);
        assert!(durable.get("epoch").is_none(), "an unreported epoch is not invented");
    }

    #[test]
    fn an_older_target_is_unasked_and_a_refusal_keeps_the_daemons_code() {
        assert!(unasked(&daemon(-32601, "Method not found: _acpmux/transfer_preflight")));
        let refused = daemon(-32000, "transfer.harness: agent \"x\" is not configured here");
        assert!(!unasked(&refused));
        assert_eq!(refusal_code(&refused), Some("transfer.harness"));
        assert_eq!(
            refusal_code(&daemon(-32000, "transfer.exists: chat s is here already")),
            Some("transfer.exists")
        );
        assert_eq!(refusal_code(&daemon(-32000, "transfer.harnessed: no")), None);
        assert_eq!(refusal_code(&anyhow!("ssh failed")), None);
    }
}
