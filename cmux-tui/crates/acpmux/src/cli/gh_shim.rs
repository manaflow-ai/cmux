//! `acpmux gh ARGS`: the GitHub broker's actions (`github_broker.rs`) in `gh`'s own words, for
//! an agent on a machine the person added. The Mac that lends the machine its login runs them.
//!
//! Only these forms parse, each with only its own flags; anything else, a flag of another
//! command included, is refused before anything is sent, so no command is ever read as a
//! different, weaker or stronger one:
//!
//! - `repo view [OWNER/REPO]`
//! - `pr view NUMBER`
//! - `pr create --draft --title T [--head BRANCH] [--base BRANCH] [--body B | --body-file F]`
//! - `issue create --title T [--body B | --body-file F]`
//! - `issue comment NUMBER (--body B | --body-file F)`
//!
//! Each also takes `--repo`/`-R OWNER/REPO`; without it the repository is the one `origin`
//! names in this folder, as `gh` would read it.

use crate::github_broker::{GithubAction, GithubActionParams, SHIM_REFUSAL_ENV};
use anyhow::{Result, anyhow, bail};
use serde_json::Value;

const USAGE: &str = "acpmux gh: supported: repo view, pr view N, pr create --draft, issue create, \
issue comment N (each with --repo OWNER/REPO)";

/// The flags each form takes: (long, short, takes a value).
type Flags = &'static [(&'static str, Option<&'static str>, bool)];
const REPO: (&str, Option<&str>, bool) = ("--repo", Some("-R"), true);
const TITLE: (&str, Option<&str>, bool) = ("--title", Some("-t"), true);
const BODY: (&str, Option<&str>, bool) = ("--body", Some("-b"), true);
const BODY_FILE: (&str, Option<&str>, bool) = ("--body-file", Some("-F"), true);

/// What one command line asked for, before the repository and the body file are read.
#[derive(Debug, Default, PartialEq)]
struct Parsed {
    positionals: Vec<String>,
    values: std::collections::BTreeMap<&'static str, String>,
    switches: Vec<&'static str>,
}

fn parse_flags(args: &[String], flags: Flags) -> Result<Parsed> {
    let mut parsed = Parsed::default();
    let mut i = 0;
    while let Some(arg) = args.get(i) {
        i += 1;
        if !arg.starts_with('-') || arg == "-" {
            parsed.positionals.push(arg.clone());
            continue;
        }
        let (name, inline) = match arg.split_once('=') {
            Some((n, v)) if n.starts_with("--") => (n, Some(v.to_owned())),
            _ => (arg.as_str(), None),
        };
        let Some(&(long, _, takes)) = flags.iter().find(|(l, s, _)| *l == name || *s == Some(name))
        else {
            bail!("acpmux gh: {name} is not supported here\n{USAGE}");
        };
        if !takes {
            if inline.is_some() {
                bail!("acpmux gh: {long} takes no value");
            }
            parsed.switches.push(long);
            continue;
        }
        let value = match inline {
            Some(v) => v,
            None => {
                let v = args.get(i).ok_or_else(|| anyhow!("acpmux gh: {long} needs a value"))?;
                i += 1;
                v.clone()
            }
        };
        if parsed.values.insert(long, value).is_some() {
            bail!("acpmux gh: {long} is given twice");
        }
    }
    Ok(parsed)
}

fn number(s: Option<&String>, what: &str) -> Result<u64> {
    let s = s.ok_or_else(|| anyhow!("acpmux gh: {what} needs a number"))?;
    s.trim_start_matches('#').parse().map_err(|_| anyhow!("acpmux gh: {s:?} is not a number"))
}

