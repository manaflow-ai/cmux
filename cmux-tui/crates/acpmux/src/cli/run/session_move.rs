//! `acpmux session move SESSION... --host PEER|auto [--interrupt] [--leave-dirty] [--dry-run]`
//! (or `--all-idle` for every idle chat here): moves chats from this machine's daemon to an ssh
//! peer's, with their history, queue and draft, and their folder made there.
//!
//! For each chat, in order, stopping at the first step that fails (nothing after it is done):
//!
//! 1. Refused while its turn runs (unless `--interrupt`), while it is being moved, once it moved
//!    away, or when its folder is gone here (`session_move_plan.rs` `refusal`).
//! 2. The target: the peer named, or with `auto` the daemon's placement (`_acpmux/place`) among
//!    the peers, never this machine. A host reserved for someone (`reservations` in
//!    fleet-registry.json, or an `acpmux host hold`) is never a target. Chats in one checkout go
//!    to one host.
//! 3. The folder (`plan_folder`): a checkout's branch is pushed to `origin` (never forced) and
//!    becomes a worktree of that branch on the target (`wt new` there when it has `wt`, else a
//!    clone under `~/Projects/checkouts`); any other folder under the home is made at the same
//!    path under the target's home.
//! 4. The move itself is `session transfer`'s (`transfer.rs`, `hub/transfer_out.rs`), with the
//!    target daemon's own local socket reached through an `ssh -L` forward: the chat is frozen
//!    here, its bundle paged across, imported there in its new folder, then committed here. The
//!    commit records where it went (`movedTo {host, sessionId, cwd, branch, commit}`), and a
//!    moved chat never runs here again (`hub/lifecycle.rs`), so there is one writer. `resolve`
//!    and agent links follow it (`hub/locate.rs`).

use super::*;
use anyhow::{Context as _, bail};
use crate::cli::session_move_plan::{self as plan, Checkout, Folder};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command as StdCommand;

pub(crate) struct MoveArgs {
    pub sessions: Vec<String>,
    pub host: String,
    pub all_idle: bool,
    pub interrupt: bool,
    pub leave_dirty: bool,
    pub dry_run: bool,
}

/// One chat's outcome, as printed and in `--json`.
struct Outcome {
    session: String,
    name: String,
    host: Option<String>,
    cwd: Option<String>,
    moved: bool,
    error: Option<String>,
}

pub(super) async fn run(args: MoveArgs, json_out: bool) -> Result<()> {
    let src = connect(true).await?;
    let ids = if args.all_idle { idle_chats(&src).await? } else { args.sessions.clone() };
    if ids.is_empty() {
        bail!("no chat to move: name one or more, or pass --all-idle");
    }
    let peers = src.request("_acpmux/peers", json!({})).await?;
    let mut targets = Targets::new(&args.host, &peers)?;
    let home = dirs::home_dir().ok_or_else(|| anyhow!("this machine has no home folder"))?;
    let mut outcomes = Vec::new();
    for key in &ids {
        let outcome = move_one(&src, key, &args, &home, &mut targets).await;
        if !json_out {
            print_outcome(&outcome, args.dry_run);
        }
        outcomes.push(outcome);
    }
    let failed = outcomes.iter().filter(|o| o.error.is_some()).count();
    if json_out {
        let rows: Vec<Value> = outcomes
            .iter()
            .map(|o| {
                json!({"sessionId": o.session, "name": o.name, "host": o.host, "cwd": o.cwd,
                       "moved": o.moved, "dryRun": args.dry_run, "error": o.error})
            })
            .collect();
        print_json(&json!({"moves": rows, "failed": failed}));
    }
    if failed > 0 {
        bail!("{failed} of {} chats did not move", outcomes.len());
    }
    Ok(())
}

fn print_outcome(o: &Outcome, dry_run: bool) {
    let host = o.host.as_deref().unwrap_or("?");
    let cwd = o.cwd.as_deref().unwrap_or("?");
    match &o.error {
        Some(e) => eprintln!("{} ({}): not moved: {e}", o.name, o.session),
        None if dry_run => println!("{} ({}): would move to {host} in {cwd}", o.name, o.session),
        None => println!("{} ({}): moved to {host} in {cwd}", o.name, o.session),
    }
}

