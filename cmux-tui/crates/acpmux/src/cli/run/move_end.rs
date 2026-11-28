//! One end of a move (`transfer.rs`): the client of a daemon the move pages through, and how to
//! reach that daemon again when its connection drops.
//!
//! A move from another machine pages the bundle through two `ssh -L` forwards
//! (`ssh_forward.rs`), each a connection the move's client cannot do without: on a laptop
//! (2026-11-23) moves from one fleet VM to another lost `_acpmux/transfer_read` and
//! `transfer_write` connections mid-move, one move waited 30 minutes on a reply that never came,
//! and a move that failed so left its chat frozen ("it is being moved already") with no one to
//! end it. So:
//!
//! - every request has a deadline ([`PAGE_WAIT`], [`FINISH_WAIT`]); past it the connection is
//!   taken as dropped;
//! - a dropped connection is opened again (a new forward for a remote daemon) and the request
//!   asked again where that is safe: a read by offset, a write the target checks by offset
//!   (`transfer_in.rs` answers an out-of-place page with the size it has, and the copy goes on
//!   from there), an abort or commit of one move;
//! - each move is noted in a journal (`moves/` under this machine's acpmux home) while it is
//!   under way. A move whose client died (killed at a timeout, its machine asleep) is ended by the
//!   next `session move` here: the target says whether the chat landed (`transfer_forget`, which
//!   also refuses any late finish), and the source commits or aborts.

use super::*;
use crate::ssh_forward::Forward;
use anyhow::bail;
use cmux_json::JsonSet as _;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

/// The longest one page (read or write), receive, abort or commit waits for its answer before the
/// connection is taken as dropped. A page is at most `MAX_PAGE` (4 MiB) of data.
pub(crate) const PAGE_WAIT: Duration = Duration::from_secs(120);
/// The longest `transfer_finish` waits: it imports the whole chat on the target.
pub(crate) const FINISH_WAIT: Duration = Duration::from_secs(900);
/// How many times one end is reached again in one move.
pub(crate) const REOPENS: u32 = 6;
/// How long one reconnect keeps trying its daemon: a daemon swapped mid-move (an update, a
/// take-over) is back at the same socket within this.
pub(crate) const RECONNECT_FOR: Duration = Duration::from_secs(120);
/// The pause between two tries of one reconnect.
const RECONNECT_EVERY: Duration = Duration::from_millis(500);

/// Which deadline a request has.
#[derive(Clone, Copy, Debug)]
pub(crate) enum Wait {
    /// [`PAGE_WAIT`].
    Page,
    /// [`FINISH_WAIT`].
    Finish,
    /// No deadline of this client's own: the daemon bounds its wait itself (a freeze that waits
    /// for the running turn or its tool call).
    Turn,
}

/// How a daemon is reached again.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub(crate) enum Reach {
    /// Its socket on this machine.
    Socket { path: PathBuf },
    /// Its socket on the ssh host `host`, through a new forward.
    Ssh { host: String, socket: String },
}

/// A request that had no answer within its deadline: the connection is taken as dropped.
#[derive(Debug)]
pub(crate) struct Stalled(pub String);

impl std::fmt::Display for Stalled {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Stalled {}

/// Whether `e` is a connection that ended or stalled, not a daemon's answer.
pub(crate) fn dropped(e: &anyhow::Error) -> bool {
    e.downcast_ref::<crate::client::TransportClosed>().is_some()
        || e.downcast_ref::<Stalled>().is_some()
}

/// One end of a move: the client it uses now, and how to reach its daemon again.
pub(crate) struct MoveEnd<'a> {
    /// `source` or `target`, for the lines this says.
    what: &'static str,
    first: &'a Client,
    /// The client of the latest reconnect, once there was one.
    now: Option<Arc<Client>>,
    reach: Option<Reach>,
    forward: Option<Forward>,
    reopens: u32,
    /// Its [`Wait::Page`] and [`Wait::Finish`] deadlines.
    waits: (Duration, Duration),
    /// How long one reconnect keeps trying ([`RECONNECT_FOR`]).
    reconnect_for: Duration,
}

impl<'a> MoveEnd<'a> {
    pub(crate) fn new(what: &'static str, client: &'a Client, reach: Option<Reach>) -> Self {
        let waits = (PAGE_WAIT, FINISH_WAIT);
        let reconnect_for = RECONNECT_FOR;
        Self {
            what,
            first: client,
            now: None,
            reach,
            forward: None,
            reopens: 0,
            waits,
            reconnect_for,
        }
    }

    /// With other deadlines than [`PAGE_WAIT`] and [`FINISH_WAIT`] (a test's).
    #[cfg(test)]
    pub(crate) fn with_waits(mut self, page: Duration, finish: Duration) -> Self {
        self.waits = (page, finish);
        self.reconnect_for = page;
        self
    }

