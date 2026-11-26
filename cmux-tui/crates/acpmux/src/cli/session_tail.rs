//! `acpmux session tail NAME [--since CURSOR] [--last N] [-f]`: a chat's events as JSON lines.
//!
//! It streams. It holds one page of the log at a time (the daemon's page: about
//! `hub::DEFAULT_PAGE_BYTES` of records, never less than one record), writes it out, and reads
//! the next page only once that one is written. A reader that stops reading stops the tail
//! (backpressure), and a reader that is gone ends it on the first write (SIGPIPE, or the write
//! error where SIGPIPE is ignored). The tail used to read every record after the cursor into
//! memory first and print only at the end: `--since 39` of a 12 GB, 1.1M-record chat grew to
//! 30 GB, and since it wrote nothing until then, a caller that had left never stopped it.
//!
//! Live events (`-f`) arrive on the client's notification queue, which holds at most
//! 4096 messages and drops the newest past that (`client.rs`).
//!
//! A tail with nothing to write (a quiet chat under `-f`) learns that its reader is gone from
//! [`unread`]: it ends once its stdout pipe's reader closed, or once its parent is
//! gone (reparented to init or a subreaper) while its stdout has no reader to ask (`/dev/null`,
//! a terminal). SIGHUP keeps its default action, ending the process.

use crate::cli::orchestrate::{ReadSuppressor, expand_session_key, parse_cursor};
use crate::cli::output::page_events;
use crate::cli::run::resolve_id;
use crate::client::Client;
use crate::rpc::{Message, method};
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::io::{self, Write};
use std::sync::Arc;
use std::time::Duration;

/// The most records one page read asks for; the daemon's byte bound per page
/// (`hub::DEFAULT_PAGE_BYTES`) is usually the smaller.
pub(crate) const PAGE_RECORDS: u64 = 10_000;

/// How often [`unread`] checks its stdout and parent.
pub(crate) const UNREAD_CHECK: Duration = Duration::from_secs(1);

/// Whether the tail goes on: `Stop` once its output is gone.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Flow {
    Go,
    Stop,
}

/// `acpmux session tail`.
pub(crate) async fn tail(
    client: Arc<Client>,
    key: &str,
    last: u64,
    since: Option<String>,
    follow: bool,
    suppress_reads: bool,
) -> Result<()> {
    let id = resolve_id(&client, &expand_session_key(key)?).await?;
    let notes =
        client.notifications().await.ok_or_else(|| anyhow!("notifications already taken"))?;
    // Whichever comes first: the tail's own end, or nobody left to read it (`unread`).
    tokio::select! {
        r = run(&client, &id, last, since, follow, suppress_reads, notes) => r,
        () = unread() => Ok(()),
    }
}

async fn run(
    client: &Arc<Client>,
    id: &str,
    last: u64,
    since: Option<String>,
    follow: bool,
    suppress_reads: bool,
    mut notes: tokio::sync::mpsc::Receiver<Message>,
) -> Result<()> {
    let (client, id) = (client.clone(), id.to_owned());
    let mut out = Out::new(&id, suppress_reads, io::stdout());
    let flow = match since {
        Some(cursor) if cursor == "seen" => {
            if follow {
                client
                    .request(
                        method::MUX_ATTACH,
                        json!({"sessionId": id, "limit": 0, "visible": false}),
                    )
                    .await?;
            }
            stream_seen(&client, &id, &mut out).await?
        }
        Some(cursor) => {
            let seq = parse_cursor(&cursor, &id)?;
            // Subscribe before reading from the cursor, so an event written
            // in between arrives live; the seq check below drops repeats.
            client.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await?;
            stream_after(&client, &id, seq, None, |page| out.events(page)).await?
        }
        None => stream_last(&client, &id, last, &mut out).await?,
    };
    if flow == Flow::Stop || !follow {
        return Ok(());
    }
    while let Some(m) = notes.recv().await {
        if let Message::Notification { method: m, params } = m {
            if m == method::MUX_DISCONNECTED {
                return Err(client.closed("following the session"));
            }
            if out.live(&m, params.unwrap_or(Value::Null))? == Flow::Stop {
                return Ok(());
            }
        }
    }
    Ok(())
}

