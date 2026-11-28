//! GitHub's own CLI as a sign-in: `gh auth login --web` (its device flow, run by
//! [`super::start_in`] as [`super::Agent::Github`]), the accounts gh has
//! ([`accounts`]), and `gh auth switch` / `gh auth logout` for one of them.
//!
//! gh keeps its tokens in its keyring or `hosts.yml`: nothing here reads that file, asks gh for
//! a token (`--show-token`) or keeps a line that names one. [`accounts`] reads only each
//! account's login, whether it is signed in and whether it is the active one.

use std::time::Duration;

use serde_json::Value;
use tokio::process::Command;
use tokio::time::Instant;
use zeroize::Zeroizing;

use super::{Cli, LoginError, reason};

/// The one host these commands touch.
pub const HOST: &str = "github.com";
/// How long [`accounts`] has, both of its gh runs together.
pub const ACCOUNTS_WAIT: Duration = Duration::from_secs(3);
/// How long `gh auth switch` or `gh auth logout` has.
pub const CHANGE_WAIT: Duration = Duration::from_secs(15);

/// Tokens in the daemon's environment that would outrank, or stand in for, the account gh signs
/// in: gh refuses `auth login` while `GH_TOKEN` is set.
const TOKEN_ENV: &[&str] =
    &["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_HOST"];

/// Shapes a gh command's environment: no prompt, no browser, no update check, no colour, and no
/// token of the daemon's.
pub fn shape(cmd: &mut Command) {
    for key in TOKEN_ENV {
        cmd.env_remove(key);
    }
    cmd.env("GH_BROWSER", "true")
        .env("BROWSER", "true")
        .env("GH_PROMPT_DISABLED", "1")
        .env("GH_NO_UPDATE_NOTIFIER", "1")
        .env("GH_SPINNER_DISABLED", "1")
        .env("NO_COLOR", "1")
        .env("TERM", "dumb");
}

/// One account gh has on github.com.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GhAccount {
    pub login: String,
    /// gh's active account (the one `gh` and git use).
    pub active: bool,
    /// gh could use its token (false: invalid, expired or unreachable).
    pub signed_in: bool,
}

