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
    let daemon = machine["daemonId"].as_str().unwrap_or_default().to_owned();
    let host = machine["host"].as_str().unwrap_or(&args.host).to_owned();
    let mut outcomes = Vec::new();
    for key in ids {
        let mut o = Outcome {
            session: key.clone(),
            name: key.clone(),
            host: Some(host.clone()),
            cwd: None,
            moved: false,
            there: None,
            resumed: Ok(false),
            carried: None,
            error: None,
        };
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
                       "there": o.there, "error": o.error})
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
    })
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
        bail!("it runs on {}, not here: move it from there", info["peer"]);
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
    if args.dry_run {
        o.cwd = Some(match &planned {
            Folder::Plain { cwd } => cwd.clone(),
            Folder::Worktree { repo, branch, subdir, .. } => {
                format!("a worktree of {repo} {branch}{}", sub_text(subdir))
            }
        });
        return Ok(());
    }
    let to = json!({"hub": daemon, "host": host});
    let begun =
        super::super::transfer::begin_move(src, &id, Some(to), (args.interrupt, args.after_turn))
            .await?;
    let made = async {
        // Read again now that the chat is frozen: it may have changed before the freeze.
        let checkout = checkout_unless_named(&cwd, args, &Source::Here).await?;
        let folder = plan::plan_folder(
            &cwd,
            &home,
            checkout.as_ref(),
            &home_text,
            leave_dirty,
            args.cwd.as_deref(),
        )
        .map_err(|e| anyhow!(e))?;
        let mut sent = json!({"sessionId": id, "transferId": begun.transfer_id,
                              "epoch": begun.epoch, "manifest": begun.begin,
                              "folder": folder_value(&folder, &home, args.cwd.is_some())?});
        if let (Folder::Worktree { branch, dirty, .. }, Some(c)) = (&folder, &checkout) {
            let commit = tokio::task::spawn_blocking({
                let (top, branch) = (c.top.clone(), branch.clone());
                move || push_branch(&top, &branch)
            })
            .await??;
            sent["branch"] = json!(branch);
            sent["commit"] = json!(commit);
            if *dirty {
                sent["uncommittedLeftOn"] = json!(crate::pairing::machine_name());
            }
        }
        Ok::<Value, anyhow::Error>(sent)
    }
    .await;
    let sent = match made {
        Ok(sent) => sent,
        Err(e) => {
            super::super::transfer::abort_move(src, &id, &begun).await;
            return Err(e);
        }
    };
    let answer = match src.request("_acpmux/transfer_hub", sent.clone()).await {
        Ok(answer) => answer,
        Err(e) => {
            let data =
                e.downcast_ref::<crate::client::DaemonError>().and_then(|d| d.0.data.clone());
            if data.as_ref().is_some_and(|d| d["refused"] == true) {
                super::super::transfer::abort_move(src, &id, &begun).await;
                return Err(e);
            }
            bail!(
                "{e:#}; the chat stays frozen here until {host} answers (its move ends on its own if it never does)"
            );
        }
    };
    let moved = &answer["moved"];
    let mut to_meta = json!({"host": host, "via": "hub", "daemonId": daemon,
                             "sessionId": moved.get("sessionId").cloned().unwrap_or(json!(id)),
                             "cwd": moved["cwd"]});
    for key in ["branch", "commit", "uncommittedLeftOn"] {
        if let Some(v) = sent.get(key) {
            to_meta[key] = v.clone();
        }
    }
    src.request(
        "_acpmux/transfer_commit",
        json!({"sessionId": id, "transferId": begun.transfer_id, "to": to_meta,
               "epoch": begun.epoch}),
    )
    .await?;
    o.moved = true;
    o.cwd = moved["cwd"].as_str().map(str::to_owned);
    o.there = moved["sessionId"].as_str().map(str::to_owned);
    Ok(())
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
        };
        assert_eq!(
            folder_value(&tree, home, false).unwrap(),
            json!({"repo": "o/n", "url": "https://github.com/o/n.git", "branch": "lane/x", "subdir": "sub"})
        );
    }
}
