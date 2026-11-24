//! `acpmux ps` (`acpmux process` with no subcommand) and `acpmux gc`: every process acpmux
//! started on this machine and every piece of state it keeps, who owns each one now, and which
//! are proven orphans; then ending only those.
//!
//! Nothing here judges ownership itself. Each process gets `process_owner`'s answer, read from
//! its own environment and its agent host's live lock (`process_owner::own`); state gets the
//! lock its record names (`agent_host::liveness`). A command line is never evidence: a process
//! whose argv looks leaked but whose host lock is held is `in-use`.
//!
//! The state of a process:
//! - `in-use`: acpmux's own (daemon, agent host, task runner), or a live session's or task's,
//!   whose session is not idle.
//! - `idle`: a live session's whose session reports `idle`.
//! - `orphaned`: `left-behind`: the agent host incarnation that started it ended (its live lock
//!   is gone) and no running task owns it. Only these are `gc` candidates.
//! - `unknown`: its owner cannot be proven either way; never ended.
//!
//! `gc` is a dry run unless `--apply`. It refuses a candidate that a live host record still
//! names (as its host or harness, or the harness's process group). `--apply` ends each remaining one through
//! `process_owner::end_owned` (SIGTERM, then SIGKILL, logged in `process-kills.jsonl` by
//! `acpmux gc` with its reason), and removes a stray live-lock file that no record names and no
//! process holds. Host records of dead hosts are reported, never removed: the next daemon's
//! adoption pass owns them (it records the loss and may resume the chat from them).

use std::path::{Path, PathBuf};

use anyhow::Result;
use serde_json::{Value, json};

use crate::agent_host::{self, HostRecord, Liveness, tree};
use crate::cli::output::print_json;
use crate::cli::process_owner::{self, Owned, Verdict};
use crate::client::Client;
use crate::rpc::method;

/// Reads a JSON pointer without indexing: a missing key reads `null`.
fn at<'a>(v: &'a Value, pointer: &str) -> &'a Value {
    v.pointer(pointer).unwrap_or(&Value::Null)
}

/// What a process acpmux started is for, from its own marks and records, never its name alone.
fn kind(o: &Owned, daemon: Option<u32>, hosts: &[HostRow]) -> &'static str {
    let argv = o.argv.as_deref().unwrap_or(&[]);
    let has = |a: &str| argv.iter().skip(1).any(|x| x == a);
    if daemon == Some(o.proc.pid)
        || argv.windows(2).any(|w| matches!(w, [a, b] if a == "daemon" && b == "run"))
    {
        return "daemon";
    }
    if has(agent_host::HOST_ARG) {
        return "agent-host";
    }
    if has(crate::bg_run::RUN_ARG) {
        return "task-runner";
    }
    if o.marks.as_ref().is_some_and(|m| m.task_mark.is_some()) {
        return "task";
    }
    if hosts.iter().any(|h| h.record.harness_pid == Some(o.proc.pid)) {
        return "agent";
    }
    let joined = argv.join(" ");
    if joined.contains("mcp") {
        return "mcp-server";
    }
    if joined.contains("relay") {
        return "relay";
    }
    "helper"
}

/// One host record of this home and what its lock says now.
#[derive(Debug, Clone)]
struct HostRow {
    dir: PathBuf,
    record: HostRecord,
    pooled: bool,
    liveness: Liveness,
}

fn host_rows() -> (Vec<HostRow>, Vec<agent_host::UnreadableRecord>) {
    let hosts = agent_host::hosts_dir();
    let mut rows = Vec::new();
    let mut bad_all = Vec::new();
    for (dir, pooled) in [(hosts.clone(), false), (agent_host::pool_dir(&hosts), true)] {
        let Ok((good, bad)) = agent_host::load_records(&dir) else { continue };
        for (_, record) in good {
            let liveness = agent_host::live_lock_dirs(&record)
                .iter()
                .map(|d| agent_host::liveness(d, &record.session_id, &record.start_nonce))
                .fold(Liveness::Dead, |acc, l| match (acc, l) {
                    (Liveness::Live, _) | (_, Liveness::Live) => Liveness::Live,
                    (Liveness::Unknown, _) | (_, Liveness::Unknown) => Liveness::Unknown,
                    _ => Liveness::Dead,
                });
            rows.push(HostRow { dir: dir.clone(), record, pooled, liveness });
        }
        bad_all.extend(bad);
    }
    (rows, bad_all)
}

