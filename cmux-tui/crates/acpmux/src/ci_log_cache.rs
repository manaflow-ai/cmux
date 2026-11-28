//! Harness magic `sharedCache` (RFD 0158 §9), first family: a finished CI run's log, shared by
//! every chat on this machine.
//!
//! Measured on fs-agent-lane-33 (transcripts, 3 days to 2026-11-27): 16 `gh run view RUN
//! --log-failed`/`--log` calls fetched 7 distinct logs, so 9 were repeats, each piped into a
//! different `grep`, which the per-session dedupe (RFD 0147) cannot answer: its output is not the
//! earlier call's. One such log, 13 MB, took 22 s and 31 s through the lane broker on two runs
//! back to back.
//!
//! The Bash hook (`bg_hook.rs`) puts this binary's `ci-log-cache --` before each `gh run view`
//! of a call that asks for `--log` or `--log-failed` ([`rewrite`]); the rest of the call (its
//! pipe, its redirects) is as it was. The wrapper ([`main`]) then:
//! - passes the call through to `gh` unchanged unless it names a run or a job, a plain
//!   `OWNER/REPO` (`-R`, `--repo` or `GH_REPO`), and no flag it does not know;
//! - asks GitHub (one small `gh api` read) for the run's attempt and status, or the job's status,
//!   and passes through unless it is `completed`: a run's log changes with each attempt, so the
//!   key carries the attempt; a job id is one attempt's;
//! - serves the log from `<cache dir>/acpmux/ci-logs` when it is there, or runs `gh`, copies its
//!   stdout through as it comes, and keeps it when `gh` exits 0 with output.
//!
//! A downstream reader that stops early (`| head`) does not stop the copy into the cache: `gh`
//! has the log whole before it prints. The cache keeps 3 days and 2 GiB, oldest first.
//!
//! Off unless `agents.harnessMagic.sharedCache.enabled` is `true` (Leo 2026-11-26 on the
//! call-answering features: "only do it for our personal fleet situation"); `ACPMUX_HM_SHAREDCACHE`
//! `0` turns it off and `1` on, over the setting. Fails open: any error of its own runs `gh`
//! as asked.

use cmux_process::{Command, Stdio};
use std::io::{Read, Seek, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use serde_json::Value;

/// The subcommand the hook puts before `gh`.
pub const SUBCOMMAND: &str = "ci-log-cache";
/// The setting that turns it on (off unless `true`).
pub const SETTING_ENABLED: &str = "agents.harnessMagic.sharedCache.enabled";
/// The daemon's switch, over the setting.
pub const KILL_ENV: &str = "ACPMUX_HM_SHAREDCACHE";

const KEEP_FOR: Duration = Duration::from_secs(3 * 24 * 3600);
const KEEP_BYTES: u64 = 2 << 30;
const TMP_STALE: Duration = Duration::from_secs(3600);
/// The status read's bound; past it the call runs as asked.
const STATUS_BOUND: Duration = Duration::from_secs(20);

/// Whether the feature is on for `doc` and the switch's value `env`.
pub(crate) fn enabled_with(doc: Option<&Value>, env: Option<&str>) -> bool {
    match env.map(|v| v.trim().to_ascii_lowercase()).as_deref() {
        Some("0" | "false" | "off" | "no") => return false,
        Some("1" | "true" | "on" | "yes") => return true,
        _ => {}
    }
    doc.and_then(|d| crate::user_settings::value(d, SETTING_ENABLED)).and_then(|v| v.as_bool())
        == Some(true)
}

/// Whether the feature is on now.
pub(crate) fn enabled() -> bool {
    let doc = match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => Some(doc),
        _ => None,
    };
    enabled_with(doc.as_ref(), std::env::var(KILL_ENV).ok().as_deref())
}

