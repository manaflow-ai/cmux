//! The far reads `acpmux ls` adds to this daemon's own list: the send relay's `lsArgv` listing
//! (`send_relay.rs`) and the down `ssh://` peers' listings (`ls_ssh.rs`). They share one short
//! budget ([`budget`], default [`FAR_BUDGET`]) and run at the same time, beside the local read,
//! so a stalled relay never turns the local listing into an error or holds it past that budget
//! (Leo, 2026-11-22: "we need it to be able to run blazingly fast under duress"; `ls` exited 1
//! after 15 s while `lane-gh sessions` stalled on a loaded lane VM).
//!
//! A relay listing that misses the budget (or fails) is served from the last good one, kept in
//! [`CACHE_FILE`] under the acpmux home with the time it was read: its rows are marked `stale`
//! with their `asOfMs`, the JSON listing says so in `remote`, and the text view in one stderr
//! line. A miss also starts one detached refresh (`ls --refresh-relay-cache`, at most one at a
//! time, its child killed at [`send_relay::LS_DEADLINE`]), so the next `ls` serves a newer copy.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};
use tokio::time::Instant;

use crate::cli::send_relay::{self, SendRelay};
use crate::client::Client;

/// How long `ls` waits for the far reads: a healthy `lane-gh sessions` answers well inside it,
/// and a listing that cannot have them in time is printed without them.
pub(crate) const FAR_BUDGET: Duration = Duration::from_millis(1500);

/// Overrides [`FAR_BUDGET`] (milliseconds), for a script that would rather wait.
const BUDGET_ENV: &str = "ACPMUX_LS_FAR_BUDGET_MS";

/// The last good relay listing, under the acpmux home.
pub(crate) const CACHE_FILE: &str = "relay-ls-cache.json";

/// Present while a detached refresh runs; its text is when it started (ms).
const REFRESH_MARK: &str = "relay-ls-cache.refreshing";

/// A cached listing older than this is not served: it would list sessions long gone.
const CACHE_MAX_AGE_MS: u64 = 24 * 3_600_000;

/// After the budget, how long `finish` still waits for a read the deadline already killed.
const GRACE: Duration = Duration::from_millis(250);

/// The far budget: [`BUDGET_ENV`] when set to a number of milliseconds, else [`FAR_BUDGET`].
pub(crate) fn budget() -> Duration {
    std::env::var(BUDGET_ENV)
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .map_or(FAR_BUDGET, Duration::from_millis)
}

fn cache_path() -> PathBuf {
    crate::config::home().join(CACHE_FILE)
}

/// Whether the relay's rows in a listing were read now, come from the cache, or are missing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum RemoteState {
    Fresh,
    Stale { as_of_ms: u64 },
    Missing,
}

/// The relay's part of a listing.
#[derive(Debug)]
pub(crate) struct RelayRead {
    pub rows: Vec<Value>,
    pub state: RemoteState,
    /// The relay program (`lane-gh`).
    pub source: String,
    /// Why the fresh read was not used (`not read within 1.5s`, `failed: ...`).
    pub missed: Option<String>,
}

impl RelayRead {
    /// The listing's top-level `remote` (JSON).
    pub(crate) fn json(&self, now: u64) -> Value {
        let (state, as_of) = match self.state {
            RemoteState::Fresh => ("fresh", Some(now)),
            RemoteState::Stale { as_of_ms } => ("stale", Some(as_of_ms)),
            RemoteState::Missing => ("missing", None),
        };
        let mut v = json!({"state": state, "asOfMs": as_of, "source": self.source});
        if let (Some(missed), Some(fields)) = (&self.missed, v.as_object_mut()) {
            fields.insert("missed".into(), json!(missed));
        }
        v
    }

    /// The stderr line for a listing without fresh far rows; none when they are fresh.
    pub(crate) fn line(&self, now: u64) -> Option<String> {
        let missed = self.missed.as_deref()?;
        let listed = match self.state {
            RemoteState::Fresh => return None,
            RemoteState::Stale { as_of_ms } => {
                format!("listed as of {} ago", crate::cli::ls_table::ago(now, as_of_ms))
            }
            RemoteState::Missing => "not listed".to_owned(),
        };
        Some(format!(
            "acpmux: other machines' sessions through {}: {missed}; {listed}",
            self.source
        ))
    }
}

