//! How `acpmux ls` reads the session list: in pages (`limit` and `cursor`,
//! `hub/session_pages.rs`), never as one reply. One fleet host's whole list was 15.7 MB with 3,700
//! sessions on 2026-10-30, past the 15 MiB message limit, and its daemon refused it with
//! `message.too_large`; a daemon that pages by `limit` (every one since the keyset pages) answers
//! these pages whatever its size, and one too old for `limit` sends the whole list as before.
//!
//! The daemon lists newest first and its `nextCursor` names the last row it sent, so a read that
//! stops at the end of a page hands that cursor on. One that stops before (`--limit` with a filter
//! the daemon does not apply) hands on the cursor of the last row it read, made as the daemon
//! makes it. A read that wants N rows asks for no more than it still wants when every filter is
//! one the daemon applies. A page too large to send is asked for again at half the rows.

use std::collections::HashSet;
use std::future::Future;
use std::io::{self, Write};

use anyhow::Result;
use cmux_json::JsonSet as _;
use serde_json::Value;

use crate::cli::errors::{AppError, Code};

/// Initial rows per page. A complete census learns a fuller page size from the first
/// successful reply; explicit one-page reads keep the requested count.
pub(super) const PAGE_ROWS: u64 = 1000;

/// The most times in a row a read takes a cursor it had already followed, each with a page twice
/// as wide.
const MAX_REPEATS: u32 = 16;

/// What a read does with a row.
pub(super) enum Step {
    Keep,
    Skip,
    /// This row and every later one are left out (`--since`: the list is newest first).
    Stop,
}

/// How a read pages.
pub(super) struct Plan {
    /// Rows asked for per page.
    pub(super) size: u64,
    /// Stop once this many rows are kept (`--limit`).
    pub(super) want: Option<usize>,
    /// Read one page only (`--cursor`).
    pub(super) one: bool,
    /// Every row the daemon sends is kept unless a filter it also applies drops it: a page asks
    /// for at most the rows still wanted, so the read ends on a page's last row.
    pub(super) exact: bool,
}

/// What a read gives.
#[derive(Debug)]
pub(super) struct Pages {
    pub(super) rows: Vec<Value>,
    /// The cursor of the rows after these (a string), `null` when none is left, or `None` when
    /// the read stopped in the middle of the whole list a daemon too old for pages sent.
    pub(super) next: Option<Value>,
}

