//! The far reads `acpmux ls` adds to this daemon's own list: the send relay's `lsArgv` listing
//! (`send_relay.rs`) and the down `ssh://` peers' listings (`ls_ssh.rs`). They share one short
//! budget ([`budget`], default [`FAR_BUDGET`]) and run at the same time, beside the local read,
//! so a stalled relay never turns the local listing into an error or holds it past that budget
//! (Leo, 2026-11-22: "we need it to be able to run blazingly fast under duress"; `ls` exited 1
//! after 15 s while `lane-gh sessions` stalled on a loaded lane VM).
//!
//! When a good listing is kept ([`CACHE_FILE`]) and is younger than [`FRESH_AGE_MS`], `ls` does
//! not wait on the relay at all: it lists the kept rows, marked with their age, and starts one
//! detached refresh for the next `ls` (lead, 2026-11-23: local `ls` p99 under 500 ms with the
//! relay stalled). An older kept listing is as old as the caller's last `ls` (a 45 s pause served
//! peers 85 s old while a fresh read takes about 0.4 s: cmuxterm-hq
//! `docs/findings/2026-11-23-acpmux-ls-serves-idle-gap.md`), so `ls` reads the relay for it, by
//! [`KEPT_WAIT`], and lists the kept rows only if that misses; while a refresh is already running
//! (a slow relay) it lists them at once. Without a kept listing it reads the relay by the budget.
//!
//! A relay that missed its budget with no kept listing is not waited on again: later `ls` calls
//! list it as not listed (`no answer yet, refreshing`) at once, while the detached refresh keeps
//! trying; its first good answer becomes the kept listing ([`MISSED_MARK`]).
//!
//! A relay listing that misses the budget (or fails) is served from the last good one, kept in
//! [`CACHE_FILE`] under the acpmux home with the time it was read: its rows carry their `asOfMs`,
//! the JSON listing says so in `remote`, and the text view in one stderr line. They are not
//! marked `stale`: that mark is a down peer's last-known copy (`hub/peer_cache.rs`), which the
//! table shows as unknown and `peer down` (`ls_table.rs` `unreadable`). A relay copy seconds old
//! is not a down peer: marked so, every one of 2,000 relay rows read `peer down` while the relay
//! listed 87 running (cmuxterm-hq `docs/findings/2026-11-23-acpmux-ls-peer-down-rows.md`). A miss also starts one detached refresh (`ls --refresh-relay-cache`, at most one at a
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

/// Present once a read of the relay missed its budget with no kept listing to show; its text is
/// when. While it stands, `ls` does not wait on the relay again: the refresh it starts is what
/// reads it, and the first good answer keeps a listing (which retires this).
const MISSED_MARK: &str = "relay-ls-cache.missed";

/// What [`RelayRead::missed`] says when the relay missed before and has not answered since.
pub(crate) const NO_ANSWER_YET: &str = "no answer yet, refreshing";

/// A cached listing older than this is not served: it would list sessions long gone.
const CACHE_MAX_AGE_MS: u64 = 24 * 3_600_000;

/// A kept listing younger than this is listed without the stderr line: it is as good as a
/// fresh read for the text view (its rows and the JSON `remote` still say `stale`).
const QUIET_AGE_MS: u64 = 60_000;

/// A kept listing younger than this is listed without reading the relay: the detached refresh an
/// earlier `ls` started has just written it.
const FRESH_AGE_MS: u64 = 10_000;

/// How long `ls` reads the relay for an older kept listing before listing the kept rows. A
/// healthy `lane-gh sessions` takes about 0.4 s, so this call often still lists the kept rows,
/// and the refresh it starts makes the next `ls` fresh: one call stale, not the caller's whole
/// pause. Small enough that the call stays inside the 500 ms p99 under load (lead, 2026-11-23).
const KEPT_WAIT: Duration = Duration::from_millis(250);

/// After [`KEPT_WAIT`], how long `finish` still waits for the read the deadline killed.
const KEPT_GRACE: Duration = Duration::from_millis(50);

/// What [`RelayRead::missed`] says when the kept listing was served without reading the relay.
pub(crate) const FROM_CACHE: &str = "from the last listing, refreshing";

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
            RemoteState::Stale { as_of_ms }
                if missed == FROM_CACHE && now.saturating_sub(as_of_ms) < QUIET_AGE_MS =>
            {
                return None;
            }
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

/// The relay's part, started: a read by the budget, the kept listing served at once, or a read
/// by [`KEPT_WAIT`] with the kept listing to list if it misses.
enum RelayPart {
    Reading(String, PathBuf, RelayTask),
    Kept(RelayRead),
    Racing { cache: PathBuf, task: RelayTask, kept: RelayRead, until: Instant },
}

