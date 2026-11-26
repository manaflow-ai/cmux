//! The `acpmux` MCP server's `pr_state` tool: one pull request's state in one call, condensed.
//! Its first line is the outcome (`#1609 open at 4db9066b: mergeable, 1 failing check
//! (ws-check), SHIP at head`), the lines after it the detail: head and base, mergeability,
//! failing checks by name and how many are pending, the newest review receipt (a comment line
//! `Review (...): SHIP at <sha>` or `BLOCK at <sha>`) and whether it is at the head, and holds
//! (a `HOLD:` body line or a hold label). `structuredContent` carries the same with `summary`
//! (the first line) and `status`: `ok` (open with nothing failing or pending, merged, or
//! closed), `failed` (a failing check, or a BLOCK at the head), `running` (checks pending) or
//! `cancelled` (nothing failing or pending, but a check's newest run was cancelled). Each check
//! is judged by its newest run at the head (`newest_runs`): a cancelled run that a newer run of
//! the same check replaced is not a verdict.
//!
//! Like every condensed tool it takes an optional `description`, a few words the transcript
//! titles the row with. The data comes from the daemon's one GitHub poller for the machine
//! (`_acpmux/github/pr_state`, `pr_poller.rs`): every chat on the machine reads one pull request
//! through one entry, with conditional requests and one budget, so N chats looking cost one
//! GitHub read, not N. Without `repo` the repository is the chat folder's `origin`. When the
//! daemon cannot answer (an older daemon, no `gh` login of its own, a repository only the
//! agent's token reads), it is one `gh pr view` run by this server, which the chat's agent
//! started with its environment, in the chat's folder, as before. The parsing is pure
//! ([`pr_state`]) and tested on fixture JSON.
//!
//! `pr_wait` waits in the daemon until the pull request is settled (nothing pending, or merged
//! or closed) or changed, or `timeoutSecs` (default 45, under Codex's 60 s tool timeout) passes:
//! every chat waiting on one pull request shares the poller's reads (`_acpmux/github/pr_wait`).

use super::{arg, error_result, ok};
use crate::client::Client;
use crate::rpc::method;
use serde_json::{Value, json};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

pub(super) const NAME: &str = "pr_state";
pub(super) const WAIT_NAME: &str = "pr_wait";
/// How long `pr_wait` waits unless asked: under the shortest harness tool timeout (Codex: 60 s).
const WAIT_DEFAULT_S: u64 = 45;
/// The longest `pr_wait` a call may ask for (the daemon's own bound is an hour).
const WAIT_MAX_S: u64 = 1800;
/// How long reading the chat folder's origin may take.
const GIT_TIMEOUT: Duration = Duration::from_secs(5);
/// The fields the one `gh pr view` asks for.
const FIELDS: &str = "number,url,state,headRefOid,baseRefName,mergeable,mergedAt,mergeCommit,\
labels,body,comments,statusCheckRollup";
/// How long gh may take: under the shortest MCP tool timeout of the harnesses (Codex: 60 s).
const GH_TIMEOUT: Duration = Duration::from_secs(45);
/// Failing check names the first line lists before `+N more`.
const NAMES_SHOWN: usize = 3;

pub(super) fn tool() -> Value {
    json!({
        "name": NAME,
        "description": "One pull request's state in one call, instead of gh in a shell. The first line is the outcome (\"#1609 open at 4db9066b: mergeable, 1 failing check (ws-check), SHIP at head\" or \"#1557 merged as f0175fe0\"); then head and base, mergeability, failing and pending checks, the newest SHIP/BLOCK review receipt and whether it is at the head, and holds. structuredContent.status is ok, failed (a failing check or BLOCK at head), running or cancelled (a check's newest run was cancelled).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "pr": {"type": "string", "description": "The pull request: its number, #number, OWNER/REPO#number, or its URL."},
                "repo": {"type": "string", "description": "OWNER/REPO (default: the chat folder's origin, or the URL's)."},
                "description": {"type": "string", "description": "A few words on why you look, shown as this call's title."}
            },
            "required": ["pr"]
        }
    })
}

