//! `acpmux process owner PID...`, `process left-behind` and `process kill --pid PID`: which agent
//! session owns a process on this machine, what an ended agent host left running, and ending a
//! process only when that answer allows it.
//!
//! Every process an agent starts carries its session in its environment: `ACPMUX_SESSION_ID` and
//! `ACPMUX_SESSION_NAME`, its agent host's start nonce (`agent_host::HOST_MARK`), and, for a
//! background task, the task's mark (`bg_run::TASK_MARK`). The kernel keeps the environment a
//! process was started with, so the owner is read from the process itself, not guessed from its
//! command line, and a process whose parent exited is still known.
//!
//! The answer, for each process:
//! - `yours`: the session the caller runs in started it.
//! - `task`: a background task's process whose runner still runs: `process kill SESSION/TASK`.
//! - `live`: another session's live agent host started it: ask that session, never end it.
//! - `left-behind`: the agent host incarnation that started it has ended (its live lock is gone),
//!   and it is no running task's: nothing will ever end it. acpmux's own host exit ends the same
//!   set (`agent_host::end_left_behind`), so ending one is the step that exit missed.
//! - `not-an-agents`: no acpmux session in its environment.
//! - `unknown`: its environment or its host's lock cannot be read; never ended.
//!
//! `kill --pid` ends a `yours` or `left-behind` process and what runs under it: SIGTERM, then
//! SIGKILL after `bg_run::GRACE` to what still runs as the same process (pid and start time), and
//! writes one line to `<acpmux home>/process-kills.jsonl`. It refuses every other answer, and
//! never signals pid 0 or 1, the caller or its ancestors.

use std::path::{Path, PathBuf};

use anyhow::{Result, anyhow};
use serde_json::{Value, json};

use crate::agent_host::{self, Liveness, tree};
use crate::cli::output::print_json;
use crate::client::Client;
use crate::rpc::method;

/// The environment names the owner is read from.
const SESSION_ID: &str = "ACPMUX_SESSION_ID";
const SESSION_NAME: &str = "ACPMUX_SESSION_NAME";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    /// acpmux itself: its daemon, an agent host, a task runner. Never ended by pid: each has its
    /// own stop (`daemon restart`, `session stop`, `process kill SESSION/TASK`).
    Acpmux,
    Yours,
    Task,
    Live,
    LeftBehind,
    NotAnAgents,
    Unknown,
}

impl Verdict {
    pub fn word(self) -> &'static str {
        match self {
            Verdict::Acpmux => "acpmux",
            Verdict::Yours => "yours",
            Verdict::Task => "task",
            Verdict::Live => "live",
            Verdict::LeftBehind => "left-behind",
            Verdict::NotAnAgents => "not-an-agents",
            Verdict::Unknown => "unknown",
        }
    }
    /// Whether `kill --pid` may end it.
    pub fn may_end(self) -> bool {
        matches!(self, Verdict::Yours | Verdict::LeftBehind)
    }
}

/// What a process's environment says of its owner.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Marks {
    pub session_id: Option<String>,
    pub session_name: Option<String>,
    pub host_nonce: Option<String>,
    pub task_mark: Option<String>,
    /// The acpmux home its daemon runs in (`ACPMUX_HOME`, which the daemon gives what it starts).
    pub home: Option<String>,
}

impl Marks {
    pub fn from_env(env: &[(String, String)]) -> Self {
        let get = |name: &str| {
            env.iter()
                .rev()
                .find(|(k, _)| k == name)
                .map(|(_, v)| v.clone())
                .filter(|v| !v.is_empty())
        };
        Marks {
            session_id: get(SESSION_ID),
            session_name: get(SESSION_NAME),
            host_nonce: get(agent_host::HOST_MARK),
            task_mark: get(crate::bg_run::TASK_MARK),
            home: get("ACPMUX_HOME"),
        }
    }
    fn any(&self) -> bool {
        self.session_id.is_some() || self.host_nonce.is_some() || self.task_mark.is_some()
    }
}

