//! `acpmux pr-wait PR`: block until a pull request's checks finish (or it merges), with one
//! GitHub poller per machine however many agents wait on the same pull request.
//!
//! An agent that waits on CI by hand runs `gh pr checks` or `gh run view` in a loop, and ten
//! agents on one machine waiting on one pull request spend ten times the person's GitHub quota
//! for one answer. Here every waiter of `OWNER/REPO#N` on this machine shares one state file:
//! the waiter that finds it older than the poll interval takes the key's lock, runs one
//! `gh pr view --json`, writes the answer and lets go; the rest read the file. A waiter that
//! exits (its timeout) leaves the lock with it, so another one polls next.
//!
//! - The interval grows with the wait (`interval`): a fresh push is checked often, an hour-long
//!   suite once a minute and a half.
//! - A rate-limited answer is not retried at once: the poller reads when the limit resets
//!   (`gh api rate_limit`, which GitHub does not count) and every waiter sleeps until then.
//! - Every wait has a deadline (`--timeout`, default an hour) and every `gh` a 45 s bound.
//! - The judgement is `pr_state`'s (`acpmux_mcp_pr.rs`), the same one the `pr_state` tool gives.
//!
//! Each check is judged by its newest run at the head: a run cancelled for a newer run of the
//! same check (a concurrency group, a rerun) is not failing; the newer run's verdict, or the
//! wait for it, counts. A check whose newest run was cancelled is reported as cancelled.
//!
//! Exit: 0 green (or merged); 1 a failing check, a check cancelled with no newer run, closed
//! unmerged, or gh failing poll after poll (the message and `--json`'s detail say which:
//! `failed`, `cancelled`, `closed`); 3 timeout; 4 the head moved off `--sha`.

use super::errors::{AppError, Code};
use crate::acpmux_mcp::pr::{self, Target};
use anyhow::{Context as _, Result, anyhow, bail};
use cmux_file_lock::{FileLock, Kind, LockError};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::io::{Read as _, Seek as _, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// The fields one poll asks for: what `pr_state` judges checks and merges by, no comments or body.
const FIELDS: &str =
    "number,url,state,headRefOid,baseRefName,mergeable,mergedAt,mergeCommit,statusCheckRollup";
/// One `gh` call's bound.
const GH_TIMEOUT: Duration = Duration::from_secs(45);
/// The most of one answer that is read.
const OUTPUT_MAX: u64 = 4 << 20;
/// How long a waiter that did not get the lock waits before it reads the state again.
const LOCK_BUSY_STEP: Duration = Duration::from_secs(2);
/// A pull request with no checks yet right after a push is not green: wait this long for them.
const NO_CHECKS_GRACE_S: u64 = 120;
/// A head that differs from `--sha` this soon after the wait started is GitHub catching up.
const HEAD_GRACE_S: u64 = 60;
/// Wait when a rate limit's reset can not be read, and the cap of the error backoff.
const LIMIT_FALLBACK_S: u64 = 300;
const ERROR_BACKOFF_CAP_S: u64 = 600;
/// Consecutive failed polls (not rate limits) before the wait gives up with exit 2.
const MAX_ERRORS: u32 = 6;

#[derive(clap::ValueEnum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum Until {
    /// The checks at the head finished (green or not), or the PR merged or closed.
    Checks,
    /// The PR merged or closed.
    Merged,
}

#[derive(clap::Args, Debug)]
pub struct PrWaitArgs {
    /// The pull request: its number, #number or URL.
    pub pr: String,
    /// OWNER/REPO (default: the URL's, or this folder's origin).
    #[arg(long, short = 'R')]
    pub repo: Option<String>,
    /// The head you pushed (`git rev-parse HEAD`): exit 4 when the PR's head moved off it.
    #[arg(long)]
    pub sha: Option<String>,
    /// What to wait for.
    #[arg(long, value_enum, default_value = "checks")]
    pub until: Until,
    /// Give up after this long (exit 3): seconds (`3600`), or a duration (`90s`, `45m`,
    /// `2h`, `1h30m`).
    #[arg(long, default_value_t = 3600, value_parser = timeout_secs)]
    pub timeout: u64,
}

/// `--timeout`'s value in seconds: a bare number of seconds, or a duration of `s`, `m`, `h` and
/// `d` parts (`1h30m`).
pub(crate) fn timeout_secs(text: &str) -> std::result::Result<u64, String> {
    let text = text.trim();
    if let Ok(secs) = text.parse::<u64>() {
        return Ok(secs);
    }
    let bad = || format!("invalid --timeout {text:?}: use seconds (3600) or a duration (45m, 2h)");
    let (mut total, mut number) = (0u64, None::<u64>);
    for c in text.chars() {
        if let Some(d) = c.to_digit(10) {
            number = Some(number.unwrap_or(0).checked_mul(10).ok_or_else(bad)? + u64::from(d));
            continue;
        }
        let unit = match c.to_ascii_lowercase() {
            's' => 1,
            'm' => 60,
            'h' => 3600,
            'd' => 86_400,
            _ => return Err(bad()),
        };
        total = total.saturating_add(number.take().ok_or_else(bad)?.saturating_mul(unit));
    }
    if number.is_some() || total == 0 && text.is_empty() {
        return Err(bad());
    }
    Ok(total)
}

