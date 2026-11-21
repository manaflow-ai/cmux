//! `acpmux monitor SESSION [--once]`: a read-only, redacted activity monitor for one chat.
//!
//! An experiment (hidden from help) for the personal-orchestration plan's read-only canary
//! (manaflow-ai/cmuxterm-hq `plans/feat-personal-orchestration/README.md`, Phases 0-1). It
//! sends the daemon only reads: [`resolve_id`] (`_acpmux/info`, then the session list), a
//! hidden `_acpmux/attach` (`limit: 0, visible: false`, to hear live notes without marking the
//! chat seen or attended) and `_acpmux/events`. It has no prompt, steer, cancel, permission or
//! process path, and it never starts a daemon.
//!
//! 1. Resolve the session through the daemon (never a guessed name).
//! 2. Print a `snapshot` envelope (`monitor_envelope`) with its `(generation, sequence)`
//!    cursor. `--once` stops here.
//! 3. Follow the event log from the cursor, one redacted `event` per record. A live note only
//!    wakes the reader; what it prints comes from the durable log, page by page.
//! 4. On a seq that skips, a new generation, or a lost connection, print a `gap`, take a new
//!    snapshot marked `resyncing`, and go on from its cursor.

use crate::cli::monitor_envelope::{Envelope, Event, Follower, GapReason, Snapshot, Step};
use crate::cli::orchestrate::expand_session_key;
use crate::cli::output::page_events;
use crate::cli::run::resolve_id;
use crate::cli::session_tail::{PAGE_RECORDS, unread};
use crate::client::Client;
use crate::rpc::{Message, method};
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::io::{self, Write};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// How many times in a row a lost daemon connection is retried before the monitor gives up.
const RECONNECTS: u32 = 5;

/// `acpmux monitor`.
pub(crate) async fn run(key: &str, once: bool, json_out: bool) -> Result<()> {
    let key = expand_session_key(key)?;
    let mut out = Out { json: json_out, w: io::stdout() };
    let client = connect().await?;
    let id = resolve_id(&client, &key).await?;
    let snap = snapshot(&client, &id, false).await?;
    if !out.put(&Envelope::Snapshot(snap.clone()))? || once {
        return Ok(());
    }
    tokio::select! {
        r = follow(client, id, snap, &mut out) => r,
        () = unread() => Ok(()),
    }
}

async fn follow(mut client: Arc<Client>, id: String, snap: Snapshot, out: &mut Out) -> Result<()> {
    let mut f = Follower::new(&snap);
    loop {
        let r = follow_connected(&client, &id, &mut f, out).await;
        match r {
            Ok(Conn::Done) => return Ok(()),
            Err(e) if !client.is_closed() => return Err(e),
            Ok(Conn::Lost) | Err(_) => {
                if !out.put(&Envelope::Gap(f.gap(GapReason::Disconnect, None)))? {
                    return Ok(());
                }
                // The next line is a fresh snapshot, or the monitor ends with the error.
                let (c, snap) = reconnect(&id).await?;
                client = c;
                f = Follower::new(&snap);
                if !out.put(&Envelope::Snapshot(snap))? {
                    return Ok(());
                }
            }
        }
    }
}

/// A new connection and a `resyncing` snapshot on it: up to [`RECONNECTS`] tries, backing off,
/// where a failed connect and a failed snapshot each count as one.
async fn reconnect(id: &str) -> Result<(Arc<Client>, Snapshot)> {
    let mut last = anyhow!("monitor: no reconnect tried");
    for failures in 1..=RECONNECTS {
        tokio::time::sleep(Duration::from_millis(500 << failures)).await;
        match connect().await {
            Ok(c) => match snapshot(&c, id, true).await {
                Ok(snap) => return Ok((c, snap)),
                Err(e) => last = e,
            },
            Err(e) => last = e,
        }
    }
    Err(last.context("monitor: the daemon connection was lost and did not come back"))
}

/// A connection with no caller identity, and no daemon autostart: the daemon ties a caller's
/// log reads to that caller (a parent reading its lane's finished turn marks the lane's report
/// read and drops it from the parent's queue, `hub/lane_report_reads.rs`), and an observer
/// must change nothing.
async fn connect() -> Result<Arc<Client>> {
    crate::daemon::connect_without_caller(false).await
}

/// How one connection's follow ended.
enum Conn {
    /// Stdout is gone: the monitor is done.
    Done,
    /// The daemon connection dropped: reconnect and resync.
    Lost,
}