/// The verdict from the marks, the caller's session, whether the task's runner still runs and
/// whether the host incarnation still runs. Pure, so every case is tested.
pub fn judge(
    marks: Option<&Marks>,
    caller: Option<&str>,
    runner: Option<Liveness>,
    host: Option<Liveness>,
) -> Verdict {
    let Some(marks) = marks else { return Verdict::Unknown };
    if !marks.any() {
        return Verdict::NotAnAgents;
    }
    let yours = caller.is_some() && marks.session_id.as_deref() == caller;
    // A task outlives the host that asked for it (a dev server runs while its chat hibernates),
    // so its runner decides, not the host; a running task, the caller's own too, is stopped
    // through its runner (`process kill SESSION/TASK`), never behind its back.
    if marks.task_mark.is_some() {
        return match runner {
            Some(Liveness::Live) => Verdict::Task,
            Some(Liveness::Dead) if yours => Verdict::Yours,
            // Its runner is gone: with no host nonce nothing else ends it (a task's process runs
            // with the daemon's environment and the task's mark only).
            Some(Liveness::Dead) => match host {
                None => Verdict::LeftBehind,
                Some(_) => judge_host(host),
            },
            _ => Verdict::Unknown,
        };
    }
    if yours {
        return Verdict::Yours;
    }
    judge_host(host)
}

fn judge_host(host: Option<Liveness>) -> Verdict {
    match host {
        Some(Liveness::Live) => Verdict::Live,
        Some(Liveness::Dead) => Verdict::LeftBehind,
        // No host nonce at all: started by a session's tool outside a host (an MCP server the
        // daemon runs): its daemon owns it.
        None => Verdict::Live,
        Some(Liveness::Unknown) => Verdict::Unknown,
    }
}

/// The runner of the task marked `<runner pid>-<start ms>`: live while that pid runs as an
/// `acpmux __bg-run` (the runner sets the mark only on its child, so it is known by its argv).
/// The mark's start is not compared: a pid reused by another runner reads live, which only
/// refuses an end, never allows one.
fn runner_liveness(mark: &str, table: &[tree::Started]) -> Liveness {
    let Some((pid, _)) = mark.split_once('-') else { return Liveness::Unknown };
    let Ok(pid) = pid.parse::<u32>() else { return Liveness::Unknown };
    match table.iter().find(|p| p.pid == pid) {
        Some(p) => runner_by_argv(p.pid),
        None => Liveness::Dead,
    }
}

fn runner_by_argv(pid: u32) -> Liveness {
    match tree::argv(pid) {
        Some(argv) if argv.iter().any(|a| a == crate::bg_run::RUN_ARG) => Liveness::Live,
        Some(_) => Liveness::Dead,
        None => Liveness::Unknown,
    }
}

/// Whether host incarnation `nonce` of `session` still runs: its live lock is held in any place
/// a host keeps it (the pool, the hosts folder, its socket's folder). A replacement host adopts a
/// harness without changing the nonce the harness carries (`agent_host/custody.rs`), so while the
/// session's current host (its record's nonce) runs, the answer is live too. Dead only when no
/// lock of either is held anywhere.
fn host_liveness(session: Option<&str>, nonce: &str) -> Liveness {
    let Some(session) = session else { return Liveness::Unknown };
    let hosts = agent_host::hosts_dir();
    let mut dirs: Vec<PathBuf> = vec![agent_host::pool_dir(&hosts), hosts.clone()];
    let record = match read_record(&hosts, session) {
        Record::Unreadable => return Liveness::Unknown,
        Record::Missing => None,
        Record::Read(nonce, socket) => Some((nonce, socket)),
    };
    if let Some(dir) =
        record.as_ref().and_then(|(_, socket)| socket.parent().map(Path::to_path_buf))
        && !dirs.contains(&dir)
    {
        dirs.push(dir);
    }
    let mut nonces = vec![nonce.to_owned()];
    if let Some((current, _)) = record.filter(|(n, _)| n != nonce) {
        nonces.push(current);
    }
    let mut out = Liveness::Dead;
    for n in &nonces {
        for dir in &dirs {
            match agent_host::liveness(dir, session, n) {
                Liveness::Live => return Liveness::Live,
                Liveness::Unknown => out = Liveness::Unknown,
                Liveness::Dead => {}
            }
        }
    }
    out
}

