//! `acpmux session move SESSION... --host PEER|auto [--after-turn|--interrupt] [--leave-dirty]
//! [--dry-run]`
//! (or `--all-idle` for every idle chat here): moves chats from this machine's daemon to an ssh
//! peer's, with their history, queue and draft, and their folder made there.
//!
//! For each chat, in order, stopping at the first step that fails (nothing after it is done):
//!
//! 1. Refused while it is being moved, once it moved away, or when its folder is gone here
//!    (`session_move_plan.rs` `refusal`). A running turn moves with it: step 3 waits for its
//!    tool calls in flight to end and stops it there, and it goes on on the target
//!    (`transfer.rs` `begin_move_live`); `--after-turn` waits for the turn to end instead,
//!    `--interrupt` stops it at once. A dry run names a running turn (`running_turn`), so its
//!    caller can offer those choices.
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
//!    home is made at the same path under the target's home; `--cwd` names it outright. With
//!    `--carry-changes` the checkout's uncommitted work is read once the branch is pushed and
//!    applied in the new worktree (`session_move_carry.rs`).
//! 5. The rest of the move is `session transfer`'s (`transfer.rs`, `hub/transfer_out.rs`), with
//!    the target daemon's own local socket reached through an `ssh -L` forward
//!    (`ssh_forward.rs`): the bundle is paged across, imported there in its new folder, then
//!    committed here. The source's watch knows the target by its ssh host and socket, so a move
//!    whose client goes away is still ended by asking the target. The
//!    commit records where it went (`movedTo {host, sessionId, cwd, branch, commit}`), and a
//!    moved chat never runs here again (`hub/lifecycle.rs`), so there is one writer. `resolve`
//!    and agent links follow it (`hub/locate.rs`).

use super::*;
use crate::cli::session_move_carry::{self as carry, Carry};
use crate::cli::session_move_plan::{self as plan, Checkout, Folder};
use crate::placement::move_targets::ranked;
use crate::ssh_forward::Forward;
#[cfg(test)]
use crate::ssh_forward::forward_argv;
use anyhow::{Context as _, bail};
use cmux_json::JsonSet as _;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command as StdCommand;

#[path = "session_move_preflight.rs"]
mod preflight;
#[path = "session_move_snapshot.rs"]
pub(crate) mod snapshot;
#[path = "session_move_target_ask.rs"]
mod target_ask;

/// `--timeout`'s default: the longest an `--after-turn` move waits for the running turn.
pub(crate) const DEFAULT_TURN_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(600);

/// How often a move that waits on something says what (`waiting`).
const PROGRESS_EVERY: std::time::Duration = std::time::Duration::from_secs(5);

/// `fut`, with a line on stderr every [`PROGRESS_EVERY`] while it runs naming the chat and the
/// step it waits on: no step of a move is silent for longer (a `--cwd --after-turn` move once
/// sat 12 minutes with no output).
async fn waiting<T>(chat: &str, step: &str, fut: impl std::future::Future<Output = T>) -> T {
    progress_every(PROGRESS_EVERY, fut, |secs| eprintln!("{}", progress_line(chat, step, secs)))
        .await
}

/// `move: CHAT: STEP (Ns so far)`.
fn progress_line(chat: &str, step: &str, secs: u64) -> String {
    format!("move: {chat}: {step} ({secs}s so far)")
}

/// Runs `fut`, calling `tick` with the whole seconds waited every `every` until it ends.
async fn progress_every<T>(
    every: std::time::Duration,
    fut: impl std::future::Future<Output = T>,
    mut tick: impl FnMut(u64),
) -> T {
    tokio::pin!(fut);
    let start = tokio::time::Instant::now();
    let mut ticks = tokio::time::interval_at(start + every, every);
    loop {
        tokio::select! {
            out = &mut fut => return out,
            _ = ticks.tick() => tick(start.elapsed().as_secs()),
        }
    }
}

/// How much longer than `--timeout` this client waits for the daemon's own bounded wait to
/// answer before it gives up itself (a daemon too old to read the bound waits 15 minutes).
const TURN_TIMEOUT_SLACK: std::time::Duration = std::time::Duration::from_secs(10);

/// [`super::transfer::begin_move`] for the chat `name`, every wait said: with `--after-turn`,
/// a line every 5 s naming the turn it waits for, and an end at `args.turn_timeout` that names
/// the chat and the step.
async fn begin_waiting(
    src: &Client,
    id: &str,
    name: &str,
    watch: Option<Value>,
    args: &MoveArgs,
) -> Result<super::transfer::Begun> {
    // Neither flag: a running turn moves with the chat, between its tool calls.
    if !args.interrupt && !args.after_turn {
        let live = super::transfer::begin_move_live(src, id, watch, super::transfer::TOOL_WAIT);
        return waiting(name, "freezing the chat for its move", live).await;
    }
    let running = (args.interrupt, args.after_turn);
    let bound = args.after_turn.then_some(args.turn_timeout);
    let begin = super::transfer::begin_move(src, id, watch, running, bound);
    let Some(bound) = bound else {
        return waiting(name, "freezing the chat for its move", begin).await;
    };
    let step = format!("waiting for its running turn to end (at most {}s)", bound.as_secs());
    match tokio::time::timeout(bound + TURN_TIMEOUT_SLACK, waiting(name, &step, begin)).await {
        Ok(Ok(begun)) => Ok(begun),
        // The daemon's own bound (`hub/transfer_out.rs` `transfer_begin`) ended the wait.
        Ok(Err(e)) if format!("{e:#}").contains("did not end within") => {
            Err(e.context(after_turn_failed(name, bound)))
        }
        Ok(Err(e)) => Err(e),
        Err(_) => Err(anyhow!("{}", after_turn_failed(name, bound))),
    }
}