/// A GitHub login: 1 to 39 of ASCII letters, digits and `-`, not starting with `-`.
pub fn login_shaped(login: &str) -> bool {
    (1..=39).contains(&login.len())
        && !login.starts_with('-')
        && login.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

/// The github.com accounts of `gh auth status --json hosts` (newer gh): `{"hosts":
/// {"github.com": [{"login", "active", "state"}]}}`. `None` when it is not that document.
pub fn parse_status_json(text: &str) -> Option<Vec<GhAccount>> {
    let doc: Value = serde_json::from_str(text.trim()).ok()?;
    let hosts = doc.get("hosts")?.as_object()?;
    let Some(list) = hosts.get(HOST) else { return Some(Vec::new()) };
    let mut out: Vec<GhAccount> = Vec::new();
    for entry in list.as_array()? {
        let Some(login) = entry.get("login").and_then(Value::as_str).filter(|l| login_shaped(l))
        else {
            continue;
        };
        if out.iter().any(|a| a.login == login) {
            continue;
        }
        out.push(GhAccount {
            login: login.to_owned(),
            active: entry.get("active").and_then(Value::as_bool).unwrap_or(false),
            signed_in: entry.get("state").and_then(Value::as_str) == Some("success"),
        });
    }
    Some(out)
}

/// The github.com accounts of `gh auth status`'s text (gh 2.40 and on; `as LOGIN` before):
///
/// ```text
/// github.com
///   ✓ Logged in to github.com account alice (keyring)
///   - Active account: true
///   X Failed to log in to github.com account bob (keyring)
///   - Active account: false
/// ```
///
/// Only those two kinds of line are read (and `Timeout trying to log in`); token lines are not.
pub fn parse_status_text(text: &str) -> Vec<GhAccount> {
    let (plain, _) = super::parse::strip_terminal(text);
    let mut out: Vec<GhAccount> = Vec::new();
    let mut last: Option<usize> = None;
    for line in plain.lines() {
        let line = line.trim();
        let lower = line.to_ascii_lowercase();
        if let Some(rest) = lower.strip_prefix("- active account:") {
            if let Some(i) = last
                && let Some(a) = out.get_mut(i)
            {
                a.active = rest.trim() == "true";
            }
            continue;
        }
        let signed_in = if lower.contains("logged in to ") {
            true
        } else if lower.contains("failed to log in to ")
            || lower.contains("timeout trying to log in to ")
        {
            false
        } else {
            continue;
        };
        last = None;
        let mut words = line.split_whitespace();
        // `... to github.com account LOGIN (...)` or `... to github.com as LOGIN (...)`.
        let Some(host) = words.by_ref().find(|w| w.eq_ignore_ascii_case(HOST) || w.contains('.'))
        else {
            continue;
        };
        if !host.eq_ignore_ascii_case(HOST) {
            continue;
        }
        let login = match words.next() {
            Some("account" | "as") => words.next(),
            _ => None,
        };
        let Some(login) =
            login.map(|w| w.trim_end_matches([',', '.', ':'])).filter(|l| login_shaped(l))
        else {
            continue;
        };
        match out.iter().position(|a| a.login == login) {
            Some(i) => last = Some(i),
            None => {
                last = Some(out.len());
                out.push(GhAccount { login: login.to_owned(), active: false, signed_in });
            }
        }
    }
    // gh before multi-account named no active one: a lone signed-in account is it.
    if out.len() == 1
        && !plain.to_ascii_lowercase().contains("active account")
        && let Some(a) = out.first_mut()
    {
        a.active = a.signed_in;
    }
    out
}

fn gh(cli: &Cli, args: &[&str]) -> Command {
    let mut cmd = cli.command(args, &std::env::temp_dir());
    shape(&mut cmd);
    cmd
}

/// The github.com accounts gh has, read in at most [`ACCOUNTS_WAIT`]: `--json hosts` first,
/// else the text. No gh, no answer in time, or nothing gh says it has: none.
pub async fn accounts(cli: &Cli) -> Vec<GhAccount> {
    let now = Instant::now();
    let deadline = now.checked_add(ACCOUNTS_WAIT).unwrap_or(now);
    let left = || deadline.saturating_duration_since(Instant::now());
    let json = gh(cli, &["auth", "status", "--hostname", HOST, "--json", "hosts"]);
    match crate::complete::run::run(json, None, left()).await {
        Ok(out) => {
            let stdout = Zeroizing::new(String::from_utf8_lossy(&out.stdout).into_owned());
            if let Some(found) = parse_status_json(&stdout) {
                return found;
            }
        }
        Err(crate::complete::run::RunError::Spawn(_)) => return Vec::new(),
        Err(crate::complete::run::RunError::Timeout) => return Vec::new(),
    }
    if left().is_zero() {
        return Vec::new();
    }
    let text = gh(cli, &["auth", "status", "--hostname", HOST]);
    match crate::complete::run::run(text, None, left()).await {
        Ok(out) => {
            // gh writes status to stdout or stderr depending on its version.
            let mut all = Zeroizing::new(String::from_utf8_lossy(&out.stdout).into_owned());
            all.push('\n');
            all.push_str(&String::from_utf8_lossy(&out.stderr));
            parse_status_text(&all)
        }
        Err(_) => Vec::new(),
    }
}

/// `gh auth <verb> --hostname github.com --user LOGIN`, in at most [`CHANGE_WAIT`].
async fn change(cli: &Cli, verb: &str, login: &str) -> Result<(), LoginError> {
    if !login_shaped(login) {
        return Err(LoginError::new(reason::UNKNOWN_ACCOUNT, "that is not a GitHub login"));
    }
    let cmd = gh(cli, &["auth", verb, "--hostname", HOST, "--user", login]);
    match crate::complete::run::run(cmd, None, CHANGE_WAIT).await {
        Ok(out) if out.success => Ok(()),
        Ok(_) => Err(LoginError::new(reason::FAILED, format!("gh auth {verb} failed for {login}"))),
        Err(crate::complete::run::RunError::Timeout) => {
            Err(LoginError::new(reason::FAILED, format!("gh auth {verb} did not finish")))
        }
        Err(crate::complete::run::RunError::Spawn(e)) if e.contains("No such file") => {
            Err(LoginError::new(
                reason::NOT_INSTALLED,
                "gh (GitHub CLI) is not installed on this machine",
            ))
        }
        Err(crate::complete::run::RunError::Spawn(e)) => {
            Err(LoginError::new(reason::FAILED, format!("start gh: {e}")))
        }
    }
}

/// `gh auth setup-git`'s arguments: git on this machine asks gh for github.com credentials.
pub const SETUP_GIT_ARGS: [&str; 4] = ["auth", "setup-git", "--hostname", HOST];

/// Makes git on this machine use gh's github.com sign-in (`gh auth setup-git`), in at most
/// [`CHANGE_WAIT`]. `gh auth login --web` with no prompt (how [`super::start_in`] runs it) skips
/// this step, so after a Cloud machine's "Sign in with GitHub" `git clone` and `git push` of a
/// private repository still had no credentials (Leo, 2026-11-25: "Sign in with GitHub from the
/// Cloud machine ... You need to just do this and wire it up"). gh writes only its own credential
/// helper line into the user's git config; no token is read or kept here.
pub async fn setup_git(cli: &Cli) -> Result<(), LoginError> {
    let cmd = gh(cli, &SETUP_GIT_ARGS);
    match crate::complete::run::run(cmd, None, CHANGE_WAIT).await {
        Ok(out) if out.success => Ok(()),
        Ok(_) => Err(LoginError::new(reason::FAILED, "gh auth setup-git failed")),
        Err(crate::complete::run::RunError::Timeout) => {
            Err(LoginError::new(reason::FAILED, "gh auth setup-git did not finish"))
        }
        Err(crate::complete::run::RunError::Spawn(e)) => {
            Err(LoginError::new(reason::FAILED, format!("start gh: {e}")))
        }
    }
}

/// Makes `login` gh's active github.com account.
pub async fn switch(cli: &Cli, login: &str) -> Result<(), LoginError> {
    change(cli, "switch", login).await
}

/// Signs `login` out of gh on github.com.
pub async fn logout(cli: &Cli, login: &str) -> Result<(), LoginError> {
    change(cli, "logout", login).await
}

/// The `Cli` gh runs as: `gh` on the login PATH with this daemon's environment.
pub fn cli() -> Cli {
    Cli { program: super::Agent::Github.program().to_owned(), ..Cli::default() }
}
