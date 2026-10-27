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
    /// The session name: `--name` as the worktree and branch name it gets
    /// (`subsession_worktree::slug`: `Gui/Composer` is `gui-composer`).
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
    /// `--report-to` was given: another session started this one.
    pub reports: bool,
}

impl Launch {
    /// Checks the launcher flags and reads the prompt file, before anything
    /// is created; every mistake fails here.
    pub(super) fn prepare(args: &NewArgs) -> Result<Self> {
        let launcher = args.worktree.is_some()
            || args.prompt_file.is_some()
            || args.report_to.is_some()
            || args.group.is_some()
            || args.reuse;
        let (name, title) = match &args.name {
            // A plain `acpmux new -n NAME` keeps its name as given.
            Some(given) if !launcher => {
                crate::session_name::validate(given).map_err(|e| anyhow::anyhow!(e))?;
                (Some(given.clone()), None)
            }
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
        if args.reuse && name.is_none() {
            bail!("--reuse needs --name: the session to reuse is found by it");
        }
        if args.report_to.is_some()
            && file_prompt.is_none()
            && args.prompt.join("").trim().is_empty()
        {
            bail!("--report-to goes with the session's first prompt: give one or --prompt-file");
        }
        Ok(Self {
            reuse: args.reuse || worktree.is_some(),
            name,
            title,
            worktree,
            file_prompt,
            reports: args.report_to.is_some(),
        })
    }

    /// Whether a launcher flag (not only `--reuse`) was given.
    pub(super) fn launches(&self) -> bool {
        self.worktree.is_some() || self.file_prompt.is_some()
    }

    /// `_meta.acpmux.disallowedTools` for `session/new`: a session the
    /// launcher starts is a lane nobody sits at, so Claude Code's
    /// AskUserQuestion (a multiple-choice question that waits for a pick)
    /// would lock its chat; it decides, says why and goes on. Kept in the
    /// session's meta, so a respawn, a resume and a restart keep it too.
    pub(super) fn disallowed_tools(&self) -> Option<Value> {
        (self.launches() || self.reports).then(|| json!(["AskUserQuestion"]))
    }

    /// The first prompt: who started the session and how to answer, where
    /// its worktree is, then the prompt words and the prompt file.
    pub(super) fn first_prompt(&self, args: &NewArgs, created: &Value) -> Option<String> {
        let mut parts = Vec::new();
        if let Some(to) = &args.report_to {
            parts.push(format!(
                "You were started by the acpmux session {to}. Report back to it with: \
                 acpmux send --no-wait {to} '<report>'"
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
        let has_words = !words.trim().is_empty();
        if has_words {
            parts.push(words);
        }
        parts.extend(self.file_prompt.clone());
        // The context lines alone are no task: no prompt at all then.
        (has_words || self.file_prompt.is_some()).then(|| parts.join("\n\n"))
    }
}

/// `name` as a session name, the same as its worktree's folder and branch
/// (`cmux/<name>`): lowercase letters and digits, every other run one `-`,
/// at most 48 characters.
pub(crate) fn session_name(name: &str) -> Result<String> {
    let out = crate::subsession_worktree::slug(name);
    crate::session_name::validate(&out).map_err(|_| {
        anyhow::anyhow!("--name {name:?} has no letters or digits to name a session")
    })?;
    Ok(out)
}

/// `REPO[@BASE]`: the last `@` splits off the base (a ref or commit),
/// unless the whole of it is a folder.
fn split_worktree(spec: &str) -> (&str, Option<&str>) {
    match spec.rsplit_once('@') {
        Some((repo, base)) if !repo.is_empty() && !base.is_empty() && !expand(spec).is_dir() => {
            (repo, Some(base))
        }
        _ => (spec, None),
    }
}

/// `~/` as the home folder (`--worktree=~/repo` reaches no shell).
fn expand(path: &str) -> PathBuf {
    match (path.strip_prefix("~/"), std::env::var_os("HOME")) {
        (Some(rest), Some(home)) => PathBuf::from(home).join(rest),
        _ => PathBuf::from(path),
    }
}

fn absolute(path: &str) -> Result<PathBuf> {
    let p = expand(path);
    let p = if p.is_absolute() { p } else { std::env::current_dir()?.join(p) };
    std::fs::canonicalize(&p)
        .map_err(|e| anyhow::anyhow!("--worktree repository {}: {e}", p.display()))
}

/// Longest prompt file read: a brief, not a log.
const MAX_PROMPT_FILE: u64 = 1 << 20;

/// The prompt file's text, read at call time; a missing or empty file fails.
fn read_prompt_file(path: &Path) -> Result<String> {
    let abs =
        if path.is_absolute() { path.to_path_buf() } else { std::env::current_dir()?.join(path) };
    let len = std::fs::metadata(&abs)
        .map_err(|e| anyhow::anyhow!("--prompt-file {}: {e}", abs.display()))?
        .len();
    if len > MAX_PROMPT_FILE {
        bail!("--prompt-file {} is {len} bytes, more than 1 MiB", abs.display());
    }
    let text = std::fs::read_to_string(&abs)
        .map_err(|e| anyhow::anyhow!("--prompt-file {}: {e}", abs.display()))?;
    if text.trim().is_empty() {
        bail!("--prompt-file {} is empty", abs.display());
    }
    Ok(text)
}

/// The session named exactly `key` (`NAME` or `HOST/NAME`; its
/// `_acpmux/info`), None when there is none. `_acpmux/info` also takes a
/// prefix of a name: a session it finds by one is not this one.
pub(super) async fn existing(client: &Client, key: &str) -> Result<Option<Value>> {
    let (host, name) = match key.split_once('/') {
        Some((host, name)) => (Some(host), name),
        None => (None, key),
    };
    match client.request(method::MUX_INFO, json!({"sessionId": key})).await {
        // A bare name also finds a peer's session of that name: not this machine's.
        Ok(v)
            if v.get("name").and_then(Value::as_str) == Some(name)
                && v.get("peer").and_then(Value::as_str) == host =>
        {
            Ok(Some(v))
        }
        Ok(_) => Ok(None),
        Err(e) => {
            let m = e.to_string().to_lowercase();
            let none = m.contains("no session") || m.contains("not found") || m.contains("matches");
            if none { Ok(None) } else { Err(e) }
        }
    }
}

/// Refuses to reuse `info` (the session named `name`) for this launch: it
/// ended, or (with `repo`, the launch's repository) it works outside that
/// repository's worktree named `name`.
pub(super) fn check_reusable(info: &Value, name: &str, repo: Option<&Path>) -> Result<()> {
    if info.get("status").and_then(Value::as_str) == Some("closed") {
        bail!(
            "a session named {name} exists but has ended: delete it with \
             `acpmux session kill --purge {name}`, or pick another --name"
        );
    }
    let cwd = info.get("cwd").and_then(Value::as_str).unwrap_or_default();
    if repo.is_some_and(|repo| !in_worktree(Path::new(cwd), repo, name)) {
        bail!(
            "a session named {name} exists but works in {cwd}, not in its worktree: \
             pick another --name"
        );
    }
    Ok(())
}

/// `cwd` is in a worktree of `repo`'s repository whose folder is `name`,
/// as git reports them (the daemon chose the folder).
fn in_worktree(cwd: &Path, repo: &Path, name: &str) -> bool {
    let git = |dir: &Path, arg: &str| {
        std::process::Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(["rev-parse", "--path-format=absolute", arg])
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
    };
    let top = git(cwd, "--show-toplevel");
    let common = git(cwd, "--git-common-dir");
    top.is_some_and(|t| Path::new(&t).file_name().is_some_and(|f| f == name))
        && common.is_some()
        && common == git(repo, "--git-common-dir")
}

/// `info`'s session was never given a prompt: no turn ran, runs or waits.
/// A launcher stopped between making it and prompting it leaves one so.
pub(super) fn never_prompted(info: &Value) -> bool {
    let none = |k: &str| info.get(k).is_none_or(Value::is_null);
    let zero = |k: &str| info.get(k).and_then(Value::as_u64).unwrap_or(0) == 0;
    none("turn") && none("lastPrompt") && none("lastTurn") && zero("turnCount") && zero("queued")
}

/// A create that lost a race to another launcher with the same name.
pub(super) fn name_taken(e: &anyhow::Error) -> bool {
    e.to_string().contains("is taken")
}

/// The sidebar workspace key for session `id`: the same on every run, so
/// the app keeps one row for it (a lowercase UUID, as `agent open` takes).
fn workspace_key(id: &str) -> String {
    let h = crate::sha256::sha256_hex(format!("acpmux-launch:{id}").as_bytes());
    format!("{}-{}-{}-{}-{}", &h[0..8], &h[8..12], &h[12..16], &h[16..20], &h[20..32])
}

/// Shows session `id` in the cmux app's sidebar group `group` through the
/// app's `agent open` action (`cmux agent open`), optionally named `title`.
/// Unnamed launches omit the title so a peer's generated session name cannot
/// accidentally match another session's workspace in the same group.
/// A remote create returns the ID mirrored by the local daemon. Open that
/// ID here, without `--host`: the workspace belongs to this Mac and its
/// acpmux forwards the chat to the peer. This also avoids a name lookup in
/// the app's peer inventory, which may not have seen the new session yet.
pub(super) fn show_in_group(id: &str, title: Option<&str>, group: &str) -> Result<()> {
    let key = workspace_key(id);
    let mut args = vec!["agent", "open", id];
    if let Some(title) = title {
        args.extend(["--name", title]);
    }
    args.extend(["--key", &key, "--group", group]);
    let retry = std::iter::once("cmux")
        .chain(args.iter().copied())
        .map(crate::harness_health::channel::quote)
        .collect::<Vec<_>>()
        .join(" ");
    let out = std::process::Command::new("cmux").args(args).output().with_context(|| {
        format!(
            "the session was created, but --group could not run cmux; put the running Mac app's \
             bundled CLI on PATH, then retry on that Mac: {retry}"
        )
    })?;
    if !out.status.success() {
        bail!(
            "the session runs, but the cmux app did not show it: {retry}: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn launch(words: &[&str]) -> Launch {
        #[derive(clap::Parser)]
        struct New {
            #[command(flatten)]
            args: NewArgs,
        }
        let dir = std::env::temp_dir().join(format!("acpmux-launch-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let brief = dir.join("brief.md");
        std::fs::write(&brief, "do it\n").unwrap();
        let mut argv = vec!["new".to_owned()];
        argv.extend(words.iter().map(|w| w.replace("BRIEF", &brief.to_string_lossy())));
        let new = <New as clap::Parser>::try_parse_from(argv).unwrap();
        Launch::prepare(&new.args).unwrap()
    }

    #[test]
    fn a_launched_session_never_gets_ask_user_question() {
        // Nobody sits at its chat: a multiple-choice question would lock it.
        let ask = Some(json!(["AskUserQuestion"]));
        assert_eq!(launch(&["-n", "x", "--prompt-file", "BRIEF"]).disallowed_tools(), ask);
        assert_eq!(launch(&["--report-to", "coord", "go"]).disallowed_tools(), ask);
        assert_eq!(launch(&["-n", "x", "go"]).disallowed_tools(), None);
        assert_eq!(launch(&["-n", "x", "--reuse"]).disallowed_tools(), None);
    }

    #[test]
    fn a_name_with_slashes_becomes_a_session_name() {
        assert_eq!(session_name("gui/composer").unwrap(), "gui-composer");
        assert_eq!(session_name("lane-launcher").unwrap(), "lane-launcher");
        assert_eq!(session_name(" a // b c ").unwrap(), "a-b-c");
        assert_eq!(session_name("/.x/").unwrap(), "x");
        // One worktree, one session: the name is the worktree's.
        assert_eq!(session_name("Lane_A").unwrap(), session_name("lane-a").unwrap());
        assert!(session_name("//").is_err());
    }

    #[test]
    fn a_remote_session_can_join_a_group_without_an_explicit_name() {
        let prepared = launch(&[
            "--host",
            "gcp-codex-lane-2",
            "-m",
            "codex",
            "--group",
            "Remote demo",
            "-d",
            "say hi",
        ]);
        assert!(prepared.name.is_none());
        assert!(!prepared.reuse);
    }

    #[test]
    fn a_named_remote_group_launch_keeps_reuse_and_its_title() {
        let prepared = launch(&[
            "--host",
            "peer",
            "--group",
            "Remote demo",
            "--name",
            "Remote task",
            "--reuse",
            "-d",
        ]);
        assert_eq!(prepared.name.as_deref(), Some("remote-task"));
        assert_eq!(prepared.title.as_deref(), Some("Remote task"));
        assert!(prepared.reuse);
    }

    #[test]
    fn the_last_at_splits_off_the_base() {
        assert_eq!(split_worktree("~/r@origin/feat"), ("~/r", Some("origin/feat")));
        assert_eq!(split_worktree("/a@b/r@main"), ("/a@b/r", Some("main")));
        assert_eq!(split_worktree("/r"), ("/r", None));
        assert_eq!(split_worktree("/r@"), ("/r@", None));
    }

    #[test]
    fn only_a_session_with_no_turn_and_nothing_queued_was_never_prompted() {
        let fresh = json!({"turn": null, "lastPrompt": null, "lastTurn": null, "turnCount": 0, "queued": 0});
        assert!(never_prompted(&fresh));
        for (k, v) in [
            ("turn", json!({"prompt": "go"})),
            ("lastPrompt", json!("go")),
            ("turnCount", json!(1)),
            ("queued", json!(1)),
        ] {
            let mut info = fresh.clone();
            info[k] = v;
            assert!(!never_prompted(&info), "{k}");
        }
    }

    #[test]
    fn a_session_outside_its_worktree_or_ended_is_not_reused() {
        let top = std::env::temp_dir().join(format!("acpmux-reuse-{}", uuid::Uuid::now_v7()));
        let (repo, wt, other) = (top.join("repo"), top.join("wts/lane"), top.join("wts/lane-2"));
        std::fs::create_dir_all(&repo).unwrap();
        let git = |dir: &Path, args: &[&str]| {
            let ok = std::process::Command::new("git")
                .arg("-C")
                .arg(dir)
                .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"])
                .args(args)
                .status()
                .unwrap()
                .success();
            assert!(ok, "git {args:?}");
        };
        git(&repo, &["init", "-q"]);
        git(&repo, &["commit", "-q", "--allow-empty", "-m", "first"]);
        git(&repo, &["worktree", "add", "-q", "-B", "a", &wt.to_string_lossy()]);
        std::fs::create_dir_all(wt.join("sub")).unwrap();
        git(&repo, &["worktree", "add", "-q", "-B", "b", &other.to_string_lossy()]);
        let at = |cwd: &Path, status: &str| json!({"cwd": cwd, "status": status});
        let r = Some(repo.as_path());
        assert!(check_reusable(&at(&wt, "ready"), "lane", r).is_ok());
        assert!(check_reusable(&at(&wt.join("sub"), "running"), "lane", r).is_ok());
        assert!(check_reusable(&at(&repo, "ready"), "lane", r).is_err());
        assert!(check_reusable(&at(&repo, "ready"), "lane", None).is_ok());
        assert!(check_reusable(&at(&wt, "closed"), "lane", r).is_err());
        assert!(check_reusable(&at(&other, "ready"), "lane", r).is_err());
        let _ = std::fs::remove_dir_all(&top);
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