/// What an `--after-turn` move that ended without the turn says: the chat, the step, the bound.
fn after_turn_failed(name: &str, bound: std::time::Duration) -> String {
    format!(
        "{name}: step `wait for the running turn` gave up: its turn did not end within {}s \
         (--timeout); nothing moved. Try again later, raise --timeout, or pass --interrupt",
        bound.as_secs()
    )
}

/// How long a move waits, after its commit, for this machine to list the chat reachable on the
/// target (`await_arrival`), and how often it asks.
const ARRIVAL_WAIT: std::time::Duration = std::time::Duration::from_secs(20);
const ARRIVAL_POLL: std::time::Duration = std::time::Duration::from_millis(250);

/// Whether `reply` (`_acpmux/info` with `sessionIds`, `row: true`) lists the moved chat as a
/// reachable row of a peer: a peer's row, not a last-known copy (`stale`), its link up
/// (`peerState` connected or degraded, as `ls` reads it, `cli/ls_table.rs`). `Err`: why not yet.
fn arrived(reply: &Value) -> Result<(), String> {
    let rows = reply.get("rows").and_then(Value::as_array).into_iter().flatten();
    let mut why = "not listed here yet".to_owned();
    for row in rows.filter(|r| r.get("peer").and_then(Value::as_str).is_some_and(|p| !p.is_empty()))
    {
        let state = row.get("peerState").and_then(Value::as_str);
        if row.get("stale").and_then(Value::as_bool) == Some(true) {
            why = format!("listed as its last-known copy (peer {})", state.unwrap_or("down"));
        } else if let Some(s) = state.filter(|s| !matches!(*s, "connected" | "degraded")) {
            why = format!("peer {s}");
        } else {
            return Ok(());
        }
    }
    Err(why)
}

/// Waits, at most `bound`, asking every `poll`, until `src` lists the moved chat `there` as
/// reachable on its new machine (`arrived`): a move that ends before then leaves `ls` showing
/// it unknown, its peer reconnecting, though it runs there. `Err`: why it is not, at the bound.
async fn await_arrival(
    src: &Client,
    there: &str,
    bound: std::time::Duration,
    poll: std::time::Duration,
) -> Result<(), String> {
    let deadline = tokio::time::Instant::now() + bound;
    let params = json!({"sessionIds": [there], "row": true});
    loop {
        let why = match src.request(method::MUX_INFO, params.clone()).await {
            Ok(reply) => match arrived(&reply) {
                Ok(()) => return Ok(()),
                Err(why) => why,
            },
            Err(e) => format!("{e:#}"),
        };
        if tokio::time::Instant::now() + poll > deadline {
            return Err(why);
        }
        tokio::time::sleep(poll).await;
    }
}

pub(crate) struct MoveArgs {
    pub sessions: Vec<String>,
    pub host: String,
    pub all_idle: bool,
    pub interrupt: bool,
    /// `--after-turn`: a running turn ends on its own first; the chat moves at its end.
    pub after_turn: bool,
    /// `--timeout`: with `after_turn`, the longest the move waits for the running turn.
    pub turn_timeout: std::time::Duration,
    pub leave_dirty: bool,
    /// `--carry-changes`: the checkout's uncommitted work goes with the chat
    /// (`session_move_carry.rs`).
    pub carry_changes: bool,
    pub cwd: Option<String>,
    pub dry_run: bool,
    /// `session resume`'s move: once moved, the held queue runs on the target, asked over the
    /// move's own connection (the route `HOST/ID` through this daemon may not know it yet).
    pub resume_there: bool,
    /// `--from MACHINE`: the chats live on that machine (one of this machine's ssh peers), and
    /// this machine drives their move over ssh to it and to the target. Neither of the two needs
    /// to reach the other: a Mac mini and a cloud VM that only this laptop reaches still trade
    /// chats, and `--machine local` brings one back here.
    pub from: Option<String>,
    /// `--from-snapshot`: the chats start on the target from this machine's copy of them
    /// (`session_move_snapshot.rs`), for a machine that does not answer.
    pub from_snapshot: bool,
}

/// Where the chats being moved live: this machine, or (`--from`) a peer this machine reaches
/// over ssh, whose daemon the move drives through a forward.
#[derive(Clone, Debug)]
pub(crate) enum Source {
    Here,
    Peer { name: String, ssh: String },
}

impl Source {
    fn ssh(&self) -> Option<&str> {
        match self {
            Source::Here => None,
            Source::Peer { ssh, .. } => Some(ssh),
        }
    }
}

/// The target name that means this machine: `local`, or its own machine name. Only a move
/// `--from` another machine takes it.
pub(crate) fn names_here(host: &str, here: &str) -> bool {
    host.eq_ignore_ascii_case("local") || host.eq_ignore_ascii_case(here)
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
    /// With `--carry-changes`: what was carried (`Carry::record`).
    carried: Option<Value>,
    error: Option<String>,
    error_code: Option<&'static str>,
    preflight: preflight::Preflight,
}

impl Outcome {
    /// The chat `key` before any step ran: not moved, no error yet.
    fn new(key: &str) -> Self {
        Outcome {
            session: key.to_owned(),
            name: key.to_owned(),
            host: None,
            cwd: None,
            moved: false,
            there: None,
            resumed: Ok(false),
            carried: None,
            error: None,
            error_code: None,
            preflight: preflight::Preflight::default(),
        }
    }
}

