//! `acpmux ci wait pr N | run ID --timeout SECS`: one bounded wait for GitHub CI that spends
//! almost none of the person's GitHub API quota, so an agent never writes a `sleep` loop around
//! `gh pr checks` or `gh run view` (the `cmux-quota` skill sends agents here).
//!
//! - Every read is conditional. The ETag and body of each URL are kept on disk, shared by every
//!   wait on this machine, so a read nothing changed is a `304 Not Modified`, which GitHub does not
//!   count against the rate limit. Two agents waiting on one pull request cost what one does.
//! - The interval starts at [`Schedule::base`] and grows by half while nothing changes, up to
//!   [`Schedule::cap`]; a change sets it back.
//! - A `403`/`429` waits out its `Retry-After`, or the reset when `x-ratelimit-remaining` is 0.
//!   Under [`LOW_WATER`] calls left the interval stretches to [`LOW_WATER_INTERVAL`].
//! - `--timeout` is required: a wait without a deadline is the loop this replaces. Past it the
//!   command exits 3 with the last state it saw.
//!
//! A pull request is green when every check run on its head finished without a failing
//! conclusion and its commit status is not pending or failing; red at the first failing check (no
//! point waiting out the rest); green as soon as it merged; red when it closed unmerged. A head
//! with no checks at all is green after [`NO_CHECKS_GRACE`] (a repository without CI).
//!
//! Exit codes (`errors.rs`): 0 green, 1 red, 2 usage, 3 timeout.
//!
//! The token: `GH_TOKEN`, `GITHUB_TOKEN`, else `gh auth token`. The API: `GITHUB_API_URL`, else
//! api.github.com.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{Context as _, Result, anyhow, bail};
use clap::{Args, Subcommand, ValueEnum};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use crate::cli::errors::{AppError, Code};
use crate::cli::output::print_json;

/// Below this many REST calls left the wait slows to [`LOW_WATER_INTERVAL`].
pub const LOW_WATER: u64 = 200;
pub const LOW_WATER_INTERVAL: Duration = Duration::from_secs(300);
/// A head with no check run and no status this long into the wait has no CI.
pub const NO_CHECKS_GRACE: Duration = Duration::from_secs(300);
/// Each request's own bound.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
/// Check-run pages read per head (100 runs each).
const MAX_PAGES: usize = 10;

#[derive(Subcommand, Debug, PartialEq, Eq)]
pub enum CiCmd {
    /// Wait until a pull request's checks or a workflow run finish, with conditional reads that
    /// cost no GitHub quota while nothing changes. Exits 0 green, 1 red, 3 at the timeout.
    Wait(WaitArgs),
}

#[derive(Args, Debug, PartialEq, Eq)]
pub struct WaitArgs {
    /// What to wait for.
    #[arg(value_enum)]
    pub kind: Kind,
    /// The pull request number or the workflow run id.
    pub id: String,
    /// OWNER/REPO; default: the GitHub repository `origin` names in this folder.
    #[arg(long, short = 'R')]
    pub repo: Option<String>,
    /// Give up after this many seconds (exit 3). Size it to the job.
    #[arg(long)]
    pub timeout: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, ValueEnum)]
pub enum Kind {
    Pr,
    Run,
}

/// How often to read.
#[derive(Clone, Copy, Debug)]
pub struct Schedule {
    pub base: Duration,
    pub cap: Duration,
}

impl Default for Schedule {
    fn default() -> Self {
        Self { base: Duration::from_secs(15), cap: Duration::from_secs(120) }
    }
}

impl Schedule {
    /// The next interval: back to `base` after a change, else half again, up to `cap`.
    pub fn next(&self, current: Duration, changed: bool) -> Duration {
        if changed {
            self.base
        } else {
            current
                .saturating_add(current.checked_div(2).unwrap_or_default())
                .clamp(self.base, self.cap)
        }
    }
}

/// Where a wait stands.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum State {
    Pending { done: usize, total: usize },
    Green { note: String },
    Red { note: String },
}