fn liveness_word(l: Liveness) -> &'static str {
    match l {
        Liveness::Live => "live",
        Liveness::Dead => "dead",
        Liveness::Unknown => "unknown",
    }
}

/// The process group, or None when it cannot be read (gone, or another user's on some systems).
fn pgid(pid: u32) -> Option<u32> {
    let pid = libc::pid_t::try_from(pid).ok()?;
    // SAFETY: getpgid only reads the kernel's process table.
    let g = unsafe { libc::getpgid(pid) };
    u32::try_from(g).ok().filter(|g| *g > 0)
}

/// Seconds since `lstart` (`ps`'s local-time start, e.g. `Sat Nov 21 15:40:03 2026`).
///
/// The local time goes through libc's `mktime`, never `chrono::Local`: on macOS chrono reads the
/// zone through CoreFoundation's CFTimeZone, which the darwin cmux-tui build (linked on Linux
/// against a CoreFoundation stub) does not have, so one `chrono::Local` fails the whole publish.
fn age_secs(lstart: &str) -> Option<i64> {
    use chrono::{Datelike as _, Timelike as _};
    let squeezed = lstart.split_whitespace().collect::<Vec<_>>().join(" ");
    let naive = chrono::NaiveDateTime::parse_from_str(&squeezed, "%a %b %d %H:%M:%S %Y").ok()?;
    // SAFETY: `tm` is plain data, for which all-zero is a valid value.
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    tm.tm_year = naive.year() - 1900;
    tm.tm_mon = i32::try_from(naive.month0()).ok()?;
    tm.tm_mday = i32::try_from(naive.day()).ok()?;
    tm.tm_hour = i32::try_from(naive.hour()).ok()?;
    tm.tm_min = i32::try_from(naive.minute()).ok()?;
    tm.tm_sec = i32::try_from(naive.second()).ok()?;
    tm.tm_isdst = -1;
    // SAFETY: mktime only reads and normalizes the `tm` it is given.
    let at: i64 = unsafe { libc::mktime(&raw mut tm) };
    if at == -1 {
        return None;
    }
    let now = i64::try_from(
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).ok()?.as_secs(),
    )
    .ok()?;
    Some((now - at).max(0))
}

/// What the daemon says about one session: its status and last update, when it answers.
/// `gone` when the daemon has no such session.
#[derive(Debug, Clone, Default)]
pub(crate) struct SessionInfo {
    pub(crate) status: Option<String>,
    pub(crate) updated_at: Option<u64>,
}

impl SessionInfo {
    /// The daemon answered that it has no such session.
    pub(crate) fn gone() -> Self {
        SessionInfo { status: Some("gone".to_owned()), ..SessionInfo::default() }
    }
}

/// Each session's info, by session id, as [`build`] reads it.
pub(crate) type Sessions = std::collections::HashMap<String, SessionInfo>;

async fn session_info(client: Option<&Client>, id: &str) -> SessionInfo {
    let Some(client) = client else { return SessionInfo::default() };
    match client.request(method::MUX_INFO, json!({"sessionId": id})).await {
        Ok(v) => SessionInfo {
            status: v.get("status").and_then(Value::as_str).map(str::to_owned),
            updated_at: v.get("updatedAt").and_then(Value::as_u64),
        },
        Err(e) if refused_as_no_session(&e) => SessionInfo::gone(),
        Err(_) => SessionInfo::default(),
    }
}

/// Whether the daemon's refusal says it has no such session: `session_name::not_found`, a
/// not-found whose message starts "no session matches", read from the refusal itself, never a
/// word inside the quoted name. That session reads `gone`, as the socket census reads one its
/// hub does not hold. Any other failure (a timeout, a daemon gone) leaves the status unknown.
pub(crate) fn is_no_session(e: &crate::rpc::RpcError) -> bool {
    e.code == crate::rpc::RpcError::not_found("").code
        && e.message.starts_with("no session matches ")
}