/// The reader's cutover and the end of this recap are both fixed by the first page.
async fn stream_seen<W: Write>(client: &Arc<Client>, id: &str, out: &mut Out<W>) -> Result<Flow> {
    let first = client
        .request(
            method::MUX_EVENTS,
            json!({"sessionId": id, "sinceSeen": true, "limit": PAGE_RECORDS}),
        )
        .await?;
    // Older daemons ignore additional event parameters and would return ordinary history.
    let seen =
        first.get("seenSeq").ok_or_else(|| anyhow!("this daemon does not support --since seen"))?;
    let end = first["lastSeq"].as_u64().ok_or_else(|| anyhow!("missing recap end cursor"))?;
    if seen.is_null() {
        out.printed_seq = end;
        return Ok(Flow::Go);
    }
    let start = seen.as_u64().ok_or_else(|| anyhow!("invalid reader cutover"))?;
    let (mut records, more) = page_events(&first);
    drop(first);
    records.retain(|event| event["seq"].as_u64().is_some_and(|seq| seq > start && seq <= end));
    out.printed_seq = start;
    if out.events(records)? == Flow::Stop {
        return Ok(Flow::Stop);
    }
    if more {
        return stream_after(client, id, out.printed_seq, Some(end), |page| out.events(page)).await;
    }
    Ok(Flow::Go)
}

/// The newest `last` events, oldest first: the attach's own page, and before it, read forward
/// from where the `last`th newest begins. Only the attach's page is held while the older ones
/// are written.
async fn stream_last<W: Write>(
    client: &Arc<Client>,
    id: &str,
    last: u64,
    out: &mut Out<W>,
) -> Result<Flow> {
    let page = client.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": last})).await?;
    let (events, more) = page_events(&page);
    let first = events.first().and_then(|e| e.get("seq")).and_then(Value::as_u64);
    if let Some(first) = first
        && more
        && (events.len() as u64) < last
    {
        let need = last - events.len() as u64;
        let from = start_of_older(client, id, first, need).await?;
        let until = Some(first - 1);
        if stream_after(client, id, from, until, |page| out.events(page)).await? == Flow::Stop {
            return Ok(Flow::Stop);
        }
    }
    Ok(out.events(events)?)
}

/// The cursor to read forward from for the `need` records before seq `before`: it pages back
/// through them, keeping only the oldest seq seen.
async fn start_of_older(client: &Arc<Client>, id: &str, mut before: u64, need: u64) -> Result<u64> {
    let mut need = need;
    while need > 0 {
        let page = client
            .request(
                method::MUX_EVENTS,
                json!({"sessionId": id, "beforeSeq": before, "limit": need.min(PAGE_RECORDS)}),
            )
            .await?;
        let (events, more) = page_events(&page);
        let Some(oldest) = events.first().and_then(|e| e.get("seq")).and_then(Value::as_u64) else {
            break;
        };
        need = need.saturating_sub(events.len() as u64);
        before = oldest;
        if !more {
            break;
        }
    }
    Ok(before.saturating_sub(1))
}

