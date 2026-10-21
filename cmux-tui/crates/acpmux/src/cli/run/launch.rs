//! `acpmux new` as the one way to start an agent for a task: `--worktree`
//! starts it in its own git worktree (made by the daemon, reused when there),
//! `--prompt-file` gives it its instructions, `--report-to` tells it who
//! started it, `--group` shows it in the cmux app's sidebar group. Running
//! the same command again gives the same session and worktree: a named
//! session that already runs is reused (its first prompt is not sent again).

use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde_json::{Value, json};

use crate::cli::command::NewArgs;
use crate::client::Client;
use crate::rpc::method;

/// What the launcher flags of one `acpmux new` add to the plain command.
pub(super) struct Launch {
    /// The session name: `--name` with every character a name may not hold
    /// (`/`, spaces) turned into `-`.
    pub name: Option<String>,
    /// `--name` as given, when the session name had to differ from it.
    pub title: Option<String>,
    /// `_meta.acpmux.worktree` for `session/new`, and the repository
    /// folder it is made from (the request's cwd).
    pub worktree: Option<(Value, PathBuf)>,
    /// Reuse a session that already has this name.
    pub reuse: bool,
    /// `--prompt-file`'s text, read now.
    pub file_prompt: Option<String>,
}

impl Launch {
    /// Checks the launcher flags and reads the prompt file, before anything
    /// is created; every mistake fails here.
    pub(super) fn prepare(args: &NewArgs) -> Result<Self> {
        let (name, title) = match &args.name {
            Some(given) => {
                let name = session_name(given)?;
                let title = (name != *given).then(|| given.clone());
                (Some(name), title)
            }
            None => (None, None),
        };
        let worktree = match &args.worktree {
            None => None,
            Some(spec) => {
                if let Some(host) = &args.host {
                    bail!(
                        "--worktree makes the worktree on this machine only: run \
                         `ssh {host} acpmux new ...` there instead of --host {host}"
                    );
                }
                if args.cwd.is_some() {
                    bail!("--worktree names the repository; it replaces --cwd");
                }
                let Some(name) = &name else {
                    bail!(
                        "--worktree needs --name: the worktree, branch and session are named by it"
                    );
                };
                let (repo, base) = split_worktree(spec);
                Some((json!({"name": name, "base": base}), absolute(repo)?))
            }
        };
        let file_prompt = args.prompt_file.as_deref().map(read_prompt_file).transpose()?;
        if args.group.is_some() && name.is_none() {
            bail!("--group needs --name, so a second run finds the same sidebar row");
        }
        Ok(Self { reuse: args.reuse || worktree.is_some(), name, title, worktree, file_prompt })
    }

    /// Whether a launcher flag (not only `--reuse`) was given.
    pub(super) fn launches(&self) -> bool {
        self.worktree.is_some() || self.file_prompt.is_some()
    }

    /// The first prompt: who started the session and how to answer, where
    /// its worktree is, then the prompt words and the prompt file.
    pub(super) fn first_prompt(&self, args: &NewArgs, created: &Value) -> Option<String> {
        let mut parts = Vec::new();
        if let Some(to) = &args.report_to {
            parts.push(format!(
                "You were started by the acpmux session {to}. Report back to it with: \
                 acpmux send --no-wait --steer {to} '<report>'"
            ));
        }
        if let Some(w) = created.pointer("/_meta/acpmux/worktree") {
            let g = |k: &str| w.get(k).and_then(Value::as_str).unwrap_or_default().to_owned();
            parts.push(format!(
                "Your worktree {} is on branch {} from {}.",
                g("root"),
                g("branch"),
                g("base")
            ));
        }
        let words = args.prompt.join(" ");
        if !words.trim().is_empty() {
            parts.push(words);
        }
        parts.extend(self.file_prompt.clone());
        // The context lines alone are no task: no prompt at all then.
        (!args.prompt.is_empty() || self.file_prompt.is_some()).then(|| parts.join("\n\n"))
    }
}

/// `name` as a session name: characters outside `[A-Za-z0-9._-]` become
/// `-`, runs of `-` collapse, and the name never starts with `.` or `-`.
pub(crate) fn session_name(name: &str) -> Result<String> {
    let mut out = String::with_capacity(name.len());
    for c in name.trim().chars() {
        let c = if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.') { c } else { '-' };
        if !(c == '-' && out.ends_with('-')) {
            out.push(c);
        }
    }
    let out: String =
        out.trim_start_matches(['.', '-']).trim_end_matches('-').chars().take(80).collect();
    crate::session_name::validate(&out).map_err(|e| anyhow::anyhow!("--name {name:?}: {e}"))?;
    Ok(out)
}

