//! `acpmux monitor SESSION [--once]`: a read-only, redacted activity monitor for one chat.
//!
//! An experiment (hidden from help) for the personal-orchestration plan's read-only canary
//! (manaflow-ai/cmuxterm-hq `plans/feat-personal-orchestration/README.md`, Phases 0-1). It
//! sends the daemon only reads: `_acpmux/sessions` through [`resolve_id`], `_acpmux/info`,
//! `_acpmux/attach` with `limit: 0` (to hear live notes) and `_acpmux/events`. It has no
//! prompt, steer, cancel, permission or process path.
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
    let client = crate::daemon::connect(true).await?;
    let id = resolve_id(&client, &key).await?;
    let snap = snapshot(&client, &id, false).await?;
    out.put(&Envelope::Snapshot(snap.clone()))?;
    if once {
        return Ok(());
    }
    tokio::select! {
        r = follow(client, id, snap, &mut out) => r,
        () = unread() => Ok(()),
    }
}

async fn follow(mut client: Arc<Client>, id: String, snap: Snapshot, out: &mut Out) -> Result<()> {
    let mut f = Follower::new(&snap);
    let mut failures = 0;
    loop {
        let r = follow_connected(&client, &id, &mut f, out).await;
        let lost = matches!(r, Ok(Conn::Lost)) || (r.is_err() && client.is_closed());
        match r {
            Ok(Conn::Done) => return Ok(()),
            _ if lost && failures < RECONNECTS => {
                failures += 1;
                out.put(&Envelope::Gap(f.gap(GapReason::Disconnect, None)))?;
                tokio::time::sleep(Duration::from_millis(500 << failures)).await;
                let Ok(c) = crate::daemon::connect(false).await else { continue };
                client = c;
                let snap = snapshot(&client, &id, true).await?;
                f = Follower::new(&snap);
                out.put(&Envelope::Snapshot(snap))?;
                failures = 0;
            }
            Ok(Conn::Lost) => return Err(client.closed("monitoring the session")),
            Err(e) => return Err(e),
        }
    }
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
    client.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await?;
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

/// Reads every log record past the cursor and prints it; on a gap, re-snapshots. False once
/// stdout is gone.
async fn read_log(client: &Arc<Client>, id: &str, f: &mut Follower, out: &mut Out) -> Result<bool> {
    loop {
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
        let mut status_seen = false;
        for rec in &records {
            let Some(e) = Event::from_record(id, f.cursor.generation, rec) else { continue };
            match f.accept(&e) {
                Step::Apply => {
                    status_seen |= e.kind == "status";
                    if !out.put(&Envelope::Event(e))? {
                        return Ok(false);
                    }
                }
                Step::Duplicate | Step::Stale => {}
                Step::Gap(gap) => {
                    out.put(&Envelope::Gap(gap))?;
                    resync(client, id, f, out).await?;
                    return Ok(true);
                }
            }
        }
        // A status record may follow a restart: check the generation then, not per record.
        if status_seen {
            let info = client.request(method::MUX_INFO, json!({"sessionId": id})).await?;
            let generation = info.pointer("/sessionReceipt/generation").and_then(Value::as_u64);
            if let Some(gap) = generation.and_then(|g| f.check_generation(g)) {
                out.put(&Envelope::Gap(gap))?;
                resync(client, id, f, out).await?;
                return Ok(true);
            }
        }
        if !more {
            return Ok(true);
        }
    }
}

async fn resync(client: &Arc<Client>, id: &str, f: &mut Follower, out: &mut Out) -> Result<()> {
    let snap = snapshot(client, id, true).await?;
    *f = Follower::new(&snap);
    out.put(&Envelope::Snapshot(snap))?;
    Ok(())
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