/// A pull request's state from its pull, its head's check runs and its combined status.
pub fn pr_state(pull: &Value, runs: &[Value], status: &Value, waited: Duration) -> State {
    if pull["merged"].as_bool() == Some(true) || !pull["merged_at"].is_null() {
        return State::Green { note: "merged".into() };
    }
    if pull["state"].as_str() == Some("closed") {
        return State::Red { note: "closed without merging".into() };
    }
    let failing: Vec<&str> = runs
        .iter()
        .filter(|r| r["status"].as_str() == Some("completed") && failed(&r["conclusion"]))
        .filter_map(|r| r["name"].as_str())
        .collect();
    let statuses = status["statuses"].as_array().map_or(&[][..], Vec::as_slice);
    let failing_statuses: Vec<&str> = statuses
        .iter()
        .filter(|s| matches!(s["state"].as_str(), Some("failure" | "error")))
        .filter_map(|s| s["context"].as_str())
        .collect();
    if !failing.is_empty() || !failing_statuses.is_empty() {
        let names: Vec<&str> = failing.into_iter().chain(failing_statuses).collect();
        return State::Red { note: format!("failing: {}", names.join(", ")) };
    }
    let total = runs.len().saturating_add(statuses.len());
    let done =
        runs.iter().filter(|r| r["status"].as_str() == Some("completed")).count().saturating_add(
            statuses.iter().filter(|s| s["state"].as_str() != Some("pending")).count(),
        );
    if total == 0 {
        return if waited >= NO_CHECKS_GRACE {
            State::Green { note: "no checks on the head".into() }
        } else {
            State::Pending { done: 0, total: 0 }
        };
    }
    if done == total {
        State::Green { note: format!("{total} checks passed") }
    } else {
        State::Pending { done, total }
    }
}

/// A workflow run's state.
pub fn run_state(run: &Value) -> State {
    if run["status"].as_str() != Some("completed") {
        return State::Pending { done: 0, total: 1 };
    }
    let conclusion = run["conclusion"].as_str().unwrap_or("unknown");
    if failed(&run["conclusion"]) {
        State::Red { note: conclusion.into() }
    } else {
        State::Green { note: conclusion.into() }
    }
}

fn failed(conclusion: &Value) -> bool {
    matches!(
        conclusion.as_str(),
        Some("failure" | "timed_out" | "cancelled" | "action_required" | "startup_failure")
    )
}

/// What a rate-limited or throttled answer asks the wait to do.
pub fn throttle(
    status: u16,
    headers: &reqwest::header::HeaderMap,
    now_epoch: u64,
) -> Option<Duration> {
    let num = |name: &str| headers.get(name)?.to_str().ok()?.trim().parse::<u64>().ok();
    if let Some(secs) = num("retry-after") {
        return Some(Duration::from_secs(secs.max(1)));
    }
    if num("x-ratelimit-remaining") == Some(0) {
        let reset = num("x-ratelimit-reset").unwrap_or(now_epoch.saturating_add(60));
        return Some(Duration::from_secs(reset.saturating_sub(now_epoch).saturating_add(1)));
    }
    // A secondary limit with neither header: GitHub asks for at least a minute.
    matches!(status, 403 | 429).then_some(Duration::from_secs(60))
}

/// The shared conditional-read cache: one file per URL, `{etag, body}`.
pub struct Cache {
    dir: PathBuf,
}

impl Cache {
    pub fn new(dir: PathBuf) -> Self {
        Self { dir }
    }

    pub fn default_dir() -> Option<PathBuf> {
        Some(dirs::cache_dir()?.join("acpmux").join("ci-wait"))
    }

    fn path(&self, url: &str) -> PathBuf {
        let digest = Sha256::digest(url.as_bytes());
        let name: String = digest.iter().take(16).map(|b| format!("{b:02x}")).collect();
        self.dir.join(format!("{name}.json"))
    }

    pub fn get(&self, url: &str) -> Option<(String, Value)> {
        let entry: Value = serde_json::from_slice(&std::fs::read(self.path(url)).ok()?).ok()?;
        Some((entry.get("etag")?.as_str()?.to_owned(), entry.get("body")?.clone()))
    }

    /// Owner-only (an answer may be a private repository's), written whole through `home_fs`.
    pub fn put(&self, url: &str, etag: &str, body: &Value) {
        let entry = json!({"etag": etag, "body": body});
        let _ = crate::home_fs::write_json_private(&self.path(url), entry.to_string().as_bytes());
    }
}