/// Every chat here that is open and between turns: not closed, not running, not being moved.
async fn idle_chats(src: &Client) -> Result<Vec<String>> {
    let list = src.request(method::MUX_SESSIONS, json!({})).await?;
    let rows = list.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default();
    Ok(rows
        .iter()
        .filter(|s| s.get("peer").is_none_or(Value::is_null))
        .filter(|s| matches!(s["status"].as_str(), Some("idle" | "ready")))
        .filter(|s| s.get("turn").is_none_or(Value::is_null) && s["moving"] != true)
        .filter(|s| s.get("movedTo").is_none_or(Value::is_null))
        .filter_map(|s| s["sessionId"].as_str().map(str::to_owned))
        .collect())
}

async fn move_one(
    src: &Client,
    key: &str,
    args: &MoveArgs,
    home: &Path,
    targets: &mut Targets,
) -> Outcome {
    let mut o = Outcome {
        session: key.to_owned(),
        name: key.to_owned(),
        host: None,
        cwd: None,
        moved: false,
        error: None,
    };
    if let Err(e) = move_steps(src, key, args, home, targets, &mut o).await {
        o.error = Some(format!("{e:#}"));
    }
    o
}

async fn move_steps(
    src: &Client,
    key: &str,
    args: &MoveArgs,
    home: &Path,
    targets: &mut Targets,
    o: &mut Outcome,
) -> Result<()> {
    let id = resolve_id(src, key).await?;
    o.session = id.clone();
    let info = src.request(method::MUX_INFO, json!({"sessionId": id})).await?;
    o.name = info["name"].as_str().unwrap_or(&id).to_owned();
    if info.get("peer").is_some_and(|p| !p.is_null()) {
        bail!("it runs on {}, not here: move it from there", info["peer"]);
    }
    if let Some(why) = plan::refusal(&info, args.interrupt) {
        bail!("{why}");
    }
    let cwd = PathBuf::from(info["cwd"].as_str().unwrap_or_default());
    let cwd = cwd.canonicalize().map_err(|_| {
        anyhow!("its folder {} is gone here; there is nothing to carry", cwd.display())
    })?;
    let checkout = tokio::task::spawn_blocking({
        let cwd = cwd.clone();
        move || checkout_of(&cwd)
    })
    .await??;
    let home = home.canonicalize().unwrap_or_else(|_| home.to_path_buf());
    let group = checkout.as_ref().map(|c| c.top.clone()).unwrap_or_else(|| cwd.clone());
    let target = targets.pick(src, &group).await?;
    o.host = Some(target.name.clone());
    let remote = target.remote().await?;
    let folder = plan::plan_folder(&cwd, &home, checkout.as_ref(), &remote.home, args.leave_dirty)
        .map_err(|e| anyhow!(e))?;
    if args.dry_run {
        o.cwd = Some(match &folder {
            Folder::Plain { cwd } => cwd.clone(),
            Folder::Worktree { repo, branch, subdir, .. } => {
                format!("a worktree of {repo} {branch}{}", sub_text(subdir))
            }
        });
        return Ok(());
    }
    let mut record = json!({"host": target.name});
    if let (Folder::Worktree { branch, dirty, .. }, Some(c)) = (&folder, &checkout) {
        let commit = tokio::task::spawn_blocking({
            let (top, branch) = (c.top.clone(), branch.clone());
            move || push_branch(&top, &branch)
        })
        .await??;
        record["branch"] = json!(branch);
        record["commit"] = json!(commit);
        if *dirty {
            record["uncommittedLeftOn"] = json!(crate::pairing::machine_name());
        }
    }
    let there = tokio::task::spawn_blocking({
        let (host, folder) = (target.ssh.clone(), folder.clone());
        move || prepare_folder(&host, &folder)
    })
    .await??;
    o.cwd = Some(there.clone());
    record["cwd"] = json!(there);
    let forward = Forward::open(&target.ssh, &remote.socket).await?;
    let dst = Client::connect(&forward.local).await?;
    dst.request(
        method::INITIALIZE,
        json!({"protocolVersion": 1, "clientInfo": {"name": "acpmux-move"}}),
    )
    .await?;
    let moved =
        super::transfer::move_chat(src, &dst, &id, None, Some(there), None, args.interrupt, record)
            .await?;
    drop(forward);
    targets.placed(&target.name);
    o.moved = true;
    if let Some(name) = moved["name"].as_str() {
        o.name = name.to_owned();
    }
    Ok(())
}

fn sub_text(subdir: &str) -> String {
    if subdir.is_empty() { String::new() } else { format!(", in {subdir}") }
}