/// The request a command line names; `repo` and `body_file` read what the line leaves out.
fn request(
    args: &[String],
    repo_here: &dyn Fn() -> Result<String>,
    read_body: &dyn Fn(&str) -> Result<String>,
    branch_here: &dyn Fn() -> Result<String>,
) -> Result<GithubActionParams> {
    let words: Vec<&str> = args.iter().take(2).map(String::as_str).collect();
    let tail = args.get(2..).unwrap_or_default();
    let (action, rest, flags): (GithubAction, &[String], Flags) = match words.as_slice() {
        ["repo", "view", ..] => (GithubAction::Read, tail, &[REPO]),
        ["pr", "view", ..] => (GithubAction::Read, tail, &[REPO]),
        ["pr", "create", ..] => (
            GithubAction::DraftPr,
            tail,
            &[
                REPO,
                TITLE,
                BODY,
                BODY_FILE,
                ("--draft", Some("-d"), false),
                ("--head", Some("-H"), true),
                ("--base", Some("-B"), true),
            ],
        ),
        ["issue", "create", ..] => (GithubAction::Issue, tail, &[REPO, TITLE, BODY, BODY_FILE]),
        ["issue", "comment", ..] => (GithubAction::Comment, tail, &[REPO, BODY, BODY_FILE]),
        _ => bail!("{USAGE}"),
    };
    let mut p = parse_flags(rest, flags)?;
    let repo_view = words.first() == Some(&"repo");
    let wants_number = matches!(action, GithubAction::Comment) || (words == ["pr", "view"]);
    let allowed = usize::from(repo_view || wants_number);
    if p.positionals.len() > allowed {
        bail!(
            "acpmux gh: unexpected argument {:?}\n{USAGE}",
            p.positionals.get(allowed).map_or("", String::as_str)
        );
    }
    if action == GithubAction::DraftPr && !p.switches.contains(&"--draft") {
        bail!("acpmux gh: only draft pull requests: add --draft");
    }
    let positional_repo = repo_view.then(|| p.positionals.first().cloned()).flatten();
    let repo = match (p.values.remove("--repo"), positional_repo) {
        (Some(_), Some(_)) => bail!("acpmux gh: give the repository once"),
        (Some(r), None) | (None, Some(r)) => r,
        (None, None) => repo_here()?,
    };
    let body = match (p.values.remove("--body"), p.values.remove("--body-file")) {
        (Some(_), Some(_)) => bail!("acpmux gh: give --body or --body-file, not both"),
        (Some(b), None) => Some(b),
        (None, Some(f)) => Some(read_body(&f)?),
        (None, None) => None,
    };
    let issue = wants_number
        .then(|| number(p.positionals.first(), "the issue or pull request"))
        .transpose()?;
    let mut branch = p.values.remove("--head");
    if action == GithubAction::DraftPr && branch.is_none() {
        branch = Some(branch_here()?);
    }
    Ok(GithubActionParams {
        session_id: None,
        action,
        repo,
        branch,
        base: p.values.remove("--base"),
        issue,
        title: p.values.remove("--title"),
        body,
        // The daemon sets it when it sends the action on.
        deadline_ms: None,
    })
}

/// `owner/name` of a GitHub remote url (`git@github.com:o/n.git`, `https://github.com/o/n`).
fn github_repo(url: &str) -> Option<String> {
    let path = url
        .strip_prefix("git@github.com:")
        .or_else(|| url.strip_prefix("ssh://git@github.com/"))
        .or_else(|| url.strip_prefix("https://github.com/"))?;
    // One `.git` only: `o/r.git.git` is the repository `o/r.git`, not `o/r`.
    let path = path.trim_end_matches('/');
    let path = path.strip_suffix(".git").unwrap_or(path);
    (path.split('/').count() == 2).then(|| path.to_owned())
}

/// How long one `git` question may take, and how much of its answer is read.
const GIT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);
const GIT_OUTPUT_MAX: usize = 8 * 1024;

fn git(args: &[&str]) -> Result<String> {
    let mut cmd = std::process::Command::new("git");
    cmd.args(args);
    bounded_output(cmd, GIT_OUTPUT_MAX, GIT_TIMEOUT)
        .map_err(|e| anyhow!("git {} failed: {e}", args.join(" ")))
}