/// Whether a request to the daemon failed with its no-such-session refusal ([`is_no_session`]):
/// the one test every CLI path that reads a session `gone` uses (`ps`, `gc`).
pub(crate) fn refused_as_no_session(e: &anyhow::Error) -> bool {
    e.downcast_ref::<crate::client::DaemonError>().is_some_and(|d| is_no_session(&d.0))
}

/// The most of one argument a trimmed census row keeps, and the most arguments it keeps.
const ARG_KEEP_BYTES: usize = 256;
const ARGS_KEPT: usize = 8;

/// Fits a census (what [`build`] returns) in `budget` bytes for one socket reply: each `argv`,
/// largest first, is cut to its first [`ARGS_KEPT`] arguments of at most [`ARG_KEEP_BYTES`]
/// each, plus a last `"... (N bytes omitted)"`, until the census fits. Every row keeps its pid,
/// owner, state and reason, so nothing a judgment rests on goes. The cut rows are counted in
/// `omitted: {reason: "too_large", argvTrimmed, bytes}`. False when even the cut census does
/// not fit: the caller refuses and points to `acpmux ps --json`, which has no reply limit.
pub(crate) fn fit_census(census: &mut Value, budget: usize) -> bool {
    let size = |v: &Value| serde_json::to_string(v).map_or(usize::MAX, |t| t.len());
    let before = size(census);
    if before <= budget {
        return true;
    }
    let mut pointers = Vec::new();
    for list in ["/processes", "/gc/candidates", "/gc/refused"] {
        let rows = census.pointer(list).and_then(Value::as_array).map_or(0, Vec::len);
        pointers.extend((0..rows).map(|i| format!("{list}/{i}/argv")));
    }
    // Room for the `omitted` mark added after the cut.
    let room = budget.saturating_sub(256);
    let trimmed =
        crate::hub::reply_fit::shrink_largest(census, before, room, pointers, |argv, _| {
            let args: Vec<String> = argv
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect();
            let total: usize = args.iter().map(String::len).sum();
            let mut kept: Vec<Value> = args
                .iter()
                .take(ARGS_KEPT)
                .map(|a| Value::String(cut(a, ARG_KEEP_BYTES).to_owned()))
                .collect();
            let kept_bytes: usize = kept.iter().filter_map(Value::as_str).map(str::len).sum();
            kept.push(Value::String(format!(
                "... ({} bytes omitted)",
                total.saturating_sub(kept_bytes)
            )));
            *argv = Value::Array(kept);
        });
    if let Some(map) = census.as_object_mut() {
        map.insert(
            "omitted".to_owned(),
            json!({"reason": "too_large", "argvTrimmed": trimmed.len(), "bytes": before}),
        );
    }
    size(census) <= budget
}

/// The start of `text`, at most `max` bytes, cut on a character boundary.
fn cut(text: &str, max: usize) -> &str {
    let mut end = text.len().min(max);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    text.get(..end).unwrap_or("")
}

/// The state of one process and why, from its verdict and its session.
fn state(o: &Owned, kind: &str, session: &SessionInfo) -> (&'static str, String) {
    let name = o
        .marks
        .as_ref()
        .and_then(|m| m.session_name.clone().or_else(|| m.session_id.clone()))
        .unwrap_or_else(|| "-".to_owned());
    match o.verdict {
        Verdict::Acpmux => ("in-use", format!("acpmux's own {kind}: stopped by its own verb, never by pid")),
        Verdict::Task => ("in-use", format!("background task of {name}; its runner still runs")),
        Verdict::Live if o.marks.as_ref().is_none_or(|m| m.host_nonce.is_none()) => (
            "in-use",
            format!("session {name} is live; acpmux runs this for it (no agent host of its own)"),
        ),
        Verdict::Yours | Verdict::Live => {
            let whose = if o.verdict == Verdict::Yours { "your session" } else { "session" };
            if session.status.as_deref() == Some("idle") {
                ("idle", format!("{whose} {name}'s agent host holds its live lock; the session is idle"))
            } else {
                ("in-use", format!("{whose} {name}'s agent host holds its live lock"))
            }
        }
        Verdict::LeftBehind => (
            "orphaned",
            format!(
                "agent host incarnation {} of {name} ended (its live lock is gone) and no running task owns it",
                o.marks.as_ref().and_then(|m| m.host_nonce.clone()).unwrap_or_else(|| "?".to_owned())
            ),
        ),
        Verdict::NotAnAgents => ("unknown", "no acpmux session in its environment".to_owned()),
        Verdict::Unknown => (
            "unknown",
            "its environment or its host's lock cannot be read (another user's, another home's): left alone"
                .to_owned(),
        ),
    }
}