pub(super) fn wait_tool() -> Value {
    json!({
        "name": WAIT_NAME,
        "description": "Wait for a pull request to settle (no check pending, or merged or closed), or with until \"change\" for its state line to change, then answer as pr_state does. The daemon's one shared GitHub poller does the waiting; use it instead of polling gh. It returns at timeoutSecs (default 45; call again to keep waiting) with structuredContent.timedOut true.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "pr": {"type": "string", "description": "The pull request: its number, #number, or its URL."},
                "repo": {"type": "string", "description": "OWNER/REPO (default: the chat folder's origin, or the URL's)."},
                "timeoutSecs": {"type": "integer", "minimum": 1, "maximum": WAIT_MAX_S, "description": "How long to wait at most (default 45)."},
                "until": {"type": "string", "enum": ["settled", "change"], "description": "settled (default) or change."},
                "description": {"type": "string", "description": "A few words on why you wait, shown as this call's title."}
            },
            "required": ["pr"]
        }
    })
}

/// Which pull request a call names: what gh is given for it, and the repo when a URL names one.
#[derive(Debug, PartialEq)]
pub(crate) struct Target {
    pub selector: String,
    pub repo: Option<String>,
}

/// `pr` and `repo` as gh takes them, or why they are refused.
pub(crate) fn target(args: &Value) -> Result<Target, String> {
    let repo = arg(args, "repo").map(str::to_owned);
    if let Some(repo) = &repo
        && !valid_repo(repo)
    {
        return Err(format!("repo must be OWNER/REPO, not {repo:?}"));
    }
    let raw = match args.get("pr") {
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::String(s)) => s.trim().to_owned(),
        _ => {
            return Err(
                "pr is required: a number, #number, OWNER/REPO#number or a pull request URL"
                    .to_owned(),
            );
        }
    };
    let number = raw.strip_prefix('#').unwrap_or(&raw);
    if !number.is_empty() && number.bytes().all(|b| b.is_ascii_digit()) {
        return Ok(Target { selector: number.to_owned(), repo });
    }
    if let Some((ref_repo, n)) = parse_ref(&raw) {
        return Ok(Target { selector: n, repo: repo.or(Some(ref_repo)) });
    }
    if let Some((url_repo, n)) = parse_url(&raw) {
        return Ok(Target { selector: n, repo: repo.or(Some(url_repo)) });
    }
    Err(format!(
        "pr must be a number, #number, OWNER/REPO#number or a pull request URL, not {raw:?}"
    ))
}

fn valid_repo(repo: &str) -> bool {
    let part = |p: &str| {
        !p.is_empty() && p.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
    };
    matches!(repo.split_once('/'), Some((o, r)) if part(o) && part(r))
}

