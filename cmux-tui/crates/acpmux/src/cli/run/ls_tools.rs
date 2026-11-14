//! `acpmux ls --with-tools`: the tool inventories of a peer's rows, read per session.
//!
//! A peer link's watch list carries no inventories (`peer.rs`): with them one host's list was
//! 23 MB for 3,700 rows (2026-10-31), past the 15 MiB message limit, and without them 16.6 MB.
//! The daemon's own rows come with their tools when a list asks (`withTools`). A peer's row may
//! carry tools kept from an earlier attachment or list, which can be stale, so every peer row is
//! read on demand with `_acpmux/info`, which the daemon forwards to the row's peer, a few at a
//! time.

use std::future::Future;

use anyhow::Result;
use cmux_json::JsonSet as _;
use futures::StreamExt as _;
use serde_json::Value;

/// Rows read at once: each read is one request the daemon forwards to the row's peer.
const PARALLEL_READS: usize = 8;

/// Whether `row` is a peer's row, whose inventory is read from the peer.
fn is_peer_row(row: &Value) -> bool {
    row.get("peer").and_then(Value::as_str).is_some_and(|p| !p.is_empty())
}

/// The key `_acpmux/info` reads `row` by: its `qualifiedSessionId` (`peer/id`, the key the
/// daemon keeps a peer's row under), else made from its `peer` and `sessionId`.
fn key(row: &Value) -> String {
    let text = |field: &str| row.get(field).and_then(Value::as_str).unwrap_or_default();
    match text("qualifiedSessionId") {
        "" => format!("{}/{}", text("peer"), text("sessionId")),
        qualified => qualified.to_owned(),
    }
}

/// Sets `tools` and `toolsMutable` of every peer row of `rows` from `info(key)` of the row (its
/// `qualifiedSessionId`), replacing any it carried. Returns how many could not be read: their
/// rows stay as listed.
pub(super) async fn fill<F, Fut>(rows: &mut [Value], info: F) -> usize
where
    F: Fn(String) -> Fut,
    Fut: Future<Output = Result<Value>>,
{
    let reads = rows.iter().enumerate().filter(|(_, row)| is_peer_row(row)).map(|(at, row)| {
        let read = info(key(row));
        async move { (at, read.await) }
    });
    let read: Vec<(usize, Result<Value>)> =
        futures::stream::iter(reads).buffer_unordered(PARALLEL_READS).collect().await;
    let failed = read.iter().filter(|(_, detail)| detail.is_err()).count();
    for (at, detail) in read {
        let (Ok(detail), Some(row)) = (detail, rows.get_mut(at)) else { continue };
        for field in ["tools", "toolsMutable"] {
            if let Some(value) = detail.get(field) {
                row.set(field, value.clone());
            }
        }
    }
    failed
}

#[cfg(test)]
mod tests;