enum Record {
    Missing,
    /// There but not readable: its socket's folder, where a lock may be, is not known.
    Unreadable,
    Read(String, PathBuf),
}

/// The session's host record: its current start nonce and socket.
fn read_record(hosts: &Path, session: &str) -> Record {
    let text = match std::fs::read_to_string(agent_host::record_path(hosts, session)) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Record::Missing,
        Err(_) => return Record::Unreadable,
    };
    let Ok(v) = serde_json::from_str::<Value>(&text) else { return Record::Unreadable };
    let Some(nonce) = v.get("start_nonce").and_then(Value::as_str) else {
        return Record::Unreadable;
    };
    match v.get("socket").and_then(Value::as_str) {
        Some(socket) => Record::Read(nonce.to_owned(), PathBuf::from(socket)),
        None => Record::Unreadable,
    }
}

/// Whether `argv` is acpmux's own: its daemon (`daemon run`), an agent host, a task runner or
/// the Bash hook.
pub fn is_acpmux_own(argv: &[String]) -> bool {
    let own = [agent_host::HOST_ARG, crate::bg_run::RUN_ARG, crate::bg_hook::HOOK_ARG];
    argv.iter().skip(1).any(|a| own.contains(&a.as_str())) || is_daemon_run(argv)
}

pub(crate) use super::is_daemon_run;

/// Whether the nearest acpmux process above `proc` is the daemon itself, not an agent host or a
/// task runner: the daemon's own helpers (MCP servers, git, peer links) carry whatever marks the
/// daemon was started with (an older build, or a handover, kept its starter chat's), so they are
/// the daemon's, never that chat's.
fn under_the_daemon(proc: &tree::Started, table: &[tree::Started], daemon: Option<u32>) -> bool {
    let mut parent = proc.ppid();
    let mut seen = 0;
    while parent > 1 && seen < 256 {
        if daemon == Some(parent) {
            return true;
        }
        if let Some(argv) = tree::argv(parent) {
            if is_daemon_run(&argv) {
                return true;
            }
            if is_acpmux_own(&argv) {
                return false;
            }
        }
        parent = table.iter().find(|p| p.pid == parent).map_or(0, tree::Started::ppid);
        seen += 1;
    }
    false
}

/// Whether `home` (a process's `ACPMUX_HOME`) is the home this command reads.
fn same_home(home: Option<&str>) -> bool {
    let Some(home) = home else { return false };
    let canon = |p: &Path| std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf());
    canon(Path::new(home)) == canon(&crate::config::home())
}

/// The pid `<acpmux home>/daemon.pid` names.
pub(crate) fn daemon_pid() -> Option<u32> {
    std::fs::read_to_string(crate::config::home().join("daemon.pid")).ok()?.trim().parse().ok()
}

/// One process and its owner.
#[derive(Debug, Clone)]
pub struct Owned {
    pub proc: tree::Started,
    pub marks: Option<Marks>,
    pub verdict: Verdict,
    pub argv: Option<Vec<String>>,
}

pub(crate) fn caller_session() -> Option<String> {
    std::env::var(SESSION_ID).ok().filter(|v| !v.is_empty())
}

pub(crate) fn own(proc: &tree::Started, table: &[tree::Started], caller: Option<&str>) -> Owned {
    let argv = tree::argv(proc.pid);
    let marks = tree::environ(proc.pid).map(|env| Marks::from_env(&env));
    // acpmux's own processes first: a daemon a chat's shell started carries that chat's marks
    // (an older build did not clear them), and ending it would end every session.
    let daemon = daemon_pid();
    if daemon == Some(proc.pid)
        || argv.as_deref().is_some_and(is_acpmux_own)
        || under_the_daemon(proc, table, daemon)
    {
        return Owned { proc: proc.clone(), marks, verdict: Verdict::Acpmux, argv };
    }
    if argv.is_none() {
        return Owned { proc: proc.clone(), marks, verdict: Verdict::Unknown, argv };
    }
    let runner =
        marks.as_ref().and_then(|m| m.task_mark.as_deref()).map(|m| runner_liveness(m, table));
    let host = marks
        .as_ref()
        .and_then(|m| m.host_nonce.as_deref().map(|n| host_liveness(m.session_id.as_deref(), n)));
    let mut verdict = judge(marks.as_ref(), caller, runner, host);
    // Host locks and records are read in this home only: a session of another home on this
    // machine (a dev build, a second daemon) has none here, so its processes would read as left
    // behind. Unless the process names this home, its host is not known.
    if verdict == Verdict::LeftBehind
        && !marks.as_ref().is_some_and(|m| same_home(m.home.as_deref()))
    {
        verdict = Verdict::Unknown;
    }
    Owned { proc: proc.clone(), marks, verdict, argv }
}