/// `OWNER/REPO#N` as (`OWNER/REPO`, `N`): the shape glaeda-gh, the land queue and every published row print,
/// so a caller pasting one back gets an answer instead of a usage error.
fn parse_ref(raw: &str) -> Option<(String, String)> {
    let (repo, n) = raw.split_once('#')?;
    (valid_repo(repo) && !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
        .then(|| (repo.to_owned(), n.to_owned()))
}

/// `https://github.com/OWNER/REPO/pull/N[/...]` as (`OWNER/REPO`, `N`).
fn parse_url(url: &str) -> Option<(String, String)> {
    let rest = url.split_once("://").map_or(url, |(_, r)| r);
    let mut parts = rest.split(['/', '?', '#']);
    let _host = parts.next()?;
    let (owner, repo, pull, n) = (parts.next()?, parts.next()?, parts.next()?, parts.next()?);
    let repo = format!("{owner}/{repo}");
    (pull == "pull" && valid_repo(&repo) && !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
        .then(|| (repo, n.to_owned()))
}

/// The gh command line for a target.
pub(super) fn gh_args(t: &Target) -> Vec<String> {
    let mut v: Vec<String> = ["pr", "view", t.selector.as_str()].map(str::to_owned).into();
    if let Some(repo) = &t.repo {
        v.extend(["-R".to_owned(), repo.clone()]);
    }
    v.extend(["--json".to_owned(), FIELDS.to_owned()]);
    v
}

pub(super) async fn call(daemon: &Arc<Client>, session: &str, args: &Value) -> Value {
    let target = match target(args) {
        Ok(t) => t,
        Err(e) => return error_result(e),
    };
    let cwd = chat_cwd(daemon, session).await;
    let via_daemon = match daemon_read(daemon, &target, cwd.clone(), None).await {
        Ok((pr, poller)) => return answer(&pr, Some(poller), args),
        Err(e) => e,
    };
    let out = match run_gh(&gh_args(&target), cwd).await {
        Ok(out) => out,
        Err(e) => return error_result(format!("{e} (the daemon's poller: {via_daemon})")),
    };
    let pr: Value = match serde_json::from_slice(&out) {
        Ok(v) => v,
        Err(e) => return error_result(format!("gh pr view gave no JSON: {e}")),
    };
    answer(&pr, None, args)
}

/// One `pr_wait` call: the wait in the daemon. With no daemon poller, one read of this chat's
/// own `gh`, said so, never a loop here.
pub(super) async fn wait(daemon: &Arc<Client>, session: &str, args: &Value) -> Value {
    let target = match target(args) {
        Ok(t) => t,
        Err(e) => return error_result(e),
    };
    let until = match arg(args, "until") {
        None => "settled",
        Some(u @ ("settled" | "change")) => u,
        Some(other) => {
            return error_result(format!("until must be settled or change, not {other:?}"));
        }
    };
    let secs = args
        .get("timeoutSecs")
        .and_then(Value::as_u64)
        .unwrap_or(WAIT_DEFAULT_S)
        .clamp(1, WAIT_MAX_S);
    let cwd = chat_cwd(daemon, session).await;
    match daemon_read(daemon, &target, cwd, Some((secs, until))).await {
        Ok((pr, poller)) => answer(&pr, Some(poller), args),
        Err(e) => error_result(format!(
            "pr_wait waits in the cmux daemon, which could not: {e}. Read it once with pr_state, or wait with run_wait"
        )),
    }
}

/// The text and `structuredContent` of an answer, with how the daemon had it.
fn answer(pr: &Value, poller: Option<Value>, args: &Value) -> Value {
    let (mut text, mut structured) = pr_state(pr);
    if let Some(obj) = structured.as_object_mut() {
        if let Some(d) = arg(args, "description") {
            obj.insert("description".to_owned(), json!(d));
        }
        if let Some(poller) = poller {
            text.push_str(&format!("\n{}", poller_line(&poller)));
            if let Some(t) = poller.get("timedOut") {
                obj.insert("timedOut".to_owned(), t.clone());
            }
            obj.insert("poller".to_owned(), poller);
        }
    }
    ok(text, structured)
}

/// `via the machine's GitHub poller: fetched now` (or `cache 12s old`, with a stale note).
pub(super) fn poller_line(p: &Value) -> String {
    let source = text_or_empty(p, "source");
    let age = field(p, "ageSecs").as_u64().unwrap_or(0);
    let mut line = match source {
        "fetched" => "via this machine's GitHub poller: read now".to_owned(),
        _ => format!("via this machine's GitHub poller: {source}, {age}s old"),
    };
    if let Some(waited) = field(p, "waitedSecs").as_u64() {
        let how =
            if field(p, "timedOut").as_bool() == Some(true) { "timed out after" } else { "waited" };
        line.push_str(&format!("; {how} {waited}s"));
    }
    if let Some(note) = text(p, "note") {
        line.push_str(&format!(" ({note})"));
    }
    line
}

/// The pull request through the daemon's poller: a read, or a wait of (`secs`, `until`).
async fn daemon_read(
    daemon: &Arc<Client>,
    t: &Target,
    cwd: Option<PathBuf>,
    wait: Option<(u64, &str)>,
) -> Result<(Value, Value), String> {
    let repo = match &t.repo {
        Some(r) => r.clone(),
        None => {
            origin_repo_of(cwd).await.ok_or("the chat folder has no GitHub origin; pass repo")?
        }
    };
    let mut params = json!({"repo": repo, "pr": t.selector});
    let m = match wait {
        None => method::MUX_GITHUB_PR_STATE,
        Some((secs, until)) => {
            if let Some(p) = params.as_object_mut() {
                p.insert("timeoutSecs".to_owned(), json!(secs));
                p.insert("until".to_owned(), json!(until));
            }
            method::MUX_GITHUB_PR_WAIT
        }
    };
    let reply = daemon.request(m, params).await.map_err(|e| format!("{e:#}"))?;
    match (reply.get("pr"), reply.get("poller")) {
        (Some(pr), Some(poller)) if pr.is_object() => Ok((pr.clone(), poller.clone())),
        _ => Err("the daemon's answer had no pull request".to_owned()),
    }
}

/// The chat folder's `origin` as OWNER/REPO, when it is on github.com.
async fn origin_repo_of(cwd: Option<PathBuf>) -> Option<String> {
    let mut cmd = tokio::process::Command::new("git");
    cmd.args(["config", "--get", "remote.origin.url"])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true);
    if let Some(cwd) = cwd {
        cmd.current_dir(cwd);
    }
    let out = tokio::time::timeout(GIT_TIMEOUT, cmd.output()).await.ok()?.ok()?;
    origin_repo(String::from_utf8_lossy(&out.stdout).trim())
}

/// `https://github.com/O/R(.git)`, `git@github.com:O/R(.git)` or `ssh://git@github.com/O/R` as
/// `O/R`.
pub(super) fn origin_repo(url: &str) -> Option<String> {
    let rest = url.strip_prefix("git@github.com:").or_else(|| {
        url.split_once("://").map(|(_, r)| r).and_then(|r| {
            let r = r.rsplit_once('@').map_or(r, |(_, h)| h);
            r.strip_prefix("github.com/").or_else(|| r.strip_prefix("github.com:"))
        })
    })?;
    let rest = rest.trim_end_matches('/');
    let rest = rest.strip_suffix(".git").unwrap_or(rest);
    let mut parts = rest.split('/');
    let repo = format!("{}/{}", parts.next()?, parts.next()?);
    (parts.next().is_none() && valid_repo(&repo)).then_some(repo)
}

/// The chat's folder, where gh finds the default repo; this server's own when the daemon
/// does not say.
async fn chat_cwd(daemon: &Arc<Client>, session: &str) -> Option<PathBuf> {
    if session.is_empty() {
        return None;
    }
    let info = daemon
        .request(method::MUX_INFO, json!({"sessionId": session, "waitLogs": false}))
        .await
        .ok()?;
    text(&info, "cwd").map(PathBuf::from).filter(|p| p.is_dir())
}

async fn run_gh(args: &[String], cwd: Option<PathBuf>) -> Result<Vec<u8>, String> {
    let mut cmd = tokio::process::Command::new("gh");
    cmd.args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    if let Some(cwd) = cwd {
        cmd.current_dir(cwd);
    }
    let out = match tokio::time::timeout(GH_TIMEOUT, cmd.output()).await {
        Err(_) => return Err(format!("gh pr view did not answer in {}s", GH_TIMEOUT.as_secs())),
        Ok(Err(e)) if e.kind() == std::io::ErrorKind::NotFound => {
            return Err("gh is not installed or not on this agent's PATH".to_owned());
        }
        Ok(Err(e)) => return Err(format!("gh could not run: {e}")),
        Ok(Ok(out)) => out,
    };
    if out.status.success() {
        return Ok(out.stdout);
    }
    let stderr = String::from_utf8_lossy(&out.stderr);
    let stderr = stderr.trim();
    let skip = stderr.chars().count().saturating_sub(600);
    let tail: String = stderr.chars().skip(skip).collect();
    let code = out.status.code().map_or("a signal".to_owned(), |c| format!("exit {c}"));
    Err(format!("gh pr view failed ({code}): {tail}"))
}

/// `v[k]` without the indexing lint: Null when absent.
fn field<'a>(v: &'a Value, k: &str) -> &'a Value {
    v.get(k).unwrap_or(&Value::Null)
}