/// Requests made, and how many GitHub answered from the ETag (free).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Counts {
    pub requests: u64,
    pub not_modified: u64,
}

/// One reader of the GitHub REST API with the shared cache.
pub struct Reader {
    http: reqwest::Client,
    api: String,
    token: String,
    cache: Cache,
    pub counts: Counts,
    /// The last `x-ratelimit-remaining` GitHub sent.
    pub remaining: Option<u64>,
}

/// A read's outcome: the body and whether it changed, or how long to back off.
enum Read {
    Body { body: Value, changed: bool },
    Throttled(Duration),
}

impl Reader {
    pub fn new(api: String, token: String, cache: Cache) -> Result<Self> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let http = reqwest::Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .user_agent(concat!("acpmux-ci-wait/", env!("CARGO_PKG_VERSION")))
            .build()?;
        Ok(Self { http, api, token, cache, counts: Counts::default(), remaining: None })
    }

    async fn get(&mut self, path: &str) -> Result<Read> {
        let url = format!("{}{path}", self.api);
        let cached = self.cache.get(&url);
        let mut request = self
            .http
            .get(&url)
            .bearer_auth(&self.token)
            .header("accept", "application/vnd.github+json")
            .header("x-github-api-version", "2022-11-28");
        if let Some((etag, _)) = &cached {
            request = request.header("if-none-match", etag);
        }
        let response = request.send().await.with_context(|| format!("GET {path}"))?;
        self.counts.requests = self.counts.requests.saturating_add(1);
        let status = response.status().as_u16();
        let headers = response.headers().clone();
        if let Some(left) =
            headers.get("x-ratelimit-remaining").and_then(|v| v.to_str().ok()?.parse::<u64>().ok())
        {
            self.remaining = Some(left);
        }
        if status == 304 {
            self.counts.not_modified = self.counts.not_modified.saturating_add(1);
            let (_, body) = cached.ok_or_else(|| anyhow!("GET {path}: 304 with nothing cached"))?;
            return Ok(Read::Body { body, changed: false });
        }
        if matches!(status, 403 | 429) {
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_secs());
            if let Some(wait) = throttle(status, &headers, now)
                && (status == 429
                    || headers.contains_key("retry-after")
                    || headers.get("x-ratelimit-remaining").is_some_and(|v| v == "0")
                    || is_secondary_limit(&response.text().await.unwrap_or_default()))
            {
                return Ok(Read::Throttled(wait));
            }
            bail!("GET {path}: {status}: check the token's access to this repository");
        }
        if !(200..300).contains(&status) {
            let text = response.text().await.unwrap_or_default();
            bail!("GET {path}: {status}: {}", text.chars().take(200).collect::<String>());
        }
        let body: Value = response.json().await.with_context(|| format!("GET {path}: body"))?;
        if let Some(etag) = headers.get("etag").and_then(|v| v.to_str().ok()) {
            self.cache.put(&url, etag, &body);
        }
        let changed = cached.is_none_or(|(_, old)| old != body);
        Ok(Read::Body { body, changed })
    }
}

fn is_secondary_limit(text: &str) -> bool {
    text.contains("secondary rate limit") || text.contains("abuse")
}

