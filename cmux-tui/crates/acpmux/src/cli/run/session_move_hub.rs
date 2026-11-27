//! `acpmux session move SESSION... --machine NAME` to one of the person's machines that no ssh
//! peer names and the team hub lists (a lane VM another lane VM never reaches over ssh): the move
//! of `session_move.rs`, carried by the hub (`hub/transfer_pull.rs`).
//!
//! For each chat: the checks of a move over ssh; the chat frozen here with the target named by
//! its hub `daemonId` (`transfer_begin {to: {hub, host}}`, with `--interrupt` or `--after-turn`
//! as there); its branch pushed (never forced); then this daemon sends op `move` and waits for
//! the target's answer (`_acpmux/transfer_hub`). The target makes the folder itself (a worktree
//! of the branch, the same path under its home, or `--cwd`), pulls the bundle from this machine
//! over the hub carrier and imports it under its own guard. Its answer commits the move here; a
//! refusal gives the chat back. No answer in time leaves it frozen: the move's watch asks the
//! target (`move_forget`) and ends it either way. `--carry-changes` does not go through the hub.

use super::super::transfer::{Staged, refused_as};
use super::*;

pub(super) async fn resolve(src: &Client, name: &str) -> Result<Value> {
    src.request("_acpmux/transfer_hub", json!({"resolve": name})).await
}

/// A qualified source may also name a local sub-session (PARENT/CHILD). Only a hub
/// machine in this person's address book takes the remote route.
pub(super) async fn holder(
    src: &Client,
    key: &str,
    here: &str,
    peers: &Value,
) -> Result<Option<(String, String)>> {
    let Some((host, session)) = key.split_once('/') else { return Ok(None) };
    if session.is_empty() || names_here(host, here) || peer_ssh(peers, host).is_some() {
        return Ok(None);
    }
    match resolve(src, host).await {
        Ok(machine) => Ok(Some((machine_id(&machine)?.to_owned(), session.to_owned()))),
        Err(e)
            if e.downcast_ref::<crate::client::DaemonError>().is_some_and(|err| {
                err.0.code == crate::rpc::RpcError::not_found("").code
                    || err.0.code == crate::rpc::RpcError::method_not_found("").code
            }) =>
        {
            Ok(None)
        }
        Err(e) => Err(e),
    }
}

fn machine_id(machine: &Value) -> Result<&str> {
    machine
        .get("daemonId")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .context("the hub returned a machine without a daemon id")
}

#[derive(serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Row {
    session_id: String,
    name: String,
    host: String,
    cwd: Option<String>,
    moved: bool,
    dry_run: bool,
    via: String,
    there: Option<String>,
    target_session_id: Option<String>,
    error: Option<String>,
    timings: Option<Value>,
}

impl Row {
    fn new(key: &str, host: &str, dry_run: bool) -> Self {
        Self {
            session_id: key.to_owned(),
            name: key.to_owned(),
            host: host.to_owned(),
            cwd: None,
            moved: false,
            dry_run,
            via: "hub".into(),
            there: None,
            target_session_id: None,
            error: None,
            timings: None,
        }
    }

    fn failed(key: &str, host: &str, error: anyhow::Error) -> Self {
        let mut row = Self::new(key, host, false);
        row.error = Some(format!("{error:#}"));
        row
    }

    pub(super) fn into_outcome(self) -> Outcome {
        let mut outcome = Outcome::new(&self.session_id);
        outcome.name = self.name;
        outcome.host = Some(self.host);
        outcome.cwd = self.cwd;
        outcome.moved = self.moved;
        outcome.there = self.there;
        outcome.error = self.error;
        outcome
    }
}

/// Both a locally driven move and an authorized move_out use this transaction on the holder.
pub(super) async fn one(
    src: &Client,
    key: &str,
    args: &MoveArgs,
    home: &Path,
    machine: &Value,
) -> Row {
    let host = machine.get("host").and_then(Value::as_str).unwrap_or(&args.host);
    let mut row = Row::new(key, host, args.dry_run);
    let result = async {
        let daemon = machine_id(machine)?;
        steps(src, key, args, home, daemon, host, &mut row).await
    }
    .await;
    if let Err(e) = result {
        row.error = Some(format!("{e:#}"));
    }
    row
}