/// Every process acpmux started here: acpmux's own, and every one carrying a session's marks.
fn started_by_acpmux(caller: Option<&str>) -> Vec<Owned> {
    let table = tree::all();
    let daemon = process_owner::daemon_pid();
    let mut out = Vec::new();
    for p in &table {
        let o = process_owner::own(p, &table, caller);
        let marked = o.marks.as_ref().is_some_and(|m| {
            m.session_id.is_some() || m.host_nonce.is_some() || m.task_mark.is_some()
        });
        let ours = o.verdict == Verdict::Acpmux || daemon == Some(p.pid);
        if ours || (marked && o.verdict != Verdict::NotAnAgents) {
            out.push(o);
        }
    }
    out
}

/// Why a live record still references `o`, if one does: its host, its harness, or the
/// harness's process group.
fn referenced_by_live_host(o: &Owned, hosts: &[HostRow]) -> Option<String> {
    let pid = o.proc.pid;
    let group = pgid(pid);
    hosts.iter().filter(|h| h.liveness != Liveness::Dead).find_map(|h| {
        let r = &h.record;
        if r.host_pid == pid || r.harness_pid == Some(pid) {
            Some(format!("the live host record of {} names it", r.session_id))
        } else if r.harness_pid.is_some() && group == r.harness_pid {
            Some(format!("it is in the harness group of {}'s live host", r.session_id))
        } else {
            None
        }
    })
}

/// What the census reads from the process table and this home's records, before it asks about
/// any session. Blocking: it reads every process's environment and probes host locks.
pub(crate) struct Gathered {
    daemon: Option<u32>,
    hosts: Vec<HostRow>,
    bad: Vec<agent_host::UnreadableRecord>,
    owned: Vec<Owned>,
}

/// Reads the processes acpmux started and its host records. `caller` is the session the asker
/// runs in: its processes read `yours` instead of `live`, and are never `orphaned` or a gc
/// candidate (gc never ends the asker's own processes), even when their agent host has ended.
pub(crate) fn gather(caller: Option<&str>) -> Gathered {
    let daemon = process_owner::daemon_pid();
    let (hosts, bad) = host_rows();
    let owned = started_by_acpmux(caller);
    Gathered { daemon, hosts, bad, owned }
}

impl Gathered {
    /// The sessions the gathered processes name, each once, in the order first named.
    pub(crate) fn session_ids(&self) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for id in self.owned.iter().filter_map(|o| o.marks.as_ref()?.session_id.clone()) {
            if !out.contains(&id) {
                out.push(id);
            }
        }
        out
    }
}

/// The whole census as JSON (`acpmux ps --json`), asking the running daemon about each session.
pub async fn census() -> Value {
    let client = crate::daemon::connect(false).await.ok();
    let client = client.as_deref();
    let gathered = gather(process_owner::caller_session().as_deref());
    let mut sessions = Sessions::new();
    for id in gathered.session_ids() {
        let info = session_info(client, &id).await;
        sessions.insert(id, info);
    }
    build(&gathered, &sessions, client.is_some())
}

