//! Dispatch of every parsed CLI command against the daemon.

use crate::cli::output::*;
use crate::cli::{errors, orchestrate};
use crate::cli::command::*;
use crate::client::Client;
use crate::config::{Config, home};
use crate::daemon::connect;
use crate::rpc::method;
use anyhow::{Result, anyhow};
use serde_json::{Value, json};

pub(crate) async fn run_client(cmd: Command, json_out: bool, suppress_reads: bool) -> Result<()> {
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
                    out.push(json!({"session": name, "sessionId": id, "permissionId": p.get("permissionId"), "title": title, "kind": kind, "options": options}));
                }
            }
            if json_out {
                print_json(&json!({"pending": out}));
            } else if out.is_empty() {
                println!("no pending permissions");
            } else {
                for p in &out {
                    let g = |k: &str| p.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
                    let opts: Vec<String> = p
                        .get("options")
                        .and_then(Value::as_array)
                        .map(|a| {
                            a.iter()
                                .filter_map(|o| {
                                    o.get("optionId").and_then(Value::as_str).map(str::to_owned)
                                })
                                .collect()
                        })
                        .unwrap_or_default();
                    println!(
                        "{:<24} {} [{}]  answer: acpmux session allow {} [{}] | acpmux session deny {}",
                        g("session"),
                        g("title"),
                        g("kind"),
                        g("session"),
                        opts.join("|"),
                        g("session")
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
            // On a peer the directory is a remote path; leave it to the
            // remote daemon (its home) unless given.
            let cwd: Option<PathBuf> = match (&args.host, args.cwd) {
                (Some(_), c) => c,
                (None, c) => Some(c.unwrap_or(std::env::current_dir()?)),
            };
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
            if let Some(c) = cwd {
                p["cwd"] = json!(c);
            }
            let v = client.request(method::SESSION_NEW, p).await?;
            let id = v.get("sessionId").and_then(Value::as_str).unwrap_or("").to_owned();
            let name =
                v.pointer("/_meta/acpmux/name").and_then(Value::as_str).unwrap_or(&id).to_owned();
            let one_shot = !args.prompt.is_empty() && (args.quiet || json_out);
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
                if one_shot {
                    let opts = CollectOpts {
                        timeout: args.timeout,
                        on_permission: OnPermission::parse(&args.on_permission)?,
                        stall_secs: args.stall,
                        retries: args.retries,
                    };
                    let outcome = collect_reply(client.clone(), &id, &text, opts).await;
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
                    let c = client.clone();
                    let id2 = id.clone();
                    tokio::spawn(async move {
                        let _ = c.request(method::SESSION_PROMPT, json!({"sessionId": id2, "prompt": [{"type": "text", "text": text}]})).await;
                    });
                    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
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
                )
                .await;
            }
            if args.detach || json_out {
                return Ok(());
            }
            crate::tui::run(client, Some(id)).await
        }
        Command::Send { session, prompt, steer, no_wait, quiet, timeout, on_permission, stall } => {
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
                let c = client.clone();
                let id2 = id.clone();
                tokio::spawn(async move {
                    let _ = c.request(method::SESSION_PROMPT, json!({"sessionId": id2, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"steer": steer}}})).await;
                });
                tokio::time::sleep(std::time::Duration::from_millis(200)).await;
                if json_out {
                    print_json(&json!({"sessionId": id, "queued": true, "queuedBehind": behind}));
                } else {
                    println!("queued");
                }
                return Ok(());
            }
            let opts = CollectOpts { timeout, on_permission, stall_secs: stall, retries: 0 };
            if quiet || json_out {
                let r = collect_reply(client, &id, &text, opts).await?;
                if json_out {
                    print_json(
                        &json!({"sessionId": id, "reply": r.reply, "stopReason": r.stop_reason, "queuedBehind": behind, "permissions": r.permissions_asked, "permissionsDenied": r.permissions_denied}),
                    );
                } else {
                    println!("{}", r.reply);
                }
                return Ok(());
            }
            stream_prompt(client, &id, &text, steer, quiet, json_out, opts, suppress_reads).await
        }
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
        Command::Cancel { session } => {
            let client = connect(true).await?;
            let id = resolve_id(&client, &session).await?;
            client.notify(method::SESSION_CANCEL, json!({"sessionId": id})).await?;
            tokio::time::sleep(std::time::Duration::from_millis(150)).await;
            println!("cancel sent");
            Ok(())
        }
        Command::Kill { session, purge } => {
            let client = connect(true).await?;
            let id = resolve_id(&client, &session).await?;
            let v =
                client.request(method::MUX_KILL, json!({"sessionId": id, "purge": purge})).await?;
            if json_out {
                print_json(&v)
            } else {
                println!("{}", if purge { "purged" } else { "closed" })
            }
            Ok(())
        }
        Command::Rename { session, new_name } => {
            let client = connect(true).await?;
            let id = resolve_id(&client, &session).await?;
            let v = client
                .request(method::MUX_RENAME, json!({"sessionId": id, "newName": new_name}))
                .await?;
            if json_out {
                print_json(&v)
            } else {
                println!("renamed")
            }
            Ok(())
        }
        Command::Fork { session, name, cwd } => {
            let client = connect(true).await?;
            let id = resolve_id(&client, &session).await?;
            let mut p = json!({"sessionId": id, "mcpServers": [], "_meta": {"acpmux": {}}});
            if let Some(c) = cwd {
                p["cwd"] = json!(c);
            }
            if let Some(n) = name {
                p["_meta"]["acpmux"]["name"] = json!(n);
            }
            let v = client.request(method::SESSION_FORK, p).await?;
            if json_out {
                print_json(&v)
            } else {
                println!(
                    "forked into {}",
                    v.pointer("/_meta/acpmux/name").and_then(Value::as_str).unwrap_or("?")
                );
            }
            Ok(())
        }
        Command::Set { session, assignment } => {
            let client = connect(true).await?;
            let id = resolve_id(&client, &session).await?;
            let (k, val) = assignment.split_once('=').ok_or_else(|| anyhow!("use key=value"))?;
            let v = match k {
                "mode" => {
                    client
                        .request(method::SESSION_SET_MODE, json!({"sessionId": id, "modeId": val}))
                        .await?
                }
                "model" => {
                    client
                        .request(
                            method::SESSION_SET_MODEL,
                            json!({"sessionId": id, "modelId": val}),
                        )
                        .await?
                }
                "policy" => {
                    client
                        .request(method::MUX_SET_POLICY, json!({"sessionId": id, "policy": val}))
                        .await?
                }
                other => {
                    let value = match val {
                        "true" => json!(true),
                        "false" => json!(false),
                        s => json!(s),
                    };
                    client
                        .request(
                            method::SESSION_SET_CONFIG_OPTION,
                            json!({"sessionId": id, "configId": other, "value": value}),
                        )
                        .await?
                }
            };
            if json_out {
                print_json(&v)
            } else {
                println!("ok")
            }
            Ok(())
        }
        Command::Allow { session, option } => answer_permission(&session, option, true).await,
        Command::Deny { session } => answer_permission(&session, None, false).await,
        Command::Export { session, dest } => {
            let client = connect(true).await?;
            let id = resolve_id(&client, &session).await?;
            let mut p = json!({"sessionId": id});
            if let Some(d) = dest {
                p["dest"] = json!(std::path::absolute(d)?);
            }
            let v = client.request(method::MUX_EXPORT, p).await?;
            // A bundle made on an ssh peer is fetched here with scp.
            let mut out = v.clone();
            if let Some(peer) = v.get("peer").and_then(Value::as_str) {
                let peers = client.request("_acpmux/peers", json!({})).await?;
                let url = peers
                    .get("peers")
                    .and_then(Value::as_array)
                    .and_then(|a| {
                        a.iter().find(|x| x.get("name").and_then(Value::as_str) == Some(peer))
                    })
                    .and_then(|x| x.get("url").and_then(Value::as_str))
                    .unwrap_or("")
                    .to_owned();
                if let Some(host) = url
                    .strip_prefix("ssh://")
                    .map(|h| h.rsplit_once(':').map(|(h, _)| h).unwrap_or(h))
                {
                    let remote_path =
                        v.get("path").and_then(Value::as_str).unwrap_or("").to_owned();
                    let local = crate::config::home().join("bundles").join(format!(
                        "{peer}-{}",
                        std::path::Path::new(&remote_path)
                            .file_name()
                            .and_then(|f| f.to_str())
                            .unwrap_or("bundle")
                    ));
                    std::fs::create_dir_all(local.parent().unwrap())?;
                    let status = std::process::Command::new("scp")
                        .args([
                            "-rq",
                            "-o",
                            "BatchMode=yes",
                            &format!("{host}:{remote_path}"),
                            &local.to_string_lossy(),
                        ])
                        .status()?;
                    if status.success() {
                        out["remotePath"] = json!(remote_path);
                        out["path"] = json!(local);
                    } else {
                        eprintln!("acpmux: bundle stays on {peer} at {remote_path} (scp failed)");
                    }
                }
            }
            if json_out {
                print_json(&out)
            } else {
                println!("{}", out.get("path").and_then(Value::as_str).unwrap_or(""))
            }
            Ok(())
        }
        Command::Import { path, name } => {
            let client = connect(true).await?;
            let mut p = json!({"path": std::path::absolute(path)?});
            if let Some(n) = name {
                p["name"] = json!(n);
            }
            let v = client.request(method::MUX_IMPORT, p).await?;
            if json_out {
                print_json(&v)
            } else {
                println!("imported as {}", v.get("name").and_then(Value::as_str).unwrap_or("?"))
            }
            Ok(())
        }
        Command::Harnesses => {
            let client = connect(true).await?;
            let v = client.request(method::MUX_HARNESSES, json!({})).await?;
            if json_out {
                print_json(&v);
                return Ok(());
            }
            let default = v.get("defaultHarness").and_then(Value::as_str).unwrap_or("");
            if let Some(agents) = v.get("harnesses").and_then(Value::as_object) {
                if agents.is_empty() {
                    println!("no harnesses configured. Edit {}", Config::path().display());
                }
                for (name, prof) in agents {
                    let argv: Vec<String> = prof
                        .get("argv")
                        .and_then(Value::as_array)
                        .map(|a| a.iter().filter_map(|s| s.as_str().map(str::to_owned)).collect())
                        .unwrap_or_default();
                    let family = prof.get("family").and_then(Value::as_str).unwrap_or("");
                    if let Some(r) = prof.get("unavailable").and_then(Value::as_str) {
                        println!(
                            "{}{:<10} {:<9} {}  [unavailable: {}]",
                            if name == default { "*" } else { " " },
                            name,
                            family,
                            argv.join(" "),
                            r.chars().take(80).collect::<String>()
                        );
                        continue;
                    }
                    let d = prof.get("defaults");
                    let extras: Vec<String> = ["model", "effort", "policy"]
                        .iter()
                        .filter_map(|k| {
                            d.and_then(|d| d.get(*k))
                                .and_then(Value::as_str)
                                .map(|v| format!("{k}={v}"))
                        })
                        .collect();
                    println!(
                        "{}{:<10} {:<9} {}{}",
                        if name == default { "*" } else { " " },
                        name,
                        family,
                        argv.join(" "),
                        if extras.is_empty() {
                            String::new()
                        } else {
                            format!("  [{}]", extras.join(" "))
                        }
                    );
                }
            }
            Ok(())
        }
        Command::Status => {
            match connect(false).await {
                Ok(client) => {
                    let v = client.request(method::MUX_STATUS, json!({})).await?;
                    if json_out {
                        print_json(&v);
                        return Ok(());
                    }
                    println!(
                        "acpmux {} pid {} up {}",
                        v.get("version").and_then(Value::as_str).unwrap_or(""),
                        v.get("pid").and_then(Value::as_u64).unwrap_or(0),
                        age(v.get("startedAt").and_then(Value::as_u64).unwrap_or(0))
                    );
                    println!("socket:   {}", v.get("socket").and_then(Value::as_str).unwrap_or(""));
                    println!("home:     {}", v.get("home").and_then(Value::as_str).unwrap_or(""));
                    println!(
                        "store:    {}",
                        v.pointer("/store/mode").and_then(Value::as_str).unwrap_or("")
                    );
                    println!(
                        "sessions: {} ({} live agents)",
                        v.get("sessions").and_then(Value::as_u64).unwrap_or(0),
                        v.get("liveAgents").and_then(Value::as_u64).unwrap_or(0)
                    );
                    println!(
                        "policy:   {}",
                        v.get("permissionPolicy").and_then(Value::as_str).unwrap_or("")
                    );
                    println!(
                        "web:      {}",
                        v.get("webUrl").and_then(Value::as_str).unwrap_or("-")
                    );
                    for p in v.get("peers").and_then(Value::as_array).cloned().unwrap_or_default() {
                        println!(
                            "peer:     {} {} ({} sessions) {}",
                            p.get("name").and_then(Value::as_str).unwrap_or(""),
                            if p.get("connected").and_then(Value::as_bool).unwrap_or(false) {
                                "connected"
                            } else {
                                "offline"
                            },
                            p.get("sessions").and_then(Value::as_u64).unwrap_or(0),
                            p.get("url").and_then(Value::as_str).unwrap_or("")
                        );
                    }
                }
                Err(e) => {
                    if json_out {
                        print_json(&json!({"running": false, "error": e.to_string()}))
                    } else {
                        println!("daemon not running ({e})")
                    }
                }
            }
            Ok(())
        }
        Command::Shutdown => {
            let client = connect(false).await?;
            let _ = client.request(method::MUX_SHUTDOWN, json!({})).await;
            println!("shutdown requested");
            Ok(())
        }
        Command::Config => {
            let path = Config::path();
            println!("# {}", path.display());
            match std::fs::read_to_string(&path) {
                Ok(s) => println!("{s}"),
                Err(_) => {
                    let cfg = Config::load()?;
                    println!("# (not written yet; effective defaults below)");
                    println!("{}", serde_json::to_string_pretty(&cfg)?);
                }
            }
            println!("# home: {}", home().display());
            Ok(())
        }
        Command::Web { no_open } => {
            let client = connect(true).await?;
            let v = client.request(method::MUX_STATUS, json!({})).await?;
            let url = v
                .get("webUrl")
                .and_then(Value::as_str)
                .ok_or_else(|| anyhow!("daemon has no web listener"))?
                .to_owned();
            println!("{url}");
            if !no_open {
                let _ = std::process::Command::new(if cfg!(target_os = "macos") {
                    "open"
                } else {
                    "xdg-open"
                })
                .arg(&url)
                .spawn();
            }
            Ok(())
        }
        Command::Peer(cmd) => {
            let client = connect(true).await?;
            let v = match cmd {
                PeerCmd::Add { name, url, token } => {
                    let mut p = json!({"name": name, "url": url});
                    if let Some(t) = token {
                        p["token"] = json!(t);
                    }
                    client.request("_acpmux/peer_add", p).await?;
                    // Give the connect loop a moment so the listing shows the real state.
                    tokio::time::sleep(std::time::Duration::from_millis(1500)).await;
                    client.request("_acpmux/peers", json!({})).await?
                }
                PeerCmd::Ls => client.request("_acpmux/peers", json!({})).await?,
                PeerCmd::Rm { name } => {
                    client.request("_acpmux/peer_remove", json!({"name": name})).await?
                }
                PeerCmd::Setup { host, name, port } => {
                    return crate::cli::hosts::setup(client, &host, name, port, json_out).await;
                }
                PeerCmd::Update { name, all } => {
                    return crate::cli::hosts::update(client, name, all, json_out).await;
                }
            };
            if json_out {
                print_json(&v);
                return Ok(());
            }
            let peers = v.get("peers").and_then(Value::as_array).cloned().unwrap_or_default();
            if peers.is_empty() {
                println!("no peers (add one: acpmux peer add sandbox-a ws://host:47811 --token T)");
            }
            for p in peers {
                let connected = p.get("connected").and_then(Value::as_bool).unwrap_or(false);
                let build = p.get("remoteBuild").and_then(Value::as_str).unwrap_or("");
                let outdated = p.get("outdated").and_then(Value::as_bool).unwrap_or(false);
                println!(
                    "{:<16} {:<10} {:>3} sessions  {:<24} {}{}{}",
                    p.get("name").and_then(Value::as_str).unwrap_or(""),
                    if connected { "connected" } else { "offline" },
                    p.get("sessions").and_then(Value::as_u64).unwrap_or(0),
                    p.get("url").and_then(Value::as_str).unwrap_or(""),
                    if build.is_empty() { String::new() } else { format!("build {build}") },
                    if outdated {
                        "  (differs from this build: acpmux host update NAME)"
                    } else {
                        ""
                    },
                    p.get("error")
                        .and_then(Value::as_str)
                        .map(|e| format!("  ({e})"))
                        .unwrap_or_default(),
                );
            }
            Ok(())
        }
        Command::DaemonRun { .. }
        | Command::Stdio { .. }
        | Command::Session(_)
        | Command::Daemon(_)
        | Command::Host(_) => {
            unreachable!()
        }
    }
}