pub(crate) async fn move_out(
    hub: &std::sync::Arc<crate::hub::Hub>,
    request: crate::mesh_control::MoveOutParams,
) -> Result<Value> {
    let args = MoveArgs {
        sessions: vec![],
        host: request.to,
        all_idle: false,
        interrupt: request.interrupt,
        after_turn: request.after_turn,
        turn_timeout: std::time::Duration::from_secs(request.timeout_secs),
        leave_dirty: false,
        carry_changes: false,
        cwd: None,
        dry_run: false,
        resume_there: false,
        from: None,
        slow_ok: false,
        from_snapshot: false,
        // A move asked for through the hub keeps the chat's harness.
        as_harness: None,
    };
    let result = async {
        // Resolve here before the CLI sees the key. A remote name must not expand against
        // the daemon process's current-session environment or select a mirrored chat.
        let session = hub.resolve(&request.session_id)?;
        let src = Client::in_process(hub.clone()).await?;
        let home = dirs::home_dir().context("this machine has no home folder")?;
        let machine = resolve(&src, &args.host).await?;
        Ok(one(&src, &session.id, &args, &home, &machine).await)
    }
    .await;
    let row = result.unwrap_or_else(|e| Row::failed(&request.session_id, &args.host, e));
    Ok(serde_json::to_value(row)?)
}

pub(super) async fn ask_holder(
    src: &Client,
    holder: &str,
    session: &str,
    args: &MoveArgs,
    here: &str,
) -> Row {
    let to = if names_here(&args.host, here) { "local" } else { &args.host };
    let params = json!({"moveOut": holder, "sessionId": session, "to": to, "afterTurn": args.after_turn,
                        "interrupt": args.interrupt, "timeoutSecs": args.turn_timeout.as_secs()});
    let result = async {
        let reply = src.request("_acpmux/transfer_hub", params).await?;
        Ok::<Row, anyhow::Error>(serde_json::from_value(reply)?)
    }
    .await;
    result.unwrap_or_else(|e| Row::failed(session, to, e))
}

/// The folder op `move` names: `{cwd}` for `--cwd`, `{home}` for a plain folder under the home
/// folder, `{repo, url, branch, subdir}` for a checkout.
fn folder_value(folder: &Folder, home: &Path, named: bool) -> Result<Value> {
    Ok(match folder {
        Folder::Plain { cwd } if named => json!({"cwd": cwd}),
        Folder::Plain { cwd } => {
            let rel = Path::new(cwd)
                .strip_prefix(home)
                .map_err(|_| anyhow!("{cwd} is outside this machine's home: pass --cwd"))?;
            json!({"home": rel.to_string_lossy()})
        }
        Folder::Worktree { repo, url, branch, subdir, .. } => {
            json!({"repo": repo, "url": url, "branch": branch, "subdir": subdir})
        }
        Folder::Bundle { top, .. } => bail!("{}", no_origin_over_the_hub(top)),
    })
}

/// Why a checkout with no owner/name `origin` does not move over the hub: the target makes the folder
/// itself from a remote, and the git bundle that carries such a checkout goes over ssh only.
fn no_origin_over_the_hub(top: &str) -> String {
    format!(
        "{top} has no owner/name origin, and such a checkout does not move through the team hub \
         yet: add a remote and push, or pass --cwd to a folder the target already has"
    )
}