/// The census as JSON: `processes`, `state`, and `gc` (what `gc` would end, and what it refuses
/// with the reason), from `g` and each session's info in `sessions`. `connected`: the daemon
/// answered (always, when the daemon builds it for `_acpmux/process/census`). Blocking: it probes
/// locks and reads the process table again.
pub(crate) fn build(g: &Gathered, sessions: &Sessions, connected: bool) -> Value {
    let Gathered { daemon, hosts, bad, owned } = g;
    let (daemon, hosts) = (*daemon, hosts.as_slice());
    let mut processes = Vec::new();
    let mut candidates = Vec::new();
    let mut refused = Vec::new();
    for o in owned {
        let sid = o.marks.as_ref().and_then(|m| m.session_id.clone());
        let info = sid.as_ref().and_then(|id| sessions.get(id)).cloned().unwrap_or_default();
        let k = kind(o, daemon, hosts);
        let (st, reason) = state(o, k, &info);
        let m = o.marks.clone().unwrap_or_default();
        // The owner now: a live host record of the session names the host that owns it after
        // any adoption (a replacement host adopts the harness, the record names it).
        let host_now = sid.as_deref().and_then(|id| {
            hosts.iter().find(|h| h.record.session_id == id && h.liveness == Liveness::Live)
        });
        let owner_pid = match o.verdict {
            Verdict::Acpmux if Some(o.proc.pid) != daemon => daemon,
            Verdict::Live if m.host_nonce.is_none() => daemon,
            Verdict::Yours | Verdict::Live | Verdict::Task => host_now.map(|h| h.record.host_pid),
            _ => None,
        };
        processes.push(json!({
            "pid": o.proc.pid,
            "ppid": o.proc.ppid(),
            "pgid": pgid(o.proc.pid),
            "kind": k,
            "owner": o.verdict.word(),
            "ownerPid": owner_pid,
            "sessionId": m.session_id,
            "sessionName": m.session_name,
            "sessionStatus": info.status,
            "lastActivityMs": info.updated_at,
            "hostNonce": m.host_nonce,
            "currentHostNonce": host_now.map(|h| h.record.start_nonce.clone()),
            "task": m.task_mark,
            "started": o.proc.start(),
            "ageSecs": age_secs(o.proc.start()),
            "state": st,
            "reason": reason,
            "argv": o.argv,
        }));
        if o.verdict != Verdict::LeftBehind {
            continue;
        }
        let refusal = referenced_by_live_host(o, hosts);
        let row = json!({"pid": o.proc.pid, "started": o.proc.start(), "sessionId": m.session_id, "reason": reason, "argv": o.argv});
        match refusal {
            Some(why) => refused.push(json!({"pid": o.proc.pid, "refused": why, "argv": o.argv})),
            None => candidates.push(row),
        }
    }

    let mut records = Vec::new();
    for h in hosts {
        let stale = h.liveness == Liveness::Dead;
        records.push(json!({
            "path": agent_host::record_path(&h.dir, &h.record.session_id),
            "sessionId": h.record.session_id,
            "pooled": h.pooled,
            "hostPid": h.record.host_pid,
            "harnessPid": h.record.harness_pid,
            "startNonce": h.record.start_nonce,
            "socket": h.record.socket,
            "socketExists": h.record.socket.exists(),
            "lock": liveness_word(h.liveness),
            "state": if stale { "stale" } else if h.liveness == Liveness::Live { "in-use" } else { "unknown" },
            "reason": if stale {
                "its host's live lock is gone; the next daemon's adoption pass clears it (gc never removes a record)"
            } else if h.liveness == Liveness::Live {
                "its host holds the live lock"
            } else {
                "its lock cannot be probed"
            },
        }));
    }
    let unreadable: Vec<Value> = bad
        .iter()
        .map(|b| json!({"path": b.path, "sessionId": b.session_id, "reason": b.reason, "state": "unknown"}))
        .collect();
    let stray = stray_live_locks(&LockNames::from_rows(hosts, bad));
    let home = crate::config::home();
    let daemon_lock = home.join("daemon.lock");
    let daemon_state = json!({
        "pid": daemon,
        "pidRunning": daemon.is_some_and(|p| tree::all().iter().any(|q| q.pid == p)),
        "lock": daemon_lock,
        "lockHeld": liveness_word(agent_host::liveness_of(&daemon_lock)),
        "socket": crate::config::socket_path(),
        "socketExists": crate::config::socket_path().exists(),
        "connected": connected,
    });
    let in_use = processes.iter().filter(|p| *at(p, "/state") == "in-use").count();
    let idle = processes.iter().filter(|p| *at(p, "/state") == "idle").count();
    let orphaned = processes.iter().filter(|p| *at(p, "/state") == "orphaned").count();
    let unknown = processes.iter().filter(|p| *at(p, "/state") == "unknown").count();
    json!({
        "product": "acpmux",
        "home": home,
        "summary": {
            "processes": processes.len(), "inUse": in_use, "idle": idle,
            "orphaned": orphaned, "unknown": unknown,
            "hostRecords": records.len(),
            "staleHostRecords": records.iter().filter(|r| *at(r, "/state") == "stale").count(),
            "strayLiveLocks": stray.len(),
        },
        "processes": processes,
        "state": {
            "daemon": daemon_state,
            "hostRecords": records,
            "unreadableHostRecords": unreadable,
            "strayLiveLocks": stray.iter().map(|p| json!({"path": p, "state": "stale",
                "reason": "no host record names this lock and no process holds it"})).collect::<Vec<_>>(),
        },
        "gc": {"candidates": candidates, "refused": refused},
    })
}

