//! `acpmux session move SESSION... --host PEER|auto [--interrupt] [--leave-dirty] [--dry-run]`
//! (or `--all-idle` for every idle chat here): moves chats from this machine's daemon to an ssh
//! peer's, with their history, queue and draft, and their folder made there.
//!
//! For each chat, in order, stopping at the first step that fails (nothing after it is done):
//!
//! 1. Refused while its turn runs (unless `--interrupt`), while it is being moved, once it moved
//!    away, or when its folder is gone here (`session_move_plan.rs` `refusal`).
//! 2. The target: the peer named, or with `auto` the daemon's placement (`_acpmux/place`) among
//!    the peers, never this machine and never one the registry marks interactive (a machine a
//!    person works at, `placement::interactive`). A host the fleet registry holds (its `hold`, or
//!    a `reservations` entry: `placement::held`) is never a target. With `auto`, each host in
//!    the placement's order is asked over a fresh ssh, best first (`walk`): one that does not
//!    answer (a pool slot with no VM behind a link the daemon still calls connected) is passed
//!    over, and so is one whose free disk, less what the move writes, is under its registry
//!    floor (`placement::disk_floor`), unless every host that answers is: then the one with
//!    the most free takes it with a warning. Each host passed over is printed with why. Chats
//!    in one checkout go to one host.
//! 3. The chat is frozen here (`transfer_begin`), so nothing changes its folder or history
//!    while the rest is made; any step below that fails gives it back (`transfer_abort`).
//! 4. The folder (`plan_folder`, planned again now that the chat is frozen): a checkout's branch
//!    is pushed to `origin` (never forced) and becomes a fresh worktree of that branch on the
//!    target (`wt new` there when it has `wt`, else a fresh clone of its own under
//!    `~/Projects/checkouts`), the chat's subfolder checked out in it; any other folder under the
//!    home is made at the same path under the target's home; `--cwd` names it outright.
//! 5. The rest of the move is `session transfer`'s (`transfer.rs`, `hub/transfer_out.rs`), with
//!    the target daemon's own local socket reached through an `ssh -L` forward
//!    (`ssh_forward.rs`): the bundle is paged across, imported there in its new folder, then
//!    committed here. The source's watch knows the target by its ssh host and socket, so a move
//!    whose client goes away is still ended by asking the target. The
//!    commit records where it went (`movedTo {host, sessionId, cwd, branch, commit}`), and a
//!    moved chat never runs here again (`hub/lifecycle.rs`), so there is one writer. `resolve`
//!    and agent links follow it (`hub/locate.rs`).

use super::*;
use crate::cli::session_move_plan::{self as plan, Checkout, Folder};
use crate::ssh_forward::Forward;
#[cfg(test)]
use crate::ssh_forward::forward_argv;
use anyhow::{Context as _, bail};
use cmux_json::JsonSet as _;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command as StdCommand;

pub(crate) struct MoveArgs {
    pub sessions: Vec<String>,
    pub host: String,
    pub all_idle: bool,
    pub interrupt: bool,
    pub leave_dirty: bool,
    pub cwd: Option<String>,
    pub dry_run: bool,
    /// `session resume`'s move: once moved, the held queue runs on the target, asked over the
    /// move's own connection (the route `HOST/ID` through this daemon may not know it yet).
    pub resume_there: bool,
}