/// `REPO[@BASE]`: the last `@` splits off the base (a ref or commit).
fn split_worktree(spec: &str) -> (&str, Option<&str>) {
    match spec.rsplit_once('@') {
        Some((repo, base)) if !repo.is_empty() && !base.is_empty() => (repo, Some(base)),
        _ => (spec, None),
    }
}

fn absolute(path: &str) -> Result<PathBuf> {
    let p = Path::new(path);
    let p = if p.is_absolute() { p.to_path_buf() } else { std::env::current_dir()?.join(p) };
    std::fs::canonicalize(&p)
        .map_err(|e| anyhow::anyhow!("--worktree repository {}: {e}", p.display()))
}

/// The prompt file's text, read at call time; a missing or empty file fails.
fn read_prompt_file(path: &Path) -> Result<String> {
    let abs =
        if path.is_absolute() { path.to_path_buf() } else { std::env::current_dir()?.join(path) };
    let text = std::fs::read_to_string(&abs)
        .map_err(|e| anyhow::anyhow!("--prompt-file {}: {e}", abs.display()))?;
    if text.trim().is_empty() {
        bail!("--prompt-file {} is empty", abs.display());
    }
    Ok(text)
}

/// The session already named `name` (its `_acpmux/info`), None when there is none.
pub(super) async fn existing(client: &Client, name: &str) -> Result<Option<Value>> {
    match client.request(method::MUX_INFO, json!({"sessionId": name})).await {
        Ok(v) => Ok(Some(v)),
        Err(e) => {
            let m = e.to_string().to_lowercase();
            if m.contains("no session") || m.contains("not found") { Ok(None) } else { Err(e) }
        }
    }
}

/// A create that lost a race to another launcher with the same name.
pub(super) fn name_taken(e: &anyhow::Error) -> bool {
    e.to_string().contains("is taken")
}

/// The sidebar workspace key for session `name`: the same on every run, so
/// the app keeps one row for it (a lowercase UUID, as `agent open` takes).
fn workspace_key(name: &str) -> String {
    let h = crate::sha256::sha256_hex(format!("acpmux-launch:{name}").as_bytes());
    format!("{}-{}-{}-{}-{}", &h[0..8], &h[8..12], &h[12..16], &h[16..20], &h[20..32])
}

/// Shows session `id` in the cmux app's sidebar group `group` through the
/// app's `agent open` action (`cmux agent open`), named `title`.
pub(super) fn show_in_group(id: &str, name: &str, title: &str, group: &str) -> Result<()> {
    let key = workspace_key(name);
    let out = std::process::Command::new("cmux")
        .args(["agent", "open", id, "--name", title, "--key", &key, "--group", group])
        .output()
        .context("--group runs `cmux agent open`; no cmux CLI on PATH")?;
    if !out.status.success() {
        bail!(
            "the session runs, but the cmux app did not show it: `cmux agent open {id} --name {title:?} \
             --key {key} --group {group:?}`: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_name_with_slashes_becomes_a_session_name() {
        assert_eq!(session_name("gui/composer").unwrap(), "gui-composer");
        assert_eq!(session_name("lane-launcher").unwrap(), "lane-launcher");
        assert_eq!(session_name(" a // b c ").unwrap(), "a-b-c");
        assert_eq!(session_name("/.x/").unwrap(), "x");
        assert!(session_name("//").is_err());
    }

    #[test]
    fn the_last_at_splits_off_the_base() {
        assert_eq!(split_worktree("~/r@origin/feat"), ("~/r", Some("origin/feat")));
        assert_eq!(split_worktree("/a@b/r@main"), ("/a@b/r", Some("main")));
        assert_eq!(split_worktree("/r"), ("/r", None));
        assert_eq!(split_worktree("/r@"), ("/r@", None));
    }

    #[test]
    fn the_sidebar_key_is_a_stable_uuid() {
        let k = workspace_key("lane");
        assert_eq!(k, workspace_key("lane"));
        assert_ne!(k, workspace_key("lane2"));
        assert!(uuid::Uuid::parse_str(&k).is_ok());
    }

    #[test]
    fn an_empty_or_missing_prompt_file_fails() {
        let dir = std::env::temp_dir().join(format!("acpmux-launch-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let empty = dir.join("empty.md");
        std::fs::write(&empty, " \n").unwrap();
        assert!(read_prompt_file(&empty).unwrap_err().to_string().contains("is empty"));
        assert!(read_prompt_file(&dir.join("missing.md")).is_err());
        let brief = dir.join("brief.md");
        std::fs::write(&brief, "do it\n").unwrap();
        assert_eq!(read_prompt_file(&brief).unwrap(), "do it\n");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