    pub(crate) fn client(&self) -> &Client {
        self.now.as_deref().unwrap_or(self.first)
    }

    /// The client it reopened after a dropped link, if it did: owned, for a caller that needs an
    /// `Arc` (the first client is only borrowed).
    pub(crate) fn reopened(&self) -> Option<Arc<Client>> {
        self.now.clone()
    }

    pub(crate) fn reach(&self) -> Option<&Reach> {
        self.reach.as_ref()
    }

    /// Ends its forward, if it has one.
    pub(crate) async fn close(self) {
        if let Some(forward) = self.forward {
            forward.close().await;
        }
    }

    /// Reaches the daemon again: a new connection (through a new forward for an ssh host).
    pub(crate) async fn reopen(&mut self) -> Result<()> {
        let Some(reach) = self.reach.clone() else {
            bail!("the {} cannot be reached again", self.what);
        };
        if self.reopens >= REOPENS {
            bail!("the connection to the {} dropped {} times in this move", self.what, REOPENS);
        }
        self.reopens += 1;
        tokio::time::sleep(Duration::from_millis(200) * self.reopens).await;
        // A daemon being swapped is not there for a moment: tried until it is, or the bound.
        let until = tokio::time::Instant::now() + self.reconnect_for;
        let (client, forward) = loop {
            match connect_reach(&reach).await {
                Ok(reached) => break reached,
                Err(e) if tokio::time::Instant::now() >= until => return Err(e),
                Err(_) => tokio::time::sleep(RECONNECT_EVERY).await,
            }
        };
        // The old forward (if any) ends here, and the old client with it.
        self.forward = forward;
        self.now = Some(client);
        Ok(())
    }

    /// [`Self::call`] for a request that is safe to ask again (a read, a stage, a progress
    /// note), within [`FINISH_WAIT`].
    pub(crate) async fn request(&mut self, m: &str, params: Value) -> Result<Value> {
        self.call(m, params, Wait::Finish, true).await
    }

    /// `m` with `params`, its answer within `wait`. A dropped or stalled connection is opened
    /// again, and with `retry` the request is asked again on it; without, the dropped error is
    /// the answer, and the end is connected again for whatever the caller asks next.
    pub(crate) async fn call(
        &mut self,
        m: &str,
        params: Value,
        wait: Wait,
        retry: bool,
    ) -> Result<Value> {
        let wait = match wait {
            Wait::Page => Some(self.waits.0),
            Wait::Finish => Some(self.waits.1),
            Wait::Turn => None,
        };
        loop {
            let asked = self.client().request(m, params.clone());
            let answer = match wait {
                None => asked.await,
                Some(wait) => match tokio::time::timeout(wait, asked).await {
                    Ok(answer) => answer,
                    Err(_) => Err(anyhow::Error::new(Stalled(format!(
                        "no answer to {m} from the {} within {}s",
                        self.what,
                        wait.as_secs()
                    )))),
                },
            };
            let e = match answer {
                Err(e) if dropped(&e) && self.reach.is_some() => e,
                other => return other,
            };
            eprintln!(
                "acpmux: the connection to the move's {} dropped ({e:#}); reconnecting",
                self.what
            );
            if let Err(again) = self.reopen().await {
                return Err(e.context(format!("{again:#}")));
            }
            if !retry {
                return Err(e);
            }
        }
    }
}

/// A client of the daemon `reach` names, initialized, and the forward it goes through.
pub(crate) async fn connect_reach(reach: &Reach) -> Result<(Arc<Client>, Option<Forward>)> {
    let (client, forward) = match reach {
        Reach::Socket { path } => (Client::connect(path).await?, None),
        Reach::Ssh { host, socket } => {
            let forward = Forward::open(host, socket).await?;
            (Client::connect(&forward.local).await?, Some(forward))
        }
    };
    let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "acpmux-move"}});
    client.request(method::INITIALIZE, hello).await?;
    Ok((client, forward))
}

/// A move under way, as its journal entry keeps it (`moves/<transferId>.json`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Journal {
    pub session_id: String,
    pub transfer_id: String,
    pub epoch: u64,
    /// The process that moves it.
    pub pid: u32,
    pub src: Reach,
    pub dst: Reach,
    /// What the source's commit records as where the chat went.
    pub to: Value,
}

/// Where the journal is.
pub(crate) fn journal_dir() -> PathBuf {
    crate::config::home().join("moves")
}

fn journal_path(dir: &Path, transfer_id: &str) -> Option<PathBuf> {
    let plain = !transfer_id.is_empty()
        && transfer_id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
    plain.then(|| dir.join(format!("{transfer_id}.json")))
}