/// What every waiter of one key reads: the newest answer and when the next poll may run.
#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Shared {
    /// Unix seconds of the newest poll, answered or not.
    pub at: u64,
    /// The newest `gh pr view --json` answer.
    pub pr: Option<Value>,
    /// No poll before this (a rate limit's reset, or the error backoff).
    pub retry_at: u64,
    /// Consecutive failed polls, and the last failure.
    pub errors: u32,
    pub error: Option<String>,
}

/// How often a wait that started `elapsed_s` ago polls: 15 s at first, growing a second per
/// 20 s waited, at most 90 s.
pub(crate) fn interval(elapsed_s: u64) -> u64 {
    (15 + elapsed_s / 20).min(90)
}

/// How one answer ends the wait, or None to keep waiting. `since_start` is how long after the
/// wait started the answer was polled.
#[derive(Debug, PartialEq)]
pub(crate) enum Outcome {
    Done { code: i32, summary: String, structured: Value },
    HeadMoved { head: String },
}

pub(crate) fn judge(
    answer: &Value,
    until: Until,
    sha: Option<&str>,
    since_start: u64,
) -> Option<Outcome> {
    let (_, structured) = pr::pr_state(answer);
    let s = |k: &str| structured.get(k).and_then(Value::as_str).unwrap_or_default().to_owned();
    let summary = s("summary");
    let done = |code| {
        Some(Outcome::Done { code, summary: summary.clone(), structured: structured.clone() })
    };
    match s("state").as_str() {
        "merged" => return done(0),
        "closed" => return done(1),
        _ => {}
    }
    let head = s("headSha");
    if let Some(sha) = sha
        && !head.is_empty()
        && !head.starts_with(&sha.to_ascii_lowercase())
    {
        return (since_start >= HEAD_GRACE_S).then_some(Outcome::HeadMoved { head });
    }
    if until == Until::Merged {
        return None;
    }
    let count = |k: &str| structured.get(k).and_then(Value::as_u64).unwrap_or(0);
    let pending = count("pendingChecks");
    let failing = structured.get("failingChecks").and_then(Value::as_array).map_or(0, Vec::len);
    if failing > 0 {
        return done(1);
    }
    if pending > 0 {
        return None;
    }
    // A check whose newest run was cancelled, with no newer run queued: no verdict is coming, so
    // the wait ends, and says cancelled (not failing): rerun it. A cancel a newer run replaced
    // never gets here (`pr::newest_runs`).
    if structured.get("cancelledChecks").and_then(Value::as_array).is_some_and(|c| !c.is_empty()) {
        return done(1);
    }
    if count("passedChecks") == 0 && since_start < NO_CHECKS_GRACE_S {
        return None;
    }
    done(0)
}

/// Whether gh's stderr says GitHub refused for a rate limit, and whether it was the secondary one.
pub(crate) fn rate_limited(stderr: &str) -> Option<bool> {
    let low = stderr.to_ascii_lowercase();
    if low.contains("secondary rate limit") || low.contains("abuse detection") {
        Some(true)
    } else if low.contains("rate limit") {
        Some(false)
    } else {
        None
    }
}

/// The key's file name: `owner__repo__N`, only characters a file name takes everywhere.
pub(crate) fn key(repo: &str, number: &str) -> String {
    let clean = |s: &str| {
        s.chars()
            .map(|c| if c.is_ascii_alphanumeric() || "-_.".contains(c) { c } else { '_' })
            .collect::<String>()
    };
    format!("{}__{}", clean(&repo.replace('/', "__")), clean(number))
}

/// `OWNER/REPO` from a GitHub remote URL (https, ssh or scp form).
pub(crate) fn repo_of_remote(url: &str) -> Option<String> {
    let url = url.trim().trim_end_matches('/');
    let rest = url.split_once("github.com").map(|(_, r)| r)?;
    let rest = rest.trim_start_matches([':', '/']).trim_end_matches(".git");
    let (owner, repo) = rest.split_once('/')?;
    (!owner.is_empty() && !repo.is_empty() && !repo.contains('/'))
        .then(|| format!("{owner}/{repo}"))
}

fn now_s() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs())
}

/// Where a wait keeps its shared state and which `gh` it runs (a fake one in the tests).
pub(crate) struct Ctx {
    pub dir: PathBuf,
    pub gh: std::ffi::OsString,
}