/// The owner of each of `pids`; `None` for one that does not run.
pub fn owners(pids: &[u32]) -> Vec<(u32, Option<Owned>)> {
    let table = tree::all();
    let caller = caller_session();
    pids.iter()
        .map(|pid| {
            (*pid, table.iter().find(|p| p.pid == *pid).map(|p| own(p, &table, caller.as_deref())))
        })
        .collect()
}

/// Every process an ended agent host left running, the caller and its ancestors aside.
pub fn left_behind() -> Vec<Owned> {
    let table = tree::all();
    let spared = tree::spared_now();
    let caller = caller_session();
    table
        .iter()
        .filter(|p| !spared.contains(&p.pid))
        .filter(|p| {
            tree::environ(p.pid).is_some_and(|env| {
                let m = Marks::from_env(&env);
                m.host_nonce.is_some() || m.task_mark.is_some()
            })
        })
        .map(|p| own(p, &table, caller.as_deref()))
        .filter(|o| o.verdict == Verdict::LeftBehind)
        .collect()
}

/// Session name, status and the next step for a verdict, from the daemon when it answers.
pub(crate) async fn session_status(client: Option<&Client>, id: &str) -> Option<String> {
    let client = client?;
    match client.request(method::MUX_INFO, json!({"sessionId": id})).await {
        Ok(v) => v.get("status").and_then(Value::as_str).map(str::to_owned),
        Err(e) if crate::cli::process_census::refused_as_no_session(&e) => Some("gone".to_owned()),
        Err(_) => None,
    }
}

fn row(o: &Owned, status: Option<&str>) -> Value {
    let m = o.marks.clone().unwrap_or_default();
    json!({
        "pid": o.proc.pid,
        "ppid": o.proc.ppid(),
        "started": o.proc.start(),
        "owner": o.verdict.word(),
        "mayEnd": o.verdict.may_end(),
        "sessionId": m.session_id,
        "sessionName": m.session_name,
        "sessionStatus": status,
        "hostNonce": m.host_nonce,
        "task": m.task_mark,
        "argv": o.argv,
    })
}

pub(crate) fn next_step(o: &Owned) -> String {
    let name =
        o.marks.as_ref().and_then(|m| m.session_name.clone().or_else(|| m.session_id.clone()));
    let name = name.unwrap_or_else(|| "-".to_owned());
    match o.verdict {
        Verdict::Acpmux => "acpmux's own (daemon, agent host or task runner): never ended by pid; \
                            use `acpmux daemon restart`, `session stop` or `process kill SESSION/TASK`"
            .to_owned(),
        Verdict::Yours => format!("yours: `acpmux process kill --pid {}` ends it", o.proc.pid),
        Verdict::Task => format!(
            "background task of {name}: `acpmux process list --session {name} --running` names it; stop it there"
        ),
        Verdict::Live => format!("{name}'s, live: ask it (`acpmux send {name} ...`); never end it"),
        Verdict::LeftBehind => format!(
            "left behind by {name}'s ended agent host: `acpmux process kill --pid {}` ends it",
            o.proc.pid
        ),
        Verdict::NotAnAgents => "no acpmux session started it: not an agent's to end".to_owned(),
        Verdict::Unknown => {
            "its owner cannot be read (another user's, or its host's lock): leave it".to_owned()
        }
    }
}

