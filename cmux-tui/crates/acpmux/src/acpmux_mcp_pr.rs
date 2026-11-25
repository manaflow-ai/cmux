//! The `acpmux` MCP server's `pr_state` tool: one pull request's state in one call, condensed.
//! Its first line is the outcome (`#1609 open at 4db9066b: mergeable, 1 failing check
//! (ws-check), SHIP at head`), the lines after it the detail: head and base, mergeability,
//! failing checks by name and how many are pending, the newest review receipt (a comment line
//! `Review (...): SHIP at <sha>` or `BLOCK at <sha>`) and whether it is at the head, and holds
//! (a `HOLD:` body line or a hold label). `structuredContent` carries the same with `summary`
//! (the first line) and `status`: `ok` (open with nothing failing or pending, merged, or
//! closed), `failed` (a failing check, or a BLOCK at the head) or `running` (checks pending).
//!
//! Like every condensed tool it takes an optional `description`, a few words the transcript
//! titles the row with. The data is one `gh pr view` run by this server, which the chat's agent
//! started with its environment, in the chat's folder, so without `repo` gh reads the folder's
//! origin. One call, never a loop: on hosts whose `gh` is a caching broker chain it is answered
//! from that cache. The parsing is pure ([`pr_state`]) and tested on fixture JSON.

use super::{arg, error_result, ok};
use crate::client::Client;
use crate::rpc::method;
use serde_json::{Value, json};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

pub(super) const NAME: &str = "pr_state";
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
        "description": "One pull request's state in one call, instead of several gh commands in a shell. The first line is the outcome (\"#1609 open at 4db9066b: mergeable, 1 failing check (ws-check), SHIP at head\" or \"#1557 merged as f0175fe0\"); then head and base, mergeability, failing checks by name and the pending count, the newest review receipt (a `Review (...): SHIP at <sha>` or `BLOCK at <sha>` comment line) and whether it is at the head, and HOLD lines or hold labels. structuredContent.status is ok, failed (a failing check, or BLOCK at head) or running (checks pending).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "pr": {"type": "string", "description": "The pull request: its number, #number, or its URL."},
                "repo": {"type": "string", "description": "OWNER/REPO (default: the chat folder's origin, or the URL's)."},
                "description": {"type": "string", "description": "A few words on why you look, shown as this call's title."}
            },
            "required": ["pr"]
        }
    })
}

/// Which pull request a call names: what gh is given for it, and the repo when a URL names one.
#[derive(Debug, PartialEq)]
pub(super) struct Target {
    pub selector: String,
    pub repo: Option<String>,
}

/// `pr` and `repo` as gh takes them, or why they are refused.
pub(super) fn target(args: &Value) -> Result<Target, String> {
    let repo = arg(args, "repo").map(str::to_owned);
    if let Some(repo) = &repo
        && !valid_repo(repo)
    {
        return Err(format!("repo must be OWNER/REPO, not {repo:?}"));
    }
    let raw = match args.get("pr") {
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::String(s)) => s.trim().to_owned(),
        _ => return Err("pr is required: a number, #number or a pull request URL".to_owned()),
    };
    let number = raw.strip_prefix('#').unwrap_or(&raw);
    if !number.is_empty() && number.bytes().all(|b| b.is_ascii_digit()) {
        return Ok(Target { selector: number.to_owned(), repo });
    }
    if let Some((url_repo, n)) = parse_url(&raw) {
        return Ok(Target { selector: n, repo: repo.or(Some(url_repo)) });
    }
    Err(format!("pr must be a number, #number or a pull request URL, not {raw:?}"))
}

fn valid_repo(repo: &str) -> bool {
    let part = |p: &str| {
        !p.is_empty() && p.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
    };
    matches!(repo.split_once('/'), Some((o, r)) if part(o) && part(r))
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
    let out = match run_gh(&gh_args(&target), cwd).await {
        Ok(out) => out,
        Err(e) => return error_result(e),
    };
    let pr: Value = match serde_json::from_slice(&out) {
        Ok(v) => v,
        Err(e) => return error_result(format!("gh pr view gave no JSON: {e}")),
    };
    let (text, mut structured) = pr_state(&pr);
    if let Some(d) = arg(args, "description")
        && let Some(obj) = structured.as_object_mut()
    {
        obj.insert("description".to_owned(), json!(d));
    }
    ok(text, structured)
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

/// Failing check names and the pending count of a `statusCheckRollup`.
fn checks(rollup: &[Value]) -> (Vec<String>, usize, usize) {
    let (mut failing, mut pending, mut passed): (Vec<String>, usize, usize) = (Vec::new(), 0, 0);
    for c in rollup {
        let name = text(c, "name").or(text(c, "context")).unwrap_or("?").to_owned();
        let up = |k: &str| text_or_empty(c, k).to_ascii_uppercase();
        if text(c, "__typename") == Some("StatusContext") || c.get("context").is_some() {
            match up("state").as_str() {
                "FAILURE" | "ERROR" => failing.push(name),
                "PENDING" | "EXPECTED" | "" => pending = pending.saturating_add(1),
                _ => passed = passed.saturating_add(1),
            }
            continue;
        }
        if up("status") != "COMPLETED" {
            pending = pending.saturating_add(1);
            continue;
        }
        match up("conclusion").as_str() {
            "FAILURE" | "TIMED_OUT" | "CANCELLED" | "STARTUP_FAILURE" | "ACTION_REQUIRED" => {
                failing.push(name)
            }
            _ => passed = passed.saturating_add(1),
        }
    }
    failing.sort();
    failing.dedup();
    (failing, pending, passed)
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
pub(super) fn pr_state(pr: &Value) -> (String, Value) {
    let s = |k: &str| text_or_empty(pr, k);
    let number = field(pr, "number").as_u64().unwrap_or(0);
    let head = s("headRefOid").to_lowercase();
    let state = s("state").to_ascii_uppercase();
    let repo = parse_url(s("url")).map(|(r, _)| r);
    let rollup = field(pr, "statusCheckRollup").as_array().map(Vec::as_slice).unwrap_or_default();
    let (failing, pending, passed) = checks(rollup);
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
