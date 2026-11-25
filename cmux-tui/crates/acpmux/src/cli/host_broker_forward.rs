//! `acpmux machine broker-forward OWNER... --socket PATH` (RFD 0127 cut 2): a lane machine's own
//! socket for its lane-gh broker that runs over the held carrier link instead of an `ssh -R`
//! forward. Each connection to PATH opens one `_acpmux/remote.pipe`
//! `{machine: OWNER, service: "lane-gh-broker"}` on this machine's daemon and carries its bytes,
//! so `LANE_GH_SOCKET=PATH lane-gh ...` uses it. It reaches the daemon fresh each time, so it
//! outlives a daemon restart. Opt-in: the `ssh -R` socket stays where `lane-gh` looks by default.
//!
//! Several owners (fleet-dogfoods-remote move 3, failure class 5): with more than one OWNER the
//! forward fails over between them, which the fleet does today with a primary broker and cold
//! standbys that take a machine over only after two empty 60 s checks.
//!
//! - **Chosen by progress, not by the link.** Every [`HEALTH_EVERY`] each owner gets a real
//!   lane-gh `ping` through its own pipe, and counts healthy only when the broker answers
//!   `"ok": true` within [`HEALTH_BOUND`]. A link that is up in front of a stalled broker (the
//!   2026-11-22 class: pings 170 s) counts as down.
//! - **A connection goes to the first healthy owner**, in the order given, then to owners not
//!   checked yet, then to the rest. An owner whose pipe will not open is marked down at once and
//!   the next is tried. Opening a pipe sends none of the client's bytes, so moving on can never
//!   run a call twice; once a byte is sent the call stays with that owner.
//! - **Owner records are stored with the peer**: [`OwnerRecord`] rows (healthy, round trip, when
//!   checked, last error, calls carried) in `~/.acpmux/broker-owners/<socket name>.json`, written
//!   after each check, so a restart starts from the last pick and `cat` shows why it was made.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};

use crate::rpc::{Message, method};

/// How often every owner gets a progress check.
pub const HEALTH_EVERY: Duration = Duration::from_secs(15);
/// How long a check's pipe and ping may take before the owner counts as down. A healthy broker
/// answers a ping in about 0.2 s (RFD 0039: `lane-gh check` p50 0.22 s, p90 0.30 s on cmux-cp-1);
/// one past this is too slow to send calls to while another owner answers.
pub const HEALTH_BOUND: Duration = Duration::from_secs(5);
/// How long opening one owner's pipe may take for a connection before the next owner is tried.
pub const OPEN_BOUND: Duration = Duration::from_secs(5);

/// What this forward knows of one owner (module docs).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OwnerRecord {
    pub owner: String,
    /// The last check's verdict; `None` until one ran.
    pub healthy: Option<bool>,
    /// The last good check's pipe-and-ping round trip.
    pub rtt_ms: Option<u64>,
    /// When the last check ended (unix seconds).
    pub checked_at: Option<u64>,
    /// Why the last failed check or open failed.
    pub error: Option<String>,
    /// Connections carried to this owner since this forward started.
    pub carried: u64,
}

/// The owners in the order given, and what is known of each.
#[derive(Debug)]
pub struct Owners {
    records: Mutex<Vec<OwnerRecord>>,
    file: Option<PathBuf>,
}