/// One look at the target: its state and whether anything changed since the last look, or how
/// long GitHub asked the wait to back off.
async fn look(
    reader: &mut Reader,
    repo: &str,
    kind: Kind,
    id: &str,
    waited: Duration,
) -> Result<Result<(State, bool, Option<String>), Duration>> {
    // One read; a throttle ends the look with GitHub's backoff.
    macro_rules! read {
        ($path:expr, $changed:ident) => {
            match reader.get(&$path).await? {
                Read::Body { body, changed } => {
                    $changed |= changed;
                    body
                }
                Read::Throttled(wait) => return Ok(Err(wait)),
            }
        };
    }
    let mut changed = false;
    if kind == Kind::Run {
        let run = read!(format!("/repos/{repo}/actions/runs/{id}"), changed);
        return Ok(Ok((run_state(&run), changed, None)));
    }
    let pull = read!(format!("/repos/{repo}/pulls/{id}"), changed);
    let sha = pull
        .pointer("/head/sha")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("pull {id} has no head"))?
        .to_owned();
    if pull.get("state").and_then(Value::as_str) == Some("closed") {
        return Ok(Ok((pr_state(&pull, &[], &Value::Null, waited), changed, Some(sha))));
    }
    let mut runs = Vec::new();
    for page in 1..=MAX_PAGES {
        let body = read!(
            format!("/repos/{repo}/commits/{sha}/check-runs?per_page=100&page={page}"),
            changed
        );
        let total = body.get("total_count").and_then(Value::as_u64).unwrap_or(0);
        let page_runs = body.get("check_runs").and_then(Value::as_array);
        runs.extend(page_runs.cloned().unwrap_or_default());
        if runs.len() as u64 >= total || page_runs.is_none_or(Vec::is_empty) {
            break;
        }
    }
    let status = read!(format!("/repos/{repo}/commits/{sha}/status"), changed);
    Ok(Ok((pr_state(&pull, &runs, &status, waited), changed, Some(sha))))
}

/// The whole wait, with its schedule; `run` gives it the real one.
pub async fn wait(
    reader: &mut Reader,
    repo: &str,
    kind: Kind,
    id: &str,
    deadline: Duration,
    schedule: Schedule,
) -> Result<(State, Option<String>)> {
    let start = Instant::now();
    let mut interval = schedule.base;
    let mut last: Option<(State, Option<String>)> = None;
    loop {
        let waited = start.elapsed();
        let pause = match look(reader, repo, kind, id, waited).await? {
            Ok((state, changed, sha)) => {
                if !matches!(state, State::Pending { .. }) {
                    return Ok((state, sha));
                }
                if changed && let State::Pending { done, total } = &state {
                    eprintln!("acpmux ci wait: {kind:?} {id}: {done}/{total} checks done");
                }
                last = Some((state, sha));
                interval = schedule.next(interval, changed);
                if reader.remaining.is_some_and(|r| r < LOW_WATER) {
                    interval.max(LOW_WATER_INTERVAL)
                } else {
                    interval
                }
            }
            Err(backoff) => {
                eprintln!(
                    "acpmux ci wait: GitHub asked to slow down; waiting {}s",
                    backoff.as_secs()
                );
                backoff
            }
        };
        let left = deadline.saturating_sub(start.elapsed());
        if left.is_zero() || pause >= left {
            if !left.is_zero() {
                tokio::time::sleep(left).await;
            }
            let (state, sha) = last.unwrap_or((State::Pending { done: 0, total: 0 }, None));
            let seen = match &state {
                State::Pending { done, total } => format!("{done}/{total} checks done"),
                _ => String::new(),
            };
            let at = sha
                .as_deref()
                .map(|s| format!(" at {}", s.get(..12).unwrap_or(s)))
                .unwrap_or_default();
            return Err(AppError::timeout(format!(
                "{} {id}{at}: still pending after {}s ({seen}); wait again with a longer --timeout or look at the run",
                kind_name(kind),
                deadline.as_secs()
            ))
            .into());
        }
        tokio::time::sleep(pause).await;
    }
}

fn kind_name(kind: Kind) -> &'static str {
    match kind {
        Kind::Pr => "pr",
        Kind::Run => "run",
    }
}

/// OWNER/REPO from a GitHub remote URL (`https://github.com/o/r(.git)`, `git@github.com:o/r.git`,
/// `ssh://git@github.com/o/r`).
pub fn repo_from_remote(url: &str) -> Option<String> {
    let url = url.trim();
    let rest = url
        .strip_prefix("git@github.com:")
        .or_else(|| url.split_once("github.com/").map(|(_, r)| r))?;
    let rest = rest.trim_end_matches('/').trim_end_matches(".git");
    let mut parts = rest.split('/');
    let (owner, name) = (parts.next()?, parts.next()?);
    (!owner.is_empty() && !name.is_empty() && parts.next().is_none())
        .then(|| format!("{owner}/{name}"))
}