/// Every event after seq `after` (through `until`, when given), oldest first, one page at a
/// time: `page` gets each page and the next is read only after it returns, so at most one page
/// is held. Ends at the log's end, or at once when `page` says [`Flow::Stop`].
pub(crate) async fn stream_after(
    client: &Arc<Client>,
    id: &str,
    mut after: u64,
    until: Option<u64>,
    mut page: impl FnMut(Vec<Value>) -> io::Result<Flow>,
) -> Result<Flow> {
    loop {
        if until.is_some_and(|u| after >= u) {
            return Ok(Flow::Go);
        }
        let v = client
            .request(
                method::MUX_EVENTS,
                json!({"sessionId": id, "afterSeq": after, "limit": PAGE_RECORDS}),
            )
            .await?;
        let (mut events, more) = page_events(&v);
        drop(v);
        let Some(last) = events.last().and_then(|e| e.get("seq")).and_then(Value::as_u64) else {
            return Ok(Flow::Go);
        };
        let done = !more || until.is_some_and(|u| last >= u);
        if let Some(u) = until {
            events.retain(|e| e.get("seq").and_then(Value::as_u64).is_none_or(|s| s <= u));
        }
        // A seq that does not move on would read the same page forever.
        if last <= after {
            return Ok(Flow::Go);
        }
        after = last;
        if page(events)? == Flow::Stop {
            return Ok(Flow::Stop);
        }
        if done {
            return Ok(Flow::Go);
        }
    }
}

/// The tail's output: one JSON line per event, with its cursor, reads blanked when asked.
pub(crate) struct Out<W: Write> {
    id: String,
    suppress_reads: bool,
    sup: ReadSuppressor,
    /// The newest seq written: a live event at or below it was in a page.
    printed_seq: u64,
    w: W,
}

impl<W: Write> Out<W> {
    pub(crate) fn new(id: &str, suppress_reads: bool, w: W) -> Self {
        Self {
            id: id.to_owned(),
            suppress_reads,
            sup: ReadSuppressor::default(),
            printed_seq: 0,
            w,
        }
    }

    /// Writes a page's events; [`Flow::Stop`] once the output is gone.
    pub(crate) fn events(&mut self, events: Vec<Value>) -> io::Result<Flow> {
        for e in events {
            let seq = e.get("seq").and_then(Value::as_u64).unwrap_or(0);
            self.printed_seq = self.printed_seq.max(seq);
            let e = self.filter(e);
            if self.line(&with_cursor(&self.id, e))? == Flow::Stop {
                return Ok(Flow::Stop);
            }
        }
        Ok(Flow::Go)
    }

    /// Writes one live notification of this chat; others are skipped.
    fn live(&mut self, m: &str, p: Value) -> io::Result<Flow> {
        if crate::cli::resolve::routed_id(&p).ok().as_deref() != Some(self.id.as_str()) {
            return Ok(Flow::Go);
        }
        let seq = if m == method::MUX_EVENT {
            p.get("seq").and_then(Value::as_u64)
        } else {
            p.pointer("/_meta/acpmux/seq").and_then(Value::as_u64)
        };
        if seq.is_some_and(|s| s <= self.printed_seq) {
            return Ok(Flow::Go);
        }
        let line = if m == method::MUX_EVENT {
            let e = self.filter(p);
            with_cursor(&self.id, e)
        } else if m == method::SESSION_UPDATE && self.suppress_reads {
            json!({"method": m, "params": self.sup.apply_update(p)})
        } else {
            json!({"method": m, "params": p})
        };
        self.line(&line)
    }

    fn filter(&mut self, e: Value) -> Value {
        if self.suppress_reads { self.sup.apply(e) } else { e }
    }

    /// One line, flushed: a closed pipe shows on this write, not at exit.
    fn line(&mut self, v: &Value) -> io::Result<Flow> {
        match writeln!(self.w, "{v}").and_then(|()| self.w.flush()) {
            Ok(()) => Ok(Flow::Go),
            Err(e) if gone(&e) => Ok(Flow::Stop),
            Err(e) => Err(e),
        }
    }
}

/// A write error that means nobody reads the output any more.
fn gone(e: &io::Error) -> bool {
    matches!(
        e.kind(),
        io::ErrorKind::BrokenPipe | io::ErrorKind::ConnectionReset | io::ErrorKind::NotConnected
    )
}

pub(crate) fn with_cursor(id: &str, mut e: Value) -> Value {
    if let Some(seq) = e.get("seq").and_then(Value::as_u64) {
        e["cursor"] = json!(format!("{id}:{seq}"));
    }
    e
}