pub(crate) fn one_line_argv(o: &Owned) -> String {
    let s = o.argv.as_ref().map(|a| a.join(" ")).unwrap_or_else(|| "?".to_owned());
    if s.chars().count() > 120 {
        format!("{}…", s.chars().take(120).collect::<String>())
    } else {
        s
    }
}

async fn print_rows(rows: &[Owned], json_out: bool, key: &str) -> Result<()> {
    let client = crate::daemon::connect(false).await.ok();
    let mut out = Vec::new();
    for o in rows {
        let id = o.marks.as_ref().and_then(|m| m.session_id.clone());
        let status = match id {
            Some(id) => session_status(client.as_deref(), &id).await,
            None => None,
        };
        if json_out {
            out.push(row(o, status.as_deref()));
        } else {
            let status = status.map(|s| format!(" (session {s})")).unwrap_or_default();
            println!("{}  {}{status}  {}", o.proc.pid, next_step(o), one_line_argv(o));
        }
    }
    if json_out {
        print_json(&json!({ key: out }));
    }
    Ok(())
}

pub async fn owner(pids: &[u32], json_out: bool) -> Result<()> {
    let found = owners(pids);
    let missing: Vec<u32> = found.iter().filter(|(_, o)| o.is_none()).map(|(p, _)| *p).collect();
    let rows: Vec<Owned> = found.into_iter().filter_map(|(_, o)| o).collect();
    print_rows(&rows, json_out, "processes").await?;
    if !missing.is_empty() && !json_out {
        for pid in &missing {
            println!("{pid}  not running");
        }
    }
    Ok(())
}

pub async fn list_left_behind(json_out: bool) -> Result<()> {
    let rows = left_behind();
    if rows.is_empty() && !json_out {
        println!(
            "nothing left behind: every process an agent host started belongs to a running host or task"
        );
        return Ok(());
    }
    print_rows(&rows, json_out, "processes").await
}

/// `kill --pid`: end `pid` and what runs under it when its owner allows it.
pub async fn kill_pid(pid: u32, json_out: bool) -> Result<()> {
    let spared = tree::spared_now();
    if spared.contains(&pid) {
        return Err(anyhow!("refused: pid {pid} is 0, 1, this command or one of its ancestors"));
    }
    let Some((_, Some(o))) = owners(&[pid]).into_iter().next() else {
        return Err(anyhow!("pid {pid} does not run"));
    };
    if !o.verdict.may_end() {
        return Err(anyhow!("refused: pid {pid} is {}: {}", o.verdict.word(), next_step(&o)));
    }
    let entry = end_owned(&o, &spared, caller_session(), None).await;
    if json_out {
        print_json(&entry);
    } else {
        let killed = entry.get("sigkill").and_then(Value::as_array).is_some_and(|a| !a.is_empty());
        let under = entry.get("processes").and_then(Value::as_array).map_or(1, Vec::len) - 1;
        let how = if killed { "SIGTERM, then SIGKILL" } else { "SIGTERM" };
        println!(
            "ended {pid} ({}) and {under} under it with {how}; logged in {}",
            o.verdict.word(),
            kills_log().display()
        );
    }
    Ok(())
}