/// One chat's outcome, as printed and in `--json`.
struct Outcome {
    session: String,
    name: String,
    host: Option<String>,
    cwd: Option<String>,
    moved: bool,
    /// The chat's id on the target, once moved.
    there: Option<String>,
    /// With `resume_there`: whether a held queue ran there, or why it did not (the chat moved).
    resumed: Result<bool, String>,
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

/// Where `session resume` moved a stopped chat (`move_off_interactive`): the peer, the chat's
/// id there routed through it (`HOST/ID`), and whether a held queue ran there (`Err`: why not;
/// the chat moved all the same).
pub(crate) struct MovedOff {
    pub host: String,
    pub routed: String,
    pub resumed: Result<bool, String>,
}

/// `session resume`'s move of the stopped chat `id` off this machine, one a person works at: the
/// same steps and pick as `session move ID --host auto`. `Err`: it did not move, and why (no peer
/// has room, a refusal, a failed step given back); the chat is here as it was.
pub(crate) async fn move_off_interactive(src: &Client, id: &str) -> Result<MovedOff> {
    let args = MoveArgs {
        sessions: vec![id.to_owned()],
        host: "auto".into(),
        all_idle: false,
        interrupt: false,
        leave_dirty: false,
        cwd: None,
        dry_run: false,
        resume_there: true,
    };
    let peers = src.request("_acpmux/peers", json!({})).await?;
    let mut targets = Targets::new(&args.host, &peers)?;
    let home = dirs::home_dir().ok_or_else(|| anyhow!("this machine has no home folder"))?;
    let o = move_one(src, id, &args, &home, &mut targets).await;
    if let Some(e) = o.error {
        bail!("{e}");
    }
    let (Some(host), Some(there)) = (o.host, o.there) else {
        bail!("the move gave no host and id for the chat there");
    };
    Ok(MovedOff { routed: format!("{host}/{there}"), host, resumed: o.resumed })
}

/// Every chat here that is open and between turns: not closed, not running, not being moved.
async fn idle_chats(src: &Client) -> Result<Vec<String>> {
    let list = src.whole_list(method::MUX_SESSIONS, json!({})).await?;
    let rows = list.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default();
    Ok(rows
        .iter()
        .filter(|s| s.get("peer").is_none_or(Value::is_null))
        .filter(|s| matches!(s.get("status").and_then(Value::as_str), Some("idle" | "ready")))
        .filter(|s| {
            s.get("turn").is_none_or(Value::is_null)
                && s.get("moving").and_then(Value::as_bool) != Some(true)
        })
        .filter(|s| s.get("movedTo").is_none_or(Value::is_null))
        .filter_map(|s| s.get("sessionId").and_then(Value::as_str).map(str::to_owned))
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
        there: None,
        resumed: Ok(false),
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
    o.name = info.get("name").and_then(Value::as_str).unwrap_or(&id).to_owned();
    if info.get("peer").is_some_and(|p| !p.is_null()) {
        bail!(
            "it runs on {}, not here: move it from there",
            info.get("peer").unwrap_or(&Value::Null)
        );
    }
    if let Some(why) = plan::refusal(&info, args.interrupt) {
        bail!("{why}");
    }
    let cwd = PathBuf::from(info.get("cwd").and_then(Value::as_str).unwrap_or_default());
    // With --cwd nothing of the folder here is carried, so it need not exist any more.
    let cwd = if args.cwd.is_some() {
        cwd
    } else {
        cwd.canonicalize().map_err(|_| {
            anyhow!("its folder {} is gone here; there is nothing to carry", cwd.display())
        })?
    };
    let checkout = checkout_unless_named(&cwd, args).await?;
    let home = home.canonicalize().unwrap_or_else(|_| home.to_path_buf());
    let group = checkout.as_ref().map(|c| c.top.clone()).unwrap_or_else(|| cwd.clone());
    // What the move writes on the target: a fresh checkout of the branch (its tracked tree at
    // HEAD); a plain folder is made empty there.
    let need = match &checkout {
        Some(c) => tokio::task::spawn_blocking({
            let top = c.top.clone();
            move || tree_bytes(&top)
        })
        .await?
        .unwrap_or(0),
        None => 0,
    };
    let target = targets.pick(src, &group, need).await?;
    o.host = Some(target.name.clone());
    let remote = match target.probed.clone() {
        Some(r) => r,
        None => target.remote().await?,
    };
    let target_cwd = args.cwd.as_deref();
    let planned = plan::plan_folder(
        &cwd,
        &home,
        checkout.as_ref(),
        &remote.home,
        args.leave_dirty,
        target_cwd,
    )
    .map_err(|e| anyhow!(e))?;
    if args.dry_run {
        o.cwd = Some(match &planned {
            Folder::Plain { cwd } => cwd.clone(),
            Folder::Worktree { repo, branch, subdir, .. } => {
                format!("a worktree of {repo} {branch}{}", sub_text(subdir))
            }
        });
        return Ok(());
    }
    // Frozen from here: no prompt, turn or agent write changes the chat while its folder is
    // made, and every failure below gives it back.
    // The peer's name too: a move the watch ends records where it went, for `resolve`.
    let watch = json!({"socket": remote.socket, "ssh": target.ssh, "host": target.name});
    let begun = super::transfer::begin_move(src, &id, Some(watch), args.interrupt).await?;
    let prepared = prepare(&cwd, &home, &target, &remote, args, o).await;
    let (record, forward, dst, dst_init) = match prepared {
        Ok(p) => p,
        Err(e) => {
            super::transfer::abort_move(src, &id, &begun).await;
            return Err(e);
        }
    };
    let there = record.get("cwd").and_then(Value::as_str).map(str::to_owned);
    let moved =
        super::transfer::finish_move(src, &dst, &dst_init, &id, &begun, there, None, record)
            .await?;
    targets.placed(&target.name);
    o.moved = true;
    o.there = moved.get("sessionId").and_then(Value::as_str).map(str::to_owned);
    if args.resume_there
        && let Some(there) = o.there.clone()
    {
        // Moved whatever this says: a failed resume leaves the chat there with its queue held.
        let resumed = match dst.request(method::MUX_INFO, json!({"sessionId": there})).await {
            Ok(info) => super::extra::resume_held(&dst, &there, &info).await,
            Err(e) => Err(e),
        };
        o.resumed = resumed.map_err(|e| format!("{e:#}"));
    }
    drop(forward);
    if let Some(name) = moved.get("name").and_then(Value::as_str) {
        o.name = name.to_owned();
    }
    Ok(())
}

/// The frozen chat's folder made on the target, and a client of the target's daemon: the
/// checkout read again (it may have changed before the freeze), its branch pushed, the folder
/// made there. Returns the move's record (`movedTo`), the forward, the client, and the
/// receiving daemon's own `initialize` reply on it (`transfer::receiver_takes`).
async fn prepare(
    cwd: &Path,
    home: &Path,
    target: &Target,
    remote: &RemoteDaemon,
    args: &MoveArgs,
    o: &mut Outcome,
) -> Result<(Value, Forward, std::sync::Arc<Client>, Value)> {
    let checkout = checkout_unless_named(cwd, args).await?;
    let folder = plan::plan_folder(
        cwd,
        home,
        checkout.as_ref(),
        &remote.home,
        args.leave_dirty,
        args.cwd.as_deref(),
    )
    .map_err(|e| anyhow!(e))?;
    let mut record = json!({"host": target.name});
    if let (Folder::Worktree { branch, dirty, .. }, Some(c)) = (&folder, &checkout) {
        let commit = tokio::task::spawn_blocking({
            let (top, branch) = (c.top.clone(), branch.clone());
            move || push_branch(&top, &branch)
        })
        .await??;
        record.set("branch", json!(branch));
        record.set("commit", json!(commit));
        if *dirty {
            record.set("uncommittedLeftOn", json!(crate::pairing::machine_name()));
        }
    }
    let there = tokio::task::spawn_blocking({
        let (host, folder) = (target.ssh.clone(), folder.clone());
        move || prepare_folder(&host, &folder)
    })
    .await??;
    o.cwd = Some(there.clone());
    record.set("cwd", json!(there));
    let forward = Forward::open(&target.ssh, &remote.socket).await?;
    let dst = Client::connect(&forward.local).await?;
    let dst_init = dst
        .request(
            method::INITIALIZE,
            json!({"protocolVersion": 1, "clientInfo": {"name": "acpmux-move"}}),
        )
        .await?;
    Ok((record, forward, dst, dst_init))
}

/// The checkout `cwd` is in, unless `--cwd` names the folder there (no checkout is carried).
async fn checkout_unless_named(cwd: &Path, args: &MoveArgs) -> Result<Option<Checkout>> {
    if args.cwd.is_some() {
        return Ok(None);
    }
    let cwd = cwd.to_path_buf();
    tokio::task::spawn_blocking(move || checkout_of(&cwd)).await?
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
        let last = err.lines().rfind(|l| !l.trim().is_empty()).unwrap_or("").trim();
        bail!("pushing {branch} to origin failed (it may have moved on there): {last}");
    }
    Ok(head)
}

/// What the target says about itself: its home, its daemon's local socket, and the disk free
/// under its home (`None`: it did not say).
#[derive(Clone, Debug)]
struct RemoteDaemon {
    home: String,
    socket: String,
    disk_free: Option<u64>,
}

/// The fixed script that asks a target for [`RemoteDaemon`]: its home on the first line, then
/// `acpmux daemon status --json` on one line, then the KiB free under its home (`df -Pk`).
const ABOUT_SCRIPT: &str = r#"PATH="$HOME/.local/bin:$PATH"; printf '%s\n' "$HOME"; acpmux daemon status --json 2>/dev/null | tr -d '\n'; printf '\n'; df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print $4}'"#;

/// `ABOUT_SCRIPT`'s answer, checked: plain absolute paths only, since both reach ssh's argv.
fn parse_about(stdout: &str) -> Result<RemoteDaemon> {
    let mut lines = stdout.lines();
    let home = lines.next().unwrap_or_default().trim().to_owned();
    let status: Value =
        serde_json::from_str(lines.next().unwrap_or_default()).unwrap_or(Value::Null);
    // The daemon says where it listens: a socket path is never guessed (per-build state roots).
    let socket = status.get("socket").and_then(Value::as_str).unwrap_or_default().to_owned();
    let plain = |p: &str| p.starts_with('/') && crate::cli::hosts::plain_path(p);
    if !plain(&home) {
        bail!("the target's home is not a plain absolute path");
    }
    if !plain(&socket) {
        bail!("the target daemon's socket is not a plain absolute path (is acpmux running there?)");
    }
    let disk_free =
        lines.next().and_then(|l| l.trim().parse::<u64>().ok()).map(|kib| kib.saturating_mul(1024));
    Ok(RemoteDaemon { home, socket, disk_free })
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
  # A fresh clone of its own, never one another chat or lane may be writing in.
  base="$HOME/Projects/checkouts/$(printf '%s' "$repo" | tr / -)"
  mkdir -p -- "$base" || exit 1
  dir=$(mktemp -d "$base/$(printf '%s' "$branch" | tr / -).XXXXXX") || exit 1
  git clone -q --branch "$branch" -- "$url" "$dir" || exit 1
fi
# A sparse checkout may leave the chat's subfolder out: check it out too.
if [ -n "$sub" ] && [ ! -d "$dir/$sub" ]; then
  git -C "$dir" sparse-checkout add -- "$sub" >/dev/null 2>&1 || true
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
        let last = out.stderr.lines().rfind(|l| !l.trim().is_empty()).unwrap_or("");
        bail!("making the folder on {host} failed: {}", last.trim());
    }
    let path = out.stdout.lines().last().unwrap_or_default().trim().to_owned();
    if !(path.starts_with('/') && crate::cli::hosts::plain_path(&path)) {
        bail!("{host} answered no plain folder path for the chat");
    }
    Ok(path)
}