/// How old a `.live` file with no record must be before gc calls it stray. A starting host
/// creates its lock first and writes its record only once the harness runs, so a young lock with
/// no record is a host still starting; and probing one could take its flock the moment the host
/// tries to (a host's lock is never an old file: each start has a fresh nonce).
pub(crate) const STRAY_LOCK_MIN_AGE: std::time::Duration = std::time::Duration::from_secs(10 * 60);

/// Who names a lock: every readable record's (session, nonce), and every unreadable record's
/// session, whatever its nonce (a record we cannot parse may still be the lock's).
#[derive(Default)]
pub(crate) struct LockNames {
    pairs: Vec<(String, String)>,
    sessions: Vec<String>,
}

impl LockNames {
    fn read() -> Self {
        let (hosts, bad) = host_rows();
        Self::from_rows(&hosts, &bad)
    }

    fn from_rows(hosts: &[HostRow], bad: &[agent_host::UnreadableRecord]) -> Self {
        Self {
            pairs: hosts
                .iter()
                .map(|h| (h.record.session_id.clone(), h.record.start_nonce.clone()))
                .collect(),
            sessions: bad.iter().map(|b| b.session_id.clone()).collect(),
        }
    }

    pub(crate) fn names(&self, session: &str, nonce: &str) -> bool {
        self.sessions.iter().any(|s| s == session)
            || self.pairs.iter().any(|(s, n)| s == session && n == nonce)
    }

    #[cfg(test)]
    pub(crate) fn for_test(pairs: &[(&str, &str)], sessions: &[&str]) -> Self {
        Self {
            pairs: pairs.iter().map(|(s, n)| ((*s).to_owned(), (*n).to_owned())).collect(),
            sessions: sessions.iter().map(|s| (*s).to_owned()).collect(),
        }
    }
}

/// `<session>.<nonce>.live` files in the hosts and pool directories that no record names and no
/// process holds: an ended host's lock whose record already went.
fn stray_live_locks(names: &LockNames) -> Vec<PathBuf> {
    let dir = agent_host::hosts_dir();
    stray_locks_in(&[agent_host::pool_dir(&dir), dir], names, STRAY_LOCK_MIN_AGE)
}

fn lock_name(path: &Path) -> Option<(&str, &str)> {
    let stem = path.file_name()?.to_str()?.strip_suffix(".live")?;
    stem.rsplit_once('.')
}

fn old_enough(path: &Path, min_age: std::time::Duration) -> bool {
    std::fs::symlink_metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.elapsed().ok())
        .is_some_and(|age| age >= min_age)
}