pub(super) async fn run(args: MoveArgs, json_out: bool) -> Result<()> {
    if args.from_snapshot {
        return snapshot::run(args, json_out).await;
    }
    let local = connect(true).await?;
    let peers = local.request("_acpmux/peers", json!({})).await?;
    let here = crate::pairing::machine_name();
    // `--from`: the chats' daemon is the peer's, reached through a forward of its local socket.
    let (src, source, home, _src_forward) = match &args.from {
        None => {
            if names_here(&args.host, &here) {
                bail!("the chats are on this machine already: name another machine");
            }
            let home =
                dirs::home_dir().ok_or_else(|| anyhow!("this machine has no home folder"))?;
            (local.clone(), Source::Here, home, None)
        }
        Some(from) => {
            let ssh = peer_ssh(&peers, from).ok_or_else(|| {
                anyhow!("{from} is not an ssh peer of this daemon (`acpmux machine ls`)")
            })?;
            if names_here(from, &here) {
                bail!("--from {from} is this machine: leave --from out");
            }
            let about = tokio::task::spawn_blocking({
                let ssh = ssh.clone();
                move || about(&ssh)
            })
            .await??;
            let forward = Forward::open(&ssh, &about.socket).await?;
            let client = Client::connect(&forward.local).await?;
            let source = Source::Peer { name: from.clone(), ssh };
            (client, source, PathBuf::from(&about.home), Some(forward))
        }
    };
    let ids = if args.all_idle { idle_chats(&src).await? } else { args.sessions.clone() };
    if ids.is_empty() {
        bail!("no chat to move: name one or more, or pass --all-idle");
    }
    let here_target = match &source {
        Source::Peer { .. } if names_here(&args.host, &here) => {
            Some(Target { name: here.clone(), ssh: String::new(), probed: Some(local_daemon()?) })
        }
        _ => None,
    };
    let mut targets = Targets::with_here(&args.host, &peers, here_target)?;
    targets.observer = Some(local);
    targets.exclude_source(&source, crate::placement::load_registry().as_ref())?;
    let mut outcomes = Vec::new();
    for key in &ids {
        let outcome = move_one_from(&src, &source, key, &args, &home, &mut targets).await;
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
                       "moved": o.moved, "dryRun": args.dry_run, "carried": o.carried,
                       "error": o.error, "errorCode": o.error_code,
                       "preflight": o.preflight, "targetSessionId": o.there})
            })
            .collect();
        print_json(&json!({"moves": rows, "failed": failed}));
    }
    match not_moved(&outcomes) {
        Some(why) => bail!("{why}"),
        None => Ok(()),
    }
}

/// The run's error when a chat did not move: how many, and each one's own reason (a caller
/// that reads only the error, as `--json`'s does, still learns why).
fn not_moved(outcomes: &[Outcome]) -> Option<String> {
    let why: Vec<String> = outcomes
        .iter()
        .filter_map(|o| o.error.as_ref().map(|e| format!("{} ({}): {e}", o.name, o.session)))
        .collect();
    (!why.is_empty()).then(|| {
        format!("{} of {} chats did not move: {}", why.len(), outcomes.len(), why.join("; "))
    })
}

fn print_outcome(o: &Outcome, dry_run: bool) {
    let host = o.host.as_deref().unwrap_or("?");
    let cwd = o.cwd.as_deref().unwrap_or("?");
    match &o.error {
        Some(e) => eprintln!("{} ({}): not moved: {e}", o.name, o.session),
        None if dry_run => println!("{} ({}): would move to {host} in {cwd}", o.name, o.session),
        None => println!("{} ({}): moved to {host} in {cwd}{}", o.name, o.session, carried_text(o)),
    }
}

/// `, with N uncommitted files (left here: .env)` for a move that carried changes.
fn carried_text(o: &Outcome) -> String {
    let Some(c) = &o.carried else { return String::new() };
    let files = c.get("files").and_then(Value::as_u64).unwrap_or(0);
    let left: Vec<&str> = c
        .get("leftOut")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|l| l.get("path").and_then(Value::as_str))
        .collect();
    let left =
        if left.is_empty() { String::new() } else { format!(" (left here: {})", left.join(", ")) };
    format!(", with {files} uncommitted file{}{left}", if files == 1 { "" } else { "s" })
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
    move_auto(src, id, true).await
}