/// `git` in `dir`, its trimmed stdout; None when it failed.
fn git(dir: &Path, args: &[&str]) -> Option<String> {
    let out = StdCommand::new("git")
        .arg("-c")
        .arg("core.fsmonitor=false")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_owned())
}

/// The git checkout `cwd` is in, if any.
fn checkout_of(cwd: &Path) -> Result<Option<Checkout>> {
    let Some(top) = git(cwd, &["rev-parse", "--show-toplevel"]).filter(|t| !t.is_empty()) else {
        return Ok(None);
    };
    let top = PathBuf::from(top);
    let top = top.canonicalize().unwrap_or(top);
    let branch = git(&top, &["symbolic-ref", "-q", "--short", "HEAD"]).filter(|b| !b.is_empty());
    let origin = git(&top, &["remote", "get-url", "origin"]).filter(|u| !u.is_empty());
    let status = git(&top, &["status", "--porcelain", "--untracked-files=normal"])
        .ok_or_else(|| anyhow!("git status failed in {}", top.display()))?;
    Ok(Some(Checkout { top, branch, origin, dirty: !status.is_empty() }))
}

/// Pushes `branch` (HEAD of `top`) to `origin`, never forced: a branch that moved on there
/// refuses the move rather than losing either side. Returns the commit pushed.
fn push_branch(top: &Path, branch: &str) -> Result<String> {
    let head = git(top, &["rev-parse", "HEAD"]).ok_or_else(|| anyhow!("no HEAD commit"))?;
    let out = StdCommand::new("git")
        .arg("-C")
        .arg(top)
        .args(["push", "--quiet", "origin"])
        .arg(format!("HEAD:refs/heads/{branch}"))
        .output()
        .context("git push")?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        let last = err.lines().filter(|l| !l.trim().is_empty()).last().unwrap_or("").trim();
        bail!("pushing {branch} to origin failed (it may have moved on there): {last}");
    }
    Ok(head)
}

/// What the target says about itself: its home and its daemon's local socket.
struct RemoteDaemon {
    home: String,
    socket: String,
}

/// The fixed script that asks a target for [`RemoteDaemon`]: its home on the first line, then
/// `acpmux daemon status --json` on one line.
const ABOUT_SCRIPT: &str = r#"PATH="$HOME/.local/bin:$PATH"; printf '%s\n' "$HOME"; acpmux daemon status --json 2>/dev/null | tr -d '\n'; printf '\n'"#;

/// `ABOUT_SCRIPT`'s answer, checked: plain absolute paths only, since both reach ssh's argv.
fn parse_about(stdout: &str) -> Result<RemoteDaemon> {
    let mut lines = stdout.lines();
    let home = lines.next().unwrap_or_default().trim().to_owned();
    let status: Value = serde_json::from_str(lines.next().unwrap_or_default()).unwrap_or(Value::Null);
    // The daemon says where it listens: a socket path is never guessed (per-build state roots).
    let socket = status["socket"].as_str().unwrap_or_default().to_owned();
    let plain = |p: &str| p.starts_with('/') && crate::cli::hosts::plain_path(p);
    if !plain(&home) {
        bail!("the target's home is not a plain absolute path");
    }
    if !plain(&socket) {
        bail!("the target daemon's socket is not a plain absolute path (is acpmux running there?)");
    }
    Ok(RemoteDaemon { home, socket })
}

/// The fixed script that makes a chat's folder on the target and prints its real path. Its
/// values come on stdin, one per line, never in the script.
const PLAIN_SCRIPT: &str = r#"read -r d || exit 2; mkdir -p -- "$d" && cd -- "$d" && pwd -P"#;
const WORKTREE_SCRIPT: &str = r#"read -r repo; read -r branch; read -r url; read -r sub
PATH="$HOME/.local/bin:$PATH"
if command -v wt >/dev/null 2>&1; then
  out=$(wt new "$repo" "$branch") || exit 1
  dir=$(printf '%s\n' "$out" | tail -n 1)
else
  dir="$HOME/Projects/checkouts/${repo#*/}/$(printf '%s' "$branch" | tr / -)"
  if [ -e "$dir/.git" ]; then
    git -C "$dir" fetch -q origin "$branch" && git -C "$dir" checkout -q "$branch" && git -C "$dir" merge -q --ff-only FETCH_HEAD || exit 1
  else
    mkdir -p -- "$(dirname -- "$dir")" && git clone -q --branch "$branch" -- "$url" "$dir" || exit 1
  fi