pub(crate) fn stray_locks_in(
    dirs: &[PathBuf],
    names: &LockNames,
    min_age: std::time::Duration,
) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for d in dirs {
        let Ok(entries) = std::fs::read_dir(d) else { continue };
        for e in entries.flatten() {
            let path = e.path();
            let Some((session, nonce)) = lock_name(&path) else { continue };
            if names.names(session, nonce) || !old_enough(&path, min_age) {
                continue;
            }
            if agent_host::liveness_of(&path) == Liveness::Dead {
                out.push(path);
            }
        }
    }
    out
}

/// Removes one stray lock, judged again under its own flock: the file is held while it is checked
/// (still old, still the same file at that path, still named by no record) and unlinked, so no
/// host can take it between the check and the unlink. `names` is read after the flock is taken.
pub(crate) fn remove_stray_lock(
    path: &Path,
    names: impl FnOnce() -> LockNames,
    min_age: std::time::Duration,
) -> std::result::Result<(), String> {
    use std::os::unix::fs::MetadataExt;
    let (session, nonce) = lock_name(path).ok_or("not a live lock name")?;
    let file = crate::home_fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .map_err(|e| format!("open: {e}"))?;
    // Held until this returns: the drop unlocks, then closes.
    let lock = match cmux_file_lock::FileLock::try_take(file, cmux_file_lock::Kind::Exclusive) {
        Ok(lock) => lock,
        Err(cmux_file_lock::LockError::Busy(_)) => return Err("a process holds it now".to_owned()),
        Err(e) => return Err(e.to_string()),
    };
    let held = lock.file().metadata().map_err(|e| format!("stat: {e}"))?;
    let at_path = std::fs::symlink_metadata(path).map_err(|e| format!("stat: {e}"))?;
    if (held.dev(), held.ino()) != (at_path.dev(), at_path.ino()) {
        return Err("another file took its name".to_owned());
    }
    if !old_enough(path, min_age) {
        return Err("it is younger than the stray-lock age".to_owned());
    }
    if names().names(session, nonce) {
        return Err("a host record names it now".to_owned());
    }
    crate::home_fs::remove_file(path).map_err(|e| format!("remove: {e}"))
}

fn print_human(c: &Value) {
    let s = at(c, "/summary");
    println!(
        "acpmux: {} processes ({} in use, {} idle, {} orphaned, {} unknown); {} host records ({} stale); {} stray locks",
        at(s, "/processes"),
        at(s, "/inUse"),
        at(s, "/idle"),
        at(s, "/orphaned"),
        at(s, "/unknown"),
        at(s, "/hostRecords"),
        at(s, "/staleHostRecords"),
        at(s, "/strayLiveLocks")
    );
    for p in at(c, "/processes").as_array().into_iter().flatten() {
        let argv = at(p, "/argv")
            .as_array()
            .map(|a| a.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" "));
        let argv: String = argv.unwrap_or_default().chars().take(80).collect();
        println!(
            "{:>7} {:<11} {:<9} {:<12} {}  {}",
            at(p, "/pid"),
            at(p, "/kind").as_str().unwrap_or("-"),
            at(p, "/state").as_str().unwrap_or("-"),
            at(p, "/sessionName").as_str().or(at(p, "/sessionId").as_str()).unwrap_or("-"),
            at(p, "/reason").as_str().unwrap_or(""),
            argv
        );
    }
}

/// `acpmux ps`.
pub async fn ps(json_out: bool) -> Result<()> {
    let c = census().await;
    if json_out {
        print_json(&c);
    } else {
        print_human(&c);
    }
    Ok(())
}