async fn steps(
    src: &Client,
    key: &str,
    args: &MoveArgs,
    home: &Path,
    daemon: &str,
    host: &str,
    o: &mut Row,
) -> Result<()> {
    let id = resolve_id(src, key).await?;
    o.session_id = id.clone();
    let info = src.request(method::MUX_INFO, json!({"sessionId": id})).await?;
    o.name = info.get("name").and_then(Value::as_str).unwrap_or(&id).to_owned();
    // The hub's pull (`hub/transfer_pull.rs`) does not carry `--as` to the target: refused
    // before the freeze rather than landed on the old name.
    if let Some(name) = &args.as_harness {
        bail!("--as {name} does not reach a machine over the team hub yet; move it over ssh");
    }
    if info.get("peer").is_some_and(|p| !p.is_null()) {
        bail!("it runs on {}, not here: move it from there", field(&info, "peer"));
    }
    // A running turn moves with the chat, as over ssh (`session_move.rs` `begin_waiting`): the
    // begin stops it between tool calls and its continuation runs on the target.
    if let Some(why) = plan::refusal(&info, hub_running_ok(args)) {
        bail!("{why}");
    }
    let cwd = PathBuf::from(info.get("cwd").and_then(Value::as_str).unwrap_or_default());
    let cwd = if args.cwd.is_some() {
        cwd
    } else {
        cwd.canonicalize().map_err(|_| {
            anyhow!("its folder {} is gone here; there is nothing to carry", cwd.display())
        })?
    };
    let home = home.canonicalize().unwrap_or_else(|_| home.to_path_buf());
    let home_text = home.to_string_lossy().into_owned();
    let leave_dirty = args.leave_dirty;
    let checkout = checkout_unless_named(&cwd, args, &Source::Here).await?;
    // Planned with this machine's home standing for the target's: a plain folder goes as its
    // path under the home folder, which the target joins to its own.
    let planned = plan::plan_folder(
        &cwd,
        &home,
        checkout.as_ref(),
        &home_text,
        leave_dirty,
        args.cwd.as_deref(),
    )
    .map_err(|e| anyhow!(e))?;
    // Refused before anything is frozen, and in a dry run too.
    if let Folder::Bundle { top, .. } = &planned {
        bail!("{}", no_origin_over_the_hub(top));
    }
    if args.dry_run {
        o.cwd = Some(match &planned {
            Folder::Plain { cwd } => cwd.clone(),
            Folder::Worktree { repo, branch, subdir, .. } => {
                format!("a worktree of {repo} {branch}{}", sub_text(subdir))
            }
            Folder::Bundle { top, .. } => top.clone(),
        });
        return Ok(());
    }
    // Pre-copied when the target takes a stage over the hub: the freeze then carries only the
    // log's tail. A target that lost the stage refuses the move as unstaged: made again in full.
    let staged = precopy(src, &id, daemon).await;
    let moving = Moving { src, id: &id, args, home: &home, home_text: &home_text, cwd: &cwd };
    let (sent, answer, timing) = match moving.run(daemon, host, staged.as_ref()).await {
        Err(e) if staged.is_some() && refused_as(&e, "transfer.unstaged") => {
            moving.run(daemon, host, None).await?
        }
        done => done?,
    };
    let moved = field(&answer, "moved");
    let mut to_meta = json!({"host": host, "via": "hub", "daemonId": daemon,
                             "sessionId": moved.get("sessionId").cloned().unwrap_or(json!(id)),
                             "cwd": moved["cwd"]});
    for key in ["branch", "commit", "uncommittedLeftOn"] {
        if let Some(v) = sent.get(key) {
            to_meta.set(key, v.clone());
        }
    }
    src.request(
        "_acpmux/transfer_commit",
        json!({"sessionId": id, "transferId": field(&sent, "transferId"), "to": to_meta,
               "epoch": field(&sent, "epoch")}),
    )
    .await?;
    let commit_ms = elapsed_ms(timing.started);
    o.timings = Some(timing.value(commit_ms));
    o.moved = true;
    o.cwd = moved["cwd"].as_str().map(str::to_owned);
    o.there = moved["sessionId"].as_str().map(str::to_owned);
    o.target_session_id = o.there.clone();
    Ok(())
}

/// What one chat's move needs to be made: the chat, its folder, and the move's flags.
struct Moving<'a> {
    src: &'a Client,
    id: &'a str,
    args: &'a MoveArgs,
    home: &'a Path,
    home_text: &'a str,
    cwd: &'a Path,
}

/// The source-side timing split for one hub move. Values are milliseconds elapsed from the
/// beginning of this client's move request. The target's transfer timings are copied into the
/// same object by `Moving::run`.
fn elapsed_ms(start: std::time::Instant) -> u64 {
    start.elapsed().as_millis().try_into().unwrap_or(u64::MAX)
}

struct Timing {
    started: std::time::Instant,
    begin_ms: u64,
    answer_ms: u64,
    /// The begin cut a running turn whose continuation moved with the chat (`continues`).
    carried: bool,
    target: Value,
}

impl Timing {
    fn value(&self, commit_ms: u64) -> Value {
        let mut value = json!({
            "beginMs": self.begin_ms,
            "answerMs": self.answer_ms,
            "commitMs": commit_ms,
            "freezeMs": commit_ms.saturating_sub(self.begin_ms),
            "carriedRunningTurn": self.carried,
        });
        if let (Some(out), Some(target)) = (value.as_object_mut(), self.target.as_object()) {
            for key in ["dialMs", "pages", "pageBytes", "pagesMs", "finishMs", "via"] {
                if let Some(value) = target.get(key) {
                    out.insert(key.to_owned(), value.clone());
                }
            }
        }
        value
    }
}