/// `cmd`'s stdout, if it exits within `timeout` with at most `limit` bytes and succeeds; killed
/// otherwise (a remote url past the limit, or a config that blocks, never hangs `acpmux gh`).
fn bounded_output(
    mut cmd: std::process::Command,
    limit: usize,
    timeout: std::time::Duration,
) -> Result<String> {
    use std::io::Read as _;
    use std::process::Stdio;
    let deadline = std::time::Instant::now() + timeout;
    let mut child =
        cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn()?;
    let mut out = child.stdout.take().ok_or_else(|| anyhow!("no stdout"))?;
    let (tx, rx) = std::sync::mpsc::channel();
    // Ends at the child's EOF, at `limit`, or when the kill below closes the pipe.
    std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let read = (&mut out).take(limit as u64 + 1).read_to_end(&mut bytes);
        let _ = tx.send(read.map(|_| bytes));
    });
    let read = rx.recv_timeout(timeout);
    let fail = |child: &mut std::process::Child, why: String| -> Result<String> {
        let _ = child.kill();
        let _ = child.wait();
        bail!("{why}")
    };
    let bytes = match read {
        Ok(Ok(bytes)) if bytes.len() <= limit => bytes,
        Ok(Ok(_)) => return fail(&mut child, format!("its output is over {limit} bytes")),
        Ok(Err(e)) => return fail(&mut child, e.to_string()),
        Err(_) => return fail(&mut child, format!("it took over {}s", timeout.as_secs())),
    };
    // Its stdout closed; it may still run (a child that closed it and went on). Its exit is
    // waited for within the same deadline, a short check at a time, then it is killed.
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if std::time::Instant::now() >= deadline {
            return fail(&mut child, format!("it took over {}s", timeout.as_secs()));
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    };
    if !status.success() {
        bail!("it exited with an error");
    }
    Ok(String::from_utf8_lossy(&bytes).trim().to_owned())
}

/// How long a `--body-file` (or stdin) may take to open and read.
const BODY_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// The body at `path` (`-`: stdin), opened and read within `timeout` (a FIFO with no writer,
/// or a pipe that stalls, is refused then; the reader left behind ends with this process).
fn read_body_within(path: &str, timeout: std::time::Duration) -> Result<String> {
    let path = path.to_owned();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let read = if path == "-" {
            read_bounded(std::io::stdin())
        } else {
            std::fs::File::open(&path).map_err(anyhow::Error::from).and_then(read_bounded)
        };
        let _ = tx.send(read);
    });
    rx.recv_timeout(timeout).unwrap_or_else(|_| {
        bail!("acpmux gh: the body did not arrive within {}s", timeout.as_secs())
    })
}

/// A body the broker can take: at most its limit, read no further (a `/dev/zero` or a FIFO
/// that never ends is refused once past it, not read into memory).
fn read_bounded(from: impl std::io::Read) -> Result<String> {
    use std::io::Read as _;
    let limit = crate::github_broker::TEXT_MAX;
    let mut bytes = Vec::new();
    from.take(limit as u64 + 1).read_to_end(&mut bytes)?;
    if bytes.len() > limit {
        bail!("acpmux gh: the body is over {} KiB", limit / 1024);
    }
    String::from_utf8(bytes).map_err(|_| anyhow!("acpmux gh: the body is not UTF-8"))
}

pub async fn run(args: Vec<String>) -> Result<()> {
    // The Mac's daemon marks the `gh` it runs: this is standing where the real `gh` should be.
    if std::env::var_os(SHIM_REFUSAL_ENV).is_some() {
        bail!("acpmux gh is on the Mac daemon's PATH where the real gh must be");
    }
    let repo_here = || {
        let url = git(&["config", "--get", "remote.origin.url"])
            .map_err(|_| anyhow!("acpmux gh: no --repo and no git remote origin here"))?;
        github_repo(&url).ok_or_else(|| anyhow!("acpmux gh: origin is not a GitHub repository"))
    };
    let read_body = |path: &str| read_body_within(path, BODY_TIMEOUT);
    let branch_here = || {
        git(&["symbolic-ref", "--short", "HEAD"])
            .map_err(|_| anyhow!("acpmux gh: no --head, and this folder is on no branch"))
    };
    let params = request(&args, &repo_here, &read_body, &branch_here)?;
    let client = crate::client::Client::connect(&crate::config::socket_path()).await?;
    let reply = client
        .request(crate::rpc::method::MUX_GITHUB_ACTION, serde_json::to_value(params)?)
        .await?;
    match reply.get("output").and_then(Value::as_str) {
        Some(output) => print!("{output}"),
        None => println!("{reply}"),
    }
    Ok(())
}

#[cfg(test)]
#[path = "gh_shim_tests.rs"]
mod tests;