fn text<'a>(v: &'a Value, k: &str) -> Option<&'a str> {
    v.get(k).and_then(Value::as_str)
}

fn text_or_empty<'a>(v: &'a Value, k: &str) -> &'a str {
    text(v, k).unwrap_or_default()
}

fn short(sha: &str) -> &str {
    sha.get(..8).unwrap_or(sha)
}

/// A review receipt line: `Review (<who>): SHIP at <sha>` or `BLOCK at <sha>`, with markdown
/// emphasis or a quote mark around it allowed.
#[derive(Debug, PartialEq)]
pub(super) struct Receipt {
    pub verdict: &'static str,
    pub sha: String,
    pub line: String,
}

pub(super) fn receipt(line: &str) -> Option<Receipt> {
    let plain: String = line.chars().filter(|c| !matches!(c, '*' | '`' | '_')).collect();
    let plain = plain.trim_start_matches(['>', '#', '-', ' ']).trim();
    let rest = plain.strip_prefix("Review")?;
    let (_, after) = rest.split_once("):")?;
    let after = after.trim_start();
    let (verdict, sha) = if let Some(s) = after.strip_prefix("SHIP at ") {
        ("SHIP", s)
    } else if let Some(s) = after.strip_prefix("BLOCK at ") {
        ("BLOCK", s)
    } else {
        return None;
    };
    let sha: String = sha.chars().take_while(char::is_ascii_hexdigit).collect();
    (sha.len() >= 7).then(|| Receipt { verdict, sha: sha.to_lowercase(), line: plain.to_owned() })
}