/// Reads `params`' rows page by page from `cursor` with `fetch` (one `_acpmux/sessions`
/// request), each row through `step`. A row that comes twice (one session id on one host, moved
/// to the top between pages) is kept once; a cursor that comes again is followed with a wider
/// page, a bounded number of times, never a loop.
pub(super) async fn read<F, Fut>(
    params: Value,
    cursor: Option<String>,
    plan: Plan,
    mut step: impl FnMut(&Value) -> Step,
    mut fetch: F,
) -> Result<Pages>
where
    F: FnMut(Value) -> Fut,
    Fut: Future<Output = Result<Value>>,
{
    let (mut size, mut widen, mut repeats) = (plan.size.max(1), 0u64, 0u32);
    let (mut rows, mut seen) = (Vec::new(), HashSet::new());
    // The cursors followed, the one the read starts from too: a page that hands it back made no
    // way past it.
    let mut cursors: HashSet<String> = cursor.iter().cloned().collect();
    let mut cursor = cursor;
    // Learn once, from a successful ordinary first page. A size refusal fixes the
    // smaller fallback for the rest of this read, so heterogeneous rows cannot
    // repeatedly make us grow and retry the same oversized page.
    let mut learn_size = plan.size == PAGE_ROWS && !plan.one && plan.want.is_none();
    loop {
        let left = plan.want.map(|want| want.saturating_sub(rows.len()));
        let ask = match left {
            Some(left) if plan.exact => size.min(u64::try_from(left).unwrap_or(u64::MAX)).max(1),
            _ => size,
        }
        .saturating_add(widen);
        let mut page_params = params.clone();
        page_params.set("limit", Value::from(ask));
        if let Some(cursor) = &cursor {
            page_params.set("cursor", Value::String(cursor.clone()));
        }
        let mut reply = match fetch(page_params).await {
            Ok(reply) => reply,
            Err(e) => match too_large(&e) {
                Some(_) if ask > 1 => {
                    learn_size = false;
                    (size, widen) = (ask / 2, 0);
                    continue;
                }
                Some(bytes) => return Err(one_row_too_large(bytes).into()),
                None => return Err(e),
            },
        };
        if learn_size && reply.get("nextCursor").is_some_and(Value::is_string) {
            size = fuller_page(&reply).max(size);
        }
        learn_size = false;
        // A daemon that pages answers a `limit` with `nextCursor` (null on the last page); one
        // too old for pages sends its whole list, with no cursor and from the start.
        let pages = reply.get("nextCursor").is_some();
        let next = match reply.get_mut("nextCursor").map(Value::take) {
            Some(Value::String(next)) => Some(next),
            _ => None,
        };
        let page = match reply.get_mut("sessions").map(Value::take) {
            Some(Value::Array(page)) => page,
            _ => anyhow::bail!("the daemon's session page lists no sessions"),
        };
        if plan.one && !pages {
            let message =
                "this daemon is too old to page the session list (`--cursor`): update acpmux on it";
            return Err(AppError::new(Code::Runtime, "runtime", message).into());
        }
        let (count, mut used) = (page.len(), 0usize);
        // Where the next rows start when the read stops before the page's end.
        let mut after = None;
        for row in page {
            used = used.saturating_add(1);
            if !seen.insert(row_key(&row)) {
                continue;
            }
            match step(&row) {
                Step::Keep => rows.push(row),
                Step::Skip => continue,
                Step::Stop => return Ok(Pages { rows, next: Some(Value::Null) }),
            }
            if plan.want.is_some_and(|want| rows.len() >= want) {
                after = rows.last().map(crate::hub::session_pages::cursor_after);
                break;
            }
        }
        let next = match (after, next) {
            // Stopped before the page's end: the rows after the last one read.
            (Some(after), _) if used < count => {
                return Ok(Pages { rows, next: pages.then_some(Value::String(after)) });
            }
            // The page read whole: the daemon's cursor, if there is a next page.
            (Some(_), next) | (None, next @ None) => {
                return Ok(Pages { rows, next: Some(next.map_or(Value::Null, Value::String)) });
            }
            (None, Some(next)) => next,
        };
        // A cursor that comes again: it names a session id and time, which a chat here and its
        // copy on a peer share on a daemon from before #28161, so the page after it
        // starts at the copy again. A wider page gets past it: it may hold a row the last page
        // ended on, never skips one. A daemon that keeps giving one cursor is an error, never a
        // loop.
        if cursors.insert(next.clone()) {
            if plan.one {
                return Ok(Pages { rows, next: Some(Value::String(next)) });
            }
            (widen, repeats) = (0, 0);
        } else {
            repeats = repeats.saturating_add(1);
            if repeats > MAX_REPEATS {
                anyhow::bail!("the daemon gave the session page cursor {next:?} again and again");
            }
            widen = widen.saturating_mul(2).max(1);
        }
        cursor = Some(next);
    }
}

/// Size the next page from measured serialized bytes, leaving the protocol's existing
/// near-cap headroom for the reply envelope and variation between rows. Count bytes
/// without allocating another copy of the page. The daemon's byte bound and the
/// halve-on-error path remain authoritative when later rows are larger.
fn fuller_page(reply: &Value) -> u64 {
    struct Bytes(usize);
    impl Write for Bytes {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            self.0 = self.0.saturating_add(bytes.len());
            Ok(bytes.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    let rows = reply.get("sessions").and_then(Value::as_array).map_or(0, Vec::len);
    let mut bytes = Bytes(0);
    if serde_json::to_writer(&mut bytes, reply).is_err() || bytes.0 == 0 {
        return PAGE_ROWS;
    }
    let count = rows.saturating_mul(crate::wire_size::NEAR_CAP_BYTES) / bytes.0;
    u64::try_from(count).unwrap_or(PAGE_ROWS)
}

/// One session on one host: a chat's copies on peers are different rows.
fn row_key(row: &Value) -> (Option<String>, Option<String>) {
    let text = |k: &str| row.get(k).and_then(Value::as_str).map(str::to_owned);
    (text("sessionId"), text("peer"))
}

/// The size of a reply refused as too large to send (`RpcError::too_large`), if `e` is one.
fn too_large(e: &anyhow::Error) -> Option<u64> {
    let data = e.downcast_ref::<crate::client::DaemonError>()?.0.data.as_ref()?;
    (data.get("reason").and_then(Value::as_str) == Some("message.too_large"))
        .then(|| data.get("bytes").and_then(Value::as_u64).unwrap_or(0))
}

fn one_row_too_large(bytes: u64) -> AppError {
    let message = format!(
        "a reply for one session is {:.1} MiB, past the {} MiB a daemon reply may hold: that \
         session's row is that large (read the sessions one by one with `acpmux session info \
         SESSION`), or this daemon is too old to page the list (update acpmux on it)",
        mib(bytes),
        crate::rpc::MAX_MESSAGE_BYTES >> 20
    );
    AppError::new(Code::Runtime, "message.too_large", message)
}

fn mib(bytes: u64) -> f64 {
    bytes as f64 / f64::from(1u32 << 20)
}

#[cfg(test)]
#[path = "ls_pages_tests.rs"]
mod tests;