fi
cd -- "$dir/$sub" && pwd -P"#;

/// Makes `folder` on the ssh host `host` and returns its path there.
fn prepare_folder(host: &str, folder: &Folder) -> Result<String> {
    let (script, input) = match folder {
        Folder::Plain { cwd } => (PLAIN_SCRIPT, format!("{cwd}\n")),
        Folder::Worktree { repo, url, branch, subdir, .. } => {
            (WORKTREE_SCRIPT, format!("{repo}\n{branch}\n{url}\n{subdir}\n"))
        }
    };
    let out = crate::cli::hosts::Remote::exec(
        &crate::cli::hosts::SshRemote(host),
        script,
        Some(input.as_bytes()),
    )?;
    if !out.ok {
        let last = out.stderr.lines().filter(|l| !l.trim().is_empty()).last().unwrap_or("");
        bail!("making the folder on {host} failed: {}", last.trim());
    }
    let path = out.stdout.lines().last().unwrap_or_default().trim().to_owned();
    if !(path.starts_with('/') && crate::cli::hosts::plain_path(&path)) {
        bail!("{host} answered no plain folder path for the chat");
    }
    Ok(path)
}

/// An `ssh -L` forward of a target daemon's local socket to a private socket here, so the
/// move talks to that daemon as its own local client does. Ends (ssh killed) when dropped.
struct Forward {
    local: PathBuf,
    dir: PathBuf,
    _ssh: tokio::process::Child,
}

impl Forward {
    async fn open(host: &str, remote_socket: &str) -> Result<Self> {
        let host = crate::cli::hosts::checked_host(host)?;
        // A short private folder: a Unix socket path has about 100 bytes, and TMPDIR is long.
        let dir = PathBuf::from(format!(
            "/tmp/acpmux-move-{}-{}",
            std::process::id(),
            uuid::Uuid::now_v7().simple()
        ));
        std::fs::create_dir(&dir)?;
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))?;
        }
        let local = dir.join("d.sock");
        let mut ssh = tokio::process::Command::new("ssh")
            .args(forward_argv(host, &local, remote_socket))
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .context("spawn ssh")?;
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(30);
        while !local.exists() {
            if let Some(status) = ssh.try_wait()? {
                let _ = std::fs::remove_dir_all(&dir);
                bail!("ssh to {host} ended ({status}) before forwarding the daemon's socket");
            }
            if tokio::time::Instant::now() > deadline {
                let _ = std::fs::remove_dir_all(&dir);
                bail!("ssh to {host} did not forward the daemon's socket within 30s");
            }
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
        Ok(Self { local, dir, _ssh: ssh })
    }
}

