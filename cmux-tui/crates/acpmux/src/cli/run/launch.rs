//! `acpmux new` as the one way to start an agent for a task: `--worktree`
//! starts it in its own git worktree (made by the daemon, reused when there),
//! `--prompt-file` gives it its instructions, `--report-to` tells it who
//! started it, `--group` shows it in the cmux app's sidebar group. Running
//! the same command again gives the same session and worktree: a named
//! session that already runs is reused (its first prompt is not sent again).

use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use anyhow::{Result, bail};
use serde_json::{Value, json};
use tokio::time::Instant;

use crate::cli::command::NewArgs;
use crate::cli::errors;
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
        if let (Some(host), Some(from)) = (&args.host, &args.harness_from) {
            bail!(
                "--harness-from copies a session on this machine only: run \
                 `ssh {host} acpmux new --harness-from {from} ...` there instead of --host {host}"
            );
        }
        let file_prompt = args.prompt_file.as_deref().map(read_prompt_file).transpose()?;
        if let Some(group) = &args.group {
            validate_group(group)?;
        }
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

/// `_meta.acpmux` of `new` for the session it takes over from (`hub/lineage/successor.rs`):
/// `--harness-from`, and `--report-to` (a successor reports to its predecessor).
pub(super) fn successor_meta(args: &NewArgs, meta: &mut Value) {
    if let Some(p) = &args.harness_from {
        meta[crate::hub::lineage::successor::HARNESS_FROM_FIELD] = json!(p);
    }
    if let Some(to) = &args.report_to {
        meta[crate::hub::lineage::successor::REPORT_TO_FIELD] = json!(to);
    }
}