/// The idle chat `id` moved off this machine as `session move ID --host auto` moves it, with no
/// one asking: the daemon's automatic evacuation (`hub/auto_evacuate.rs`) calls this with
/// `resume_there` false. `Err`: it did not move, and why; the chat is here as it was.
pub(crate) async fn move_auto(src: &Client, id: &str, resume_there: bool) -> Result<MovedOff> {
    let args = MoveArgs {
        sessions: vec![id.to_owned()],
        host: "auto".into(),
        all_idle: false,
        interrupt: false,
        after_turn: false,
        turn_timeout: DEFAULT_TURN_TIMEOUT,
        leave_dirty: false,
        carry_changes: false,
        cwd: None,
        dry_run: false,
        resume_there,
        from: None,
        from_snapshot: false,
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
    move_one_from(src, &Source::Here, key, args, home, targets).await
}

async fn move_one_from(
    src: &Client,
    source: &Source,
    key: &str,
    args: &MoveArgs,
    home: &Path,
    targets: &mut Targets,
) -> Outcome {
    let mut o = Outcome::new(key);
    if let Err(e) = move_steps(src, source, key, args, home, targets, &mut o).await {
        o.error = Some(format!("{e:#}"));
    }
    o
}

async fn move_steps(
    src: &Client,
    source: &Source,
    key: &str,
    args: &MoveArgs,
    home: &Path,
    targets: &mut Targets,
    o: &mut Outcome,
) -> Result<()> {
    let id = resolve_id(src, key).await?;
    o.session = id.clone();
    let info = src.request(method::MUX_INFO, json!({"sessionId": id})).await?;
    o.preflight.running = plan::running(&info);
    o.name = info.get("name").and_then(Value::as_str).unwrap_or(&id).to_owned();
    if info.get("peer").is_some_and(|p| !p.is_null()) {
        bail!(
            "it runs on {}, not here: move it from there",
            info.get("peer").unwrap_or(&Value::Null)
        );
    }
    let cwd = PathBuf::from(info.get("cwd").and_then(Value::as_str).unwrap_or_default());
    // With --cwd nothing of the folder here is carried, so it need not exist any more.
    let cwd = if args.cwd.is_some() {
        cwd
    } else if let Source::Peer { name, .. } = source {
        // That machine's own path, as its daemon reports it; its checkout is read there.
        let path = cwd.to_string_lossy();
        if !(path.starts_with('/') && crate::cli::hosts::plain_path(&path)) {
            bail!("its folder {path:?} on {name} is not a plain absolute path: pass --cwd");
        }
        cwd
    } else {
        cwd.canonicalize().map_err(|_| {
            anyhow!("its folder {} is gone here; there is nothing to carry", cwd.display())
        })?
    };
    let checkout = checkout_unless_named(&cwd, args, source).await?;
    o.preflight.dirty = Some(checkout.as_ref().is_some_and(|c| c.dirty));
    // A dry run is the preflight: it names a running turn even with --after-turn, so the caller
    // can offer Move after this turn or Move now. A real move goes on: by default it takes the
    // turn along between its tool calls (`transfer.rs` `begin_move_live`), with --after-turn
    // transfer_begin waits for the turn under its lock.
    let running_ok = args.interrupt || !args.dry_run;
    if let Some(why) = plan::refusal(&info, running_ok) {
        o.error_code = preflight::session_refusal_code(&info, running_ok);
        bail!("{why}");
    }
    let home = match source {
        Source::Here => home.canonicalize().unwrap_or_else(|_| home.to_path_buf()),
        Source::Peer { .. } => home.to_path_buf(),
    };
    let group = checkout.as_ref().map(|c| c.top.clone()).unwrap_or_else(|| cwd.clone());
    // What the move writes on the target: a fresh checkout of the branch (its tracked tree at
    // HEAD); a plain folder is made empty there.
    let need = match &checkout {
        // Its tree is on the other machine; placement goes by free disk alone.
        Some(_) if source.ssh().is_some() => 0,
        Some(c) => tokio::task::spawn_blocking({
            let top = c.top.clone();
            move || tree_bytes(&top)
        })
        .await?
        .unwrap_or(0),
        None => 0,
    };
    let target = waiting(&o.name, "choosing the machine", targets.pick(src, &group, need)).await?;
    o.host = Some(target.name.clone());
    let remote = match target.probed.clone() {
        Some(r) => r,
        None => waiting(&o.name, "asking the target about itself", target.remote()).await?,
    };
    let target_cwd = args.cwd.as_deref();
    let planned = plan::plan_folder(
        &cwd,
        &home,
        checkout.as_ref(),
        &remote.home,
        args.leave_dirty || args.carry_changes,
        target_cwd,
    )
    .map_err(|e| {
        // Only classify a dirty refusal when accepting dirt makes this same plan valid.
        // A detached HEAD or missing origin must never be shown as a proceed button.
        if o.preflight.dirty == Some(true)
            && !args.leave_dirty
            && !args.carry_changes
            && plan::plan_folder(&cwd, &home, checkout.as_ref(), &remote.home, true, target_cwd)
                .is_ok()
        {
            o.error_code = Some("dirty_worktree");
        }
        anyhow!(e)
    })?;
    // The target is asked what `transfer_receive` will ask, before anything is frozen or copied:
    // a refusal it can give without the bytes ends the move (and the dry run) here, in its words.
    let opened =
        waiting(&o.name, "opening the target's daemon", target_ask::open(&target, &remote)).await?;
    let asked =
        waiting(&o.name, "asking the target to take it", target_ask::ask(&opened.dst, &id, &info))
            .await;
    let answer = match asked {
        Ok(answer) => answer,
        Err(e) => {
            o.error_code = target_ask::refusal_code(&e);
            opened.close().await;
            return Err(e);
        }
    };
    if args.dry_run {
        opened.close().await;
        if answer == target_ask::Answer::Unasked {
            // An older acpmux there: nothing says the move would land, so the dry run does not.
            o.error_code = Some("target_unasked");
            bail!(
                "{} could not be asked whether it takes this chat: its acpmux is older than \
                 this check (update acpmux there; a move without --dry-run still asks it at \
                 the copy)",
                target.name
            );
        }
        o.cwd = Some(match &planned {
            Folder::Plain { cwd } => cwd.clone(),
            Folder::Worktree { repo, branch, subdir, snapshot: false, .. } => {
                format!("a worktree of {repo} {branch}{}", sub_text(subdir))
            }
            Folder::Worktree { repo, branch, subdir, snapshot: true, .. } => format!(
                "a detached checkout of {repo} at this {branch}'s HEAD{} ({branch} is shared: \
                 never pushed; the commit goes under {SNAPSHOT_REFS}, outside refs/heads)",
                sub_text(subdir)
            ),
        });
        return Ok(());
    }
    // Frozen from here: no prompt, turn or agent write changes the chat while its folder is
    // made, and every failure below gives it back.
    // The peer's name too: a move the watch ends records where it went, for `resolve`.
    // A source on another machine reaches neither this one nor the target by these ssh names:
    // no watch. A move whose client goes away then stays frozen there until it is ended.
    let watch = match source {
        Source::Here => {
            Some(json!({"socket": remote.socket, "ssh": target.ssh, "host": target.name}))
        }
        Source::Peer { .. } => None,
    };
    let name = o.name.clone();
    let begun = begin_waiting(src, &id, &name, watch, args).await?;
    let prepared = waiting(
        &name,
        "making its folder on the target",
        prepare(&cwd, &home, &target, &remote, args, source, o),
    )
    .await;
    let target_ask::Opened { forward, dst, init: dst_init } = opened;
    let record = match prepared {
        Ok(record) => record,
        Err(e) => {
            super::transfer::abort_move(src, &id, &begun).await;
            if let Some(forward) = forward {
                forward.close().await;
            }
            return Err(e);
        }
    };
    let there = record.get("cwd").and_then(Value::as_str).map(str::to_owned);
    let moved = waiting(
        &name,
        "copying the chat to the target",
        super::transfer::finish_move(src, &dst, &dst_init, &id, &begun, there, None, record),
    )
    .await?;
    targets.placed(&target.name);
    o.moved = true;
    o.there = moved.get("sessionId").and_then(Value::as_str).map(str::to_owned);
    // Done only once this machine lists it where it went, reachable: else `ls` right after
    // shows the chat unknown, its peer reconnecting (item D).
    if let Some(there) = o.there.clone() {
        let step = format!("waiting until this machine lists it reachable on {}", target.name);
        let listed =
            waiting(&name, &step, await_arrival(src, &there, ARRIVAL_WAIT, ARRIVAL_POLL)).await;
        if let Err(why) = listed {
            eprintln!(
                "move: {name}: moved to {}, but this machine does not list it reachable there \
                 after {}s ({why}); it runs there, and `acpmux ls` shows it once the link is up",
                target.name,
                ARRIVAL_WAIT.as_secs()
            );
        }
    }
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
    if let Some(forward) = forward {
        forward.close().await;
    }
    if let Some(name) = moved.get("name").and_then(Value::as_str) {
        o.name = name.to_owned();
    }
    Ok(())
}

/// The frozen chat's folder made on the target: the checkout read again (it may have changed
/// before the freeze), its branch pushed, the folder made there. Returns the move's record
/// (`movedTo`). The client of the target's daemon is `target_ask::open`'s, from before the freeze.
async fn prepare(
    cwd: &Path,
    home: &Path,
    target: &Target,
    remote: &RemoteDaemon,
    args: &MoveArgs,
    source: &Source,
    o: &mut Outcome,
) -> Result<Value> {
    let checkout = checkout_unless_named(cwd, args, source).await?;
    let folder = plan::plan_folder(
        cwd,
        home,
        checkout.as_ref(),
        &remote.home,
        args.leave_dirty || args.carry_changes,
        args.cwd.as_deref(),
    )
    .map_err(|e| anyhow!(e))?;
    let mut record = json!({"host": target.name});
    let mut carry = None;
    let mut at = None;
    if let (Folder::Worktree { branch, dirty, snapshot, .. }, Some(c)) = (&folder, &checkout) {
        // A shared branch (main, master, origin's HEAD) is never pushed: its HEAD goes under a ref
        // of this move's own, and the target checks that commit out detached.
        let dest = if *snapshot { snapshot_ref() } else { format!("refs/heads/{branch}") };
        let commit = tokio::task::spawn_blocking({
            let (top, dest, ssh) = (c.top.clone(), dest.clone(), source.ssh().map(str::to_owned));
            move || match ssh {
                None => push_branch(&top, &dest),
                Some(ssh) => push_branch_on(&ssh, &top, &dest),
            }
        })
        .await??;
        record.set("branch", json!(branch));
        record.set("commit", json!(commit));
        if *snapshot {
            record.set("snapshotRef", json!(dest));
            record.set("detached", json!(true));
            at = Some((dest, commit.clone(), c.top.clone()));
        }
        if *dirty && args.carry_changes {
            // Read after the freeze and the push: what the agent left, against what was pushed.
            let read = tokio::task::spawn_blocking({
                let (top, ssh) = (c.top.clone(), source.ssh().map(str::to_owned));
                move || match ssh {
                    None => carry::snapshot(&|script, input| run_here(script, input), &top, true),
                    Some(ssh) => carry::snapshot(
                        &|script, input| {
                            crate::cli::hosts::Remote::exec(
                                &crate::cli::hosts::SshRemote(&ssh),
                                script,
                                Some(input),
                            )
                        },
                        &top,
                        false,
                    ),
                }
            })
            .await??;
            carry::check_base(&read, &commit)?;
            record.set("uncommittedCarried", read.record());
            o.carried = Some(read.record());
            carry = Some(read);
        } else if *dirty {
            let left_on = match source {
                Source::Here => crate::pairing::machine_name(),
                Source::Peer { name, .. } => name.clone(),
            };
            record.set("uncommittedLeftOn", json!(left_on));
        }
    }
    let there = tokio::task::spawn_blocking({
        let (host, folder) = (target.ssh.clone(), folder.clone());
        let pin = at.as_ref().map(|(r, c, _)| (r.clone(), c.clone()));
        move || prepare_folder(&host, &folder, pin.as_ref().map(|(r, c)| (r.as_str(), c.as_str())))
    })
    .await;
    if let Some((dest, _, top)) = at {
        // The target has the commit (or failed to): the move's own ref is not left on origin.
        let ssh = source.ssh().map(str::to_owned);
        let _ = tokio::task::spawn_blocking(move || match ssh {
            None => drop_ref(&top, &dest),
            Some(ssh) => drop_ref_on(&ssh, &top, &dest),
        })
        .await;
    }
    let there = there??;
    if let Some(carry) = carry.filter(|c| !c.patch.is_empty()) {
        tokio::task::spawn_blocking({
            let (host, there) = (target.ssh.clone(), there.clone());
            move || apply_carry(&host, &there, &carry)
        })
        .await??;
    }
    o.cwd = Some(there.clone());
    record.set("cwd", json!(there));
    Ok(record)
}

/// The checkout `cwd` is in, unless `--cwd` names the folder there (no checkout is carried).
async fn checkout_unless_named(
    cwd: &Path,
    args: &MoveArgs,
    source: &Source,
) -> Result<Option<Checkout>> {
    if args.cwd.is_some() {
        return Ok(None);
    }
    let cwd = cwd.to_path_buf();
    let ssh = source.ssh().map(str::to_owned);
    tokio::task::spawn_blocking(move || match ssh {
        None => checkout_of(&cwd),
        Some(ssh) => checkout_on(&ssh, &cwd),
    })
    .await?
}

/// The fixed script that reads the checkout a folder is in on a source machine (`--from`): the
/// folder on stdin; `none`, or tab-separated `top`, `branch`, `origin` and `default` (origin's
/// HEAD, `origin/main`) lines and a `dirty`
/// line when it has uncommitted changes. Exit 3: git status failed.
const CHECKOUT_SCRIPT: &str = r#"read -r d || exit 2
top=$(git -c core.fsmonitor=false -C "$d" rev-parse --show-toplevel 2>/dev/null) || { echo none; exit 0; }
[ -n "$top" ] || { echo none; exit 0; }
top=$(cd -- "$top" && pwd -P) || exit 2
printf 'top\t%s\n' "$top"
printf 'branch\t%s\n' "$(git -C "$top" symbolic-ref -q --short HEAD 2>/dev/null)"
printf 'origin\t%s\n' "$(git -C "$top" remote get-url origin 2>/dev/null)"
printf 'default\t%s\n' "$(git -C "$top" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"
s=$(git -c core.fsmonitor=false -C "$top" status --porcelain --untracked-files=normal) || exit 3
if [ -n "$s" ]; then echo dirty; fi"#;

/// [`CHECKOUT_SCRIPT`]'s answer.
pub(crate) fn parse_checkout(stdout: &str) -> Result<Option<Checkout>> {
    let (mut top, mut branch, mut origin, mut dirty) = (None, None, None, false);
    let mut default_branch = None;
    for line in stdout.lines() {
        match line.split_once('\t') {
            Some(("top", v)) if !v.is_empty() => top = Some(PathBuf::from(v)),
            Some(("branch", v)) if !v.is_empty() => branch = Some(v.to_owned()),
            Some(("origin", v)) if !v.is_empty() => origin = Some(v.to_owned()),
            Some(("default", v)) if !v.is_empty() => default_branch = origin_head(v),
            _ if line.trim() == "dirty" => dirty = true,
            _ if line.trim() == "none" => return Ok(None),
            _ => {}
        }
    }
    let top = top.ok_or_else(|| anyhow!("the source answered no checkout folder"))?;
    let text = top.to_string_lossy();
    if !(text.starts_with('/')
        && crate::cli::hosts::plain_path(&text)
        && !text.split('/').any(|c| c == ".."))
    {
        bail!("the source's checkout folder is not a plain path");
    }
    Ok(Some(Checkout { top, branch, origin, dirty, default_branch }))
}

/// The branch `git symbolic-ref --short refs/remotes/origin/HEAD` names (`origin/main` → `main`).
fn origin_head(short: &str) -> Option<String> {
    short.trim().strip_prefix("origin/").filter(|b| !b.is_empty()).map(str::to_owned)
}

/// Where a move's snapshot of a shared branch goes on origin: outside `refs/heads`, so no branch
/// moves and no branch list shows it.
const SNAPSHOT_REFS: &str = "refs/acpmux/moves/";

/// A fresh ref of [`SNAPSHOT_REFS`] for one move.
fn snapshot_ref() -> String {
    format!("{SNAPSHOT_REFS}{}", uuid::Uuid::now_v7().simple())
}

/// The git checkout `cwd` is in on the ssh host `ssh`, if any.
fn checkout_on(ssh: &str, cwd: &Path) -> Result<Option<Checkout>> {
    let input = format!("{}\n", cwd.display());
    let out = crate::cli::hosts::Remote::exec(
        &crate::cli::hosts::SshRemote(ssh),
        CHECKOUT_SCRIPT,
        Some(input.as_bytes()),
    )?;
    if !out.ok {
        let last = out.stderr.lines().rfind(|l| !l.trim().is_empty()).unwrap_or("").trim();
        bail!("reading the checkout of {} on {ssh} failed: {last}", cwd.display());
    }
    parse_checkout(&out.stdout)
}

/// The fixed script that pushes HEAD on a source machine, never forced: the checkout and the
/// full ref it goes to (`refs/heads/BRANCH`, or a [`SNAPSHOT_REFS`] one) on stdin; prints the
/// commit pushed.
pub(crate) const PUSH_SCRIPT: &str = r#"read -r top; read -r dest
case "$dest" in refs/heads/*|refs/acpmux/moves/*) ;; *) exit 2;; esac
head=$(git -C "$top" rev-parse HEAD) || exit 2
git -C "$top" push --quiet origin "HEAD:$dest" || exit 3
printf '%s\n' "$head""#;

/// The fixed script that deletes a move's own [`SNAPSHOT_REFS`] ref on origin, best effort.
const DROP_REF_SCRIPT: &str = r#"read -r top; read -r dest
case "$dest" in refs/acpmux/moves/*) ;; *) exit 2;; esac
git -C "$top" push --quiet origin ":$dest""#;

/// Deletes the snapshot ref `dest` from origin, from the checkout `top` here; best effort.
fn drop_ref(top: &Path, dest: &str) {
    let input = format!("{}\n{dest}\n", top.display());
    let _ = run_here(DROP_REF_SCRIPT, input.as_bytes());
}

/// [`drop_ref`] on the ssh host `ssh`.
fn drop_ref_on(ssh: &str, top: &Path, dest: &str) {
    let input = format!("{}\n{dest}\n", top.display());
    let _ = crate::cli::hosts::Remote::exec(
        &crate::cli::hosts::SshRemote(ssh),
        DROP_REF_SCRIPT,
        Some(input.as_bytes()),
    );
}

/// [`push_branch`] on the ssh host `ssh`.
fn push_branch_on(ssh: &str, top: &Path, dest: &str) -> Result<String> {
    let branch = dest.strip_prefix("refs/heads/").unwrap_or(dest);
    let input = format!("{}\n{dest}\n", top.display());
    let out = crate::cli::hosts::Remote::exec(
        &crate::cli::hosts::SshRemote(ssh),
        PUSH_SCRIPT,
        Some(input.as_bytes()),
    )?;
    let head = out.stdout.lines().last().unwrap_or_default().trim().to_owned();
    if !out.ok || head.len() < 40 {
        let last = out.stderr.lines().rfind(|l| !l.trim().is_empty()).unwrap_or("").trim();
        bail!("pushing {branch} to origin on {ssh} failed (it may have moved on there): {last}");
    }
    Ok(head)
}

/// Applies `carry` in the chat's new folder `there` on the ssh host `host` (this machine when
/// empty), through [`carry::APPLY_SCRIPT`].
fn apply_carry(host: &str, there: &str, carry: &Carry) -> Result<()> {
    let input = carry::apply_input(there, carry);
    let out = if host.is_empty() {
        run_here(carry::APPLY_SCRIPT, &input)?
    } else {
        crate::cli::hosts::Remote::exec(
            &crate::cli::hosts::SshRemote(host),
            carry::APPLY_SCRIPT,
            Some(&input),
        )?
    };
    if !out.ok {
        let host = if host.is_empty() { "this machine" } else { host };
        let last = out.stderr.lines().rfind(|l| !l.trim().is_empty()).unwrap_or("").trim();
        bail!("its uncommitted changes did not apply in {there} on {host}: {last}");
    }
    Ok(())
}

/// This machine's daemon as a target (`--machine local`): its home and local socket.
fn local_daemon() -> Result<RemoteDaemon> {
    let home = dirs::home_dir().ok_or_else(|| anyhow!("this machine has no home folder"))?;
    Ok(RemoteDaemon {
        home: home.to_string_lossy().into_owned(),
        socket: crate::config::socket_path().to_string_lossy().into_owned(),
        disk_free: None,
    })
}

/// The ssh destination of the peer `name` in a `_acpmux/peers` answer.
fn peer_ssh(peers: &Value, name: &str) -> Option<String> {
    peers.get("peers").and_then(Value::as_array).into_iter().flatten().find_map(|p| {
        let n = p.get("name").and_then(Value::as_str)?;
        if !n.eq_ignore_ascii_case(name) {
            return None;
        }
        let url = p.get("url").and_then(Value::as_str)?;
        crate::peer::ssh_target(url).ok().map(|t| t.destination)
    })
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
    let default_branch = git(&top, &["symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"])
        .and_then(|h| origin_head(&h));
    Ok(Some(Checkout { top, branch, origin, dirty: !status.is_empty(), default_branch }))
}

/// Pushes HEAD of `top` to the full ref `dest` on `origin` (`refs/heads/BRANCH`, or a
/// [`SNAPSHOT_REFS`] one), never forced: a branch that moved on there refuses the move rather
/// than losing either side. Returns the commit pushed.
fn push_branch(top: &Path, dest: &str) -> Result<String> {
    let branch = dest.strip_prefix("refs/heads/").unwrap_or(dest);
    let head = git(top, &["rev-parse", "HEAD"]).ok_or_else(|| anyhow!("no HEAD commit"))?;
    let out = StdCommand::new("git")
        .arg("-C")
        .arg(top)
        .args(["push", "--quiet", "origin"])
        .arg(format!("HEAD:{dest}"))
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
/// With a `ref` and `at` line (a snapshot of a shared branch), a detached checkout of the commit
/// `at`, fetched from origin's `ref`; never a checkout of the branch itself.
pub(crate) const WORKTREE_SCRIPT: &str = r#"read -r repo; read -r branch; read -r url; read -r sub
read -r ref || true; read -r at || true
PATH="$HOME/.local/bin:$PATH"
dir=
if [ -n "$at" ]; then
  if command -v wt >/dev/null 2>&1; then
    out=$(wt new "$repo" --at "$at" --name "move-$(printf '%.12s' "$at")") && dir=$(printf '%s\n' "$out" | tail -n 1)
  fi
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    base="$HOME/Projects/checkouts/$(printf '%s' "$repo" | tr / -)"
    mkdir -p -- "$base" || exit 1
    dir=$(mktemp -d "$base/move-$(printf '%.12s' "$at").XXXXXX") || exit 1
    git clone -q --no-checkout -- "$url" "$dir" || exit 1
    git -C "$dir" fetch -q origin "$ref" || exit 1
    git -C "$dir" -c advice.detachedHead=false checkout -q --detach "$at" || exit 1
  fi
elif command -v wt >/dev/null 2>&1; then
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

/// Makes `folder` on the ssh host `host` (this machine when empty) and returns its path there.
/// `at`: a snapshot's ref and commit, checked out detached instead of the branch.
fn prepare_folder(host: &str, folder: &Folder, at: Option<(&str, &str)>) -> Result<String> {
    let (script, input) = match folder {
        Folder::Plain { cwd } => (PLAIN_SCRIPT, format!("{cwd}\n")),
        Folder::Worktree { repo, url, branch, subdir, .. } => {
            let pin = at.map_or_else(String::new, |(r, c)| format!("{r}\n{c}\n"));
            (WORKTREE_SCRIPT, format!("{repo}\n{branch}\n{url}\n{subdir}\n{pin}"))
        }
    };
    let out = if host.is_empty() {
        run_here(script, input.as_bytes())?
    } else {
        crate::cli::hosts::Remote::exec(
            &crate::cli::hosts::SshRemote(host),
            script,
            Some(input.as_bytes()),
        )?
    };
    let host = if host.is_empty() { "this machine" } else { host };
    if !out.ok {
        return Err(folder_failure(host, &out));
    }
    let path = out.stdout.lines().last().unwrap_or_default().trim().to_owned();
    if !(path.starts_with('/') && crate::cli::hosts::plain_path(&path)) {
        bail!("{host} answered no plain folder path for the chat");
    }
    Ok(path)
}

/// Explain a remote folder command failure without dropping the only useful diagnostic. SSH
/// wrappers occasionally leave stderr empty while the script writes its reason to stdout, and a
/// quiet non-zero exit must still be distinguishable from a successful empty answer.
fn folder_failure(host: &str, out: &crate::cli::hosts::RemoteOut) -> anyhow::Error {
    let detail = out
        .stderr
        .lines()
        .chain(out.stdout.lines())
        .rfind(|line| !line.trim().is_empty())
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .unwrap_or("remote command returned no diagnostic output");
    anyhow!("making the folder on {host} failed (non-zero exit status): {detail}")
}

/// Runs one of the fixed scripts on this machine, `input` on its stdin.
fn run_here(script: &str, input: &[u8]) -> Result<crate::cli::hosts::RemoteOut> {
    use std::io::Write as _;
    let mut child = StdCommand::new("/bin/sh")
        .arg("-c")
        .arg(script)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .context("sh")?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(input)?;
    }
    let out = child.wait_with_output()?;
    Ok(crate::cli::hosts::RemoteOut {
        ok: out.status.success(),
        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
    })
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
    /// This machine, when it is the named target (`--machine local` with `--from`).
    here: Option<Target>,
    /// Placement must describe the initiating daemon's peers, even when the chat lives elsewhere.
    observer: Option<std::sync::Arc<Client>>,
}

impl Targets {
    fn new(host: &str, peers: &Value) -> Result<Self> {
        Self::with_here(host, peers, None)
    }

    /// [`Targets::new`]; `here` is this machine as the named target (`--machine local` on a move
    /// `--from` another machine).
    fn with_here(host: &str, peers: &Value, here: Option<Target>) -> Result<Self> {
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
        if let Some(t) = here {
            return Ok(Self {
                named: Some(t.name.clone()),
                peers,
                by_group: HashMap::new(),
                placed: HashMap::new(),
                unreachable: HashMap::new(),
                here: Some(t),
                observer: None,
            });
        }
        let named = (host != "auto").then(|| host.to_owned());
        if let Some(n) = &named
            && !peers.iter().any(|(p, _)| p.eq_ignore_ascii_case(n))
        {
            bail!("{n} is not an ssh peer of this daemon (`acpmux machine ls`)");
        }
        Ok(Self {
            here: None,
            observer: None,
            named,
            peers,
            by_group: HashMap::new(),
            placed: HashMap::new(),
            unreachable: HashMap::new(),
        })
    }

    /// The source cannot also be a destination, including saved aliases for its SSH endpoint.
    fn exclude_source(&mut self, source: &Source, registry: Option<&Value>) -> Result<()> {
        let Source::Peer { name, ssh } = source else { return Ok(()) };
        let identity = crate::placement::move_targets::identity;
        let source_id = identity(registry, name);
        let is_source = |peer: &str, endpoint: &str| {
            identity(registry, peer) == source_id || endpoint.eq_ignore_ascii_case(ssh)
        };
        if let Some(named) = &self.named
            && self.peers.iter().any(|(peer, endpoint)| {
                peer.eq_ignore_ascii_case(named) && is_source(peer, endpoint)
            })
        {
            bail!("the chats are on {name} already: name another machine");
        }
        self.peers.retain(|(peer, endpoint)| !is_source(peer, endpoint));
        Ok(())
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
        if let Some(t) = &self.here {
            return Ok(t.clone());
        }
        // A machine a person works at is never a target: moving there is what a move off one
        // avoids (`server/place.rs`). A named one is the caller's choice.
        let observer = self.observer.as_deref().unwrap_or(src);
        let verdict = observer
            .request(
                "_acpmux/place",
                json!({"work": "agent", "offInteractive": true, "outdatedOk": true}),
            )
            .await?;
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
                    auto_refusal(n, self.target(n).is_some(), registry.as_ref())
                });
                for line in outdated_lines(&hosts, &order) {
                    eprintln!("{line}");
                }
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
                        "no peer can take a moved chat: {} (`acpmux machine pick`)",
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

/// Why `--machine auto` passes over the placement host `name` (`ssh`: an ssh peer of this
/// daemon), from the registry: not an ssh peer, a machine `placement::auto_move_refusal` names
/// (a person's own, never a dependency; a last-resort host), or one `placement::held` holds or
/// someone reserved. `None`: it may take the move.
fn auto_refusal(name: &str, ssh: bool, registry: Option<&Value>) -> Option<String> {
    if !ssh {
        return Some("not an ssh peer of this daemon".to_owned());
    }
    crate::placement::auto_move_refusal(registry, name)
        .map(|why| format!("{why} with --machine {name}"))
        .or_else(|| crate::placement::held(registry, name))
}

/// One line for each host of `order` placement marks `outdated` (its build differs from this
/// one's; `server/place.rs` `outdatedOk`): it stays ranked, since the move reaches its daemon
/// over ssh, and the line gives the one command that refreshes it. Not run by the move: an
/// update restarts that daemon and every chat live on it.
fn outdated_lines(hosts: &[Value], order: &[String]) -> Vec<String> {
    order
        .iter()
        .filter_map(|n| {
            let h = hosts.iter().find(|h| h.get("name").and_then(Value::as_str) == Some(n))?;
            (h.get("outdated").and_then(Value::as_bool) == Some(true)).then(|| {
                let refresh = h
                    .get("refresh")
                    .and_then(Value::as_str)
                    .map_or_else(|| crate::placement::refresh_command(n), str::to_owned);
                format!(
                    "auto: {n} runs another acpmux build (a stale disk copy); ranked anyway, \
                     since the move goes over ssh to its own daemon. Not refreshed here (an \
                     update restarts its daemon and the chats on it); refresh it with `{refresh}`"
                )
            })
        })
        .collect()
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