/// The chat's history staged on the hub target `daemon` before the freeze, when it can be; None
/// (a whole move) on any failure, an old target included (it refuses the stage).
async fn precopy(src: &Client, id: &str, daemon: &str) -> Option<Staged> {
    let status = src.request(method::MUX_STATUS, json!({})).await.ok()?;
    if !super::super::transfer::lists_precopy(&status, "/capabilities") {
        return None;
    }
    let ask = json!({"sessionId": id, "stage": {"daemon": daemon}});
    let staged = src.request("_acpmux/transfer_hub", ask).await.ok()?;
    Some(Staged {
        prepare_id: field(&staged, "prepareId").as_str()?.to_owned(),
        after_seq: field(&staged, "afterSeq").as_u64()?,
        stage_id: field(&staged, "stageId").as_str()?.to_owned(),
        history_later: false,
    })
}

impl Moving<'_> {
    /// Freezes the chat (after `staged`, when the source still holds it as staged), sends op
    /// `move` and waits for the target's answer: the request sent and its answer. A refusal or a
    /// failure before the send gives the chat back.
    async fn run(
        &self,
        daemon: &str,
        host: &str,
        staged: Option<&Staged>,
    ) -> Result<(Value, Value, Timing)> {
        let Moving { src, id, args, home, home_text, cwd } = *self;
        let (id, leave_dirty) = (id.to_owned(), args.leave_dirty);
        let started = std::time::Instant::now();
        let started_at = crate::store::now_ms();
        let to = json!({"hub": daemon, "host": host});
        let running = (args.interrupt, args.after_turn);
        use super::super::transfer as t;
        // The hub carries the move: this end is the source's daemon here, asked on one
        // connection. A staged prefix the source no longer holds as staged is sent whole
        // (`begin_staged`).
        let turn_bound = args.after_turn.then_some(args.turn_timeout);
        let src_end = &mut MoveEnd::new("source", src, None);
        let begun = if args.interrupt || args.after_turn {
            t::begin_staged(src_end, &id, Some(to), running, staged, turn_bound).await?
        } else {
            t::begin_move_live(src_end, &id, Some(to), t::TOOL_WAIT, staged).await?
        };
        let carried = begun.begin.get("continues").is_some_and(|c| !c.is_null());
        let made = async {
            // Read again now that the chat is frozen: it may have changed before the freeze.
            let checkout = checkout_unless_named(cwd, args, &Source::Here).await?;
            let folder = plan::plan_folder(
                cwd,
                home,
                checkout.as_ref(),
                home_text,
                leave_dirty,
                args.cwd.as_deref(),
            )
            .map_err(|e| anyhow!(e))?;
            let mut sent = json!({"sessionId": id, "transferId": begun.transfer_id,
                                  "epoch": begun.epoch, "manifest": begun.begin,
                                  "folder": folder_value(&folder, home, args.cwd.is_some())?,
                                  "host": host});
            if let Some(stage_id) = &begun.stage_id {
                sent.set("stageId", json!(stage_id));
            }
            if let (Folder::Worktree { branch, dirty, .. }, Some(c)) = (&folder, &checkout) {
                let commit = tokio::task::spawn_blocking({
                    let (top, branch) = (c.top.clone(), branch.clone());
                    move || push_branch(&top, &branch)
                })
                .await??;
                sent.set("branch", json!(branch));
                sent.set("commit", json!(commit));
                if *dirty {
                    sent.set("uncommittedLeftOn", json!(crate::pairing::machine_name()));
                }
            }
            Ok::<Value, anyhow::Error>(sent)
        }
        .await;
        let sent = match made {
            Ok(sent) => sent,
            Err(e) => {
                super::super::transfer::abort_move(src_end, &id, &begun).await;
                return Err(e);
            }
        };
        match src.request("_acpmux/transfer_hub", sent.clone()).await {
            Ok(answer) => {
                let answer_ms = elapsed_ms(started);
                let moved = field(&answer, "moved");
                let target_timings = moved.get("timings").cloned().unwrap_or_else(|| json!({}));
                let begin_ms = begun
                    .begin
                    .get("freezeStartedAtMs")
                    .and_then(Value::as_u64)
                    .map(|at| at.saturating_sub(started_at))
                    .map(|at| at.min(answer_ms))
                    // Older daemons do not expose the fence marker. The move request's
                    // beginning is the only honest lower bound in that case. Do not report the
                    // target answer as the freeze boundary.
                    .unwrap_or(0);
                Ok((
                    sent,
                    answer,
                    Timing { started, begin_ms, answer_ms, carried, target: target_timings },
                ))
            }
            Err(e) => {
                let data =
                    e.downcast_ref::<crate::client::DaemonError>().and_then(|d| d.0.data.clone());
                if data.as_ref().is_some_and(|d| d["refused"] == true) {
                    super::super::transfer::abort_move(src_end, &id, &begun).await;
                    return Err(e);
                }
                bail!(
                    "{e:#}; the chat stays frozen here until {host} answers (its move ends on its own if it never does)"
                );
            }
        }
    }
}