/// What the far reads gave.
pub(crate) struct Far {
    /// None: no relay with an `lsArgv`.
    pub relay: Option<RelayRead>,
    /// The down ssh peers that answered, and their rows (`ls_ssh::rows`).
    pub ssh_hosts: Vec<String>,
    pub ssh_rows: Vec<Value>,
}

type RelayTask = tokio::task::JoinHandle<anyhow::Result<Option<Vec<Value>>>>;

/// The far reads, running.
pub(crate) struct FarRead {
    deadline: Instant,
    budget: Duration,
    relay: Option<(String, PathBuf, RelayTask)>,
    /// Read for the down ssh peers in [`FarRead::finish`], beside the relay.
    client: Option<Arc<Client>>,
}

/// Starts the far reads for `client`'s listing, each by `budget` from now: the relay's at once
/// (off the runtime), the ssh peers' when [`FarRead::finish`] runs it beside the relay's.
pub(crate) fn start(client: Arc<Client>, budget: Duration) -> FarRead {
    let relay = send_relay::configured().filter(|r| r.ls_argv.is_some());
    start_with(relay, cache_path(), Some(client), budget)
}

/// [`start`] with the relay, cache file and client given (tests).
pub(crate) fn start_with(
    relay: Option<SendRelay>,
    cache: PathBuf,
    client: Option<Arc<Client>>,
    budget: Duration,
) -> FarRead {
    let deadline = Instant::now() + budget;
    let relay = relay.map(|relay| {
        let source = source_name(&relay);
        let task =
            tokio::task::spawn_blocking(move || send_relay::relay_ls(&relay, Some(deadline)));
        (source, cache, task)
    });
    FarRead { deadline, budget, relay, client }
}

impl FarRead {
    /// What the far reads gave by their deadline (and [`GRACE`] for a killed read to return).
    /// A relay read that missed it is served from the cache, and a refresh is started.
    pub(crate) async fn finish(self) -> Far {
        let FarRead { deadline, budget, relay, client } = self;
        let until = deadline + GRACE;
        let ssh = async move {
            let Some(client) = client else { return (Vec::new(), Vec::new()) };
            let read = async {
                // Each peer's url and link state (`_acpmux/peers`, the read `machine ls` makes).
                let peers = client.request("_acpmux/peers", json!({})).await.ok();
                let peers = peers
                    .as_ref()
                    .and_then(|s| s.get("peers"))
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                crate::cli::ls_ssh::rows(&peers, false, deadline).await
            };
            tokio::time::timeout_at(until, read).await.unwrap_or_default()
        };
        let relay = async move {
            let (source, cache, mut task) = relay?;
            let read = tokio::time::timeout_at(until, &mut task).await;
            let missed = match read {
                Ok(Ok(Ok(Some(rows)))) => {
                    write_cache(&cache, &source, &rows, crate::store::now_ms());
                    return Some(RelayRead {
                        rows,
                        state: RemoteState::Fresh,
                        source,
                        missed: None,
                    });
                }
                Ok(Ok(Ok(None))) => return None,
                Ok(Ok(Err(e))) if !timed_out(&e) => format!("failed ({e})"),
                Ok(Err(e)) => format!("failed ({e})"),
                Ok(Ok(Err(_))) | Err(_) => {
                    task.abort();
                    format!("not read within {}", seconds(budget))
                }
            };
            refresh_detached(&cache);
            Some(match read_cache(&cache, crate::store::now_ms()) {
                Some((as_of_ms, rows)) => RelayRead {
                    rows,
                    state: RemoteState::Stale { as_of_ms },
                    source,
                    missed: Some(missed),
                },
                None => RelayRead {
                    rows: Vec::new(),
                    state: RemoteState::Missing,
                    source,
                    missed: Some(missed),
                },
            })
        };
        let (relay, (ssh_hosts, ssh_rows)) = tokio::join!(relay, ssh);
        Far { relay, ssh_hosts, ssh_rows }
    }
}

/// `1.5s`, `2s`.
fn seconds(d: Duration) -> String {
    let ms = d.as_millis();
    if ms.is_multiple_of(1000) {
        format!("{}s", ms / 1000)
    } else {
        format!("{:.1}s", d.as_secs_f64())
    }
}

fn timed_out(e: &anyhow::Error) -> bool {
    e.chain().any(|c| {
        c.downcast_ref::<std::io::Error>()
            .is_some_and(|io| io.kind() == std::io::ErrorKind::TimedOut)
    }) || e.to_string().contains("timed out")
}