/// Follows on one connection until it drops or stdout goes.
async fn follow_connected(
    client: &Arc<Client>,
    id: &str,
    f: &mut Follower,
    out: &mut Out,
) -> Result<Conn> {
    let mut notes =
        client.notifications().await.ok_or_else(|| anyhow!("notifications already taken"))?;
    // Subscribe before the first read, so a record written in between wakes a read.
    client.request(method::MUX_ATTACH, attach_params(id)).await?;
    loop {
        if !read_log(client, id, f, out).await? {
            return Ok(Conn::Done);
        }
        // Wait for a note of this chat, then drain what queued behind it: one read per burst.
        loop {
            let Some(m) = notes.recv().await else { return Ok(Conn::Lost) };
            if let Message::Notification { method: m, params } = m {
                if m == method::MUX_DISCONNECTED {
                    return Ok(Conn::Lost);
                }
                let p = params.unwrap_or(Value::Null);
                if crate::cli::resolve::routed_id(&p).ok().as_deref() == Some(id) {
                    break;
                }
            }
        }
        while notes.try_recv().is_ok() {}
    }
}

/// The monitor's subscription: no history (`limit: 0`) and hidden (`visible: false`), so it
/// neither marks the chat seen nor counts as someone watching it.
pub(crate) fn attach_params(id: &str) -> Value {
    json!({"sessionId": id, "limit": 0, "visible": false})
}

/// Reads every log record past the cursor and prints it; on a gap, re-snapshots. False once
/// stdout is gone.
///
/// A daemon restart changes the receipt's generation, and it also drops this connection, so
/// the reconnect in [`follow`] re-snapshots; no per-record generation read is needed here.
async fn read_log(client: &Arc<Client>, id: &str, f: &mut Follower, out: &mut Out) -> Result<bool> {
    loop {
        let before = f.cursor;
        let page = client
            .request(
                method::MUX_EVENTS,
                json!({"sessionId": id, "afterSeq": f.cursor.sequence, "limit": PAGE_RECORDS}),
            )
            .await?;
        let (records, more) = page_events(&page);
        if records.is_empty() {
            return Ok(true);
        }
        for rec in &records {
            let Some(e) = Event::from_record(id, f.cursor.generation, rec) else { continue };
            match f.accept(&e) {
                Step::Apply => {
                    if !out.put(&Envelope::Event(e))? {
                        return Ok(false);
                    }
                }
                Step::Duplicate | Step::Stale => {}
                Step::Gap(gap) => {
                    if !out.put(&Envelope::Gap(gap))? {
                        return Ok(false);
                    }
                    return resync(client, id, f, out).await;
                }
            }
        }
        // A page that moved the cursor nowhere would be asked for again forever: resync.
        if f.cursor == before {
            let got = records.last().and_then(|r| r.get("seq")).and_then(Value::as_u64);
            if !out.put(&Envelope::Gap(f.gap(GapReason::Sequence, got)))? {
                return Ok(false);
            }
            return resync(client, id, f, out).await;
        }
        if !more {
            return Ok(true);
        }
    }
}

/// A fresh snapshot marked `resyncing`; the follower restarts from its cursor. False once
/// stdout is gone.
async fn resync(client: &Arc<Client>, id: &str, f: &mut Follower, out: &mut Out) -> Result<bool> {
    let snap = snapshot(client, id, true).await?;
    *f = Follower::new(&snap);
    Ok(out.put(&Envelope::Snapshot(snap))?)
}

async fn snapshot(client: &Client, id: &str, resyncing: bool) -> Result<Snapshot> {
    let info = client.request(method::MUX_INFO, json!({"sessionId": id})).await?;
    Snapshot::from_info(&info, now_ms(), resyncing).ok_or_else(|| {
        anyhow!("the daemon's info for {id} has no session receipt generation or lastSeq")
    })
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

/// One line per envelope: JSON with `--json`, else a short human line.
struct Out<W: Write = io::Stdout> {
    json: bool,
    w: W,
}

impl<W: Write> Out<W> {
    /// False once nobody reads stdout.
    fn put(&mut self, e: &Envelope) -> io::Result<bool> {
        let line =
            if self.json { serde_json::to_string(e).map_err(io::Error::other)? } else { human(e) };
        match writeln!(self.w, "{line}").and_then(|()| self.w.flush()) {
            Ok(()) => Ok(true),
            Err(e) if e.kind() == io::ErrorKind::BrokenPipe => Ok(false),
            Err(e) => Err(e),
        }
    }
}

pub(crate) fn human(e: &Envelope) -> String {
    match e {
        Envelope::Snapshot(s) => format!(
            "snapshot{} {} {} gen={} seq={} perms={} age={}",
            if s.resyncing { " (resyncing)" } else { "" },
            s.agent.name.as_deref().unwrap_or(&s.session_id),
            s.state,
            s.cursor.generation,
            s.cursor.sequence,
            s.pending_permissions,
            s.freshness.age_ms.map_or("?".to_owned(), |a| format!("{}s", a / 1000)),
        ),
        Envelope::Event(e) => match &e.state {
            Some(st) => format!("{} {} {st}", e.sequence, e.kind),
            None => format!("{} {}", e.sequence, e.kind),
        },
        Envelope::Gap(g) => {
            format!("gap {:?} at seq={} got={:?}: resyncing", g.reason, g.cursor.sequence, g.got)
        }
        Envelope::Complete(c) => format!("complete {} {}", c.operation_id, c.state),
    }
}

#[cfg(test)]
#[path = "monitor_tests.rs"]
mod tests;