/// The newest comment's last receipt line, with the comment's author.
fn newest_receipt(comments: &[Value]) -> Option<(Receipt, String)> {
    comments.iter().rev().find_map(|c| {
        let found = text_or_empty(c, "body").lines().filter_map(receipt).next_back()?;
        Some((found, text_or_empty(field(c, "author"), "login").to_owned()))
    })
}

/// A check run's job id: REST's `id`, a projection's `databaseId`, or the `/job/N` of its
/// `detailsUrl` (what `gh pr view`'s rollup gives). GitHub hands job ids out in order, so a
/// higher one is a newer run.
fn job_id(c: &Value) -> u64 {
    if let Some(id) = c.get("databaseId").or(c.get("id")).and_then(Value::as_u64) {
        return id;
    }
    let url = text(c, "detailsUrl").or(text(c, "details_url")).or(text(c, "html_url"));
    url.and_then(|u| u.split("/job/").nth(1))
        .and_then(|t| t.split(|ch: char| !ch.is_ascii_digit()).next())
        .and_then(|d| d.parse().ok())
        .unwrap_or(0)
}

/// Where a run sorts among the runs of its name, oldest first: its job id, then its start time
/// (a run not finished and not started yet is the newest: it was queued after the rest), then
/// its place in the list.
fn run_order(c: &Value, index: usize) -> (u64, String, usize) {
    let started = text(c, "startedAt").or(text(c, "started_at")).unwrap_or_default();
    let finished = text_or_empty(c, "status").eq_ignore_ascii_case("completed");
    let time = if !started.is_empty() && !started.starts_with("0001-") {
        started.to_owned()
    } else if finished {
        String::new()
    } else {
        "~".to_owned()
    };
    (job_id(c), time, index)
}

/// The runs a head's checks are judged by: of the check runs that share a name (and workflow,
/// when the rollup names it), only the newest. A run the concurrency group cancelled, or an
/// attempt a rerun replaced, stays in GitHub's list beside the run that replaced it; it is no
/// verdict once a newer run of the check passed or is still running. Status contexts pass
/// through: GitHub keeps one per context already. The order of the list is kept.
pub(crate) fn newest_runs(rollup: &[Value]) -> Vec<&Value> {
    let mut newest: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    let mut keep = vec![true; rollup.len()];
    for (i, c) in rollup.iter().enumerate() {
        if text(c, "__typename") == Some("StatusContext") || c.get("context").is_some() {
            continue;
        }
        let workflow = text(c, "workflowName").or(text(c, "workflow_name")).unwrap_or_default();
        let key = format!("{workflow}\u{0}{}", text_or_empty(c, "name"));
        match newest.get(&key).copied() {
            Some(j) if run_order(&rollup[j], j) > run_order(c, i) => keep[i] = false,
            Some(j) => {
                keep[j] = false;
                newest.insert(key, i);
            }
            None => {
                newest.insert(key, i);
            }
        }
    }
    // A concurrency group shared across workflows cancels one workflow's job for another's
    // (manaflow-ai/cmux#50693): a cancel is also replaced by a newer same-named run of another
    // workflow that passed or is still running. A newer red replaces nothing here: it is its
    // own check's verdict.
    let cancelled = |c: &Value| {
        text_or_empty(c, "status").eq_ignore_ascii_case("completed")
            && text_or_empty(c, "conclusion").eq_ignore_ascii_case("cancelled")
    };
    let failed = |c: &Value| {
        text_or_empty(c, "status").eq_ignore_ascii_case("completed")
            && matches!(
                text_or_empty(c, "conclusion").to_ascii_uppercase().as_str(),
                "FAILURE" | "TIMED_OUT" | "CANCELLED" | "STARTUP_FAILURE" | "ACTION_REQUIRED"
            )
    };
    let survivors: Vec<usize> = newest.values().copied().collect();
    for &i in &survivors {
        let c = &rollup[i];
        if !cancelled(c) {
            continue;
        }
        let name = text_or_empty(c, "name");
        if survivors.iter().any(|&j| {
            let t = &rollup[j];
            j != i
                && text_or_empty(t, "name") == name
                && !failed(t)
                && run_order(t, j) > run_order(c, i)
        }) {
            keep[i] = false;
        }
    }
    rollup.iter().zip(keep).filter_map(|(c, k)| k.then_some(c)).collect()
}