/// `command` with `prefix` (this binary's quoted words and [`SUBCOMMAND`] `--`) before each
/// `gh run view` that starts a simple command outside quotes and asks for a log, or `None` when
/// there is none. Only an insertion: every other byte of the call stays.
pub(crate) fn rewrite(command: &str, prefix: &str) -> Option<String> {
    if !command.contains("gh run view") || command.contains(SUBCOMMAND) {
        return None;
    }
    let bytes = command.as_bytes();
    let mut out = String::with_capacity(command.len() + prefix.len() + 1);
    let mut last = 0;
    let mut quote: Option<u8> = None;
    let mut at_start = true;
    let mut i = 0;
    let mut changed = false;
    while i < bytes.len() {
        let c = bytes[i];
        if let Some(q) = quote {
            if c == q {
                quote = None;
            } else if c == b'\\' && q == b'"' {
                i += 1;
            }
            i += 1;
            continue;
        }
        match c {
            b'\'' | b'"' => {
                quote = Some(c);
                at_start = false;
            }
            b'\\' => {
                i += 2;
                at_start = false;
                continue;
            }
            b';' | b'&' | b'|' | b'(' | b'{' | b'\n' => at_start = true,
            b' ' | b'\t' => {}
            _ if at_start && command.get(i..).is_some_and(|r| r.starts_with("gh run view ")) => {
                if asks_for_log(command.get(i..).unwrap_or("")) {
                    // `i` starts a match, so it and `last` (an earlier match, or 0) are char boundaries.
                    out.push_str(command.get(last..i).unwrap_or(""));
                    out.push_str(prefix);
                    out.push(' ');
                    last = i;
                    changed = true;
                }
                at_start = false;
            }
            _ if at_start && command.get(i..).is_some_and(|r| r.starts_with("timeout ")) => {
                // `timeout DURATION gh run view ...`: the command starts after the duration.
                let rest = command.get(i + "timeout ".len()..).unwrap_or("");
                let dur = rest.trim_start();
                let skip = rest.len() - dur.len();
                let word = dur.find([' ', '\t']).unwrap_or(dur.len());
                if dur
                    .get(..word)
                    .unwrap_or("")
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'.')
                    && word > 0
                {
                    i += "timeout ".len() + skip + word;
                    continue;
                }
                at_start = false;
            }
            _ => at_start = false,
        }
        i += 1;
    }
    if !changed {
        return None;
    }
    out.push_str(command.get(last..).unwrap_or(""));
    Some(out)
}

/// Whether the simple command at the start of `rest` has a `--log` or `--log-failed` word.
fn asks_for_log(rest: &str) -> bool {
    let end = rest.find([';', '&', '|', '\n', ')', '>', '<']).unwrap_or(rest.len());
    rest.get(..end).unwrap_or(rest).split_whitespace().any(|w| w == "--log" || w == "--log-failed")
}

/// Whose log an [`Ask`] reads: a job (one attempt's already) wins over its run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum LogOf {
    Run(u64),
    Job(u64),
}

/// What one `gh run view` call asks for, when it is one the cache can answer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Ask {
    pub repo: String,
    pub of: LogOf,
    pub attempt: Option<u64>,
    pub failed_only: bool,
}

/// The [`Ask`] of `args` (the words after `gh`), or `None` for any call the cache passes
/// through.
pub(crate) fn ask_of(args: &[String], gh_repo: Option<&str>) -> Option<Ask> {
    let mut it = args.iter();
    if it.next()? != "run" || it.next()? != "view" {
        return None;
    }
    let (mut repo, mut run, mut job, mut attempt) = (None, None, None, None);
    let mut log = None;
    while let Some(w) = it.next() {
        let (flag, inline) = match w.split_once('=') {
            Some((f, v)) if f.starts_with("--") => (f, Some(v.to_owned())),
            _ => (w.as_str(), None),
        };
        let mut value = || inline.clone().or_else(|| it.next().cloned());
        match flag {
            "-R" | "--repo" => repo = Some(value()?),
            "-j" | "--job" => job = Some(value()?.parse().ok()?),
            "-a" | "--attempt" => attempt = Some(value()?.parse().ok()?),
            "--log" if inline.is_none() => log = Some(log.unwrap_or(false)),
            "--log-failed" if inline.is_none() => log = Some(true),
            _ if !w.starts_with('-') && run.is_none() => run = Some(w.parse().ok()?),
            _ => return None,
        }
    }
    let repo = repo.or_else(|| gh_repo.map(str::to_owned))?;
    let plain = |s: &str| {
        !s.is_empty()
            && s.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
    };
    let (owner, name) = repo.split_once('/')?;
    if !plain(owner) || !plain(name) || name.contains('/') {
        return None;
    }
    let of = match (job, run) {
        (Some(job), _) => LogOf::Job(job),
        (None, Some(run)) => LogOf::Run(run),
        (None, None) => return None,
    };
    Some(Ask { repo, of, attempt, failed_only: log? })
}