/// A chosen target: its peer name and ssh destination, and its answer to `ABOUT_SCRIPT` when the
/// pick already asked (`auto` asks each host it tries).
#[derive(Clone)]
struct Target {
    name: String,
    ssh: String,
    probed: Option<RemoteDaemon>,
}

impl Target {
    async fn remote(&self) -> Result<RemoteDaemon> {
        let ssh = self.ssh.clone();
        tokio::task::spawn_blocking(move || about(&ssh)).await?
    }
}

/// Asks the ssh host `ssh` for [`RemoteDaemon`] over a fresh ssh, the way the move reaches it.
fn about(ssh: &str) -> Result<RemoteDaemon> {
    let out =
        crate::cli::hosts::Remote::exec(&crate::cli::hosts::SshRemote(ssh), ABOUT_SCRIPT, None)?;
    if !out.ok {
        let why = out.stderr.lines().filter(|l| !l.trim().is_empty()).collect::<Vec<_>>();
        bail!("ssh to {ssh} failed: {}", why.join("; ").trim());
    }
    parse_about(&out.stdout)
}

/// Where chats go: the one peer named, or (`auto`) the placement's pick among the peers, one
/// host per checkout, spread by the chats this run placed.
struct Targets {
    named: Option<String>,
    peers: Vec<(String, String)>,
    by_group: HashMap<PathBuf, Target>,
    placed: HashMap<String, f64>,
    /// Hosts `auto` found it could not reach in this run, and why: not asked again.
    unreachable: HashMap<String, String>,
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
        Ok(Self {
            named,
            peers,
            by_group: HashMap::new(),
            placed: HashMap::new(),
            unreachable: HashMap::new(),
        })
    }

    fn target(&self, name: &str) -> Option<Target> {
        self.peers.iter().find(|(p, _)| p.eq_ignore_ascii_case(name)).map(|(p, ssh)| Target {
            name: p.clone(),
            ssh: ssh.clone(),
            probed: None,
        })
    }

    /// The target for a chat in `group` (its checkout, or its folder), whose move writes about
    /// `need` bytes there.
    async fn pick(&mut self, src: &Client, group: &Path, need: u64) -> Result<Target> {
        if let Some(t) = self.by_group.get(group) {
            return Ok(t.clone());
        }
        // A machine a person works at is never a target: moving there is what a move off one
        // avoids (`server/place.rs`). A named one is the caller's choice.
        let verdict =
            src.request("_acpmux/place", json!({"work": "agent", "offInteractive": true})).await?;
        let hosts = verdict.get("hosts").and_then(Value::as_array).cloned().unwrap_or_default();
        // The registry's one reader of holds and reservations (`placement::held`); placement
        // already refuses such a host, and a named one is checked the same way.
        let registry = crate::placement::load_registry();
        let held = |name: &str| crate::placement::held(registry.as_ref(), name);
        let target = match &self.named {
            Some(n) => {
                let t = self.target(n).ok_or_else(|| anyhow!("{n} is not an ssh peer"))?;
                if let Some(why) = held(&t.name) {
                    bail!("{} is not a target now: {why}", t.name);
                }
                t
            }
            None => {
                let (order, mut skipped) = ranked(&hosts, &self.placed, |n| {
                    if self.target(n).is_none() {
                        return Some("not an ssh peer of this daemon".to_owned());
                    }
                    held(n)
                });
                let tries: Vec<Target> = order.iter().filter_map(|n| self.target(n)).collect();
                let floors: HashMap<String, u64> = tries
                    .iter()
                    .map(|t| {
                        (t.name.clone(), crate::placement::disk_floor(registry.as_ref(), &t.name))
                    })
                    .collect();
                let known = self.unreachable.clone();
                let walked = tokio::task::spawn_blocking(move || {
                    walk(
                        &tries,
                        need,
                        |n| floors.get(n).copied().unwrap_or(0),
                        |t| match known.get(&t.name) {
                            Some(why) => Err(why.clone()),
                            None => about(&t.ssh).map_err(|e| format!("{e:#}")),
                        },
                    )
                })
                .await?;
                skipped.extend(walked.skipped.iter().cloned());
                for (name, why) in &walked.unreachable {
                    self.unreachable.insert(name.clone(), why.clone());
                }
                for (name, why) in &skipped {
                    eprintln!("auto: passed over {name}: {why}");
                }
                if let Some(warning) = &walked.warning {
                    eprintln!("auto: {warning}");
                }
                walked.pick.ok_or_else(|| {
                    anyhow!(
                        "no peer can take a moved chat: {} (`acpmux host place`)",
                        if skipped.is_empty() {
                            "none has room".to_owned()
                        } else {
                            skipped
                                .iter()
                                .map(|(n, w)| format!("{n}: {w}"))
                                .collect::<Vec<_>>()
                                .join("; ")
                        }
                    )
                })?
            }
        };
        self.by_group.insert(group.to_path_buf(), target.clone());
        Ok(target)
    }

    fn placed(&mut self, name: &str) {
        *self.placed.entry(name.to_owned()).or_default() += 1.0;
    }
}