/// A head's checks, each judged by its newest run (`newest_runs`).
#[derive(Debug, Default, PartialEq)]
pub(crate) struct Checks {
    /// Names whose newest run failed.
    pub failing: Vec<String>,
    /// Names whose newest run was cancelled, with no newer run: no verdict, and none coming.
    pub cancelled: Vec<String>,
    pub pending: usize,
    pub passed: usize,
}

/// The checks of a `statusCheckRollup`.
fn checks(rollup: &[Value]) -> Checks {
    let mut out = Checks::default();
    for c in newest_runs(rollup) {
        let name = text(c, "name").or(text(c, "context")).unwrap_or("?").to_owned();
        let up = |k: &str| text_or_empty(c, k).to_ascii_uppercase();
        if text(c, "__typename") == Some("StatusContext") || c.get("context").is_some() {
            match up("state").as_str() {
                "FAILURE" | "ERROR" => out.failing.push(name),
                "PENDING" | "EXPECTED" | "" => out.pending = out.pending.saturating_add(1),
                _ => out.passed = out.passed.saturating_add(1),
            }
            continue;
        }
        if up("status") != "COMPLETED" {
            out.pending = out.pending.saturating_add(1);
            continue;
        }
        match up("conclusion").as_str() {
            "CANCELLED" => out.cancelled.push(name),
            "FAILURE" | "TIMED_OUT" | "STARTUP_FAILURE" | "ACTION_REQUIRED" => {
                out.failing.push(name)
            }
            _ => out.passed = out.passed.saturating_add(1),
        }
    }
    for names in [&mut out.failing, &mut out.cancelled] {
        names.sort();
        names.dedup();
    }
    // A name failing in one workflow and cancelled in another is failing.
    let failing = out.failing.clone();
    out.cancelled.retain(|n| !failing.contains(n));
    out
}

/// HOLD lines of the body and hold labels.
fn holds(pr: &Value) -> Vec<String> {
    let mut found: Vec<String> = text_or_empty(pr, "body")
        .lines()
        .map(str::trim)
        .filter(|l| l.starts_with("HOLD:"))
        .map(str::to_owned)
        .collect();
    for label in field(pr, "labels").as_array().into_iter().flatten() {
        let name = text_or_empty(label, "name");
        if name.split(|c: char| !c.is_ascii_alphanumeric()).any(|w| w.eq_ignore_ascii_case("hold"))
        {
            found.push(format!("label {name}"));
        }
    }
    found
}

fn plural(n: usize, one: &str) -> String {
    if n == 1 { format!("1 {one}") } else { format!("{n} {one}s") }
}