impl Ask {
    /// The GitHub read that says whether its log is final, and which attempt it is.
    fn status_path(&self) -> String {
        match self.of {
            LogOf::Job(job) => format!("repos/{}/actions/jobs/{job}", self.repo),
            LogOf::Run(run) => format!("repos/{}/actions/runs/{run}", self.repo),
        }
    }

    /// The cache key, given the attempt GitHub reported (a job is one attempt's already).
    pub(crate) fn key(&self, attempt: Option<u64>) -> String {
        let kind = if self.failed_only { "log-failed" } else { "log" };
        match self.of {
            LogOf::Job(job) => format!("{}|job={job}|{kind}", self.repo),
            LogOf::Run(run) => {
                let attempt = self.attempt.or(attempt).unwrap_or(0);
                format!("{}|run={run}|attempt={attempt}|{kind}", self.repo)
            }
        }
    }
}

/// Reads `gh api PATH` and returns `(status, run_attempt)`.
fn status(gh: &str, ask: &Ask) -> Option<(String, Option<u64>)> {
    // The answer goes to a file, so no reader thread is needed beside the bounded wait.
    let mut out = tempfile::tempfile().ok()?;
    let mut child = Command::new(gh)
        .args(["api", &ask.status_path()])
        .stdin(Stdio::null())
        .stdout(out.try_clone().ok()?)
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    // A child past the bound is ended by `Child`'s drop.
    match child.wait_timeout(STATUS_BOUND) {
        Ok(Some(s)) if s.success() => {}
        _ => return None,
    }
    let mut text = String::new();
    out.rewind().ok()?;
    out.read_to_string(&mut text).ok()?;
    let body: Value = serde_json::from_str(&text).ok()?;
    let status = body.get("status")?.as_str()?.to_owned();
    Some((status, body.get("run_attempt").and_then(Value::as_u64)))
}

/// The cache's directory.
fn dir() -> Option<PathBuf> {
    Some(dirs::cache_dir()?.join("acpmux").join("ci-logs"))
}

/// The file `key` lives in under `dir`.
pub(crate) fn path_for(dir: &Path, key: &str) -> PathBuf {
    dir.join(format!("{}.log", crate::sha256::sha256_hex(key.as_bytes())))
}

/// `acpmux ci-log-cache -- gh ARGS...`: the exit code the shell reads.
pub fn main(words: &[String]) -> i32 {
    let Some((gh, args)) = words.split_first() else { return 2 };
    let Some(dir) = dir() else { return run_through(gh, args) };
    run_in(words, &dir, std::env::var("GH_REPO").ok().as_deref())
}

/// [`main`] with its cache under `dir`.
pub(crate) fn run_in(words: &[String], dir: &Path, gh_repo: Option<&str>) -> i32 {
    let Some((gh, args)) = words.split_first() else { return 2 };
    let ask = (Path::new(gh).file_name().and_then(|n| n.to_str()) == Some("gh"))
        .then(|| ask_of(args, gh_repo))
        .flatten();
    let Some(ask) = ask else { return run_through(gh, args) };
    let Some((state, attempt)) = status(gh, &ask) else { return run_through(gh, args) };
    if state != "completed" {
        return run_through(gh, args);
    }
    let path = path_for(dir, &ask.key(attempt));
    if let Ok(mut file) = crate::home_fs::OpenOptions::new().read(true).open(&path) {
        let _ = file.set_modified(SystemTime::now());
        let mut stdout = std::io::stdout().lock();
        // A reader that stopped early is not an error of the cached log's.
        let _ = std::io::copy(&mut file, &mut stdout);
        let _ = stdout.flush();
        return 0;
    }
    fill(gh, args, dir, &path)
}