/// `acpmux gc [--apply]`.
pub async fn gc(apply: bool, json_out: bool) -> Result<()> {
    let c = &census().await;
    let candidates: Vec<u32> = at(c, "/gc/candidates")
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|r| at(r, "/pid").as_u64().and_then(|p| u32::try_from(p).ok()))
        .collect();
    let stray: Vec<PathBuf> = at(c, "/state/strayLiveLocks")
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|r| at(r, "/path").as_str().map(PathBuf::from))
        .collect();
    let mut ended = Vec::new();
    let mut removed = Vec::new();
    let mut skipped = Vec::new();
    if apply {
        let spared = tree::spared_now();
        // Judge each one again right before ending it, one at a time: the census is a moment old,
        // and each end can wait out its grace, so a verdict read for the whole batch would age.
        for &pid in &candidates {
            let again = process_owner::owners(&[pid]).into_iter().next().and_then(|(_, o)| o);
            match again {
                Some(o) if o.verdict == Verdict::LeftBehind && !spared.contains(&pid) => {
                    let (hosts, _) = host_rows();
                    if let Some(why) = referenced_by_live_host(&o, &hosts) {
                        skipped.push(json!({"pid": pid, "refused": why}));
                        continue;
                    }
                    let reason = state(&o, "process", &SessionInfo::default()).1;
                    ended.push(
                        process_owner::end_owned(
                            &o,
                            &spared,
                            Some("acpmux gc".to_owned()),
                            Some(reason),
                        )
                        .await,
                    );
                }
                Some(o) => skipped
                    .push(json!({"pid": pid, "refused": format!("now {}", o.verdict.word())})),
                None => skipped.push(json!({"pid": pid, "refused": "no longer runs"})),
            }
        }
        for path in &stray {
            match remove_stray_lock(path, LockNames::read, STRAY_LOCK_MIN_AGE) {
                Ok(()) => {
                    let reason = "stray live lock: no record names it, no process holds it";
                    removed.push(json!({"path": path, "reason": reason}));
                    log_state_removal(path);
                }
                Err(why) => skipped.push(json!({"path": path, "refused": why})),
            }
        }
    }
    let receipt = json!({
        "product": "acpmux",
        "dryRun": !apply,
        "candidates": at(c, "/gc/candidates"),
        "refused": at(c, "/gc/refused"),
        "strayLiveLocks": at(c, "/state/strayLiveLocks"),
        "staleHostRecords": at(c, "/state/hostRecords").as_array().into_iter().flatten()
            .filter(|r| *at(r, "/state") == "stale").cloned().collect::<Vec<_>>(),
        "ended": ended,
        "removed": removed,
        "skipped": skipped,
        "log": process_owner::kills_log(),
    });
    if json_out {
        print_json(&receipt);
        return Ok(());
    }
    let n = candidates.len();
    let verb = if apply { "ended" } else { "would end" };
    println!(
        "acpmux gc{}: {verb} {} orphaned process(es); {} refused; {verb} {} stray lock(s)",
        if apply { "" } else { " (dry run; --apply ends them)" },
        if apply { ended.len() } else { n },
        at(c, "/gc/refused").as_array().map_or(0, Vec::len),
        if apply { removed.len() } else { stray.len() }
    );
    let listed: Vec<&Value> = if apply {
        ended.iter().collect()
    } else {
        at(c, "/gc/candidates").as_array().into_iter().flatten().collect()
    };
    for r in listed {
        println!("  {}  {}", at(r, "/pid"), at(r, "/reason").as_str().unwrap_or(""));
    }
    for r in at(c, "/gc/refused").as_array().into_iter().flatten().chain(skipped.iter()) {
        let what = at(r, "/pid")
            .as_u64()
            .map_or_else(|| at(r, "/path").as_str().unwrap_or("-").to_string(), |p| p.to_string());
        println!("  {what}  refused: {}", at(r, "/refused").as_str().unwrap_or(""));
    }
    if apply {
        for r in &removed {
            println!(
                "  {}  removed: {}",
                at(r, "/path").as_str().unwrap_or("-"),
                at(r, "/reason").as_str().unwrap_or("")
            );
        }
    } else {
        for p in &stray {
            println!("  {}  stray live lock", p.display());
        }
    }
    if apply {
        println!("logged in {}", process_owner::kills_log().display());
    }
    Ok(())
}

fn log_state_removal(path: &Path) {
    process_owner::log_kill(
        &json!({"at": crate::store::now_ms(), "by": "acpmux gc", "removed": path,
        "reason": "stray live lock: no record names it, no process holds it"}),
    );
}

#[cfg(test)]
#[path = "process_census_tests.rs"]
mod tests;