/// The result of `pr_state` for `gh pr view --json` output: the text (outcome line first) and
/// the `structuredContent`.
pub(crate) fn pr_state(pr: &Value) -> (String, Value) {
    let s = |k: &str| text_or_empty(pr, k);
    let number = field(pr, "number").as_u64().unwrap_or(0);
    let head = s("headRefOid").to_lowercase();
    let state = s("state").to_ascii_uppercase();
    let repo = parse_url(s("url")).map(|(r, _)| r);
    let rollup = field(pr, "statusCheckRollup").as_array().map(Vec::as_slice).unwrap_or_default();
    let Checks { failing, cancelled, pending, passed } = checks(rollup);
    let comments = field(pr, "comments").as_array().map(Vec::as_slice).unwrap_or_default();
    let review = newest_receipt(comments);
    let at_head = |r: &Receipt| !head.is_empty() && head.starts_with(&r.sha);
    let holds = holds(pr);
    let merge_commit = text_or_empty(field(pr, "mergeCommit"), "oid");
    let mergeable = match s("mergeable").to_ascii_uppercase().as_str() {
        "MERGEABLE" => "mergeable",
        "CONFLICTING" => "conflicts",
        _ => "mergeability unknown",
    };

    let review_part = match &review {
        None => "no review".to_owned(),
        Some((r, _)) if at_head(r) => format!("{} at head", r.verdict),
        Some((r, _)) => format!("{} at old head {}", r.verdict, short(&r.sha)),
    };
    let (summary, status) = match state.as_str() {
        "MERGED" => (format!("#{number} merged as {}", short(merge_commit)), "ok"),
        "CLOSED" => (format!("#{number} closed unmerged at {}", short(&head)), "ok"),
        _ => {
            let checks_part = if !failing.is_empty() {
                let mut names = failing.iter().take(NAMES_SHOWN).cloned().collect::<Vec<_>>();
                if failing.len() > NAMES_SHOWN {
                    names.push(format!("+{} more", failing.len().saturating_sub(NAMES_SHOWN)));
                }
                format!("{} ({})", plural(failing.len(), "failing check"), names.join(", "))
            } else if pending > 0 {
                format!("{} pending", plural(pending, "check"))
            } else if !cancelled.is_empty() {
                let mut names = cancelled.iter().take(NAMES_SHOWN).cloned().collect::<Vec<_>>();
                if cancelled.len() > NAMES_SHOWN {
                    names.push(format!("+{} more", cancelled.len().saturating_sub(NAMES_SHOWN)));
                }
                format!(
                    "{} with no newer run ({})",
                    plural(cancelled.len(), "cancelled check"),
                    names.join(", ")
                )
            } else if passed > 0 {
                "checks green".to_owned()
            } else {
                "no checks".to_owned()
            };
            let mut parts = vec![mergeable.to_owned(), checks_part, review_part.clone()];
            if !holds.is_empty() {
                parts.push("held".to_owned());
            }
            let blocked = review.as_ref().is_some_and(|(r, _)| at_head(r) && r.verdict == "BLOCK");
            let status = if !failing.is_empty() || blocked {
                "failed"
            } else if pending > 0 {
                "running"
            } else if !cancelled.is_empty() {
                "cancelled"
            } else {
                "ok"
            };
            (format!("#{number} open at {}: {}", short(&head), parts.join(", ")), status)
        }
    };

    let mut lines = vec![summary.clone()];
    lines.push(format!("head {head} -> {}", s("baseRefName")));
    if state == "MERGED" {
        lines.push(format!("merged as {merge_commit} at {}", s("mergedAt")));
    } else {
        lines.push(format!("mergeable: {mergeable}"));
    }
    let mut check_line = format!("checks: {passed} passed, {} failing", failing.len());
    if !failing.is_empty() {
        check_line.push_str(&format!(" ({})", failing.join(", ")));
    }
    if !cancelled.is_empty() {
        check_line.push_str(&format!(", {} cancelled ({})", cancelled.len(), cancelled.join(", ")));
    }
    check_line.push_str(&format!(", {pending} pending"));
    lines.push(check_line);
    lines.push(match &review {
        None => "review: none".to_owned(),
        Some((r, by)) => {
            let where_ = if at_head(r) { "at head" } else { "not at head" };
            let by = if by.is_empty() { String::new() } else { format!(" (by {by})") };
            format!("review: {}{by}, {where_}", r.line)
        }
    });
    for h in &holds {
        lines.push(format!("hold: {h}"));
    }

    let structured = json!({
        "summary": summary,
        "status": status,
        "pr": number,
        "repo": repo,
        "state": state.to_lowercase(),
        "headSha": head,
        "base": s("baseRefName"),
        "mergeable": mergeable,
        "mergeCommit": (!merge_commit.is_empty()).then_some(merge_commit),
        "failingChecks": failing,
        "cancelledChecks": cancelled,
        "pendingChecks": pending,
        "passedChecks": passed,
        "review": review.as_ref().map(|(r, by)| json!({
            "verdict": r.verdict, "sha": r.sha, "atHead": at_head(r), "line": r.line, "author": by,
        })),
        "holds": holds,
    });
    (lines.join("\n"), structured)
}

#[cfg(test)]
#[path = "acpmux_mcp_pr_tests.rs"]
mod tests;