impl Drop for Forward {
    fn drop(&mut self) {
        let _ = self._ssh.start_kill();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// `ssh -N -L LOCAL:REMOTE -- HOST`, failing at once when the forward cannot be made.
pub(crate) fn forward_argv(host: &str, local: &Path, remote: &str) -> Vec<String> {
    let mut argv: Vec<String> = [
        "-N",
        "-o",
        "BatchMode=yes",
        "-o",
        "ExitOnForwardFailure=yes",
        "-o",
        "StreamLocalBindUnlink=yes",
        "-o",
        "ServerAliveInterval=15",
        "-o",
        "ConnectTimeout=20",
        "-L",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    argv.push(format!("{}:{remote}", local.display()));
    argv.push("--".into());
    argv.push(host.to_owned());
    argv
}

/// A chosen target: its peer name and ssh destination.
#[derive(Clone)]
struct Target {
    name: String,
    ssh: String,
}

impl Target {
    async fn remote(&self) -> Result<RemoteDaemon> {
        let ssh = self.ssh.clone();
        let out = tokio::task::spawn_blocking(move || {
            crate::cli::hosts::Remote::exec(&crate::cli::hosts::SshRemote(&ssh), ABOUT_SCRIPT, None)
        })
        .await??;
        if !out.ok {
            bail!("ssh to {} failed: {}", self.ssh, out.stderr.trim());
        }
        parse_about(&out.stdout)
    }
}

/// Where chats go: the one peer named, or (`auto`) the placement's pick among the peers, one
/// host per checkout, spread by the chats this run placed.
struct Targets {
    named: Option<String>,
    peers: Vec<(String, String)>,
    by_group: HashMap<PathBuf, Target>,
    placed: HashMap<String, f64>,
}

impl Targets {
    fn new(host: &str, peers: &Value) -> Result<Self> {
        let peers: Vec<(String, String)> = peers
            .get("peers")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|p| {
                let name = p.get("name").and_then(Value::as_str)?;
                let url = p.get("url").and_then(Value::as_str)?;
                let t = crate::peer::ssh_target(url).ok()?;
                // The daemon's own socket is reached as the ssh login, not another user.
                Some((name.to_owned(), t.destination))
            })
            .collect();
        let named = (host != "auto").then(|| host.to_owned());
        if let Some(n) = &named
            && !peers.iter().any(|(p, _)| p.eq_ignore_ascii_case(n))
        {
            bail!("{n} is not an ssh peer of this daemon (`acpmux host ls`)");
        }
        Ok(Self { named, peers, by_group: HashMap::new(), placed: HashMap::new() })
    }

    fn target(&self, name: &str) -> Option<Target> {
        self.peers
            .iter()
            .find(|(p, _)| p.eq_ignore_ascii_case(name))
            .map(|(p, ssh)| Target { name: p.clone(), ssh: ssh.clone() })
    }

    /// The target for a chat in `group` (its checkout, or its folder).
    async fn pick(&mut self, src: &Client, group: &Path) -> Result<Target> {
        if let Some(t) = self.by_group.get(group) {
            return Ok(t.clone());
        }
        let verdict = src.request("_acpmux/place", json!({"work": "agent"})).await?;
        let hosts = verdict["hosts"].as_array().cloned().unwrap_or_default();
        let held = |name: &str| -> Option<String> {
            let row = hosts.iter().find(|h| h["name"].as_str() == Some(name));
            if let Some(why) = row.and_then(|h| h["reserved"].as_str()) {
                return Some(why.to_owned());
            }
            let holds = crate::cli::hosts::host_hold::Holds::read(&crate::cli::hosts::host_hold::holds_path());
            match holds {
                Ok(h) => h.why(name, name, crate::cli::hosts::host_hold::now_ms()),
                Err(e) => Some(format!("its holds cannot be read ({e:#})")),
            }
        };
        let target = match &self.named {
            Some(n) => {
                let t = self.target(n).ok_or_else(|| anyhow!("{n} is not an ssh peer"))?;
                if let Some(why) = held(&t.name) {
                    bail!("{} is not a target now: {why}", t.name);
                }
                t
            }
            None => {
                let pick = choose(&hosts, &self.placed, |n| {
                    self.target(n).is_some() && held(n).is_none()
                })
                .ok_or_else(|| anyhow!("no peer has room for a moved chat (`acpmux host place`)"))?;
                self.target(&pick).ok_or_else(|| anyhow!("{pick} is not an ssh peer"))?
            }
        };
        self.by_group.insert(group.to_path_buf(), target.clone());
        Ok(target)
    }

    fn placed(&mut self, name: &str) {
        *self.placed.entry(name.to_owned()).or_default() += 1.0;
    }
}

/// The host with the most room left, less the chats this run put there: hosts that take the
/// work first (`ok`), else those passed over only for load (`load`, as `place` does: load caps
/// only warn). Never this machine, never one `usable` refuses.
pub(crate) fn choose(
    hosts: &[Value],
    placed: &HashMap<String, f64>,
    usable: impl Fn(&str) -> bool,
) -> Option<String> {
    let name = |h: &Value| h["name"].as_str().unwrap_or_default().to_owned();
    let mine = |h: &Value| placed.get(&name(h)).copied().unwrap_or(0.0);
    let room = |h: &Value| h["room"].as_f64().unwrap_or(-1.0) - mine(h);
    // Fewer agents (live there, plus this run's) breaks a tie in room.
    let busy = |h: &Value| h["live"].as_f64().unwrap_or(f64::MAX) + mine(h);
    let mut usable_hosts: Vec<&Value> = hosts
        .iter()
        .filter(|h| h["local"] != true)
        .filter(|h| h["ok"] == true || h["load"] == true)
        .filter(|h| h["name"].as_str().is_some_and(&usable))
        .collect();
    usable_hosts.sort_by(|a, b| {
        let fits = |h: &Value| h["ok"] == true && room(h) >= 1.0;
        fits(b).cmp(&fits(a)).then(room(b).total_cmp(&room(a))).then(busy(a).total_cmp(&busy(b)))
    });
    usable_hosts.first().map(|h| name(h))
}

#[cfg(test)]
#[path = "session_move_tests.rs"]
mod tests;