/// Where the shared state lives: `ACPMUX_PR_WAIT_DIR`, else the user cache folder's
/// `cmux/pr-wait` (`cmux-next/pr-wait` on macOS, `cmux_config::NEXT_DIR`). Regenerable: deleting it costs one poll.
fn state_dir() -> Result<PathBuf> {
    if let Some(dir) = std::env::var_os("ACPMUX_PR_WAIT_DIR") {
        return Ok(PathBuf::from(dir));
    }
    let cache = dirs::cache_dir().ok_or_else(|| anyhow!("no cache folder for pr-wait's state"))?;
    Ok(cache.join(cmux_config::NEXT_DIR).join("pr-wait"))
}

fn read_shared(path: &Path) -> Shared {
    std::fs::read(path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

fn write_shared(path: &Path, shared: &Shared) -> Result<()> {
    let tmp = path.with_extension(format!("tmp{}", std::process::id()));
    std::fs::write(&tmp, serde_json::to_vec(shared)?)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

/// One bounded `gh` run: its stdout on success, else its stderr.
fn gh(ctx: &Ctx, args: &[&str], deadline: Instant) -> Result<std::result::Result<Vec<u8>, String>> {
    // Its output goes to unnamed files, so a large answer never fills a pipe nobody reads yet.
    let (mut out, mut err) = (tempfile::tempfile()?, tempfile::tempfile()?);
    let mut child = cmux_process::Command::new(&ctx.gh)
        .args(args)
        .stdin(cmux_process::Stdio::null())
        .stdout(out.try_clone()?)
        .stderr(err.try_clone()?)
        .spawn()
        .map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => anyhow!("gh is not installed or not on PATH"),
            _ => anyhow!("gh could not run: {e}"),
        })?;
    let bound = deadline.min(Instant::now() + GH_TIMEOUT).saturating_duration_since(Instant::now());
    // Past the bound the Child drops here, which ends gh's group and reaps it.
    let Some(status) = child.wait_timeout(bound)? else {
        return Ok(Err(format!("gh did not answer in {}s", bound.as_secs())));
    };
    let read = |f: &mut std::fs::File| -> std::io::Result<Vec<u8>> {
        f.seek(SeekFrom::Start(0))?;
        let mut buf = Vec::new();
        f.take(OUTPUT_MAX).read_to_end(&mut buf)?;
        Ok(buf)
    };
    if status.success() {
        return Ok(Ok(read(&mut out)?));
    }
    let stderr = read(&mut err)?;
    let stderr = String::from_utf8_lossy(&stderr);
    let tail: String =
        stderr.trim().chars().rev().take(400).collect::<Vec<_>>().into_iter().rev().collect();
    Ok(Err(tail))
}

/// Poll once, as the key's lock holder, and fold the answer into `shared`.
fn poll(
    ctx: &Ctx,
    target: &Target,
    repo: &str,
    shared: &mut Shared,
    deadline: Instant,
) -> Result<()> {
    let now = now_s();
    shared.at = now;
    let args = ["pr", "view", target.selector.as_str(), "-R", repo, "--json", FIELDS];
    match gh(ctx, &args, deadline)? {
        Ok(stdout) => {
            shared.pr = Some(serde_json::from_slice(&stdout).context("gh pr view gave no JSON")?);
            shared.errors = 0;
            shared.error = None;
            shared.retry_at = 0;
        }
        Err(stderr) => {
            shared.errors = shared.errors.saturating_add(1);
            shared.retry_at = match rate_limited(&stderr) {
                // The secondary limit names no reset; GitHub asks for a minute or more.
                Some(true) => now + 120,
                Some(false) => {
                    limit_reset(ctx, deadline).map_or(now + LIMIT_FALLBACK_S, |r| r.max(now) + 5)
                }
                None => now + (30u64 << shared.errors.min(5)).min(ERROR_BACKOFF_CAP_S),
            };
            if rate_limited(&stderr).is_some() {
                // A rate limit is no failure of the wait: it ends at the reset.
                shared.errors = 0;
            }
            shared.error = Some(stderr);
        }
    }
    Ok(())
}

/// When the GraphQL limit (`gh pr view`'s) resets, in unix seconds. `rate_limit` costs no quota.
fn limit_reset(ctx: &Ctx, deadline: Instant) -> Option<u64> {
    let out =
        gh(ctx, &["api", "rate_limit", "--jq", ".resources.graphql.reset"], deadline).ok()?.ok()?;
    String::from_utf8_lossy(&out).trim().parse().ok()
}

fn sleep_until(at_s: u64, deadline: Instant) {
    let wait = Duration::from_secs(at_s.saturating_sub(now_s()).max(1));
    let left = deadline.saturating_duration_since(Instant::now());
    std::thread::sleep(wait.min(left));
}

fn resolve_repo(target: &Target) -> Result<String> {
    if let Some(repo) = &target.repo {
        return Ok(repo.clone());
    }
    let out = cmux_process::Command::new("git")
        .args(["config", "--get", "remote.origin.url"])
        .stderr(cmux_process::Stdio::null())
        .output()
        .context("git could not run")?;
    repo_of_remote(&String::from_utf8_lossy(&out.stdout))
        .ok_or_else(|| anyhow!("no GitHub origin in this folder: pass --repo OWNER/REPO"))
}

/// The wait itself, on a blocking thread: for `run` and the tests.
fn wait_blocking(ctx: &Ctx, args: &PrWaitArgs, json_out: bool) -> Result<()> {
    let target = pr::target(&json!({"pr": args.pr, "repo": args.repo})).map_err(|e| anyhow!(e))?;
    let repo = resolve_repo(&target)?;
    let dir = &ctx.dir;
    std::fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
    let key = key(&repo, &target.selector);
    let state_path = dir.join(format!("{key}.json"));
    let lock_path = dir.join(format!("{key}.lock"));
    let started = now_s();
    let deadline = Instant::now() + Duration::from_secs(args.timeout);
    let mut last_summary = String::new();
    let mut last_error: Option<String> = None;
    loop {
        let now = now_s();
        let elapsed = now.saturating_sub(started);
        let shared = read_shared(&state_path);
        if let Some(answer) =
            shared.pr.as_ref().filter(|_| shared.at >= started.saturating_sub(interval(0)))
        {
            match judge(answer, args.until, args.sha.as_deref(), shared.at.saturating_sub(started))
            {
                Some(Outcome::Done { code: 0, summary, structured }) => {
                    if json_out {
                        crate::cli::output::print_json(&structured);
                    } else {
                        println!("{summary}");
                    }
                    return Ok(());
                }
                Some(Outcome::Done { summary, structured, .. }) => {
                    let detail = if structured.get("state").and_then(Value::as_str)
                        == Some("closed")
                    {
                        "closed"
                    } else if structured.get("status").and_then(Value::as_str) == Some("cancelled")
                    {
                        "cancelled"
                    } else {
                        "failed"
                    };
                    return Err(AppError::new(Code::Runtime, detail, summary)
                        .with_data(structured)
                        .into());
                }
                Some(Outcome::HeadMoved { head }) => {
                    let sha = args.sha.as_deref().unwrap_or_default();
                    let mut e = AppError::new(
                        Code::Runtime,
                        "head_moved",
                        format!("the head moved to {head}, off --sha {sha}: wait on the new head"),
                    );
                    e.exit = Some(4);
                    return Err(e.into());
                }
                None => {
                    let (summary, _) = pr::pr_state(answer);
                    let first = summary.lines().next().unwrap_or_default().to_owned();
                    if first != last_summary && !json_out {
                        eprintln!("pr-wait: {first}");
                        last_summary = first;
                    }
                }
            }
        }
        if shared.errors >= MAX_ERRORS {
            bail!(
                "gh failed {} times in a row: {}",
                shared.errors,
                shared.error.unwrap_or_default()
            );
        }
        if shared.error != last_error {
            if let Some(e) = &shared.error {
                eprintln!(
                    "pr-wait: gh: {e} (next try in {}s)",
                    shared.retry_at.saturating_sub(now)
                );
            }
            last_error = shared.error.clone();
        }
        if Instant::now() >= deadline {
            let last =
                if last_summary.is_empty() { String::new() } else { format!(": {last_summary}") };
            return Err(
                AppError::timeout(format!("timed out after {}s{last}", args.timeout)).into()
            );
        }
        let next = shared.retry_at.max(shared.at + interval(elapsed));
        if now < next {
            sleep_until(next, deadline);
            continue;
        }
        let file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(&lock_path)?;
        match FileLock::try_take(file, Kind::Exclusive) {
            Ok(_held) => {
                // Another waiter may have polled between the read and the lock.
                let mut shared = read_shared(&state_path);
                if now_s() >= shared.retry_at.max(shared.at + interval(elapsed)) {
                    poll(ctx, &target, &repo, &mut shared, deadline)?;
                    write_shared(&state_path, &shared)?;
                }
            }
            Err(LockError::Busy(_)) => std::thread::sleep(LOCK_BUSY_STEP),
            Err(LockError::Io(e)) => return Err(e.into()),
        }
    }
}

pub async fn run(args: PrWaitArgs, json_out: bool) -> Result<()> {
    tokio::task::spawn_blocking(move || {
        wait_blocking(&Ctx { dir: state_dir()?, gh: "gh".into() }, &args, json_out)
    })
    .await?
}

#[cfg(test)]
#[path = "pr_wait_tests.rs"]
mod tests;