/// Resolves once nobody can read the tail's output:
///
/// - its stdout is a pipe or socket whose reader closed, whatever its parent;
/// - or its parent at the time of this call is gone (reparented to init or a subreaper) and its
///   stdout has no reader to ask: `/dev/null`, a terminal, or closed.
///
/// A pipe whose reader is alive keeps the tail when its parent goes: the reader decides (a
/// relay that ended on a changed parent alone cut live ssh sessions, hq handbook
/// `process-outlives-its-reader`, 2026-11-15). A regular file keeps it too: a tail writing to a
/// file was put there on purpose (`nohup ... > log &`). A thread checks every [`UNREAD_CHECK`],
/// so a write blocked on a full pipe does not stop the check; with no thread (or off Unix) this
/// never resolves and the tail ends on a write only.
pub(crate) async fn unread() {
    #[cfg(unix)]
    {
        let parent = crate::parent_watch::parent_pid();
        let kind = stdout_kind();
        let (tx, rx) = tokio::sync::oneshot::channel();
        let watch = std::thread::Builder::new().name("tail-unread".into()).spawn(move || {
            loop {
                if tx.is_closed() {
                    return;
                }
                if stdout_reader_gone(UNREAD_CHECK)
                    || (kind == Stdout::Unread && parent_gone(parent))
                {
                    let _ = tx.send(());
                    return;
                }
            }
        });
        match watch {
            Ok(_) => {
                if rx.await.is_ok() {
                    return;
                }
            }
            Err(error) => {
                tracing::warn!("session tail: no unread watch, it ends on a write only: {error}");
            }
        }
    }
    std::future::pending::<()>().await
}

/// Whether this process's parent is no longer `parent`.
#[cfg(unix)]
pub(crate) fn parent_gone(parent: u32) -> bool {
    crate::parent_watch::parent_pid() != parent
}

/// What stdout is, for [`unread`].
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Stdout {
    /// A pipe or socket: its reader's close shows as POLLERR or POLLHUP.
    Read,
    /// A regular file, kept on purpose.
    File,
    /// A character device (`/dev/null`, a terminal) or nothing: no reader to ask.
    Unread,
}

#[cfg(unix)]
pub(crate) fn stdout_kind() -> Stdout {
    fd_kind(1)
}

#[cfg(unix)]
pub(crate) fn fd_kind(fd: libc::c_int) -> Stdout {
    // SAFETY: an all-zero stat is a valid out value; fstat fills it.
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: a descriptor number and a valid out pointer.
    if unsafe { libc::fstat(fd, &mut st) } != 0 {
        return Stdout::Unread;
    }
    match st.st_mode & libc::S_IFMT {
        libc::S_IFIFO | libc::S_IFSOCK => Stdout::Read,
        libc::S_IFREG => Stdout::File,
        _ => Stdout::Unread,
    }
}

/// Waits up to `wait` for stdout to report an error or hangup: on a pipe, its reader closed.
/// A terminal or a file never does. Asks for no readiness (`events: 0`), so a writable pipe
/// does not wake it.
#[cfg(unix)]
pub(crate) fn stdout_reader_gone(wait: Duration) -> bool {
    fd_reader_gone(1, wait)
}

#[cfg(unix)]
pub(crate) fn fd_reader_gone(fd: libc::c_int, wait: Duration) -> bool {
    let mut p = libc::pollfd { fd, events: 0, revents: 0 };
    let ms = libc::c_int::try_from(wait.as_millis()).unwrap_or(libc::c_int::MAX);
    // SAFETY: one valid pollfd.
    let n = unsafe { libc::poll(&mut p, 1, ms) };
    if n <= 0 {
        if n < 0 {
            // EINTR or worse: wait as the caller asked before checking again.
            std::thread::sleep(wait);
        }
        return false;
    }
    // POLLNVAL: fd 1 was closed; nothing can be written.
    p.revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0
}

#[cfg(test)]
#[path = "session_tail_tests.rs"]
mod tests;