/// The warnings in a new session's reply, one line each: started past this host's lane cap
/// (`hub/admission.rs`), never a refusal, and running unlike the session it takes over from
/// (`hub/lineage/successor.rs`).
pub(crate) fn print_new_warnings(created: &Value) {
    for at in ["/_meta/acpmux/admission/warning", "/_meta/acpmux/successor/warning"] {
        if let Some(w) = created.pointer(at).and_then(Value::as_str) {
            eprintln!("acpmux: warning: {w}");
        }
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

/// A group is a person's label, not a cmux object id. Rejecting ids before
/// `session/new` keeps a bad launcher from creating persistent sidebar junk.
pub(crate) fn validate_group(group: &str) -> Result<()> {
    let label = group.trim();
    let lower = label.to_ascii_lowercase();
    let id_prefix = ["grp_", "ws_", "tab_", "pane_", "win_", "workspace_group:"]
        .iter()
        .any(|prefix| lower.starts_with(prefix));
    let uuid = uuid::Uuid::parse_str(label).is_ok();
    if label.is_empty() || id_prefix || uuid {
        let message = "--group must be a non-empty human label, not a cmux id; use e.g. `--group \"GUI push\"`, or omit --group";
        let data = json!({"reason": "usage.group_name", "group": group});
        return Err(errors::AppError::new(errors::Code::Usage, "group_name", message)
            .with_data(data)
            .into());
    }
    Ok(())
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
    read_prompt_file_with(path, std::io::stdin().lock())
}

/// Read a prompt file, using `stdin` when `path` names the already-open fd 0.
/// Keeping the reader injectable lets tests cover the fd-0 paths without replacing the process stdin.
fn read_prompt_file_with<R: Read>(path: &Path, stdin: R) -> Result<String> {
    if is_stdin_path(path) {
        return read_prompt_reader(path, stdin);
    }

    let abs =
        if path.is_absolute() { path.to_path_buf() } else { std::env::current_dir()?.join(path) };
    let len = std::fs::metadata(&abs)
        .map_err(|e| anyhow::anyhow!("--prompt-file {}: {e}", abs.display()))?
        .len();
    if len > MAX_PROMPT_FILE {
        bail!("--prompt-file {} is {len} bytes, more than 1 MiB", abs.display());
    }
    let file = std::fs::File::open(&abs)
        .map_err(|e| anyhow::anyhow!("--prompt-file {}: {e}", abs.display()))?;
    read_prompt_reader(&abs, file)
}

fn is_stdin_path(path: &Path) -> bool {
    matches!(
        path.to_str(),
        Some("-") | Some("/dev/stdin") | Some("/proc/self/fd/0") | Some("/dev/fd/0")
    )
}

fn read_prompt_reader<R: Read>(path: &Path, reader: R) -> Result<String> {
    let mut bytes = Vec::with_capacity((MAX_PROMPT_FILE + 1) as usize);
    reader
        .take(MAX_PROMPT_FILE + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| anyhow::anyhow!("--prompt-file {}: {e}", path.display()))?;
    if bytes.len() as u64 > MAX_PROMPT_FILE {
        bail!("--prompt-file {} is more than 1 MiB", path.display());
    }
    let text = String::from_utf8(bytes)
        .map_err(|e| anyhow::anyhow!("--prompt-file {}: {e}", path.display()))?;
    if text.trim().is_empty() {
        bail!("--prompt-file {} is empty", path.display());
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
            let none = m.contains("no session")
                || m.contains("no local session")
                || m.contains("not found")
                || m.contains("matches");
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
/// A remote create's ID stays qualified with its owning peer. Open that
/// qualified ID here, without `--host`: the workspace belongs to this Mac and its
/// acpmux forwards the chat to the peer. This also avoids a name lookup in
/// the app's peer inventory, which may not have seen the new session yet.
pub(super) fn show_in_group(
    id: &str,
    session_name: &str,
    title: Option<&str>,
    group: &str,
    daemon_cli_path: Option<&std::path::Path>,
    deadline: Option<Instant>,
) -> Result<()> {
    let key = workspace_key(id);
    let mut args = vec!["agent", "open", id];
    if let Some(title) = title {
        args.extend(["--name", title]);
    }
    args.extend(["--key", &key, "--group", group]);
    // Prefer the app's bundled CLI when the daemon was started by the app.
    // A plain shell can otherwise resolve an older standalone `cmux` first.
    let cli =
        select_cli(daemon_cli_path, std::env::var_os(crate::login_env::BUNDLED_CLI_ENV).as_deref());
    let path_cli = PathBuf::from("cmux");
    let (cli, result) = run_with_fallback(&cli, &args, &path_cli, deadline);
    let command = std::iter::once(cli.to_string_lossy().as_ref())
        .chain(args.iter().copied())
        .map(crate::harness_health::channel::quote)
        .collect::<Vec<_>>()
        .join(" ");
    let out = result.map_err(|error| -> anyhow::Error {
        if error.kind() == std::io::ErrorKind::TimedOut {
            return crate::cli::errors::AppError::timeout(format!(
                "session {session_name} was created, but showing it in --group {group} did not finish \
                 before the deadline ({error}); retry only the open: {command}"
            ))
            .with_session(id)
            .into();
        }
        anyhow::anyhow!(
            "session {session_name} was created, but --group could not run cmux ({error}); put the running Mac app's \
             bundled CLI on PATH, then retry on that Mac: {command}"
        )
    })?;
    if !out.status.success() {
        bail!(
            "session {session_name} was created, but the cmux app did not show it ({}): {}; retry only the open: {command}",
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(())
}

fn run_with_fallback(
    primary: &Path,
    args: &[&str],
    fallback: &Path,
    deadline: Option<Instant>,
) -> (PathBuf, std::io::Result<std::process::Output>) {
    let result = run_bounded(primary, args, deadline);
    if primary != fallback
        && !result.as_ref().is_ok_and(|output| output.status.success())
        && !result.as_ref().is_err_and(|error| error.kind() == std::io::ErrorKind::TimedOut)
    {
        let fallback_result = run_bounded(fallback, args, deadline);
        return (fallback.to_path_buf(), fallback_result);
    }
    (primary.to_path_buf(), result)
}

fn run_bounded(path: &Path, args: &[&str], deadline: Option<Instant>) -> std::io::Result<Output> {
    let mut command = Command::new(path);
    command.args(args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    #[cfg(unix)]
    std::os::unix::process::CommandExt::process_group(&mut command, 0);
    let done =
        crate::cli::bounded_child::wait(command.spawn()?, None, deadline, "cmux agent open")?;
    Ok(Output { status: done.status, stdout: done.stdout, stderr: done.stderr })
}

fn select_cli(daemon_cli_path: Option<&Path>, env_cli_path: Option<&std::ffi::OsStr>) -> PathBuf {
    for path in [daemon_cli_path.map(Path::to_path_buf), env_cli_path.map(PathBuf::from)]
        .into_iter()
        .flatten()
    {
        if is_executable_file(&path) {
            return path;
        }
    }
    PathBuf::from("cmux")
}

#[cfg(unix)]
fn is_executable_file(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path)
        .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
}

#[cfg(not(unix))]
fn is_executable_file(path: &Path) -> bool {
    path.is_file()
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
        // A brief of its own per call: tests run in parallel, and a shared
        // file one test rewrites (truncate, then write) reads empty in another.
        let dir = tempfile::tempdir().unwrap();
        let brief = dir.path().join("brief.md");
        std::fs::write(&brief, "do it\n").unwrap();
        let mut argv = vec!["new".to_owned()];
        argv.extend(words.iter().map(|w| w.replace("BRIEF", &brief.to_string_lossy())));
        let new = <New as clap::Parser>::try_parse_from(argv).unwrap();
        Launch::prepare(&new.args).unwrap()
    }

    #[test]
    fn stale_bundled_cli_falls_back_to_path_name() {
        let stale = std::env::temp_dir().join(format!("acpmux-stale-cli-{}", std::process::id()));
        assert_eq!(select_cli(Some(&stale), None), Path::new("cmux"));
    }

    #[cfg(unix)]
    #[test]
    fn a_failing_bundled_cli_retries_the_path_cli() {
        let root =
            std::env::temp_dir().join(format!("acpmux-cli-fallback-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&root).unwrap();
        let bundled = root.join("bundled");
        let path_cli = root.join("path-cmux");
        std::fs::write(&bundled, "#!/bin/sh\nexit 7\n").unwrap();
        std::fs::write(&path_cli, "#!/bin/sh\nexit 0\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            for path in [&bundled, &path_cli] {
                std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
            }
        }
        let args = ["agent", "open", "session-id"];
        let (chosen, output) = run_with_fallback(&bundled, &args, &path_cli, None);
        assert_eq!(chosen, path_cli);
        assert!(output.unwrap().status.success());
        std::fs::remove_dir_all(root).unwrap();
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
    fn a_group_is_a_human_label_and_never_an_object_id() {
        for group in [
            "",
            "   ",
            "grp_012345",
            "ws_012345",
            "workspace_group:42",
            "550e8400-e29b-41d4-a716-446655440000",
        ] {
            let refused = validate_group(group).unwrap_err();
            let error = refused.to_string();
            assert!(error.contains("human label"), "{group:?}: {error}");
            assert!(error.contains("omit --group"), "{group:?}: {error}");
            // A usage error (exit 2) the --json envelope names, before any session is made.
            let app = crate::cli::errors::classify(&refused);
            assert_eq!(app.exit_status(), 2, "{group:?}");
            let envelope = app.envelope();
            assert_eq!(envelope["error"]["detail"], "group_name", "{envelope}");
            assert_eq!(envelope["error"]["data"]["reason"], "usage.group_name", "{envelope}");
        }
        assert!(validate_group("GUI push").is_ok());
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
    fn a_group_open_failure_keeps_the_session_name_and_retry_command() {
        let error = show_in_group(
            "session-id",
            "lane-name",
            None,
            "remote-audit",
            Some(Path::new("/definitely/missing/cmux")),
            None,
        )
        .unwrap_err()
        .to_string();
        assert!(error.contains("session lane-name was created"), "{error}");
        assert!(error.contains("cmux agent open session-id"), "{error}");
        assert!(error.contains("--group remote-audit"), "{error}");
    }

    /// A `cmux agent open` that stalls ends at the caller's deadline, exits as a timeout and is
    /// not tried again on the PATH fallback.
    #[cfg(unix)]
    #[test]
    fn a_stalled_group_open_ends_at_the_caller_deadline_as_a_timeout() {
        let dir = std::env::temp_dir().join(format!("acpmux-group-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let cli = dir.join("cmux");
        crate::test_exec::write_executable(&cli, "#!/bin/sh\nsleep 30\n");
        let started = std::time::Instant::now();
        let deadline = Instant::now() + std::time::Duration::from_millis(300);
        let error = show_in_group("session-id", "lane-name", None, "g", Some(&cli), Some(deadline))
            .unwrap_err();
        assert!(started.elapsed() < std::time::Duration::from_secs(2), "{:?}", started.elapsed());
        let app = error.downcast_ref::<crate::cli::errors::AppError>();
        assert_eq!(app.map(|a| a.code), Some(crate::cli::errors::Code::Timeout), "{error:#}");
        assert!(error.to_string().contains("session lane-name was created"), "{error:#}");
        std::fs::remove_dir_all(dir).unwrap();
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
        let oversized = dir.join("oversized.md");
        std::fs::write(&oversized, vec![b'x'; (MAX_PROMPT_FILE + 1) as usize]).unwrap();
        assert!(read_prompt_file(&oversized).unwrap_err().to_string().contains("more than 1 MiB"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn stdin_prompt_paths_read_from_the_already_open_stdin() {
        for path in ["-", "/dev/stdin", "/proc/self/fd/0", "/dev/fd/0"] {
            assert_eq!(
                read_prompt_file_with(Path::new(path), std::io::Cursor::new("do it\n")).unwrap(),
                "do it\n",
                "{path}"
            );
        }
    }
}