impl Journal {
    /// Notes the move as under way. A move with no way to reach either end again is not noted:
    /// nothing could end it from here.
    pub(crate) fn note(&self, dir: &Path) {
        let Some(path) = journal_path(dir, &self.transfer_id) else { return };
        let _ = crate::home_fs::create_dirs(dir);
        if let Ok(text) = serde_json::to_vec(self) {
            let _ = crate::home_fs::write(path, text);
        }
    }

    /// The move ended (committed, aborted, or the chat is known to be where it is).
    pub(crate) fn done(dir: &Path, transfer_id: &str) {
        if let Some(path) = journal_path(dir, transfer_id) {
            let _ = crate::home_fs::remove_file(path);
        }
    }

    fn all(dir: &Path) -> Vec<Journal> {
        let Ok(entries) = std::fs::read_dir(dir) else { return Vec::new() };
        entries
            .flatten()
            .filter_map(|e| std::fs::read(e.path()).ok())
            .filter_map(|bytes| serde_json::from_slice(&bytes).ok())
            .collect()
    }
}

/// Whether process `pid` still runs (a move it began is still its own).
fn alive(pid: u32) -> bool {
    #[cfg(unix)]
    {
        if pid == std::process::id() {
            return true;
        }
        let Ok(pid) = libc::pid_t::try_from(pid) else { return false };
        // SAFETY: signal 0 only checks that the pid exists.
        let sent = unsafe { libc::kill(pid, 0) } == 0;
        sent || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
    }
    #[cfg(not(unix))]
    {
        let _ = pid;
        true
    }
}

/// How a dead move ended.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Reclaimed {
    /// The target has the chat: the source committed the move.
    Committed,
    /// The target does not, and now refuses it: the source gave the chat back.
    Aborted,
}

/// Ends every move in the journal at `dir` whose client is gone: the target is asked
/// (`transfer_forget`), then the source commits or aborts. A move either end cannot answer for
/// stays noted, for the next run. Returns each ended move's chat and how it ended.
pub(crate) async fn reclaim_dead_moves(dir: &Path) -> Vec<(String, Reclaimed)> {
    let mut ended = Vec::new();
    for j in Journal::all(dir) {
        if alive(j.pid) {
            continue;
        }
        match reclaim(&j).await {
            Ok(how) => {
                eprintln!(
                    "acpmux: a move of {} whose client went away ended: {}",
                    j.session_id,
                    match how {
                        Reclaimed::Committed => "the target has the chat; the source committed it",
                        Reclaimed::Aborted =>
                            "the target never took it; the chat runs where it was",
                    }
                );
                Journal::done(dir, &j.transfer_id);
                ended.push((j.session_id.clone(), how));
            }
            Err(e) => eprintln!(
                "acpmux: a move of {} whose client went away could not be ended yet: {e:#}",
                j.session_id
            ),
        }
    }
    ended
}

async fn reclaim(j: &Journal) -> Result<Reclaimed> {
    let (dst, _dst_forward) = within("reaching the target", connect_reach(&j.dst)).await??;
    let forget = json!({"transferId": j.transfer_id, "sessionId": j.session_id});
    let answer =
        within("transfer_forget", dst.request("_acpmux/transfer_forget", forget)).await??;
    let landed = answer["landed"].as_bool().ok_or_else(|| anyhow!("transfer_forget: {answer}"))?;
    let (src, _src_forward) = within("reaching the source", connect_reach(&j.src)).await??;
    let mut params =
        json!({"sessionId": j.session_id, "transferId": j.transfer_id, "epoch": j.epoch});
    let (m, how) = if landed {
        params.set("to", j.to.clone());
        ("_acpmux/transfer_commit", Reclaimed::Committed)
    } else {
        ("_acpmux/transfer_abort", Reclaimed::Aborted)
    };
    match within(m, src.request(m, params)).await? {
        Ok(_) => Ok(how),
        // The source ended it already (its own watch, or an earlier run of this): nothing is
        // left to end.
        Err(e) if gone_already(&e) => Ok(how),
        Err(e) => Err(e),
    }
}

/// `f`'s output within [`PAGE_WAIT`].
async fn within<T>(what: &str, f: impl std::future::Future<Output = T>) -> Result<T> {
    tokio::time::timeout(PAGE_WAIT, f)
        .await
        .map_err(|_| anyhow!("{what}: no answer within {}s", PAGE_WAIT.as_secs()))
}

/// Whether the source answered that the move is not under way any more.
fn gone_already(e: &anyhow::Error) -> bool {
    let text = format!("{e:#}").to_lowercase();
    text.contains("transfer.unknown")
        || text.contains("not being moved")
        || text.contains("no move")
}

// The fake daemon listens on a unix socket.
#[cfg(all(test, unix))]
#[path = "move_end_tests.rs"]
mod tests;
