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

pub(super) async fn run(
    src: &Client,
    ids: &[String],
    args: &MoveArgs,
    home: &Path,
    json_out: bool,
) -> Result<()> {
    if args.carry_changes {
        bail!("--carry-changes does not go through the team hub yet: commit, or --leave-dirty");
    }
    let machine =
        src.request("_acpmux/transfer_hub", json!({"resolve": args.host})).await.map_err(|e| {
            anyhow!(
                "{} is neither an ssh peer of this daemon nor a machine the team hub lists: {e:#}",
                args.host
            )
        })?;
    let daemon = field(&machine, "daemonId").as_str().unwrap_or_default().to_owned();
    let host = field(&machine, "host").as_str().unwrap_or(&args.host).to_owned();
    let mut outcomes = Vec::new();
    for key in ids {
        let mut o = Outcome::new(key);
        o.host = Some(host.clone());
        if let Err(e) = steps(src, key, args, home, &daemon, &host, &mut o).await {
            o.error = Some(format!("{e:#}"));
        }
        if !json_out {
            print_outcome(&o, args.dry_run);
        }
        outcomes.push(o);
    }
    let failed = outcomes.iter().filter(|o| o.error.is_some()).count();
    if json_out {
        let rows: Vec<Value> = outcomes
            .iter()
            .map(|o| {
                json!({"sessionId": o.session, "name": o.name, "host": o.host, "cwd": o.cwd,
                       "moved": o.moved, "dryRun": args.dry_run, "via": "hub",
                       "there": o.there, "targetSessionId": o.there,
                       "error": o.error})
            })
            .collect();
        print_json(&json!({"moves": rows, "failed": failed}));
    }
    if failed > 0 {
        bail!("{failed} of {} chats did not move", outcomes.len());
    }
    Ok(())
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

/// Why a checkout with no `origin` does not move over the hub: the target makes the folder
/// itself from a remote, and the git bundle that carries such a checkout goes over ssh only.
fn no_origin_over_the_hub(top: &str) -> String {
    format!(
        "{top} has no origin, and a checkout with no remote does not move through the team hub \
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
    o: &mut Outcome,
) -> Result<()> {
    let id = resolve_id(src, key).await?;
    o.session = id.clone();
    let info = src.request(method::MUX_INFO, json!({"sessionId": id})).await?;
    o.name = info.get("name").and_then(Value::as_str).unwrap_or(&id).to_owned();
    if info.get("peer").is_some_and(|p| !p.is_null()) {
        bail!("it runs on {}, not here: move it from there", field(&info, "peer"));
    }
    if let Some(why) = plan::refusal(&info, args.interrupt || args.after_turn) {
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
    let (sent, answer) = match moving.run(daemon, host, staged.as_ref()).await {
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
    o.moved = true;
    o.cwd = moved["cwd"].as_str().map(str::to_owned);
    o.there = moved["sessionId"].as_str().map(str::to_owned);
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
    ) -> Result<(Value, Value)> {
        let Moving { src, id, args, home, home_text, cwd } = *self;
        let (id, leave_dirty) = (id.to_owned(), args.leave_dirty);
        let to = json!({"hub": daemon, "host": host});
        let running = (args.interrupt, args.after_turn);
        use super::super::transfer as t;
        // The hub carries the move: this end is the source's daemon here, asked on one
        // connection. A staged prefix the source no longer holds as staged is sent whole
        // (`begin_staged`).
        let src_end = &mut MoveEnd::new("source", src, None);
        let begun = t::begin_staged(src_end, &id, Some(to), running, staged, None).await?;
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
                                  "folder": folder_value(&folder, home, args.cwd.is_some())?});
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
            Ok(answer) => Ok((sent, answer)),
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

/// `v[k]` without the indexing lint: Null when absent.
fn field<'a>(v: &'a Value, k: &str) -> &'a Value {
    v.get(k).unwrap_or(&Value::Null)
}

#[cfg(test)]
mod tests {
    use super::*;

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