pub(crate) async fn resolve_id(client: &Client, key: &str) -> Result<String> {
    let key = orchestrate::expand_session_key(key)?;
    let v = client.request(method::MUX_INFO, json!({"sessionId": key})).await.map_err(|e| {
        let m = e.to_string().to_lowercase();
        if m.contains("no session") || m.contains("not found") {
            anyhow::Error::from(errors::AppError::no_session(&key))
        } else {
            e
        }
    })?;
    Ok(v.get("sessionId").and_then(Value::as_str).unwrap_or(&key).to_owned())
}

pub(crate) async fn answer_permission(
    session: &str,
    option: Option<String>,
    allow: bool,
) -> Result<()> {
    let client = connect(true).await?;
    let id = resolve_id(&client, session).await?;
    let info = client.request(method::MUX_INFO, json!({"sessionId": id})).await?;
    let pending = info.get("pending").and_then(Value::as_array).cloned().unwrap_or_default();
    let Some(first) = pending.first() else {
        return Err(anyhow!("no pending permission"));
    };
    let pid = first.get("permissionId").and_then(Value::as_str).unwrap_or("").to_owned();
    let options =
        first.pointer("/request/options").and_then(Value::as_array).cloned().unwrap_or_default();
    let pick = |kinds: &[&str]| {
        kinds.iter().find_map(|k| {
            options
                .iter()
                .find(|o| o.get("kind").and_then(Value::as_str) == Some(k))
                .and_then(|o| o.get("optionId").and_then(Value::as_str).map(str::to_owned))
        })
    };
    let option_id = match (option, allow) {
        (Some(o), _) => Some(o),
        (None, true) => pick(&["allow_once", "allow_always"]),
        (None, false) => pick(&["reject_once", "reject_always"]),
    };
    client
        .request(
            method::MUX_PERMISSION_RESPOND,
            json!({"sessionId": id, "permissionId": pid, "optionId": option_id}),
        )
        .await?;
    println!("{}", if allow { "allowed" } else { "denied" });
    Ok(())
}