/// Runs `gh` with stdout copied both to ours and into the cache, kept when it exits 0 with
/// output.
fn fill(gh: &str, args: &[String], dir: &Path, path: &Path) -> i32 {
    if crate::home_fs::create_dirs(dir).is_err() {
        return run_through(gh, args);
    }
    let nanos = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap_or_default();
    let tmp = dir.join(format!(".tmp-{}-{}", std::process::id(), nanos.as_nanos()));
    let Ok(mut file) = crate::home_fs::create_file(&tmp) else { return run_through(gh, args) };
    let Ok(mut child) = Command::new(gh).args(args).stdout(Stdio::piped()).spawn() else {
        let _ = crate::home_fs::remove_file(&tmp);
        return 127;
    };
    let Some(mut out) = child.stdout.take() else {
        let _ = crate::home_fs::remove_file(&tmp);
        return match child.wait() {
            Ok(status) => status.code().unwrap_or(1),
            Err(_) => 1,
        };
    };
    let mut stdout = std::io::stdout().lock();
    let mut reader_gone = false;
    let mut stored = true;
    let mut bytes = 0u64;
    let mut buf = vec![0u8; 64 << 10];
    loop {
        let n = match out.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => {
                stored = false;
                break;
            }
        };
        bytes += n as u64;
        if stored && file.write_all(&buf[..n]).is_err() {
            stored = false;
        }
        if !reader_gone && stdout.write_all(&buf[..n]).is_err() {
            reader_gone = true;
        }
    }
    let _ = stdout.flush();
    let code = match child.wait() {
        Ok(s) => exit_code(s),
        Err(_) => 1,
    };
    if stored && code == 0 && bytes > 0 && file.sync_all().is_ok() {
        if crate::home_fs::rename(&tmp, path).is_err() {
            let _ = crate::home_fs::remove_file(&tmp);
        }
        evict(dir, SystemTime::now(), KEEP_FOR, KEEP_BYTES);
    } else {
        let _ = crate::home_fs::remove_file(&tmp);
    }
    code
}

#[cfg(unix)]
fn exit_code(s: std::process::ExitStatus) -> i32 {
    use std::os::unix::process::ExitStatusExt;
    s.code().unwrap_or_else(|| 128 + s.signal().unwrap_or(0))
}
#[cfg(not(unix))]
fn exit_code(s: std::process::ExitStatus) -> i32 {
    s.code().unwrap_or(1)
}

/// The call as asked: `gh ARGS` with our stdio, its exit code.
fn run_through(gh: &str, args: &[String]) -> i32 {
    match Command::new(gh).args(args).status() {
        Ok(s) => exit_code(s),
        Err(_) => 127,
    }
}

/// Drops logs older than `keep_for` and the oldest past `keep_bytes`, and a stale temp file.
pub(crate) fn evict(dir: &Path, now: SystemTime, keep_for: Duration, keep_bytes: u64) {
    let Ok(entries) = crate::home_fs::read_dir(dir) else { return };
    let mut logs: Vec<(SystemTime, u64, PathBuf)> = Vec::new();
    for e in entries {
        if !e.is_file {
            continue;
        }
        let path = dir.join(&e.name);
        let Ok(meta) = crate::home_fs::symlink_metadata(&path) else { continue };
        let at = meta.modified().unwrap_or(now);
        let age = now.duration_since(at).unwrap_or_default();
        let name = e.name.to_string_lossy();
        if name.starts_with(".tmp-") {
            if age > TMP_STALE {
                let _ = crate::home_fs::remove_file(&path);
            }
        } else if name.ends_with(".log") {
            if age > keep_for {
                let _ = crate::home_fs::remove_file(&path);
            } else {
                logs.push((at, meta.len(), path));
            }
        }
    }
    logs.sort_by_key(|(at, ..)| std::cmp::Reverse(*at));
    let mut total = 0u64;
    for (_, len, path) in logs {
        total += len;
        if total > keep_bytes {
            let _ = crate::home_fs::remove_file(path);
        }
    }
}

#[cfg(test)]
#[path = "ci_log_cache_tests.rs"]
mod tests;