/// The relay program's name: `lane-gh` for `["lane-gh", "sessions"]`.
fn source_name(relay: &SendRelay) -> String {
    relay
        .ls_argv
        .as_deref()
        .and_then(<[String]>::first)
        .map(|p| Path::new(p).file_name().map_or(p.clone(), |n| n.to_string_lossy().into_owned()))
        .unwrap_or_else(|| "the send relay".to_owned())
}

/// Keeps `rows`, read at `at`, as the last good listing (written whole: a copy renamed over it).
/// A failed write costs only the next miss's stale rows.
pub(crate) fn write_cache(path: &Path, source: &str, rows: &[Value], at: u64) {
    let body = json!({"version": 1, "readAtMs": at, "source": source, "sessions": rows});
    let _ = crate::home_fs::write(path, body.to_string());
}

/// The cached listing's read time and rows, each marked `stale` with its `asOfMs`; none when
/// there is none, it does not parse, or it is older than [`CACHE_MAX_AGE_MS`].
pub(crate) fn read_cache(path: &Path, now: u64) -> Option<(u64, Vec<Value>)> {
    let text = std::fs::read_to_string(path).ok()?;
    let value: Value = serde_json::from_str(&text).ok()?;
    let at = value.get("readAtMs").and_then(Value::as_u64)?;
    if now.saturating_sub(at) > CACHE_MAX_AGE_MS {
        return None;
    }
    let rows = value
        .get("sessions")
        .and_then(Value::as_array)?
        .iter()
        .take(send_relay::LS_MAX_ROWS)
        .cloned()
        .map(|mut row| {
            if let Some(fields) = row.as_object_mut() {
                fields.insert("stale".into(), json!(true));
                fields.insert("asOfMs".into(), json!(at));
            }
            row
        })
        .collect();
    Some((at, rows))
}

/// Starts `ls --refresh-relay-cache` detached, unless one started within the relay's own
/// deadline is still marked. Not in tests: this process is the test binary there.
fn refresh_detached(cache: &Path) {
    let mark = cache.with_file_name(REFRESH_MARK);
    let now = crate::store::now_ms();
    let started = std::fs::read_to_string(&mark).ok().and_then(|t| t.trim().parse::<u64>().ok());
    let bound = u64::try_from(send_relay::LS_DEADLINE.as_millis()).unwrap_or(u64::MAX) + 5_000;
    if started.is_some_and(|at| now.saturating_sub(at) < bound) {
        return;
    }
    if crate::home_fs::write(&mark, now.to_string()).is_err() {
        return;
    }
    #[cfg(not(test))]
    {
        let Ok(exe) = std::env::current_exe() else { return };
        let mut cmd = cmux_process::Command::new(exe);
        cmd.args(["ls", "--refresh-relay-cache"])
            .stdin(cmux_process::Stdio::null())
            .stdout(cmux_process::Stdio::null())
            .stderr(cmux_process::Stdio::null())
            .process_group(0);
        if let Ok(mut child) = cmd.spawn() {
            child.detach(
                "refreshes the relay cache after this ls exits; its relay child is killed at send_relay::LS_DEADLINE",
            );
        }
    }
}

/// `ls --refresh-relay-cache`: one relay listing, by [`send_relay::LS_DEADLINE`], kept as the
/// cache; then the refresh mark goes.
pub(crate) async fn refresh_now() -> anyhow::Result<()> {
    let cache = cache_path();
    let result = match send_relay::configured().filter(|r| r.ls_argv.is_some()) {
        Some(relay) => {
            let source = source_name(&relay);
            let deadline = Instant::now() + send_relay::LS_DEADLINE;
            let read =
                tokio::task::spawn_blocking(move || send_relay::relay_ls(&relay, Some(deadline)))
                    .await?;
            if let Ok(Some(rows)) = &read {
                write_cache(&cache, &source, rows, crate::store::now_ms());
            }
            read.map(|_| ())
        }
        None => Ok(()),
    };
    let _ = crate::home_fs::remove_file(cache.with_file_name(REFRESH_MARK));
    result
}

/// The relay's rows for a caller with no listing of its own to show a stale line (the MCP `ls`
/// tool): fresh by [`budget`], else the cached ones, marked stale.
pub(crate) async fn relay_rows() -> Vec<Value> {
    let far = start_with(
        send_relay::configured().filter(|r| r.ls_argv.is_some()),
        cache_path(),
        None,
        budget(),
    );
    far.finish().await.relay.map(|r| r.rows).unwrap_or_default()
}

#[cfg(test)]
#[path = "ls_far_tests.rs"]
pub(crate) mod tests;