/// End `o` (already judged `may_end`) and what runs under it that is the same session's and
/// may end too, SIGTERM then SIGKILL after `bg_run::GRACE`, and log it in
/// `process-kills.jsonl` as done `by` (a session id, or `acpmux gc`). The one kill path for
/// `process kill --pid` and `acpmux gc --apply`.
/// Ends `o` and what runs under it in the same session, then logs the entry, with `reason` when
/// the caller has one (gc's), in `process-kills.jsonl`.
pub(crate) async fn end_owned(
    o: &Owned,
    spared: &[u32],
    by: Option<String>,
    reason: Option<String>,
) -> Value {
    let pid = o.proc.pid;
    // What runs under it goes too, each only when its own answer allows it and it is the same
    // session's: never acpmux's own processes or another session's that happen to sit below.
    let table = tree::all();
    let caller = caller_session();
    let session = o.marks.as_ref().and_then(|m| m.session_id.clone());
    // The walk stops at a process it may not end: nothing below one is taken.
    let mut procs = vec![o.proc.clone()];
    let mut frontier = vec![pid];
    while let Some(parent) = frontier.pop() {
        for p in table.iter().filter(|p| p.ppid() == parent && !spared.contains(&p.pid)) {
            if procs.iter().any(|q| q.pid == p.pid) {
                continue;
            }
            let c = own(p, &table, caller.as_deref());
            if c.verdict.may_end() && c.marks.as_ref().and_then(|m| m.session_id.clone()) == session
            {
                procs.push(c.proc);
                frontier.push(p.pid);
            }
        }
    }
    tree::signal_still_running(&procs, libc::SIGTERM);
    let deadline = std::time::Instant::now() + crate::bg_run::GRACE;
    let mut left = tree::still_running(&procs);
    while !left.is_empty() && std::time::Instant::now() < deadline {
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        left = tree::still_running(&left);
    }
    let killed = !left.is_empty();
    if killed {
        tree::kill_still_running(&left);
    }
    let mut entry = json!({
        "at": crate::store::now_ms(),
        "by": by,
        "pid": pid,
        "started": o.proc.start(),
        "owner": o.verdict.word(),
        "session": o.marks.as_ref().and_then(|m| m.session_id.clone()),
        "argv": o.argv,
        "processes": procs.iter().map(|p| p.pid).collect::<Vec<_>>(),
        "sigkill": left.iter().map(|p| p.pid).collect::<Vec<_>>(),
    });
    if let Some(reason) = reason
        && let Some(fields) = entry.as_object_mut()
    {
        fields.insert("reason".into(), json!(reason));
    }
    log_kill(&entry);
    entry
}

pub fn kills_log() -> PathBuf {
    crate::config::home().join("process-kills.jsonl")
}