impl Owners {
    pub fn new(owners: &[String], file: Option<PathBuf>) -> Self {
        // A record left by an earlier run of this forward seeds the verdicts, never the order.
        let saved: Vec<OwnerRecord> = file
            .as_deref()
            .and_then(|f| std::fs::read(f).ok())
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        let mut seen = std::collections::HashSet::new();
        let records = owners
            .iter()
            .filter(|o| seen.insert(o.as_str()))
            .map(|o| {
                let old = saved.iter().find(|r| &r.owner == o);
                OwnerRecord {
                    owner: o.clone(),
                    healthy: old.and_then(|r| r.healthy),
                    rtt_ms: old.and_then(|r| r.rtt_ms),
                    checked_at: old.and_then(|r| r.checked_at),
                    error: old.and_then(|r| r.error.clone()),
                    carried: 0,
                }
            })
            .collect();
        Self { records: Mutex::new(records), file }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<OwnerRecord>> {
        self.records.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The owners a connection tries, in turn: healthy, then unchecked, then down, each group
    /// in the order given.
    pub fn order(&self) -> Vec<String> {
        let records = self.lock();
        let rank = |r: &OwnerRecord| match r.healthy {
            Some(true) => 0,
            None => 1,
            Some(false) => 2,
        };
        let mut ranked: Vec<(usize, &OwnerRecord)> = records.iter().map(|r| (rank(r), r)).collect();
        ranked.sort_by_key(|(rank, _)| *rank);
        ranked.into_iter().map(|(_, r)| r.owner.clone()).collect()
    }

    pub fn records(&self) -> Vec<OwnerRecord> {
        self.lock().clone()
    }

    /// A check's or an open's verdict on `owner`.
    pub fn note(&self, owner: &str, verdict: Result<Duration, String>) {
        let mut records = self.lock();
        let Some(r) = records.iter_mut().find(|r| r.owner == owner) else { return };
        r.checked_at = Some(now_s());
        match verdict {
            Ok(rtt) => {
                r.healthy = Some(true);
                r.rtt_ms = Some(u64::try_from(rtt.as_millis()).unwrap_or(u64::MAX));
                r.error = None;
            }
            Err(why) => {
                r.healthy = Some(false);
                r.error = Some(why);
            }
        }
    }

    fn carried(&self, owner: &str) {
        if let Some(r) = self.lock().iter_mut().find(|r| r.owner == owner) {
            r.carried += 1;
        }
    }

    /// Write the records beside the peer state; a failed write costs only the record.
    pub fn save(&self) {
        let Some(file) = &self.file else { return };
        let body = match serde_json::to_vec_pretty(&self.records()) {
            Ok(b) => b,
            Err(_) => return,
        };
        if let Some(dir) = file.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let tmp = file.with_extension("json.tmp");
        if std::fs::write(&tmp, body).is_ok() {
            let _ = std::fs::rename(&tmp, file);
        }
    }
}

fn now_s() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// Where the owner records of the forward listening at `socket` live.
pub fn records_file(socket: &Path) -> PathBuf {
    let name = socket.file_name().and_then(|n| n.to_str()).unwrap_or("broker");
    crate::config::home().join("broker-owners").join(format!("{name}.json"))
}

pub async fn run(owners: Vec<String>, socket: PathBuf) -> Result<()> {
    if owners.is_empty() {
        return Err(anyhow!("broker-forward needs at least one OWNER"));
    }
    let listener = bind(&socket)?;
    let owners = Arc::new(Owners::new(&owners, Some(records_file(&socket))));
    eprintln!(
        "broker-forward: {} reaches the lane-gh broker of {} over the carrier",
        socket.display(),
        owners.order().join(", then ")
    );
    let daemon = crate::config::socket_path();
    // The checks and one task per connection, owned by this command: they end when it does.
    let tasks = cmux_scope::Scope::new("machine broker-forward");
    {
        let owners = owners.clone();
        let daemon = daemon.clone();
        tasks.spawn_until_cancelled("broker-forward health", async move {
            loop {
                check_all(&owners, &daemon).await;
                tokio::time::sleep(HEALTH_EVERY).await;
            }
        });
    }
    loop {
        let (conn, _) = listener.accept().await.context("accept")?;
        let owners = owners.clone();
        let daemon = daemon.clone();
        tasks.spawn_until_cancelled("broker-forward connection", async move {
            if let Err(e) = carry_any(conn, &owners, &daemon).await {
                eprintln!("broker-forward: {e:#}");
            }
        });
    }
}

/// One progress check of every owner, at once, then the records written.
pub async fn check_all(owners: &Owners, daemon: &Path) {
    let names = owners.records().into_iter().map(|r| r.owner).collect::<Vec<_>>();
    let checks = names.iter().map(|o| async move { (o, check(o, daemon).await) });
    for (owner, verdict) in futures::future::join_all(checks).await {
        if let Err(why) = &verdict {
            eprintln!("broker-forward: {owner} is down: {why}");
        }
        owners.note(owner, verdict);
    }
    owners.save();
}

/// A lane-gh `ping` through `owner`'s pipe: its round trip when the broker answers `ok` within
/// [`HEALTH_BOUND`].
pub async fn check(owner: &str, daemon: &Path) -> Result<Duration, String> {
    let started = Instant::now();
    let ping = async {
        let mut pipe = open_pipe(owner, daemon).await.map_err(|e| format!("{e:#}"))?;
        pipe.write_all(b"{\"op\":\"ping\",\"check_push\":false}\n")
            .await
            .map_err(|e| format!("send the ping: {e}"))?;
        let mut line = Vec::new();
        BufReader::new(&mut pipe)
            .read_until(b'\n', &mut line)
            .await
            .map_err(|e| format!("read the ping's answer: {e}"))?;
        let answer: Value = serde_json::from_slice(&line)
            .map_err(|_| "the broker's ping answer is not JSON (or it closed)".to_owned())?;
        if answer.get("ok") == Some(&Value::Bool(true)) {
            Ok(())
        } else {
            let why = answer.get("error").and_then(Value::as_str).unwrap_or("not ok");
            Err(format!("the broker answered the ping: {why}"))
        }
    };
    match tokio::time::timeout(HEALTH_BOUND, ping).await {
        Ok(Ok(())) => Ok(started.elapsed()),
        Ok(Err(why)) => Err(why),
        Err(_) => Err(format!("no ping answer within {} s", HEALTH_BOUND.as_secs())),
    }
}

/// Listen at `socket`, replacing a stale socket file there (never any other kind of file).
fn bind(socket: &Path) -> Result<UnixListener> {
    use std::os::unix::fs::FileTypeExt;
    if let Some(dir) = socket.parent().filter(|d| !d.as_os_str().is_empty()) {
        std::fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
    }
    match std::fs::symlink_metadata(socket) {
        Ok(meta) if meta.file_type().is_socket() => {
            if std::os::unix::net::UnixStream::connect(socket).is_ok() {
                return Err(anyhow!("{} is already served", socket.display()));
            }
            std::fs::remove_file(socket)
                .with_context(|| format!("remove stale {}", socket.display()))?;
        }
        Ok(_) => return Err(anyhow!("{} exists and is not a socket", socket.display())),
        Err(_) => {}
    }
    UnixListener::bind(socket).with_context(|| format!("listen at {}", socket.display()))
}

/// Carry one client connection to the first owner whose pipe opens (module docs).
pub(crate) async fn carry_any(
    mut client: UnixStream,
    owners: &Owners,
    daemon: &Path,
) -> Result<()> {
    let mut refusals = Vec::new();
    for owner in owners.order() {
        let opened = tokio::time::timeout(OPEN_BOUND, open_pipe(&owner, daemon)).await;
        let mut pipe = match opened {
            Ok(Ok(pipe)) => pipe,
            Ok(Err(e)) => {
                let why = format!("{e:#}");
                owners.note(&owner, Err(why.clone()));
                refusals.push(why);
                continue;
            }
            Err(_) => {
                let why = format!("{owner}: no pipe within {} s", OPEN_BOUND.as_secs());
                owners.note(&owner, Err(why.clone()));
                refusals.push(why);
                continue;
            }
        };
        owners.carried(&owner);
        tokio::io::copy_bidirectional(&mut client, &mut pipe).await.ok();
        return Ok(());
    }
    // Nothing was sent: lane-gh reads a closed socket as "nothing listening" and waits it out.
    Err(anyhow!("no owner's broker reachable: {}", refusals.join("; ")))
}

/// A `remote.pipe` to `owner`'s lane-gh broker on the daemon at `daemon`, past its reply line.
pub(crate) async fn open_pipe(owner: &str, daemon: &Path) -> Result<UnixStream> {
    let mut stream = UnixStream::connect(daemon)
        .await
        .with_context(|| format!("this machine's daemon at {}", daemon.display()))?;
    // `hub_carrier::LANE_GH_BROKER_SERVICE`; the CLI builds without the `hub-carrier` feature.
    let request = Message::request(
        1,
        method::MUX_REMOTE_PIPE,
        json!({"machine": owner, "service": "lane-gh-broker"}),
    );
    stream.write_all(request.to_line().as_bytes()).await?;
    // One line, read a byte at a time so no carried byte is buffered away.
    let mut line = Vec::new();
    let mut reader = BufReader::with_capacity(1, &mut stream);
    reader.read_until(b'\n', &mut line).await?;
    let reply: Value = serde_json::from_slice(&line).context("the daemon's remote.pipe reply")?;
    if let Some(error) = reply.get("error") {
        let message = error.get("message").and_then(Value::as_str).unwrap_or("refused");
        let reason = error.pointer("/data/reason").and_then(Value::as_str).unwrap_or("");
        return Err(anyhow!("{owner}'s lane-gh broker: {message} ({reason})"));
    }
    Ok(stream)
}

#[cfg(test)]
#[path = "host_broker_forward_tests.rs"]
mod tests;
