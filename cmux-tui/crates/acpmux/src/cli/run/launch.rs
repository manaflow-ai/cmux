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
                         `ssh {host} acpmux new ...` there instead of --machine {host}"
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
                 `ssh {host} acpmux new --harness-from {from} ...` there instead of --machine {host}"
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
                 acpmux send --no-wait {to} '<report>'. Hand it an image with \
                 --attach /abs/path.png, never a provider's file id (libfile_…)."
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

/// The session named `key` (`NAME` or `HOST/NAME`; its `_acpmux/info`), in
/// this case or another, None when there is none. `_acpmux/info` also takes a
/// prefix of a name: a session it finds by one is not this one.
pub(super) async fn existing(client: &Client, key: &str) -> Result<Option<Value>> {
    match client.request(method::MUX_INFO, json!({"sessionId": key})).await {
        Ok(v) if names(&v, key) => Ok(Some(v)),
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

/// `info` is the session `key` names whole, in this case or another (Leo, 2026-11-05: "stuff
/// like that should work better yes"): `--name td2-a --reuse` finds `td2-A` rather than starting
/// a second session beside it. Never by a prefix or without separators, and a bare name never
/// names a peer's session of that name.
fn names(info: &Value, key: &str) -> bool {
    let (host, name) = match key.split_once('/') {
        Some((host, name)) => (Some(host), name),
        None => (None, key),
    };
    let whole = |found: &str, typed: &str| found.eq_ignore_ascii_case(typed);
    let peer = info.get("peer").and_then(Value::as_str);
    info.get("name").and_then(Value::as_str).is_some_and(|found| whole(found, name))
        && match (peer, host) {
            (Some(peer), Some(host)) => whole(peer, host),
            (peer, host) => peer == host,
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
pub(crate) fn workspace_key(id: &str) -> String {
    let h = crate::sha256::sha256_hex(format!("acpmux-launch:{id}").as_bytes());
    format!("{}-{}-{}-{}-{}", &h[0..8], &h[8..12], &h[12..16], &h[16..20], &h[20..32])
}

/// The name a workspace opened for an unnamed launch shows: the session's own
/// name (`gcp-lane-11/ergo-help` for a peer's session, so two peers' `codex-1`
/// read apart), never the app's `workspace-N`. `name` is the session's name
/// as the daemon reported it, `session_id` its raw id (`name` falls back to it
/// when the daemon reported none, which names nothing) and `peer` the machine
/// that runs it. Nil when there is nothing better than `workspace-N`.
pub(super) fn default_workspace_name(
    name: &str,
    session_id: &str,
    peer: Option<&str>,
) -> Option<String> {
    let name = name.trim();
    if name.is_empty() || name == session_id {
        return None;
    }
    match peer.map(str::trim).filter(|peer| !peer.is_empty()) {
        Some(peer) if !name.starts_with(&format!("{peer}/")) => Some(format!("{peer}/{name}")),
        _ => Some(name.to_owned()),
    }
}

/// The words of `cmux agent open` for session `id` in group `group`. `title`
/// (an explicit launch name) goes as `--name`, which reuses a predecessor row
/// of that name in the group. `default_name` (an unnamed launch's session name,
/// `default_workspace_name`) goes as `--default-name`: the new workspace's
/// name, which never matches a predecessor row, so a peer's generated session
/// name cannot put its chat in another session's workspace.
fn group_open_args(
    id: &str,
    key: &str,
    title: Option<&str>,
    default_name: Option<&str>,
    group: &str,
) -> Vec<String> {
    let mut args = vec!["agent".to_owned(), "open".to_owned(), id.to_owned()];
    if let Some(title) = title {
        args.extend(["--name".to_owned(), title.to_owned()]);
    } else if let Some(default_name) = default_name {
        args.extend(["--default-name".to_owned(), default_name.to_owned()]);
    }
    args.extend(["--key".to_owned(), key.to_owned(), "--group".to_owned(), group.to_owned()]);
    args
}

/// Shows session `id` in the cmux app's sidebar group `group` through the
/// app's `agent open` action (`cmux agent open`), named `title` (an explicit
/// launch name) or else `default_name` (`group_open_args`).
/// A remote create's ID stays qualified with its owning peer. Open that
/// qualified ID here, without `--host`: the workspace belongs to this Mac and its
/// acpmux forwards the chat to the peer. This also avoids a name lookup in
/// the app's peer inventory, which may not have seen the new session yet.
pub(super) fn show_in_group(
    id: &str,
    session_name: &str,
    title: Option<&str>,
    default_name: Option<&str>,
    group: &str,
    daemon_cli_path: Option<&std::path::Path>,
    deadline: Option<Instant>,
) -> Result<()> {
    let key = workspace_key(id);
    // Prefer the app's bundled CLI when the daemon was started by the app.
    // A plain shell can otherwise resolve an older standalone `cmux` first.
    let primary =
        select_cli(daemon_cli_path, std::env::var_os(crate::login_env::BUNDLED_CLI_ENV).as_deref());
    let path_cli = PathBuf::from("cmux");
    let named = group_open_args(id, &key, title, default_name, group);
    let plain = group_open_args(id, &key, None, None, group);
    let mut args = named.iter().map(String::as_str).collect::<Vec<_>>();
    let (mut cli, mut result) = run_with_fallback(&primary, &args, &path_cli, deadline);
    // An app older than `defaultName` refuses the whole open (an unknown argument): once more
    // without it, so a newer acpmux beside an older app still shows the session, unnamed as before.
    if title.is_none()
        && default_name.is_some()
        && !result.as_ref().is_ok_and(|output| output.status.success())
        && !result.as_ref().is_err_and(|error| error.kind() == std::io::ErrorKind::TimedOut)
    {
        args = plain.iter().map(String::as_str).collect();
        (cli, result) = run_with_fallback(&primary, &args, &path_cli, deadline);
    }
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
mod tests;