/// Appends one line to `process-kills.jsonl`, through the held home (`home_fs`), owner-only.
pub(crate) fn log_kill(entry: &Value) {
    use std::io::Write as _;
    if let Ok(mut f) =
        crate::home_fs::OpenOptions::new().create(true).append(true).mode(0o600).open(kills_log())
    {
        let _ = writeln!(f, "{entry}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn marks(session: &str, nonce: Option<&str>, task: Option<&str>) -> Marks {
        Marks {
            session_id: Some(session.to_owned()),
            session_name: Some("n".to_owned()),
            host_nonce: nonce.map(str::to_owned),
            task_mark: task.map(str::to_owned),
            home: None,
        }
    }

    #[test]
    fn the_callers_own_process_is_yours_whatever_its_host() {
        let m = marks("s1", Some("abc"), None);
        assert_eq!(judge(Some(&m), Some("s1"), None, Some(Liveness::Dead)), Verdict::Yours);
        assert_eq!(judge(Some(&m), Some("s1"), None, Some(Liveness::Live)), Verdict::Yours);
    }

    #[test]
    fn another_sessions_process_under_a_live_host_is_never_ended() {
        let m = marks("s2", Some("abc"), None);
        let v = judge(Some(&m), Some("s1"), None, Some(Liveness::Live));
        assert_eq!(v, Verdict::Live);
        assert!(!v.may_end());
    }

    #[test]
    fn a_process_whose_host_ended_is_left_behind_and_may_end() {
        let m = marks("s2", Some("abc"), None);
        let v = judge(Some(&m), Some("s1"), None, Some(Liveness::Dead));
        assert_eq!(v, Verdict::LeftBehind);
        assert!(v.may_end());
        // No caller session (a person's terminal): the same.
        assert_eq!(judge(Some(&m), None, None, Some(Liveness::Dead)), Verdict::LeftBehind);
    }

    #[test]
    fn a_running_task_outlives_its_hibernated_host() {
        let m = marks("s2", Some("abc"), Some("123-456"));
        assert_eq!(
            judge(Some(&m), Some("s1"), Some(Liveness::Live), Some(Liveness::Dead)),
            Verdict::Task
        );
        assert!(!Verdict::Task.may_end());
        // Its runner gone too: left behind.
        assert_eq!(
            judge(Some(&m), Some("s1"), Some(Liveness::Dead), Some(Liveness::Dead)),
            Verdict::LeftBehind
        );
        assert_eq!(
            judge(Some(&m), Some("s1"), Some(Liveness::Unknown), Some(Liveness::Dead)),
            Verdict::Unknown
        );
    }

    #[test]
    fn nothing_unreadable_or_unproven_may_end() {
        assert_eq!(judge(None, Some("s1"), None, None), Verdict::Unknown);
        let m = marks("s2", Some("abc"), None);
        assert_eq!(judge(Some(&m), Some("s1"), None, Some(Liveness::Unknown)), Verdict::Unknown);
        assert_eq!(judge(Some(&Marks::default()), Some("s1"), None, None), Verdict::NotAnAgents);
        for v in [Verdict::Task, Verdict::Live, Verdict::NotAnAgents, Verdict::Unknown] {
            assert!(!v.may_end(), "{v:?}");
        }
    }

    #[test]
    fn acpmuxs_own_processes_are_known_by_argv() {
        let v = |a: &[&str]| a.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
        assert!(is_acpmux_own(&v(&["/x/acpmux", "daemon", "run", "--ready-fd", "3"])));
        assert!(is_acpmux_own(&v(&["/x/acpmux", "__agent-host"])));
        assert!(is_acpmux_own(&v(&["/x/acpmux", "__bg-run"])));
        assert!(!is_acpmux_own(&v(&["/usr/bin/python3", "server.py", "--daemon"])));
        assert!(!is_acpmux_own(&v(&["__bg-run"])));
        assert!(!Verdict::Acpmux.may_end());
    }

    #[test]
    fn a_task_whose_runner_ended_with_no_host_is_left_behind() {
        let m = marks("s2", None, Some("123-456"));
        assert_eq!(judge(Some(&m), Some("s1"), Some(Liveness::Dead), None), Verdict::LeftBehind);
        assert_eq!(judge(Some(&m), Some("s1"), Some(Liveness::Live), None), Verdict::Task);
    }

    #[test]
    fn the_callers_own_running_task_is_stopped_through_its_runner() {
        let m = marks("s1", None, Some("123-456"));
        assert_eq!(judge(Some(&m), Some("s1"), Some(Liveness::Live), None), Verdict::Task);
        assert_eq!(judge(Some(&m), Some("s1"), Some(Liveness::Dead), None), Verdict::Yours);
    }

    #[test]
    fn a_daemon_drops_every_mark_this_module_reads() {
        let dropped = crate::daemon::STARTER_SESSION_MARKS;
        for k in [SESSION_ID, SESSION_NAME, agent_host::HOST_MARK, crate::bg_run::TASK_MARK] {
            assert!(dropped.contains(&k), "{k}");
        }
    }

    #[test]
    fn marks_read_the_last_value_and_skip_empty_ones() {
        let env = vec![
            (SESSION_ID.to_owned(), "old".to_owned()),
            (SESSION_ID.to_owned(), "s1".to_owned()),
            (agent_host::HOST_MARK.to_owned(), String::new()),
        ];
        let m = Marks::from_env(&env);
        assert_eq!(m.session_id.as_deref(), Some("s1"));
        assert_eq!(m.host_nonce, None);
    }

    #[test]
    fn only_a_process_of_this_home_can_be_left_behind() {
        let here = crate::config::home();
        assert!(same_home(here.to_str()));
        assert!(!same_home(None));
        assert!(!same_home(Some("/nonexistent/other-acpmux-home")));
    }

    #[test]
    fn a_host_whose_lock_is_gone_from_every_place_of_this_home_is_dead() {
        // A session id no host ever had: no record, no lock anywhere.
        assert_eq!(host_liveness(Some("no-such-session-0000"), "00ff"), Liveness::Dead);
        assert_eq!(host_liveness(None, "00ff"), Liveness::Unknown);
    }

    #[test]
    fn a_live_process_of_this_test_is_read_with_its_marks() {
        // This test process: never ended, and `owners` reads it.
        let me = std::process::id();
        let found = owners(&[me]);
        assert_eq!(found.len(), 1);
        assert!(found[0].1.is_some());
    }
}