/// Whether a hub move takes a running turn along: always for a real move (the begin stops it
/// between tool calls, `--after-turn` waits for it, `--interrupt` stops it now), as the ssh
/// route does; a dry run only reports it.
fn hub_running_ok(args: &MoveArgs) -> bool {
    args.interrupt || args.after_turn || !args.dry_run
}

/// `v[k]` without the indexing lint: Null when absent.
fn field<'a>(v: &'a Value, k: &str) -> &'a Value {
    v.get(k).unwrap_or(&Value::Null)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(interrupt: bool, after_turn: bool, dry_run: bool) -> MoveArgs {
        MoveArgs {
            sessions: vec![],
            host: "vm-b".into(),
            all_idle: false,
            interrupt,
            after_turn,
            turn_timeout: std::time::Duration::from_secs(60),
            leave_dirty: false,
            carry_changes: false,
            cwd: None,
            dry_run,
            resume_there: false,
            from: None,
            slow_ok: false,
            from_snapshot: false,
            as_harness: None,
        }
    }

    /// Leo: "any chat moves Mac↔Cloud and back in one action, keeping its live state". A hub move
    /// of a chat mid-turn takes the turn along, as an ssh move does, instead of refusing it.
    #[test]
    fn a_hub_move_takes_a_running_turn_along() {
        let running = json!({"status": "running", "turn": {"id": "t1"}});
        assert_eq!(plan::refusal(&running, hub_running_ok(&args(false, false, false))), None);
        assert_eq!(plan::refusal(&running, hub_running_ok(&args(true, false, false))), None);
        assert_eq!(plan::refusal(&running, hub_running_ok(&args(false, true, false))), None);
        // A dry run only reports the running turn, as over ssh.
        assert!(plan::refusal(&running, hub_running_ok(&args(false, false, true))).is_some());
    }

    #[test]
    fn a_hub_move_says_whether_it_carried_the_running_turn() {
        let timing = |carried| Timing {
            started: std::time::Instant::now(),
            begin_ms: 10,
            answer_ms: 50,
            carried,
            target: json!({"via": "circuit"}),
        };
        let carried = timing(true).value(80);
        assert_eq!(carried["carriedRunningTurn"], true);
        assert_eq!(carried["freezeMs"], 70);
        assert_eq!(carried["via"], "circuit");
        assert_eq!(timing(false).value(80)["carriedRunningTurn"], false);
    }

    #[test]
    fn a_hub_move_names_its_folder_as_the_target_can_make_it() {
        let home = Path::new("/home/me");
        let plain = Folder::Plain { cwd: "/home/me/notes/a".into() };
        assert_eq!(folder_value(&plain, home, false).unwrap(), json!({"home": "notes/a"}));
        assert_eq!(folder_value(&plain, home, true).unwrap(), json!({"cwd": "/home/me/notes/a"}));
        let outside = Folder::Plain { cwd: "/srv/x".into() };
        assert!(folder_value(&outside, home, false).is_err());
        let tree = Folder::Worktree {
            repo: "o/n".into(),
            url: "https://github.com/o/n.git".into(),
            branch: "lane/x".into(),
            subdir: "sub".into(),
            dirty: false,
            snapshot: false,
        };
        assert_eq!(
            folder_value(&tree, home, false).unwrap(),
            json!({"repo": "o/n", "url": "https://github.com/o/n.git", "branch": "lane/x", "subdir": "sub"})
        );
    }
}
