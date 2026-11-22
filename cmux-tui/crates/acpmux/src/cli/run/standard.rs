//! Owns the primary session and prompt command dispatch arms.

use super::*;

pub(super) fn handles(cmd: &Command) -> bool {
    matches!(
        cmd,
        Command::Wait { .. }
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
            | Command::Ls { .. }
            | Command::New(..)
            | Command::Send { .. }
            | Command::Chats(..)
            | Command::Attach { .. }
            | Command::Tail { .. }
            | Command::Info { .. }
    )
}

pub(super) async fn run(cmd: Command, json_out: bool, suppress_reads: bool) -> Result<()> {
    match cmd {
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
        Command::Ensure { name, model, preset, host, cwd, policy, effort } => {
            orchestrate::ensure(
                connect(true).await?,
                &name,
                model,
                preset,
                host,
                cwd,
                policy,
                effort,
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
            let v = client.request(method::MUX_SESSIONS, json!({})).await?;
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
                    out.push(json!({"session": name, "sessionId": id, "permissionId": p.get("permissionId"), "title": title, "kind": kind, "options": options, "question": is_question, "answer": hint}));
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
        Command::Ls { status, pending, tag } => {
            let client = connect(true).await?;
            let mut v = client.request(method::MUX_SESSIONS, json!({})).await?;
            if status.is_some() || pending || tag.is_some() {
                let keep: Vec<Value> = v
                    .get("sessions")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default()
                    .into_iter()
                    .filter(|s| {
                        let pend =
                            s.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0) > 0;
                        let st = s.get("status").and_then(Value::as_str).unwrap_or("");
                        let status_ok = match status.as_deref() {
                            None => true,
                            Some("waiting") => pend,
                            Some(want) => st == want,
                        };
                        let tag_ok = match tag.as_deref() {
                            None => true,
                            Some(t) => {
                                let (k, want) = t
                                    .split_once('=')
                                    .map(|(k, v)| (k, Some(v)))
                                    .unwrap_or((t, None));
                                s.get("tags")
                                    .and_then(|m| m.get(k))
                                    .map(|v| want.map(|w| v.as_str() == Some(w)).unwrap_or(true))
                                    .unwrap_or(false)
                            }
                        };
                        status_ok && (!pending || pend) && tag_ok
                    })
                    .collect();
                v["sessions"] = Value::Array(keep);
            }
            if json_out {
                print_json(&v);
                return Ok(());
            }
            let sessions = v.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default();
            if sessions.is_empty() {
                println!("no sessions (create one: acpmux new -m codex -n my-task)");
                return Ok(());
            }
            println!(
                "{:<24} {:<8} {:<13} {:>5} {:<6} LAST",
                "NAME", "AGENT", "STATUS", "TURNS", "AGE"
            );
            for s in sessions {
                let g = |k: &str| s.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
                let mut status = g("status");
                if s.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0) > 0 {
                    status = "waiting!".into();
                }
                println!(
                    "{:<24} {:<8} {:<13} {:>5} {:<6} {}",
                    short(&g("name"), 24),
                    short(&g("harness"), 8),
                    status,
                    s.get("turnCount").and_then(Value::as_u64).unwrap_or(0),
                    age(s.get("updatedAt").and_then(Value::as_u64).unwrap_or(0)),
                    short(s.get("lastPrompt").and_then(Value::as_str).unwrap_or(""), 50)
                );
            }
            Ok(())
        }
        Command::New(args) => {
            // Checked before connecting, so the error needs no daemon.
            let cwd = new_session_cwd(args.host.as_deref(), args.cwd.clone())?;
            let client = connect(true).await?;
            if let Some(n) = &args.name {
                crate::session_name::validate(n).map_err(|e| anyhow!(e))?;
            }
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
            if let Some(h) = &args.host {
                meta["peer"] = json!(h);
            }
            if let Some(n) = &args.name {
                meta["name"] = json!(n);
            }
            if let Some(p) = &args.policy {
                meta["policy"] = json!(p);
            }
            if let Some(e) = &args.effort {
                meta["effort"] = json!(e);
            }
            let mut p = json!({"mcpServers": [], "_meta": {"acpmux": meta}});
            p["cwd"] = json!(cwd);
            let v = client.request(method::SESSION_NEW, p).await?;
            let id = v.get("sessionId").and_then(Value::as_str).unwrap_or("").to_owned();
            let name =
                v.pointer("/_meta/acpmux/name").and_then(Value::as_str).unwrap_or(&id).to_owned();
            let one_shot = !args.prompt.is_empty() && (args.quiet || json_out || args.ephemeral);
            if json_out && !one_shot {
                let info = client
                    .request(method::MUX_INFO, json!({"sessionId": id}))
                    .await
                    .unwrap_or(v.clone());
                print_json(&info);
            } else if !one_shot {
                println!("created {name} ({})", &id[..8.min(id.len())]);
            }
            if !args.prompt.is_empty() {
                let text = args.prompt.join(" ");
                let prompt = PromptId::new(args.prompt_id.clone());
                if one_shot {
                    let opts = CollectOpts {
                        timeout: args.timeout,
                        on_permission: OnPermission::parse(&args.on_permission)?,
                        stall_secs: args.stall,
                        retries: args.retries,
                    };
                    let outcome = collect_reply(client.clone(), &id, &text, opts, &prompt).await;
                    if args.ephemeral {
                        let _ = client
                            .request(method::MUX_KILL, json!({"sessionId": id, "purge": true}))
                            .await;
                    }
                    let r = outcome?;
                    if json_out {
                        print_json(
                            &json!({"sessionId": id, "name": name, "reply": r.reply, "stopReason": r.stop_reason, "permissions": r.permissions_asked, "permissionsDenied": r.permissions_denied, "ephemeral": args.ephemeral}),
                        );
                    } else {
                        println!("{}", r.reply);
                    }
                    return Ok(());
                }
                if args.detach {
                    queue_prompt(client, &id, &text, false, &prompt).await?;
                    return Ok(());
                }
                let opts = CollectOpts {
                    timeout: args.timeout,
                    on_permission: OnPermission::parse(&args.on_permission)?,
                    stall_secs: args.stall,
                    retries: args.retries,
                };
                return stream_prompt(
                    client,
                    &id,
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
            crate::tui::run(client, Some(id)).await
        }
        Command::Send {
            session,
            prompt,
            steer,
            no_wait,
            quiet,
            timeout,
            on_permission,
            stall,
            prompt_id,
        } => {
            let prompt_id = PromptId::new(prompt_id);
            let client = connect(true).await?;
            let text = arg_or_stdin(&prompt)?;
            let id = resolve_id(&client, &session).await?;
            let on_permission = OnPermission::parse(&on_permission)?;
            // Never refuse: report what the prompt queues behind.
            let info = client.request(method::MUX_INFO, json!({"sessionId": id})).await?;
            let running = info.get("status").and_then(Value::as_str) == Some("running")
                || info.get("turn").map(|t| !t.is_null()).unwrap_or(false);
            let pending = info.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0);
            let queued = info.get("queued").and_then(Value::as_u64).unwrap_or(0);
            let behind =
                json!({"permissions": pending, "turns": if running { 1 + queued } else { queued }});
            if (running || pending > 0) && !steer {
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
            if no_wait {
                // Return once the daemon recorded the prompt, not after a guess.
                let accepted = queue_prompt(client, &id, &text, steer, &prompt_id).await?;
                if json_out {
                    print_json(
                        &json!({"sessionId": id, "queued": true, "queuedBehind": behind, "promptId": prompt_id.id, "accepted": accepted}),
                    );
                } else {
                    println!("queued");
                }
                return Ok(());
            }
            let opts = CollectOpts { timeout, on_permission, stall_secs: stall, retries: 0 };
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
        Command::Chats(cmd) => crate::cli::chats::run(cmd, json_out).await,
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
        Command::Info { session } => {
            let client = connect(true).await?;
            let id = resolve_id(&client, &session).await?;
            let v = client.request(method::MUX_INFO, json!({"sessionId": id})).await?;
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
            println!("status:    {}", g("status"));
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