/// What [`walk`] found: the target (with its answer), the hosts it passed over and why, the
/// unreachable ones among them, and a warning when the pick is short of disk.
#[derive(Default)]
struct Walked {
    pick: Option<Target>,
    skipped: Vec<(String, String)>,
    unreachable: Vec<(String, String)>,
    warning: Option<String>,
}

const GB: f64 = 1e9;

/// Tries `order` (best first) until a host answers over a fresh ssh (`probe`) with room on its
/// disk for this move: its free bytes, less `need`, at or over its floor (`floor`, bytes). A
/// host that does not answer is passed over: a peer link the daemon still calls connected says
/// nothing about a new ssh (a pool slot with no VM behind it fails there). One short of disk is
/// passed over too, but when every host that answers is short, the one with the most free takes
/// the move with a warning: disk floors only warn. A host that answers no disk reading is
/// taken.
fn walk(
    order: &[Target],
    need: u64,
    floor: impl Fn(&str) -> u64,
    mut probe: impl FnMut(&Target) -> Result<RemoteDaemon, String>,
) -> Walked {
    let mut w = Walked::default();
    let mut short: Vec<(Target, u64)> = Vec::new();
    for t in order {
        let remote = match probe(t) {
            Ok(r) => r,
            Err(why) => {
                let why = format!("unreachable from here ({why})");
                w.skipped.push((t.name.clone(), why.clone()));
                w.unreachable.push((t.name.clone(), why));
                continue;
            }
        };
        let floor = floor(&t.name);
        match remote.disk_free {
            Some(free) if free.saturating_sub(need) < floor => {
                w.skipped.push((
                    t.name.clone(),
                    format!(
                        "{:.1} GB disk free, under its {:.0} GB floor plus this move's {:.1} GB",
                        free as f64 / GB,
                        floor as f64 / GB,
                        need as f64 / GB
                    ),
                ));
                short.push((Target { probed: Some(remote), ..t.clone() }, free));
            }
            _ => {
                w.pick = Some(Target { probed: Some(remote), ..t.clone() });
                return w;
            }
        }
    }
    if let Some((t, free)) = short.into_iter().max_by_key(|(_, free)| *free) {
        w.warning = Some(format!(
            "every host that answers is short of disk for this move; {} takes it anyway \
             ({:.1} GB free): disk floors only warn",
            t.name,
            free as f64 / GB
        ));
        w.pick = Some(t);
    }
    w
}

