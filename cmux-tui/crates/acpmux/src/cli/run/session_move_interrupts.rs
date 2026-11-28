//! Before a chat moves, the daemon that holds it is asked what the move would interrupt
//! (`_acpmux/transfer_interrupts`, `hub/move_interrupts.rs`; RFD 0063 item 6). A dry run and a
//! real move both carry the answer in `--json` (`interrupts`) and print its lines; a daemon older
//! than the question answers method-not-found, and the move goes on as before with `interrupts`
//! null: an old peer never stops a move.

use super::*;

/// The schema this client reads. A newer one is still shown (its `lines` are the words to say);
/// an answer with no `schema` is not an answer.
pub(super) const SCHEMA: &str = "acpmux.move-interrupts.v1";

/// The holder's answer, `None` when it is older than the question.
pub(super) async fn ask(src: &Client, id: &str) -> Result<Option<Value>> {
    match src.request("_acpmux/transfer_interrupts", json!({"sessionId": id})).await {
        Ok(answer) => Ok(read(answer)),
        Err(e) if old_peer(&e) => Ok(None),
        Err(e) => Err(e),
    }
}

/// The answer kept, when it names a move-interrupts schema.
pub(super) fn read(answer: Value) -> Option<Value> {
    let schema = answer.get("schema").and_then(Value::as_str)?;
    schema.starts_with("acpmux.move-interrupts.").then_some(answer)
}

/// Whether the holder does not know the question (JSON-RPC method not found).
pub(super) fn old_peer(e: &anyhow::Error) -> bool {
    e.downcast_ref::<crate::client::DaemonError>().is_some_and(|e| e.0.code == -32601)
}

/// The lines to print for a chat: what it interrupts, or nothing.
pub(super) fn text(name: &str, answer: Option<&Value>, dry_run: bool) -> Vec<String> {
    let Some(lines) = answer.and_then(|a| a.get("lines")).and_then(Value::as_array) else {
        return Vec::new();
    };
    let lines: Vec<&str> = lines.iter().filter_map(Value::as_str).collect();
    if lines.is_empty() {
        return Vec::new();
    }
    let verb = if dry_run { "would interrupt" } else { "interrupts" };
    let mut out = vec![format!("moving {name} {verb}:")];
    out.extend(lines.into_iter().map(|l| format!("  - {l}")));
    out
}

#[cfg(test)]
#[path = "session_move_interrupts_tests.rs"]
mod tests;
