//! Owns the primary session and prompt command dispatch arms.

use super::*;
use cmux_json::JsonSet as _;
use std::io::IsTerminal;
use std::sync::Arc;

pub(super) fn handles(cmd: &Command) -> bool {
    matches!(
        cmd,
        Command::Dispatch(..)
            | Command::Briefs(..)
            | Command::Wait { .. }
            | Command::Ensure { .. }
            | Command::Continue(..)
            | Command::History { .. }
            | Command::TagCmd { .. }
            | Command::RulesCmd { .. }
            | Command::Compare { .. }
            | Command::Preset { .. }
            | Command::Models { .. }
            | Command::Reload
            | Command::Schema
            | Command::Defaults { .. }
            | Command::Skill
            | Command::Last { .. }
            | Command::Pending
            | Command::Ls(..)
            | Command::New(..)
            | Command::Send { .. }
            | Command::Inbox(..)
            | Command::Deliver { .. }
            | Command::Chats(..)
            | Command::Process(..)
            | Command::Worktree(..)
            | Command::Attach { .. }
            | Command::Tail { .. }
            | Command::Info { .. }
    )
}

pub(super) async fn run(cmd: Command, json_out: bool, suppress_reads: bool) -> Result<()> {
    let deadline = caller_deadline(match &cmd {
        Command::New(args) => args.timeout,
        Command::Send { timeout, .. } => *timeout,
        _ => None,
    })?;
    match cmd {
        Command::Dispatch(args) => dispatch(connect(true).await?, args, json_out).await,
        Command::Briefs(cmd) => briefs(connect(true).await?, cmd, json_out).await,
        Command::Wait {
            sessions,
            timeout,
            all,
            any: _,
            print,
            until,
            match_text,
            regex,
            notify,
        } => {
            let client = connect(true).await?;
            let matcher = match (match_text, regex) {
                (Some(t), _) => Some(orchestrate::Matcher::Text(t)),
                (None, Some(r)) => {
                    Some(orchestrate::Matcher::Regex(regex::Regex::new(&r).map_err(|e| {
                        errors::AppError::new(errors::Code::Usage, "invalid_regex", e.to_string())
                    })?))
                }
                _ => None,
            };
            orchestrate::wait(
                client,
                orchestrate::WaitOpts { sessions, until, all, timeout, print, notify, matcher },
                json_out,
            )
            .await
        }
        Command::Ensure { name, model, preset, host, cwd, policy, effort, tags, harness_from } => {
            orchestrate::ensure(
                connect(true).await?,
                &name,
                model,
                preset,
                host,
                cwd,
                policy,
                effort,
                tags,
                harness_from,
                json_out,
            )
            .await
        }
        Command::Continue(args) => {
            crate::cli::handoff::run(connect(true).await?, args, json_out).await
        }
        Command::History { session, limit } => {
            orchestrate::history(connect(true).await?, &session, limit, json_out).await
        }
        Command::TagCmd { session, assignments, remove, ttl } => {
            orchestrate::tag(connect(true).await?, &session, assignments, remove, ttl, json_out)
                .await
        }
        Command::RulesCmd { session, rules, clear } => {
            orchestrate::rules(connect(true).await?, &session, rules, clear, json_out).await
        }
        Command::Compare { harnesses: agents, prompt, cwd, policy, timeout } => {
            let prompt = arg_or_stdin(&prompt)?;
            orchestrate::compare(
                connect(true).await?,
                agents,
                prompt,
                cwd,
                policy,
                timeout,
                json_out,
            )
            .await
        }
        Command::Preset { name, pairs, clear } => {
            orchestrate::preset(connect(true).await?, name, pairs, clear, json_out).await
        }
        Command::Models { refresh } => {
            let client = connect(true).await?;
            let v = client.request("_acpmux/models", json!({"refresh": refresh})).await?;
            if json_out {
                print_json(&v);
                return Ok(());
            }
            for h in v.get("harnesses").and_then(Value::as_array).into_iter().flatten() {
                let agent = h.get("harness").and_then(Value::as_str).unwrap_or("?");
                let ids: Vec<&str> = h
                    .get("models")
                    .and_then(Value::as_array)
                    .map(|a| a.iter().filter_map(|m| m.get("id").and_then(Value::as_str)).collect())
                    .unwrap_or_default();
                println!("{agent} ({})", ids.len());
                for id in ids {
                    println!("  {id}");
                }
            }
            Ok(())
        }
        Command::Reload => {
            let client = connect(true).await?;
            let v = client.request(method::MUX_RELOAD_CONFIG, json!({})).await?;
            if json_out {
                print_json(&v);
            } else {
                let count = v.get("harnesses").and_then(Value::as_array).map(Vec::len).unwrap_or(0);
                println!("reloaded catalog ({count} harnesses; existing sessions kept running)");
            }
            Ok(())
        }
        Command::Schema => {
            use std::io::Write;
            let _ = std::io::stdout().write_all(crate::schema::SCHEMA.as_bytes());
            Ok(())
        }
        Command::Defaults { family, pairs, clear } => {
            orchestrate::defaults(connect(true).await?, family, pairs, clear, json_out).await
        }
        Command::Skill => {
            use std::io::Write;
            let _ = std::io::stdout().write_all(orchestrate::guide().as_bytes());
            Ok(())
        }
        Command::Last { session, count } => {
            let client = connect(true).await?;
            let id = resolve_id(&client, &session).await?;
            let replies = last_replies(&client, &id, count).await?;
            if json_out {
                print_json(&json!({"sessionId": id, "replies": replies}));
            } else {
                for (i, r) in replies.iter().enumerate() {
                    if i > 0 {
                        println!("\n---\n");
                    }
                    println!("{r}");
                }
            }
            Ok(())
        }
        Command::Pending => {
            let client = connect(true).await?;
            let v = client.whole_list(method::MUX_SESSIONS, json!({})).await?;
            let mut out = Vec::new();
            for s in v.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default() {
                if s.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0) == 0 {
                    continue;
                }
                let id = s.get("sessionId").and_then(Value::as_str).unwrap_or("").to_owned();
                let name = s.get("name").and_then(Value::as_str).unwrap_or("").to_owned();
                let d = client.request(method::MUX_INFO, json!({"sessionId": id})).await?;
                for p in d.get("pending").and_then(Value::as_array).cloned().unwrap_or_default() {
                    let req = p.get("request").cloned().unwrap_or(Value::Null);
                    let title = req
                        .pointer("/toolCall/title")
                        .and_then(Value::as_str)
                        .unwrap_or("permission")
                        .to_owned();
                    let kind = req
                        .pointer("/toolCall/kind")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_owned();
                    let options: Vec<Value> =
                        req.get("options").and_then(Value::as_array).cloned().unwrap_or_default();
                    let hint = crate::question_answer::pending_hint(&req, &name);
                    let is_question = crate::question_answer::question(&req).is_some();
                    // The ask's Needs you link: an agent writes it in a reply instead of restating
                    // the ask, and the pane draws it as a chip that opens the list on this ask.
                    let needs_you = p
                        .get("permissionId")
                        .and_then(Value::as_str)
                        .map(|pid| format!("cmux://needs-you/{pid}"));
                    out.push(json!({"session": name, "sessionId": id, "permissionId": p.get("permissionId"), "title": title, "kind": kind, "options": options, "question": is_question, "answer": hint, "needsYou": needs_you}));
                }
            }
            if json_out {
                print_json(&json!({"pending": out}));
            } else if out.is_empty() {
                println!("no pending permissions");
            } else {
                for p in &out {
                    let g = |k: &str| p.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
                    println!(
                        "{:<24} {} [{}]  answer: {}",
                        g("session"),
                        g("title"),
                        g("kind"),
                        g("answer")
                    );
                }
            }
            Ok(())
        }
        Command::Ls(args) => super::ls::run(args, json_out).await,
        Command::New(args) if args.parent.is_some() => {
            super::parent::run(*args, json_out, deadline).await
        }
        Command::New(args) => {
            let args = *args;
            // Checked before connecting, so the error needs no daemon. Preparing first preserves
            // launch-file semantics and rejects whitespace-only prompt words like `new "  "`.
            let launch = launch::Launch::prepare(&args)?;
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
            let setup_name = launch.name.as_deref().unwrap_or("new");
            let client = before_deadline(deadline, setup_name, connect(true)).await?;
            // A machine a person works at places command-line sessions on a fleet host
            // (`cli/place.rs` `new_target`); the app's chats never come through here.
            let interactive = crate::cli::place::here_is_interactive();
            let folder_named = args.cwd.is_some() || launch.worktree.is_some();
            let target =
                crate::cli::place::new_target(args.host.as_deref(), interactive, folder_named);
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
            let mut reused = None;
            // Found after a lost create: the winner sends the first prompt.
            let mut lost_race = false;
            if launch.reuse
                && let Some(key) = &key
            {
                reused = before_deadline(deadline, key, launch::existing(&client, key)).await?;
            }
            let mut p = json!({"mcpServers": [], "_meta": {"acpmux": meta}});
            if let Some(cwd) = &cwd {
                p["cwd"] = json!(cwd);
            }
            let v = match reused.clone() {
                Some(info) => info,
                None => match if ephemeral || probe || args.no_parent {
                    before_deadline(
                        deadline,
                        setup_name,
                        client.request_parentless(method::SESSION_NEW, p),
                    )
                    .await
                } else {
                    before_deadline(deadline, setup_name, client.request(method::SESSION_NEW, p))
                        .await
                } {
                    Ok(v) => v,
                    Err(e) => {
                        let found = match &key {
                            Some(key) if launch.reuse && launch::name_taken(&e) => {
                                before_deadline(deadline, key, launch::existing(&client, key))
                                    .await?
                            }
                            _ => None,
                        };
                        reused = Some(found.ok_or(e)?);
                        lost_race = true;
                        reused.clone().unwrap_or_default()
                    }
                },
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
            // A failed sidebar step is an error after the session has been
            // created, so scripts can retry only the exact open command.
            let daemon_cli_path = client.daemon_cli_path();
            let show = || -> Result<()> {
                if let Some(group) = &args.group {
                    // Only explicit names opt into the app's predecessor-row reuse.
                    // Generated names can be identical on independent peers.
                    let title =
                        launch.name.as_ref().map(|_| launch.title.as_deref().unwrap_or(&name));
                    launch::show_in_group(
                        &id,
                        &name,
                        title,
                        group,
                        daemon_cli_path.as_deref(),
                        deadline,
                    )?;
                }
                Ok(())
            };
            if let Some(info) = &reused {
                launch::check_reusable(
                    info,
                    &name,
                    launch.worktree.as_ref().map(|(_, r)| r.as_path()),
                )?;
                // Its first prompt went with the first run and is not sent
                // twice, unless that run stopped before sending it.
                let first = launch
                    .first_prompt(&args, &v)
                    .filter(|_| !lost_race && launch::never_prompted(info));
                if let Some(text) = &first {
                    let prompt = PromptId::new(args.prompt_id.clone());
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
                    print_json(&info);
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
                return Ok(());
            }
            let first = launch.first_prompt(&args, &v);
            // A detached launch must already have its instructions if the CLI
            // is interrupted while the app is opening its workspace.
            let queue_before_open = args.detach && !one_shot;
            if queue_before_open && let Some(text) = &first {
                let prompt = PromptId::new(args.prompt_id.clone());
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
                    let prompt = PromptId::new(args.prompt_id.clone());
                    if let Err(error) = before_deadline(
                        deadline,
                        route_id,
                        queue_prompt(client.clone(), route_id, text, false, None, &prompt),
                    )
                    .await
                    {
                        open_error =
                            anyhow!("{open_error}; first prompt was not confirmed: {error}");
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
                print_json(&info);
            } else if !one_shot {
                let folder = v.pointer("/_meta/acpmux/cwd").and_then(Value::as_str);
                let line = crate::cli::session_folder::created_line(
                    &name,
                    session_id,
                    host.as_deref(),
                    folder,
                );
                println!("{line}");
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
            if let Some(text) = first {
                let prompt = PromptId::new(args.prompt_id.clone());
                if one_shot {
                    let opts = CollectOpts {
                        timeout: args.timeout,
                        deadline,
                        on_permission,
                        stall_secs: args.stall,
                        retries: args.retries,
                        steer: false,
                    };
                    let outcome =
                        collect_reply(client.clone(), route_id, &text, opts, &prompt).await;
                    if ephemeral {
                        let _ = before_deadline(
                            deadline,
                            route_id,
                            client.request(
                                method::MUX_KILL,
                                json!({"sessionId": route_id, "purge": true}),
                            ),
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
            crate::tui::run(client, Some(route_id.to_owned())).await
        }
        Command::Send {
            session,
            prompt,
            steer,
            no_steer,
            no_wait,
            quiet,
            timeout,
            on_permission,
            stall,
            prompt_id,
            from,
            status,
            supersede,
            class,
            inbox,
            attach,
            tag,
            dry_run,
        } => {
            if let Some(delivery) = status {
                let client = before_deadline(deadline, &delivery, connect(true)).await?;
                return before_deadline(
                    deadline,
                    &delivery,
                    super::send_async::status(&client, &delivery, json_out),
                )
                .await;
            }
            let mut prompt_id = PromptId::new(prompt_id);
            prompt_id.from_agent = from.or_else(crate::cli::sender::of_this_process);
            prompt_id.cli_host = crate::cli::sender::person_host(prompt_id.from_agent.is_some());
            let superseding = supersede.is_some();
            prompt_id.supersede = supersede;
            let classed = class.is_some();
            prompt_id.class = class;
            (prompt_id.pr, prompt_id.thread) = (inbox.pr, inbox.thread);
            // An agent's send and a message (--no-wait) steer; the person's waiting send queues.
            let agent = crate::cli::sender::from_an_agent(prompt_id.from_agent.is_some());
            let mut steer = send_steers(steer, no_steer, no_wait, agent);
            if let Some(tag) = tag {
                if !attach.is_empty() {
                    return Err(errors::AppError::usage(
                        "send --tag carries text only, not --attach",
                    )
                    .into());
                }
                // No SESSION with --tag: clap read the prompt's first word as one.
                let words: Vec<String> = session.into_iter().chain(prompt).collect();
                let text = arg_or_stdin(&words)?;
                let steer = send_steers(false, no_steer, true, agent);
                return super::fanout::send_to_tag(
                    &tag, &text, &prompt_id, steer, dry_run, json_out,
                )
                .await;
            }
            let session = session.ok_or_else(|| anyhow!("a session is required"))?;
            let text = arg_or_stdin(&prompt)?;
            // A team address (`@member/agent`, `@team/role`); a bare `@` is the caller's own
            // session (`orchestrate::expand_session_key`), never the team path.
            if session.strip_prefix('@').is_some_and(|rest| !rest.is_empty()) {
                if !attach.is_empty() || superseding || classed {
                    return Err(anyhow!(
                        "team messages currently carry text only and do not support --supersede or --class"
                    ));
                }
                let client = connect(true).await?;
                let receipt = client
                    .request(
                        method::MUX_TEAM_SEND,
                        json!({"to": session, "body": text, "idempotencyKey": prompt_id.id}),
                    )
                    .await?;
                if json_out {
                    print_json(&receipt);
                } else {
                    println!("{}", team_receipt_line(&receipt));
                }
                return Ok(());
            }
            // A target nobody here resolves goes to the configured relay, if any (`send_relay.rs`).
            let relay = crate::cli::send_relay::configured();
            let relaying = relay.is_some();
            let relay_from = crate::cli::send_relay::sender(prompt_id.from_agent.as_deref(), |k| {
                std::env::var(k).ok()
            });
            let (relay_session, relay_text, attaching) =
                (session.clone(), text.clone(), !attach.is_empty());
            // A send that waits, to a name nobody here resolves, goes to this daemon's outbox once
            // more when config.json names a mesh hub: the hub delivers it (`server/mesh_send.rs`).
            let (mesh_prompt, mesh_steer) = (prompt_id.clone(), steer);
            let sent = async move {
                let client = before_deadline(deadline, &session, connect(true)).await?;
                // Any size and number: inline when they fit one message with the text, else uploaded
                // to the chat first and named by reference (`attach.rs`).
                if !attach.is_empty() {
                    prompt_id.attachments = before_deadline(deadline, &session, crate::attach::blocks_for(&client, &session, &text, &attach, &|line| {
                        eprintln!("{line}");
                    }))
                    .await
                        .map_err(|e| crate::cli::send_relay::attach_error(e, relaying, &session))?;
                }
                // A sub-session's send to its parent waits for the parent's turn to end, as its
                // send_message does (`hub/subsession_send.rs`), --steer or not.
                if steer && before_deadline(deadline, &session, async { Ok(to_parent(&client, &session).await) }).await? {
                    steer = false;
                }
                if no_wait {
                    before_deadline(deadline, &session, async { announce_machine_wake(&client, &session).await; Ok(()) }).await?;
                    return super::send_async::queue(
                        &client,
                        &session,
                        &text,
                        steer,
                        &prompt_id,
                        superseding,
                        json_out,
                        deadline,
                    )
                    .await;
                }
                let id = before_deadline(deadline, &session, resolve_id(&client, &session)).await?;
                let on_permission = OnPermission::parse(&on_permission)?;
                // Never refuse: report what the prompt queues behind.
                let info = before_deadline(deadline, &id, client.request(method::MUX_INFO, json!({"sessionId": id}))).await?;
                announce_machine_wake_value(&info);
                let running = info.get("status").and_then(Value::as_str) == Some("running")
                    || info.get("turn").map(|t| !t.is_null()).unwrap_or(false);
                let pending = info.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0);
                let queued = info.get("queued").and_then(Value::as_u64).unwrap_or(0);
                let behind =
                    json!({"permissions": pending, "turns": if running { 1 + queued } else { queued }});
                // As the hub decides: a running turn of an agent that steers, pending permission or not.
                let steers_now = steer && running && steering(&info);
                if (running || pending > 0) && !steers_now {
                    let mut parts = Vec::new();
                    if pending > 0 {
                        parts.push(format!(
                            "{pending} pending permission{}",
                            if pending == 1 { "" } else { "s" }
                        ));
                    }
                    if running {
                        parts.push(format!(
                            "{} running turn{}",
                            1 + queued,
                            if queued == 0 { "" } else { "s" }
                        ));
                    }
                    eprintln!("queued behind {}", parts.join(" and "));
                }
                // Before its first turn: an allow it asks for is the app's alone.
                if !(quiet || json_out)
                    && on_permission == OnPermission::Wait
                    && info.get("turnCount").and_then(Value::as_u64) == Some(0)
                    && let Some(note) = crate::question_answer::app_allow_note(&info, &session)
                {
                    eprintln!("{note}");
                }
                let opts = CollectOpts { timeout, deadline, on_permission, stall_secs: stall, retries: 0, steer };
                if quiet || json_out {
                    let r = collect_reply(client, &id, &text, opts, &prompt_id).await?;
                    if json_out {
                        print_json(
                            &json!({"sessionId": id, "reply": r.reply, "stopReason": r.stop_reason, "queuedBehind": behind, "permissions": r.permissions_asked, "permissionsDenied": r.permissions_denied}),
                        );
                    } else {
                        println!("{}", r.reply);
                    }
                    return Ok(());
                }
                stream_prompt(
                    client,
                    &id,
                    &text,
                    steer,
                    quiet,
                    json_out,
                    opts,
                    suppress_reads,
                    &prompt_id,
                )
                .await
            }
            .await;
            match (sent, relay) {
                (Err(e), Some(relay)) if crate::cli::send_relay::no_such_session(&e) => {
                    crate::cli::send_relay::send_with_deadline(
                        &relay,
                        &relay_session,
                        &relay_text,
                        relay_from.as_deref(),
                        attaching,
                        json_out,
                        deadline,
                    )
                }
                (Err(e), None)
                    if !no_wait
                        && !attaching
                        && crate::cli::send_relay::no_such_session(&e)
                        && crate::mesh_http::configured() =>
                {
                    let client = before_deadline(deadline, &relay_session, connect(true)).await?;
                    super::send_async::queue(
                        &client,
                        &relay_session,
                        &relay_text,
                        mesh_steer,
                        &mesh_prompt,
                        superseding,
                        json_out,
                        deadline,
                    )
                    .await
                }
                (sent, _) => sent,
            }
        }
        Command::Inbox(args) => {
            let client = connect(true).await?;
            let (method, params) = match args.command.unwrap_or(crate::cli::command::InboxCmd::List)
            {
                crate::cli::command::InboxCmd::List => {
                    (method::MUX_TEAM_INBOX, json!({"unreadOnly": false, "before": args.before}))
                }
                crate::cli::command::InboxCmd::Read { id } => {
                    (method::MUX_TEAM_READ, json!({"id": id}))
                }
                crate::cli::command::InboxCmd::Ack { id } => {
                    (method::MUX_TEAM_ACK, json!({"id": id}))
                }
            };
            let value = client.request(method, params).await?;
            if json_out {
                print_json(&value);
            } else if method == method::MUX_TEAM_INBOX {
                let messages = value.get("messages").and_then(Value::as_array);
                if messages.is_none_or(Vec::is_empty) {
                    println!("team inbox is empty");
                } else {
                    for message in messages.into_iter().flatten() {
                        let id = message.get("messageId").and_then(Value::as_str).unwrap_or("?");
                        let from = message
                            .pointer("/from/teamAddress")
                            .and_then(Value::as_str)
                            .or_else(|| message.pointer("/from/user").and_then(Value::as_str))
                            .or_else(|| message.pointer("/from/name").and_then(Value::as_str))
                            .unwrap_or("teammate");
                        let to = message
                            .pointer("/to/teamAddress")
                            .and_then(Value::as_str)
                            .unwrap_or("?");
                        let state =
                            message.get("state").and_then(Value::as_str).unwrap_or("queued");
                        let subject = message
                            .get("subject")
                            .and_then(Value::as_str)
                            .or_else(|| message.get("body").and_then(Value::as_str))
                            .unwrap_or("");
                        println!(
                            "{id}\t{from}\t{to}\t{state}\t{}",
                            subject.lines().next().unwrap_or("")
                        );
                    }
                }
                if let Some(next) = value.get("next").and_then(Value::as_u64) {
                    println!("More: acpmux inbox --before {next}");
                }
            } else if method == method::MUX_TEAM_READ {
                println!(
                    "{}",
                    value.pointer("/message/body").and_then(Value::as_str).unwrap_or("")
                );
            } else {
                println!("ok");
            }
            Ok(())
        }
        Command::Deliver { target, prompt, id, audience } => {
            if !target.starts_with("reports:") {
                return Err(anyhow!("--target must start with reports:"));
            }
            if !matches!(audience.as_str(), "leo" | "coordinator" | "silent") {
                return Err(anyhow!("--audience must be leo, coordinator, or silent"));
            }
            let text = arg_or_stdin(&prompt)?;
            let sender = std::env::var("ACPMUX_SESSION_ID")
                .map_err(|_| anyhow!("acpmux deliver must run from an attached agent session"))?;
            let id = id.unwrap_or_else(|| format!("report-{}", uuid::Uuid::now_v7()));
            let client = connect(true).await?;
            // The daemon only accepts a sender identity that is bound to this
            // connection. `deliver` is a session-local CLI, so attach before
            // the quiet write. Keep the view hidden so attaching does not mark
            // the agent seen or publish a visible status event.
            client
                .request(
                    method::MUX_ATTACH,
                    json!({"sessionId": sender, "limit": 0, "visible": false}),
                )
                .await?;
            let value = client
                .request(
                    method::MUX_MAIL_SEND,
                    json!({
                        "id": id,
                        "sender": sender,
                        "target": target,
                        "body": text,
                        "metadata": {"audience": audience, "kind": "report"},
                    }),
                )
                .await?;
            if json_out {
                print_json(&value);
            } else {
                let message_id =
                    value.pointer("/message/id").and_then(Value::as_str).unwrap_or("?");
                println!("delivered {message_id} to reports basket (woke=false)");
            }
            Ok(())
        }
        Command::Chats(cmd) => crate::cli::chats::run(cmd, json_out).await,
        Command::Process(cmd) => crate::cli::process::run(cmd, json_out).await,
        Command::Worktree(cmd) => crate::cli::worktree::run(cmd, json_out),
        Command::Attach { session, plain } => {
            let client = connect(true).await?;
            let id = match &session {
                Some(s) => Some(resolve_id(&client, s).await?),
                None => None,
            };
            if plain {
                let id = id.ok_or_else(|| anyhow!("--plain needs a session"))?;
                return plain_attach(client, &id).await;
            }
            crate::tui::run(client, id).await
        }
        Command::Tail { session, last, follow, since } => {
            orchestrate::tail(connect(true).await?, &session, last, since, follow, suppress_reads)
                .await
        }
        Command::Info { session, fields } => {
            let client = connect(true).await?;
            let id = resolve_id(&client, &session).await?;
            let v = client.request(method::MUX_INFO, json!({"sessionId": id})).await?;
            if let Some(fields) = fields {
                return super::fanout::print_info_fields(&v, &fields, json_out);
            }
            if json_out {
                print_json(&v);
                return Ok(());
            }
            let g = |k: &str| {
                v.get(k)
                    .map(|x| match x {
                        Value::String(s) => s.clone(),
                        Value::Null => "-".into(),
                        o => o.to_string(),
                    })
                    .unwrap_or_default()
            };
            println!("name:      {}", g("name"));
            println!("id:        {}", g("sessionId"));
            println!("agent:     {}  (agent session {})", g("harness"), g("agentSessionId"));
            println!("cwd:       {}", g("cwd"));
            // Its agent restarts on its profile's new launch when the turn ends.
            let respawn = v
                .get("respawnPending")
                .and_then(Value::as_str)
                .map(|why| format!("  (respawn pending: {why})"))
                .unwrap_or_default();
            println!("status:    {}{respawn}", g("status"));
            println!("mode:      {}", g("currentModeId"));
            println!("model:     {}", g("model"));
            println!("policy:    {}", g("policy"));
            println!(
                "turns:     {}   events: {}   last seq: {}",
                g("turnCount"),
                g("eventCount"),
                g("lastSeq")
            );
            if let Some(modes) = v.pointer("/modes/availableModes").and_then(Value::as_array) {
                let names: Vec<String> = modes
                    .iter()
                    .filter_map(|m| m.get("id").and_then(Value::as_str).map(str::to_owned))
                    .collect();
                println!("modes:     {}", names.join(", "));
            }
            if let Some(opts) = v.get("configOptions").and_then(Value::as_array) {
                for o in opts {
                    let id = o.get("id").and_then(Value::as_str).unwrap_or("?");
                    let cur = o.get("currentValue").map(|x| x.to_string()).unwrap_or_default();
                    let choices: Vec<String> = o
                        .get("options")
                        .and_then(Value::as_array)
                        .map(|a| {
                            a.iter()
                                .filter_map(|c| {
                                    c.get("value").and_then(Value::as_str).map(str::to_owned)
                                })
                                .collect()
                        })
                        .unwrap_or_default();
                    println!("config:    {id} = {cur}   [{}]", choices.join(", "));
                }
            }
            if let Some(p) = v.get("pending").and_then(Value::as_array) {
                for perm in p {
                    println!(
                        "PENDING:   {} ({})",
                        perm.pointer("/request/toolCall/title")
                            .and_then(Value::as_str)
                            .unwrap_or("permission"),
                        perm.get("permissionId").and_then(Value::as_str).unwrap_or("")
                    );
                }
            }
            Ok(())
        }
        _ => Err(anyhow!("command routed to the wrong dispatch family")),
    }
}

async fn announce_machine_wake(client: &Arc<crate::client::Client>, session: &str) {
    if !machine_wake_enabled() {
        return;
    }
    if let Ok(info) = client.request(method::MUX_INFO, json!({"sessionId": session})).await {
        announce_machine_wake_value(&info);
    }
}

fn announce_machine_wake_value(info: &Value) {
    if machine_wake_enabled() && crate::machine_wake::has_paused_lease(info) {
        eprintln!("Waking machine…");
    }
}

fn machine_wake_enabled() -> bool {
    crate::config::Config::load()
        .ok()
        .and_then(|config| config.machine_wake)
        .is_some_and(|config| config.enabled)
}

async fn dispatch(client: Arc<Client>, args: DispatchArgs, json_out: bool) -> Result<()> {
    let brief = if args.brief.as_os_str() == "-" {
        arg_or_stdin(&[])?
    } else {
        std::fs::read_to_string(&args.brief)?
    };
    let mut obj = serde_json::Map::from_iter([
        ("brief".into(), json!(brief)),
        ("host".into(), json!(args.host)),
    ]);
    for (key, value) in [
        ("title", args.title),
        ("to", args.to),
        ("stopCondition", args.stop_condition),
        ("model", args.model),
        ("preset", args.preset),
        ("policy", args.policy),
    ] {
        if let Some(value) = value {
            obj.insert(key.into(), json!(value));
        }
    }
    if let Some(cwd) = args.cwd {
        obj.insert("cwd".into(), json!(cwd));
    }
    let v = client.request(crate::rpc::method::MUX_DISPATCH, Value::Object(obj)).await?;
    if json_out {
        print_json(&v);
    } else {
        if let Some(warning) = v.get("warning").and_then(Value::as_str) {
            eprintln!("warning: {warning}");
        }
        if let Some(host) = v.get("suggestedHost").and_then(Value::as_str) {
            eprintln!("suggestion: dispatch the next brief to {host}");
        }
        let b = v.get("brief").unwrap_or(&v);
        println!(
            "sent brief {:?} → {} on {}",
            b.get("title").and_then(Value::as_str).unwrap_or("brief"),
            b.get("to").and_then(Value::as_str).unwrap_or("agent"),
            b.get("host").and_then(Value::as_str).unwrap_or("local")
        );
    }
    Ok(())
}

async fn briefs(client: Arc<Client>, cmd: BriefsCmd, json_out: bool) -> Result<()> {
    let v =
        match cmd {
            BriefsCmd::Ls { status, limit } => {
                client
                    .request(crate::rpc::method::MUX_BRIEFS, json!({"status":status,"limit":limit}))
                    .await?
            }
            BriefsCmd::Steer { brief_id, text } => {
                client
                    .request(
                        crate::rpc::method::MUX_STEER,
                        json!({"briefId":brief_id,"text":arg_or_stdin(&text)?}),
                    )
                    .await?
            }
            BriefsCmd::Report { brief_id, summary, status } => client
                .request(
                    crate::rpc::method::MUX_REPORT,
                    json!({"briefId":brief_id,"summary":arg_or_stdin(&summary)?,"status":status}),
                )
                .await?,
        };
    if json_out {
        print_json(&v);
        return Ok(());
    }
    if let Some(rows) = v.get("briefs").and_then(Value::as_array) {
        for b in rows {
            println!(
                "{:<24} {:<9} {}",
                b.get("briefId").and_then(Value::as_str).unwrap_or("?"),
                b.get("status").and_then(Value::as_str).unwrap_or("?"),
                b.get("title").and_then(Value::as_str).unwrap_or("")
            );
        }
        // Peers whose briefs are missing from the list, and why (`server/requests/briefs.rs`).
        for f in v.get("peersFailed").and_then(Value::as_array).into_iter().flatten() {
            eprintln!(
                "left out {}: {}",
                f.get("peer").and_then(Value::as_str).unwrap_or("?"),
                f.get("error").and_then(Value::as_str).unwrap_or("?")
            );
        }
    } else {
        println!(
            "{}",
            v.get("brief")
                .and_then(|b| b.get("status"))
                .and_then(Value::as_str)
                .unwrap_or("updated")
        );
    }
    Ok(())
}

/// Whether `acpmux send` steers: `--steer` always, `--no-steer` never, else an agent's send
/// (`agent`: `--from`, `ACPMUX_FROM`, or one in an acpmux session) and a message sent with
/// `--no-wait` do, so inter-session messages land in the running turn instead of waiting
/// minutes for it to end (Leo, 2026-10-25: "I don't know why these things are queued up").
/// The person's send that waits for its reply queues, as Cmd-Return does. A send that waits
/// and steers answers with the reply of the turn it went into (`steer_reply.rs`). A steer never
/// stops a turn: the agent reads it at its next tool boundary, and to an agent that does not
/// steer it queues.
fn send_steers(steer: bool, no_steer: bool, no_wait: bool, agent: bool) -> bool {
    !no_steer && (steer || no_wait || agent)
}

/// Whether the session `target` names is the parent of the acpmux session this send runs in
/// (its `startedBy`). Only a sub-session asks which session `target` is.
async fn to_parent(client: &crate::client::Client, target: &str) -> bool {
    let Some(own) = std::env::var("ACPMUX_SESSION_ID").ok().filter(|v| !v.trim().is_empty()) else {
        return false;
    };
    let info =
        |key: &str| client.request(method::MUX_INFO, json!({"sessionId": key, "waitLogs": false}));
    let Some(parent) = info(&own).await.ok().as_ref().and_then(started_by) else {
        return false;
    };
    if target == parent {
        return true;
    }
    let Ok(key) = orchestrate::expand_session_key(target) else { return false };
    info(&key)
        .await
        .is_ok_and(|t| t.get("sessionId").and_then(Value::as_str) == Some(parent.as_str()))
}

/// The session that started the one `info` describes, if one did.
fn started_by(info: &Value) -> Option<String> {
    info.get("startedBy").and_then(Value::as_str).filter(|p| !p.is_empty()).map(str::to_owned)
}

/// The agent of the session `info` describes takes a prompt mid-turn.
fn steering(info: &Value) -> bool {
    info.get("steering").and_then(Value::as_bool) == Some(true)
}

fn new_without_prompt_requires_tty(
    no_prompt: bool,
    detach: bool,
    stdin_terminal: bool,
    stdout_terminal: bool,
) -> bool {
    no_prompt && !detach && (!stdin_terminal || !stdout_terminal)
}

fn new_requires_tty(
    json_out: bool,
    no_prompt: bool,
    detach: bool,
    stdin_terminal: bool,
    stdout_terminal: bool,
) -> bool {
    !json_out && new_without_prompt_requires_tty(no_prompt, detach, stdin_terminal, stdout_terminal)
}

/// Parse the compact durations accepted by `ls --since` (`30m`, `24h`, `7d`, or combinations).
fn team_receipt_line(receipt: &Value) -> String {
    let canonical =
        receipt.pointer("/to/teamAddress").and_then(Value::as_str).unwrap_or("unresolved");
    let decision = receipt.get("startWork").and_then(Value::as_str).unwrap_or("information");
    let state = receipt.get("state").and_then(Value::as_str).unwrap_or("queued");
    let id = receipt.get("messageId").and_then(Value::as_str).unwrap_or("?");
    format!("{state} to {canonical}; startWork={decision} (acpmux send --status mesh:{id})")
}

#[cfg(test)]
mod tests {
    #[test]
    fn team_receipt_shows_the_hubs_canonical_resolution() {
        let receipt = serde_json::json!({"to":{"teamAddress":"@user_42/coordinator"},"startWork":"information","state":"queued","messageId":"message-1"});
        let line = super::team_receipt_line(&receipt);
        assert!(line.contains("@user_42/coordinator"));
        assert!(line.contains("startWork=information"));
    }
    use super::{new_requires_tty, new_without_prompt_requires_tty, send_steers, started_by};
    use serde_json::json;

    #[test]
    fn send_steers_messages_by_default_and_queues_the_persons_waiting_sends() {
        assert!(send_steers(false, false, true, false), "--no-wait steers by default");
        assert!(!send_steers(false, true, true, false), "--no-steer opts out");
        assert!(!send_steers(false, false, false, false), "the person's send that waits queues");
        assert!(send_steers(true, false, false, false), "--steer steers a waiting send");
    }

    /// Leo, 2026-10-25: "I don't know why these things are queued up." An agent's send steers
    /// whether or not it waits for the reply; `--no-steer` still queues it.
    #[test]
    fn an_agents_send_steers_by_default_even_when_it_waits() {
        assert!(send_steers(false, false, false, true), "an agent's waiting send steers");
        assert!(send_steers(false, false, true, true), "and so does its --no-wait send");
        assert!(!send_steers(false, true, false, true), "--no-steer opts out");
        assert!(!send_steers(false, true, true, true), "--no-steer opts out with --no-wait too");
    }

    #[test]
    fn a_sub_session_names_the_parent_that_started_it() {
        let child = json!({"sessionId": "child", "startedBy": "p"});
        assert_eq!(started_by(&child).as_deref(), Some("p"));
        assert_eq!(started_by(&json!({"sessionId": "root", "startedBy": null})), None);
        assert_eq!(started_by(&json!({"sessionId": "old"})), None);
    }

    #[test]
    fn a_promptless_new_requires_a_terminal_unless_detached() {
        assert!(new_without_prompt_requires_tty(true, false, false, true));
        assert!(new_without_prompt_requires_tty(true, false, true, false));
        assert!(!new_without_prompt_requires_tty(true, true, false, false));
        assert!(!new_without_prompt_requires_tty(false, false, false, false));
        assert!(!new_without_prompt_requires_tty(true, false, true, true));
        assert!(!new_requires_tty(true, true, false, false, false));
        assert!(new_requires_tty(false, true, false, false, true));
    }
}