/// The hosts that may take the move, best first, and every other host with why it was passed
/// over: hosts that take the work first (`ok`), else those passed over only for load (`load`,
/// as `place` does: load caps only warn), by most room left, less the chats this run put there,
/// then fewer agents. Never this machine, never one placement refuses for its role or
/// `unusable` names a reason for.
pub(crate) fn ranked(
    hosts: &[Value],
    placed: &HashMap<String, f64>,
    unusable: impl Fn(&str) -> Option<String>,
) -> (Vec<String>, Vec<(String, String)>) {
    let name = |h: &Value| h.get("name").and_then(Value::as_str).unwrap_or_default().to_owned();
    let mine = |h: &Value| placed.get(&name(h)).copied().unwrap_or(0.0);
    let room = |h: &Value| h.get("room").and_then(Value::as_f64).unwrap_or(-1.0) - mine(h);
    // Fewer agents (live there, plus this run's) breaks a tie in room.
    let busy = |h: &Value| h.get("live").and_then(Value::as_f64).unwrap_or(f64::MAX) + mine(h);
    let mut usable_hosts: Vec<&Value> = Vec::new();
    let mut skipped = Vec::new();
    for h in hosts {
        if h.get("local").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        let ok = h.get("ok").and_then(Value::as_bool) == Some(true);
        let load = h.get("load").and_then(Value::as_bool) == Some(true);
        if !ok && !load {
            let why = h.get("refused").and_then(Value::as_str).unwrap_or("refused by placement");
            skipped.push((name(h), why.to_owned()));
            continue;
        }
        if let Some(why) = unusable(&name(h)) {
            skipped.push((name(h), why));
            continue;
        }
        usable_hosts.push(h);
    }
    usable_hosts.sort_by(|a, b| {
        let fits = |h: &Value| h.get("ok").and_then(Value::as_bool) == Some(true) && room(h) >= 1.0;
        fits(b).cmp(&fits(a)).then(room(b).total_cmp(&room(a))).then(busy(a).total_cmp(&busy(b)))
    });
    (usable_hosts.iter().map(|h| name(h)).collect(), skipped)
}

