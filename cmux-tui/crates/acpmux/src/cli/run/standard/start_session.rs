//! Local and peer creation for `cmux chat new` and the legacy acpmux launcher.
//! Both arrive with the same parsed arguments and pass the same checks before create.

use super::*;
use cmux_json::JsonSet as _;
use std::io::IsTerminal as _;

pub(super) async fn run(
    args: NewArgs,
    json_out: bool,
    suppress_reads: bool,
    deadline: Option<tokio::time::Instant>,
) -> Result<()> {
    if args.parent.is_some() {
        return crate::cli::run::parent::run(args, json_out, deadline).await;
    }
    // A detached named launch shares the public chat launch budget. Preserve an explicit
    // caller deadline and never apply the implicit startup limit to a model's reply.
    let reply_deadline = deadline;
    let deadline = deadline.or_else(|| {
        (args.detach && args.host.is_some())
            .then(|| tokio::time::Instant::now() + crate::launch_contract::NAMED_START_LIMIT)
    });
    // Checked before connecting, so the error needs no daemon. Preparing first preserves
    // launch-file semantics and rejects whitespace-only prompt words like `new "  "`.
    let (args, launch) = launch::Launch::before_create(args, deadline).await?;
    // A promptless `new` opens the full-screen TUI. In a pipe (the
    // common agent/scripting case), refuse before connecting so the
    // caller gets an immediate, stable usage error.
    if new_requires_tty(
        json_out,
        args.prompt.join(" ").trim().is_empty() && launch.file_prompt.is_none(),
        args.detach,
        std::io::stdin().is_terminal(),
        std::io::stdout().is_terminal(),
    ) {
        return Err(errors::AppError::usage(
            "acpmux new without a prompt needs a terminal; pass a prompt or -d",
        )
        .into());
    }
    // A name that reads as an id gets a one-line hint; it is never refused.
    if let Some(hint) = launch.name.as_deref().and_then(crate::session_name::naming_hint) {
        eprintln!("{hint}");
    }
    let setup_name = launch.name.as_deref().unwrap_or("new");
    let mut client = before_deadline(deadline, setup_name, connect(true)).await?;
    // A machine a person works at places command-line sessions on a fleet host
    // (`cli/place.rs` `new_target`); the app's chats never come through here.
    let interactive = crate::cli::place::here_is_interactive();
    let folder_named = args.cwd.is_some() || launch.worktree.is_some();
    let target = crate::cli::place::new_target(args.host.as_deref(), interactive, folder_named);
    let host = match target {
        crate::cli::place::Target::Place(work) => {
            before_deadline(
                deadline,
                setup_name,
                crate::cli::place::resolve(
                    &client,
                    work,
                    launch.name.as_deref(),
                    launch.reuse,
                    interactive,
                    args.host.is_none(),
                ),
            )
            .await?
        }
        crate::cli::place::Target::Host(h) => Some(h),
        crate::cli::place::Target::Here => None,
        crate::cli::place::Target::HereForFolder => {
            eprintln!("{}", crate::cli::place::FOLDER_HERE);
            None
        }
    };
    let cwd = match &launch.worktree {
        Some((_, repo)) => Some(repo.clone()),
        None => new_session_cwd(host.as_deref(), args.cwd.clone())?,
    };
    let mut meta = json!({});
    if let Some(spec) = &args.model {
        let (h, m) = orchestrate::split_target(spec);
        meta["harness"] = json!(h);
        if let Some(m) = m {
            meta["model"] = json!(m);
        }
    }
    if let Some(p) = &args.preset {
        meta["preset"] = json!(p);
    }
    if let Some(h) = &host {
        meta["peer"] = json!(h);
    }
    if args.force_admit {
        meta["forceAdmit"] = json!(true);
    }
    if let Some(n) = &launch.name {
        meta.set("name", json!(n));
    }
    if let Some(p) = &args.policy {
        meta["policy"] = json!(p);
    }
    if let Some(m) = &args.mode {
        meta["mode"] = json!(m);
    }
    if args.require_asking {
        // A daemon that does not list it would start the session unchecked.
        if !client.daemon_lists(crate::hub::require_asking::FEATURE) {
            anyhow::bail!(
                "the running acpmux daemon is older than this CLI and cannot refuse a \
                 start that would not ask, so nothing started; run `acpmux daemon \
                 restart`, then try again"
            );
        }
        meta.set(crate::hub::require_asking::FIELD, json!(true));
    }
    if let Some(e) = &args.effort {
        meta["effort"] = json!(e);
    }
    launch::successor_meta(&args, &mut meta);
    meta["argv"] = json!(crate::cli::entry::original_args());
    if let Some(prompt) = &launch.file_prompt {
        meta["promptFileText"] = json!(prompt);
    }
    if !args.tags.is_empty() {
        meta["tags"] = orchestrate::parse_tags(&args.tags)?;
    }
    // A detached launch only queues its prompt, with --json too. Known
    // before the create (a prompt file or words make the first prompt).
    let one_shot = launch.first_prompt(&args, &Value::Null).is_some()
        && (args.quiet || json_out || args.ephemeral)
        && !(args.detach && launch.launches());
    // Checked before the session exists, so a bad value leaves none behind.
    let on_permission = OnPermission::parse(&args.on_permission)?;
    // A route check an agent runs from its shell ("Reply with only: OK",
    // `probe_prompt.rs`) is a throwaway, never the agent's subagent: a one-shot
    // one goes as an ephemeral chat does once its reply is printed. A named
    // one is kept, since the agent may check a worker is up before giving it
    // its task; only `--ephemeral` purges that.
    let probe = std::env::var("ACPMUX_SESSION_ID").is_ok_and(|id| !id.is_empty())
        && crate::probe_prompt::is_probe(&args.prompt.join(" "));
    let ephemeral = one_shot && (args.ephemeral || (probe && args.name.is_none()));
    // The daemon purges an ephemeral session when this connection ends
    // (`server/ephemeral.rs`), however the CLI exits: killed during the
    // turn, by a caller's timeout, or a lost connection. The kill after
    // the reply below stays the normal path.
    if ephemeral {
        meta["ephemeral"] = json!(true);
    }
    if let Some((w, _)) = &launch.worktree {
        meta["worktree"] = w.clone();
    }
    if let Some(tools) = launch.disallowed_tools() {
        meta["disallowedTools"] = tools;
    }
    // A session of this name already running is the one asked for:
    // found before the create, or after losing the create to another
    // launcher with the same name.
    let key = launch.name.as_ref().map(|n| match &host {
        Some(h) => format!("{h}/{n}"),
        None => n.clone(),
    });
    let mut p = json!({"mcpServers": [], "_meta": {"acpmux": meta}});
    if let Some(cwd) = &cwd {
        p["cwd"] = json!(cwd);
    }
    let parentless = ephemeral || probe || args.no_parent;
    // A daemon restarted while this create waits (the app's keyed acpmux
    // start, a machine update) closes the connection with no reply, and the
    // create may already have happened. A named `--reuse` launch reconnects
    // and runs the whole find-or-create again, so it finds that session and
    // never makes a second one; a handover can happen twice in a row
    // (systemd's daemon taking over one the CLI started), hence two tries.
    // Without a name to find it by, a retry could make a duplicate: no retry,
    // except after the daemon's shutdown refused the create before making
    // anything (`refused_before_create`): a self-update's restart, or one on a
    // failing disk, then never fails a new session.
    let mut reconnects = 0;
    let (v, reused, lost_race) = loop {
        match find_or_create(
            &client,
            deadline,
            setup_name,
            key.as_deref().filter(|_| launch.reuse),
            p.clone(),
            parentless,
        )
        .await
        {
            Err(error)
                if reconnects < NEW_RECONNECTS
                    && ((launch.reuse && key.is_some() && daemon_closed_error(&error))
                        || refused_before_create(&error)) =>
            {
                reconnects += 1;
                client = before_deadline(deadline, setup_name, reconnect_after_update()).await?;
            }
            found => break found?,
        }
    };
    let id = crate::cli::resolve::routed_id(&v)?;
    let session_id = v["sessionId"].as_str().unwrap_or_default();
    let session_id = v["peer"]
        .as_str()
        .and_then(|peer| session_id.strip_prefix(&format!("{peer}/")))
        .unwrap_or(session_id);
    // Keep the host-qualified route for every follow-up request. A peer may
    // legitimately return the same raw id as a local session; using the raw id
    // here would send prompts, info and lifecycle controls to the local chat.
    let route_id = id.as_str();
    if reused.is_none() {
        launch::print_new_warnings(&v);
    }
    let name = v
        .pointer("/_meta/acpmux/name")
        .or_else(|| v.get("name"))
        .and_then(Value::as_str)
        .unwrap_or(session_id)
        .to_owned();
    let print_detached_link = |record: &Value| {
        if args.detach
            && !json_out
            && let Some(link) =
                crate::agent_link::AgentLink::from_start_record(record, host.as_deref(), &name)
        {
            println!("{link}");
        }
    };
    // A failed sidebar step is an error after the session has been
    // created, so scripts can retry only the exact open command.
    let daemon_cli_path = client.daemon_cli_path();
    let show = || -> Result<()> {
        if let Some(group) = &args.group {
            // Only explicit names opt into the app's predecessor-row reuse.
            // Generated names can be identical on independent peers.
            let title = launch.name.as_ref().map(|_| launch.title.as_deref().unwrap_or(&name));
            // An unnamed launch still names its workspace for the session (never
            // `workspace-N`), through an argument that reuses no predecessor row.
            let peer = v.get("peer").and_then(Value::as_str);
            let default_name = launch::default_workspace_name(&name, session_id, peer);
            launch::show_in_group(
                &id,
                &name,
                title,
                default_name.as_deref(),
                group,
                daemon_cli_path.as_deref(),
                deadline,
            )?;
        }
        Ok(())
    };
    if let Some(info) = &reused {
        launch::check_reusable(info, &name, launch.worktree.as_ref().map(|(_, r)| r.as_path()))?;
        // Its first prompt went with the first run and is not sent
        // twice, unless that run stopped before sending it.
        let first =
            launch.first_prompt(&args, &v).filter(|_| !lost_race && launch::never_prompted(info));
        if let Some(text) = &first {
            let prompt = first_prompt_id(&args);
            let accepted = before_deadline(
                deadline,
                route_id,
                queue_prompt(client, route_id, text, false, None, &prompt),
            )
            .await?;
            if !json_out {
                warn_host_pressure(&accepted);
            }
        }
        show()?;
        if json_out {
            let mut info = info.clone();
            info["reused"] = json!(true);
            info["prompted"] = json!(first.is_some());
            print_json(&crate::cli::output::session_record(info, args.full));
        } else if first.is_some() {
            println!(
                "reused {name} ({}): it had no prompt yet, so its first prompt is queued",
                session_id.get(..8).unwrap_or(session_id)
            );
        } else {
            println!(
                "reused {name} ({}): it already runs, so the prompt was not sent again; \
                 use `acpmux send {name}` to give it more",
                session_id.get(..8).unwrap_or(session_id)
            );
        }
        print_detached_link(info);
        return Ok(());
    }
    let first = launch.first_prompt(&args, &v);
    // A detached launch must already have its instructions if the CLI
    // is interrupted while the app is opening its workspace.
    let queue_before_open = args.detach && !one_shot;
    if queue_before_open && let Some(text) = &first {
        let prompt = first_prompt_id(&args);
        let accepted = before_deadline(
            deadline,
            route_id,
            queue_prompt(client.clone(), route_id, text, false, None, &prompt),
        )
        .await?;
        if !json_out {
            warn_host_pressure(&accepted);
        }
    }
    if let Err(mut open_error) = show() {
        if !queue_before_open && let Some(text) = &first {
            let prompt = first_prompt_id(&args);
            if let Err(error) = before_deadline(
                deadline,
                route_id,
                queue_prompt(client.clone(), route_id, text, false, None, &prompt),
            )
            .await
            {
                open_error = anyhow!("{open_error}; first prompt was not confirmed: {error}");
            }
        }
        if ephemeral
            && host.is_none()
            && let Err(error) = before_deadline(
                deadline,
                route_id,
                client.request(method::MUX_KEEP, json!({"sessionId": route_id})),
            )
            .await
        {
            open_error = anyhow!(
                "{open_error}; the ephemeral session could not be retained: {error}; retry the launch without --ephemeral"
            );
        }
        return Err(open_error);
    }
    if json_out && !one_shot {
        let mut info = before_deadline(deadline, route_id, async {
            Ok(client
                .request(method::MUX_INFO, json!({"sessionId": route_id}))
                .await
                .unwrap_or(v.clone()))
        })
        .await?;
        if let Some(w) = v.pointer("/_meta/acpmux/worktree") {
            info["worktree"] = w.clone();
        }
        if let Some(a) = v.pointer("/_meta/acpmux/admission") {
            info["admission"] = a.clone();
        }
        print_json(&crate::cli::output::session_record(info, args.full));
    } else if !one_shot {
        let folder = v.pointer("/_meta/acpmux/cwd").and_then(Value::as_str);
        let line =
            crate::cli::session_folder::created_line(&name, session_id, host.as_deref(), folder);
        println!("{line}");
        print_detached_link(&v);
        if let Some(w) = v.pointer("/_meta/acpmux/worktree") {
            let g = |k: &str| w.get(k).and_then(Value::as_str).unwrap_or_default();
            println!("  worktree {} on {} from {}", g("root"), g("branch"), g("base"));
        }
        // Before it works: an allow it asks for is the app's alone.
        if on_permission == OnPermission::Wait
            && let Ok(info) = before_deadline(deadline, route_id, async {
                Ok(client.request(method::MUX_INFO, json!({"sessionId": route_id})).await)
            })
            .await?
            && let Some(note) = crate::question_answer::app_allow_note(&info, &name)
        {
            eprintln!("{note}");
        }
    }
    let deadline = reply_deadline;
    if let Some(text) = first {
        let prompt = first_prompt_id(&args);
        if one_shot {
            let opts = CollectOpts {
                timeout: args.timeout,
                deadline,
                on_permission,
                stall_secs: args.stall,
                retries: args.retries,
                steer: false,
            };
            let outcome = collect_reply(client.clone(), route_id, &text, opts, &prompt).await;
            if ephemeral {
                let _ = before_deadline(
                    deadline,
                    route_id,
                    client.request(method::MUX_KILL, json!({"sessionId": route_id, "purge": true})),
                )
                .await;
            }
            let r = outcome?;
            if json_out {
                let mut out = json!({"sessionId": session_id, "name": name, "reply": r.reply, "stopReason": r.stop_reason, "permissions": r.permissions_asked, "permissionsDenied": r.permissions_denied, "ephemeral": ephemeral});
                if v["peer"].is_string() {
                    out["peer"] = v["peer"].clone();
                    out["qualifiedSessionId"] = json!(id);
                }
                if let Some(a) = v.pointer("/_meta/acpmux/admission") {
                    out["admission"] = a.clone();
                }
                print_json(&out);
            } else {
                println!("{}", r.reply);
            }
            return Ok(());
        }
        if args.detach {
            return Ok(());
        }
        let opts = CollectOpts {
            timeout: args.timeout,
            deadline,
            on_permission,
            stall_secs: args.stall,
            retries: args.retries,
            steer: false,
        };
        return stream_prompt(
            client,
            route_id,
            &text,
            false,
            false,
            json_out,
            opts,
            suppress_reads,
            &prompt,
        )
        .await;
    }
    if args.detach || json_out {
        return Ok(());
    }
    crate::tui_entry::run(client, Some(route_id.to_owned())).await
}