/// The far reads, running.
pub(crate) struct FarRead {
    deadline: Instant,
    budget: Duration,
    relay: Option<RelayPart>,
    /// Read for the down ssh peers in [`FarRead::finish`], beside the relay.
    client: Option<Arc<Client>>,
}

/// Starts the far reads for `client`'s listing, each by `budget` from now: the relay's at once
/// (off the runtime), the ssh peers' when [`FarRead::finish`] runs it beside the relay's. With a
/// kept listing the relay is not read here: the kept rows are served and a refresh detached.
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
        let now = crate::store::now_ms();
        if let Some((as_of_ms, rows)) = read_cache(&cache, now) {
            let kept = RelayRead {
                rows,
                state: RemoteState::Stale { as_of_ms },
                source,
                missed: Some(FROM_CACHE.to_owned()),
            };
            if now.saturating_sub(as_of_ms) < FRESH_AGE_MS || refreshing(&cache, now) {
                refresh_detached(&cache);
                return RelayPart::Kept(kept);
            }
            let read_by = deadline.min(Instant::now() + KEPT_WAIT);
            let task =
                tokio::task::spawn_blocking(move || send_relay::relay_ls(&relay, Some(read_by)));
            return RelayPart::Racing { cache, task, kept, until: read_by + KEPT_GRACE };
        }
        // A relay that missed its budget before and never gave a listing: not waited on again
        // (a known slow peer must not make every `ls` slow); its rows are unknown until the
        // detached refresh keeps an answer.
        if missed_mark_live(&cache, crate::store::now_ms()) {
            refresh_detached(&cache);
            return RelayPart::Kept(RelayRead {
                rows: Vec::new(),
                state: RemoteState::Missing,
                source,
                missed: Some(NO_ANSWER_YET.to_owned()),
            });
        }
        let task =
            tokio::task::spawn_blocking(move || send_relay::relay_ls(&relay, Some(deadline)));
        RelayPart::Reading(source, cache, task)
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
            let (source, cache, mut task) = match relay? {
                RelayPart::Kept(kept) => return Some(kept),
                RelayPart::Racing { cache, mut task, kept, until } => {
                    if let Ok(Ok(Ok(Some(rows)))) = tokio::time::timeout_at(until, &mut task).await
                    {
                        write_cache(&cache, &kept.source, &rows, crate::store::now_ms());
                        return Some(RelayRead {
                            rows,
                            state: RemoteState::Fresh,
                            source: kept.source,
                            missed: None,
                        });
                    }
                    task.abort();
                    refresh_detached(&cache);
                    return Some(kept);
                }
                RelayPart::Reading(source, cache, task) => (source, cache, task),
            };
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
                    let _ = crate::home_fs::write(
                        cache.with_file_name(MISSED_MARK),
                        crate::store::now_ms().to_string(),
                    );
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

fn missed_mark_live(cache: &Path, now: u64) -> bool {
    std::fs::read_to_string(cache.with_file_name(MISSED_MARK))
        .ok()
        .and_then(|t| t.trim().parse::<u64>().ok())
        .is_some_and(|at| now.saturating_sub(at) <= CACHE_MAX_AGE_MS)
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
    let _ = crate::home_fs::remove_file(path.with_file_name(MISSED_MARK));
}

/// The cached listing's read time and rows, each with its `asOfMs` (never `stale`: see the module
/// doc); none when
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
                fields.insert("asOfMs".into(), json!(at));
            }
            row
        })
        .collect();
    Some((at, rows))
}

/// Whether a detached refresh started within the relay's own deadline is still marked.
fn refreshing(cache: &Path, now: u64) -> bool {
    let mark = cache.with_file_name(REFRESH_MARK);
    let started = std::fs::read_to_string(&mark).ok().and_then(|t| t.trim().parse::<u64>().ok());
    let bound = u64::try_from(send_relay::LS_DEADLINE.as_millis()).unwrap_or(u64::MAX) + 5_000;
    started.is_some_and(|at| now.saturating_sub(at) < bound)
}

/// Starts `ls --refresh-relay-cache` detached, unless one started within the relay's own
/// deadline is still marked. Not in tests: this process is the test binary there.
#[cfg_attr(test, allow(clippy::needless_return))]
fn refresh_detached(cache: &Path) {
    let mark = cache.with_file_name(REFRESH_MARK);
    let now = crate::store::now_ms();
    if refreshing(cache, now) {
        return;
    }
    // Not marked: start none, or two could race.
    #[cfg_attr(test, allow(unused_variables))]
    let marked = crate::home_fs::write(&mark, now.to_string()).is_ok();
    #[cfg(not(test))]
    if marked {
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
/// tool): fresh by [`budget`], else the cached ones, each with its `asOfMs`.
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