/// The first of [`ranked`]: the host with the most room left.
#[cfg(test)]
pub(crate) fn choose(
    hosts: &[Value],
    placed: &HashMap<String, f64>,
    usable: impl Fn(&str) -> bool,
) -> Option<String> {
    let (order, _) = ranked(hosts, placed, |n| (!usable(n)).then(|| "unusable".to_owned()));
    order.into_iter().next()
}

/// The bytes of `top`'s tracked tree at HEAD: what a fresh checkout of its branch writes.
/// `None` when git cannot say.
fn tree_bytes(top: &Path) -> Option<u64> {
    let out = StdCommand::new("git")
        .arg("-C")
        .arg(top)
        .args(["ls-tree", "-r", "-l", "-z", "HEAD"])
        .output()
        .ok()?;
    out.status.success().then(|| sum_tree_sizes(&out.stdout))
}

/// The sizes in `git ls-tree -r -l -z` output (`MODE TYPE OID SIZE\tPATH` records); a
/// submodule's `-` counts nothing.
fn sum_tree_sizes(listing: &[u8]) -> u64 {
    listing
        .split(|b| *b == 0)
        .filter_map(|rec| {
            let head = rec.split(|b| *b == b'\t').next()?;
            let size = std::str::from_utf8(head).ok()?.split_whitespace().nth(3)?;
            size.parse::<u64>().ok()
        })
        .sum()
}

#[cfg(test)]
#[path = "session_move_tests.rs"]
mod tests;