fn valid_repo(repo: &str) -> bool {
    let mut parts = repo.split('/');
    let ok = |p: Option<&str>| {
        p.is_some_and(|p| {
            !p.is_empty()
                && p.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
        })
    };
    ok(parts.next()) && ok(parts.next()) && parts.next().is_none()
}

/// PROGRAM's trimmed stdout when it succeeds within 10 s (`github_status::from_gh`'s pattern).
async fn run_bounded(program: &str, args: &[&str], dir: Option<&Path>) -> Option<String> {
    use std::process::Stdio;
    let mut command = tokio::process::Command::new(program);
    command.args(args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
    command.kill_on_drop(true);
    if let Some(dir) = dir {
        command.current_dir(dir);
    }
    let output =
        tokio::time::timeout(Duration::from_secs(10), command.output()).await.ok()?.ok()?;
    output.status.success().then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

async fn token() -> Result<String> {
    for name in ["GH_TOKEN", "GITHUB_TOKEN"] {
        if let Ok(value) = std::env::var(name)
            && !value.trim().is_empty()
        {
            return Ok(value.trim().to_owned());
        }
    }
    run_bounded("gh", &["auth", "token"], None).await.filter(|t| !t.is_empty()).ok_or_else(|| {
        AppError::usage("no GitHub token: set GH_TOKEN, or sign in with `gh auth login`").into()
    })
}

pub async fn run(cmd: CiCmd, json_out: bool) -> Result<()> {
    let CiCmd::Wait(args) = cmd;
    if args.timeout == 0 {
        return Err(AppError::usage("--timeout must be more than 0 seconds").into());
    }
    let id = args.id.trim_start_matches('#').to_owned();
    if id.is_empty() || !id.chars().all(|c| c.is_ascii_digit()) {
        return Err(AppError::usage(format!("{:?} is not a number", args.id)).into());
    }
    let repo = match args.repo {
        Some(repo) => repo,
        None => run_bounded("git", &["remote", "get-url", "origin"], Some(Path::new(".")))
            .await
            .as_deref()
            .and_then(repo_from_remote)
            .ok_or_else(|| AppError::usage("no GitHub `origin` here: pass --repo OWNER/REPO"))?,
    };
    if !valid_repo(&repo) {
        return Err(AppError::usage(format!("{repo:?} is not OWNER/REPO")).into());
    }
    let api = std::env::var("GITHUB_API_URL")
        .ok()
        .filter(|u| !u.is_empty())
        .unwrap_or_else(|| "https://api.github.com".into());
    let cache = Cache::new(Cache::default_dir().ok_or_else(|| anyhow!("no cache folder"))?);
    let mut reader = Reader::new(api.trim_end_matches('/').to_owned(), token().await?, cache)?;
    let started = Instant::now();
    let outcome = wait(
        &mut reader,
        &repo,
        args.kind,
        &id,
        Duration::from_secs(args.timeout),
        Schedule::default(),
    )
    .await;
    let counts = reader.counts;
    let (state, sha) = outcome?;
    let (verdict, note) = match &state {
        State::Green { note } => ("green", note.as_str()),
        State::Red { note } => ("red", note.as_str()),
        // `wait` returns only a finished state; a pending one reads as the timeout it would be.
        State::Pending { .. } => ("pending", "not finished"),
    };
    if json_out {
        print_json(&json!({
            "repo": repo, "kind": kind_name(args.kind), "id": id, "sha": sha, "verdict": verdict,
            "note": note, "waitedSecs": started.elapsed().as_secs(),
            "requests": counts.requests, "notModified": counts.not_modified,
        }));
    } else {
        let at =
            sha.as_deref().map(|s| format!(" at {}", s.get(..12).unwrap_or(s))).unwrap_or_default();
        println!(
            "{repo} {} {id}{at}: {verdict}: {note} ({} requests, {} answered free by ETag)",
            kind_name(args.kind),
            counts.requests,
            counts.not_modified
        );
    }
    let what = format!("{repo} {} {id}: {note}", kind_name(args.kind));
    match verdict {
        "red" => Err(AppError::new(Code::Runtime, "ci_red", what).into()),
        "pending" => Err(AppError::timeout(what).into()),
        _ => Ok(()),
    }
}

#[cfg(test)]
#[path = "ci_wait_tests.rs"]
mod tests;
