//! Owns the remaining daemon, session maintenance, peer, and output commands.

use super::*;

fn peer_add_params(name: &str, url: &str, token: Option<&str>) -> Value {
    let mut params = json!({"name": name, "url": url, "wait": false});
    if let Some(token) = token {
        cmux_json::JsonSet::set(&mut params, "token", json!(token));
    }
    params
}

/// Whether `session resume` moves the chat `info` (`MUX_INFO`) before resuming it: this machine is
/// one a person works at (`placement::interactive`) and the chat is stopped here (no agent runs:
/// `closed`, `idle` or `disconnected`, no turn), so resuming it would start its agent here. It
/// goes where `session move --host auto` puts it (`session_move::move_off_interactive`). A chat
/// on a peer, one with a live agent, one moving or moved away resumes where it is.
pub(super) fn resume_moves_off(info: &Value, interactive: bool) -> bool {
    interactive
        && info.get("peer").is_none_or(Value::is_null)
        && info.get("turn").is_none_or(Value::is_null)
        && info.get("movedTo").is_none_or(Value::is_null)
        && info["moving"] != true
        && matches!(info["status"].as_str(), Some("closed" | "idle" | "disconnected"))
}

/// Runs the queue a failed turn held in chat `id` (`info` is its `MUX_INFO`), through `client`:
/// `_acpmux/queue_edit` `resume` names the queue by any of its prompts, a held one. False when
/// nothing is held.
pub(super) async fn resume_held(client: &Client, id: &str, info: &Value) -> Result<bool> {
    let held = info["queue"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|q| q["held"] == true)
        .and_then(|q| q["promptId"].as_str());
    let Some(prompt_id) = held else { return Ok(false) };
    let v = client
        .request(
            method::MUX_QUEUE_EDIT,
            json!({"sessionId": id, "promptId": prompt_id, "op": "resume"}),
        )
        .await?;
    Ok(v["ok"] == true)
}

/// What `session resume` prints when it moved the chat first.
fn moved_line(host: &str) -> String {
    format!(
        "moved to {host} (as `session move --host auto` does): this machine is one a person works at, so a stopped chat resumes on a fleet host"
    )
}

pub(super) async fn run(cmd: Command, json_out: bool, _suppress_reads: bool) -> Result<()> {
    match cmd {
        Command::Session(control) => crate::cli::mesh_control::run(control, json_out).await,
        Command::Retention(args) => {
            let client = connect(true).await?;
            let archive = args.archive.map(std::path::absolute).transpose()?;
            let v = client
                .request(
                    method::MUX_RETENTION,
                    json!({"dryRun": args.dry_run, "archive": archive, "olderThanDays": args.older_than_days, "only": args.only}),
                )
                .await?;
            if json_out {
                print_json(&v);
            } else {
                let mb = |key: &str| v[key].as_u64().unwrap_or(0) as f64 / 1_048_576.0;
                println!(
                    "{} closed chats older than {} days: {:.1} MB of {:.1} MB {}",
                    v["chats"],
                    v["olderThanDays"],
                    mb("freedBytes"),
                    mb("bytesBefore"),
                    if args.dry_run { "would be freed (dry run)" } else { "freed" }
                );
                println!("skipped: {}", v["skipped"]);
            }
            Ok(())
        }
        Command::Cancel { session } => {
            let client = connect(true).await?;
            let id = crate::cli::resolve::control_id(&client, &session).await?;
            // As a request, the reply says the daemon handled the cancel.
            client.request(method::SESSION_CANCEL, json!({"sessionId": id})).await?;
            if json_out {
                print_json(&json!({"sessionId": id, "cancelSent": true}));
            } else {
                println!("cancel sent");
            }
            Ok(())
        }
        Command::Kill { session, purge, condition } => {
            let client = connect(true).await?;
            // An older daemon would ignore the condition and stop a busy session.
            if condition.if_idle && !client.daemon_lists(crate::hub::stop_if_idle::FEATURE) {
                return Err(crate::cli::errors::AppError::new(
                    crate::cli::errors::Code::Runtime,
                    "stop_if_idle_unsupported",
                    "the running daemon predates `session stop --if-idle`: nothing was stopped; \
                     restart it on the installed acpmux, then retry",
                )
                .into());
            }
            let id = crate::cli::resolve::control_id(&client, &session).await?;
            let mut params = json!({"sessionId": id, "purge": purge});
            if condition.if_idle {
                cmux_json::JsonSet::set(&mut params, "ifIdle", json!(true));
            }
            if let Some(rev) = condition.expect_revision {
                cmux_json::JsonSet::set(&mut params, "expectRevision", json!(rev));
            }
            let v = client.request(method::MUX_KILL, params).await?;
            if json_out {
                print_json(&v)
            } else {
                println!("{}", if purge { "purged" } else { "closed" })
            }
            Ok(())
        }
        Command::RestartAgent { session } => {
            let client = connect(true).await?;
            let id = resolve_id(&client, &session).await?;
            let v = client
                .request(method::MUX_SESSIONS_RESTART_HARNESS, json!({"sessions": [id]}))
                .await?;
            if json_out {
                print_json(&v);
            } else if let Some(error) = v.pointer("/errors/0/error").and_then(Value::as_str) {
                return Err(anyhow!("the agent did not start again: {error}"));
            } else if v["restarted"].as_u64().unwrap_or(0) > 0 {
                println!("restarted");
            } else if v["after_turn"].as_u64().unwrap_or(0) > 0 {
                println!("restarts when its turn ends");
            } else {
                println!("not running: it starts with a new token at its next prompt");
            }
            Ok(())
        }
        Command::LimitsCmd { session, max, clear } => {
            let client = connect(true).await?;
            crate::cli::session_limits::run(&client, &session, max, clear, json_out).await
        }
        Command::SessionInboxCmd(crate::cli::command::SessionInboxTarget {
            session,
            thread,
            unread,
        }) => {
            let client = connect(true).await?;
            crate::cli::session_inbox::run(&client, &session, thread.as_deref(), unread, json_out)
                .await
        }
        Command::TurnCapCmd { session, minutes, off, clear } => {
            use crate::cli::session_turn_cap::Change;
            let change = match (minutes, off, clear) {
                (Some(m), _, _) => Change::Minutes(m),
                (None, true, _) => Change::Off,
                (None, false, true) => Change::Clear,
                (None, false, false) => Change::Show,
            };
            let client = connect(true).await?;
            crate::cli::session_turn_cap::run(&client, &session, change, json_out).await
        }
        Command::QueueCmd(q) => {
            let client = connect(true).await?;
            crate::cli::session_queue::run(&client, q, json_out).await
        }
        Command::ResumeQueue { session } => {
            let client = connect(true).await?;
            let mut id = crate::cli::resolve::control_id(&client, &session).await?;
            let info = client.request(method::MUX_INFO, json!({"sessionId": id})).await?;
            let mut moved_to = None;
            let mut resumed = None;
            if resume_moves_off(&info, crate::cli::place::here_is_interactive()) {
                match super::session_move::move_off_interactive(&client, &id).await {
                    Ok(moved) => {
                        eprintln!("{}", moved_line(&moved.host));
                        id = moved.routed;
                        moved_to = Some(moved.host);
                        resumed = Some(moved.resumed);
                    }
                    Err(e) => eprintln!("resuming on this machine: it did not move ({e:#})"),
                }
            }
            let resumed = match resumed {
                Some(Ok(resumed)) => resumed,
                Some(Err(why)) => {
                    anyhow::bail!(
                        "it moved to {id}, but its held queue did not resume there: {why}"
                    )
                }
                None => resume_held(&client, &id, &info).await?,
            };
            if json_out {
                print_json(&json!({"sessionId": id, "resumed": resumed, "movedTo": moved_to}));
            } else if resumed {
                println!("resumed");
            } else {
                println!("nothing is held");
            }
            Ok(())
        }
        Command::InboxDigest { session, dry_run } => {
            let client = connect(true).await?;
            let id = crate::cli::resolve::control_id(&client, &session).await?;
            let v = client
                .request(method::MUX_INBOX_DIGEST, json!({"sessionId": id, "dryRun": dry_run}))
                .await?;
            let field = |key: &str| v.get(key).unwrap_or(&Value::Null);
            let digested = field("digested").as_u64().unwrap_or(0);
            if json_out {
                print_json(&v);
            } else if digested == 0 {
                println!("no agent message waits in its queue");
            } else if dry_run {
                println!("{}", field("text").as_str().unwrap_or_default());
                println!("\n(dry run: nothing changed; --digest sends it)");
            } else {
                let how = match field("delivery").as_str() {
                    Some("steer") => "steered into its running turn".to_owned(),
                    _ => format!("queued at position {}", field("position")),
                };
                println!(
                    "{digested} messages went into digest {}, {how}",
                    field("promptId").as_str().unwrap_or_default()
                );
            }
            Ok(())
        }
        Command::Retry(args) => crate::cli::retry::run(args, json_out).await,
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
        Command::Fork { session, name, cwd, force_admit } => {
            let client = connect(true).await?;
            let id = resolve_id(&client, &session).await?;
            let mut p = json!({"sessionId": id, "mcpServers": [], "_meta": {"acpmux": {}}});
            if let Some(c) = cwd {
                p["cwd"] = json!(c);
            }
            if let Some(n) = name {
                p["_meta"]["acpmux"]["name"] = json!(n);
            }
            if force_admit {
                p["_meta"]["acpmux"]["forceAdmit"] = json!(true);
            }
            let v = client.request(method::SESSION_FORK, p).await?;
            super::launch::print_new_warnings(&v);
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
                "team-address" | "teamAddress" => {
                    if !crate::mesh::valid_team_suffix(val) {
                        return Err(anyhow!(
                            "team-address must be an agent suffix such as coordinator; the hub supplies your member namespace"
                        ));
                    }
                    client
                        .request(
                            method::MUX_TAG,
                            json!({"sessionId": id, "set": {"teamAddress": val}}),
                        )
                        .await?
                }
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
        Command::Allow { session, option } => {
            answer_permission(&session, option, true, json_out).await
        }
        Command::Deny { session } => answer_permission(&session, None, false, json_out).await,
        Command::Answer { session, answer } => answer_question(&session, &answer, json_out).await,
        Command::Export { session, dest } => {
            let client = connect(true).await?;
            let id = resolve_id(&client, &session).await?;
            // For a peer's session, --dest is where the fetched bundle lands
            // here; the peer writes to its own default directory.
            let info = client.request(method::MUX_INFO, json!({"sessionId": id})).await?;
            let remote = info.get("peer").is_some();
            let dest = dest.map(|d| std::path::absolute(&d)).transpose()?;
            let mut p = json!({"sessionId": id});
            if let Some(d) = dest.as_ref().filter(|_| !remote) {
                p["dest"] = json!(d);
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
                if url.starts_with("ssh://") {
                    let remote_path =
                        v.get("path").and_then(Value::as_str).unwrap_or("").to_owned();
                    let file = std::path::Path::new(&remote_path)
                        .file_name()
                        .and_then(|f| f.to_str())
                        .unwrap_or("bundle")
                        .to_owned();
                    let local = match &dest {
                        Some(d) => d.join(&file),
                        None => {
                            crate::config::home().join("bundles").join(format!("{peer}-{file}"))
                        }
                    };
                    std::fs::create_dir_all(local.parent().unwrap())?;
                    let argv = crate::cli::hosts::scp_fetch_argv(
                        &url,
                        &remote_path,
                        &local.to_string_lossy(),
                    )?;
                    let status = std::process::Command::new("scp").args(argv).status()?;
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
        Command::MoveSessions {
            sessions,
            host,
            all_idle,
            interrupt,
            leave_dirty,
            cwd,
            dry_run,
        } => {
            let args = super::session_move::MoveArgs {
                sessions,
                host,
                all_idle,
                interrupt,
                leave_dirty,
                cwd,
                dry_run,
                resume_there: false,
            };
            super::session_move::run(args, json_out).await
        }
        Command::Transfer { session, to, cwd, name, interrupt } => {
            super::transfer::run(&session, &to, cwd, name, interrupt, json_out).await
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
        which @ (Command::Status { .. } | Command::DaemonStart { .. }) => {
            let start = matches!(which, Command::DaemonStart { .. });
            if start {
                crate::daemon::mark_explicit_start();
            }
            let show_token = match &which {
                Command::Status { show_token } | Command::DaemonStart { show_token, .. } => {
                    *show_token
                }
                _ => false,
            };
            // A keyed start (cx-0q7o, D2): the daemon must be the one this
            // command starts, with the key from the app's own exec.
            #[cfg(unix)]
            if let Command::DaemonStart { person_key_fd: Some(fd), .. } = &which {
                crate::daemon::start_keyed(*fd).await?;
            }
            #[cfg(not(unix))]
            if let Command::DaemonStart { person_key_fd: Some(_), .. } = &which {
                return Err(crate::platform::unsupported("--person-key-fd"));
            }
            match connect(start).await {
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
                    for stuck in v["stuckSessions"].as_array().into_iter().flatten() {
                        println!(
                            "stuck: {} ({}) since {}: {}",
                            stuck["name"].as_str().unwrap_or(""),
                            stuck["stuckReason"].as_str().unwrap_or(""),
                            stuck["stuckSince"],
                            stuck["stuckError"].as_str().unwrap_or("")
                        );
                    }
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
                    let url = v.get("webUrl").and_then(Value::as_str);
                    println!("web:      {}", web_line(url, show_token));
                    if let Some(line) = host_pressure_line(&v["host_pressure"]) {
                        println!("host:     {line}");
                    }
                    let login = match &v["loginSession"] {
                        Value::Bool(here) => Some(Some(*here)),
                        Value::String(s) if s == "unknown" => Some(None),
                        _ => None,
                    };
                    let own = v.get("ownHome").and_then(Value::as_bool).unwrap_or(true);
                    if let Some(line) =
                        login.and_then(|l| crate::daemon::login_placement::keychain_line(l, own))
                    {
                        println!("{line}");
                    }
                    for p in v.get("peers").and_then(Value::as_array).cloned().unwrap_or_default() {
                        println!(
                            "peer:     {} {} ({} sessions) {}",
                            p.get("name").and_then(Value::as_str).unwrap_or(""),
                            crate::peer_link::state_label(&p, crate::store::now_ms()),
                            p.get("sessions").and_then(Value::as_u64).unwrap_or(0),
                            p.get("url").and_then(Value::as_str).unwrap_or("")
                        );
                    }
                }
                // `daemon start` promised a running daemon: failing to start
                // one is an error, so callers such as `host setup` see it.
                Err(e) if start => return Err(e),
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
        Command::Shutdown { end_agents, keep_agents, restart } => {
            crate::cli::shutdown::run(end_agents, keep_agents, restart, json_out).await
        }
        Command::DaemonRestart => crate::cli::shutdown::restart(json_out).await,
        Command::Config { show_token, set } => {
            let path = Config::path();
            if let Some(assignment) = set {
                let (key, value) =
                    assignment.split_once('=').ok_or_else(|| anyhow!("--set expects KEY=VALUE"))?;
                let mut cfg = Config::load()?;
                cfg.set_session_resource(key, value)?;
                cfg.save()?;
                // Refresh the local daemon's cached config before reporting success;
                // a later defaults/token save must retain these resource settings.
                // Config is local even when the CLI targets a remote peer.
                if let Ok(client) =
                    crate::client::Client::connect(&crate::config::socket_path()).await
                {
                    client.request(method::MUX_RELOAD_CONFIG, json!({})).await?;
                }
                if json_out {
                    print_json(&json!({"path": path, "key": key, "value": value}));
                } else {
                    println!("set {key}={value} in {}", path.display());
                }
                return Ok(());
            }
            if json_out {
                let (written, config) = match std::fs::read_to_string(&path) {
                    Ok(s) => (true, serde_json::from_str::<Value>(&s).unwrap_or(Value::String(s))),
                    Err(_) => (false, serde_json::to_value(Config::load()?)?),
                };
                print_json(
                    &json!({"path": path, "written": written, "config": config, "home": home()}),
                );
                return Ok(());
            }
            println!("# {}", path.display());
            match std::fs::read_to_string(&path) {
                Ok(s) if show_token => println!("{s}"),
                Ok(s) => println!("{}", config_text_without_tokens(&s)),
                Err(_) => {
                    let cfg = Config::load()?;
                    println!("# (not written yet; effective defaults below)");
                    let s = serde_json::to_string_pretty(&cfg)?;
                    println!("{}", if show_token { s } else { config_text_without_tokens(&s) });
                }
            }
            println!("# home: {}", home().display());
            Ok(())
        }
        Command::Web { no_open, show_token, rotate_token } => {
            let client = connect(true).await?;
            let m = if rotate_token { method::MUX_WEB_TOKEN_ROTATE } else { method::MUX_STATUS };
            let v = client.request(m, json!({})).await?;
            let url = v
                .get("webUrl")
                .and_then(Value::as_str)
                .ok_or_else(|| anyhow!("daemon has no web listener"))?
                .to_owned();
            if json_out {
                // JSON mode is for scripts: report the URL, open nothing.
                print_json(&json!({"url": url}));
                return Ok(());
            }
            println!("{}", web_line(Some(&url), show_token));
            // The browser gets the whole link: without its token the page cannot connect.
            // The opener's own output stays out of the terminal: `xdg-open` with no
            // browser prints the link it was given, token and all.
            if !no_open {
                let opener = if cfg!(target_os = "macos") { "open" } else { "xdg-open" };
                if let Err(e) = std::process::Command::new(opener)
                    .arg(&url)
                    .stdin(std::process::Stdio::null())
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .spawn()
                {
                    eprintln!(
                        "acpmux: could not run {opener} ({e}); `acpmux web --no-open --show-token` prints the link"
                    );
                }
            }
            Ok(())
        }
        // No daemon connection: the update must work while the daemon does not.
        Command::Host(PeerCmd::SelfUpdate { channel }) => {
            crate::cli::hosts::self_update(&channel, json_out).await
        }
        // A file of this machine's; the daemon, when it runs, only reloads it.
        Command::Host(PeerCmd::Approvals { cmd }) => {
            crate::cli::host_approvals::run(cmd, json_out).await
        }
        Command::Host(PeerCmd::Join {
            ticket,
            name,
            hub,
            replace,
            status,
            peer_name,
            advertise,
        }) => {
            crate::cli::join_input::validate_arguments(
                ticket.as_deref(),
                hub.is_some(),
                replace,
                status,
            )?;
            if status {
                return crate::cli::cloud_join::status(hub, json_out).await;
            }
            // A process-wide file lock protects the check, redeem and commit as one
            // transaction. A second installer never redeems behind the first one.
            let _lock = crate::cli::cloud_join::join_lock().map_err(|_| {
                crate::cli::errors::AppError::new(
                    crate::cli::errors::Code::Runtime,
                    "join.store",
                    "local machine store is busy or unavailable",
                )
                .with_exit(5)
            })?;
            let value = match ticket {
                Some(value) => {
                    eprintln!("{}", crate::cli::pairing::ARGV_TICKET_WARNING);
                    zeroize::Zeroizing::new(value)
                }
                None => {
                    let joined = crate::cli::cloud_join::join_incomplete()?
                        || (!replace && crate::cli::cloud_join::credential_present()?);
                    match crate::cli::join_input::read_stdin_line(joined)? {
                        Some(value) => value,
                        None => {
                            return crate::cli::cloud_join::join_with_token(
                                hub, name, replace, json_out, None,
                            )
                            .await;
                        }
                    }
                }
            };
            if value.starts_with("cmj_") {
                let token = crate::cli::cloud_join::parse_token_text(&value).map_err(|_| {
                    crate::cli::errors::AppError::new(
                        crate::cli::errors::Code::Usage,
                        "join.malformed",
                        "join token is malformed",
                    )
                    .with_exit(2)
                })?;
                crate::cli::cloud_join::join_with_token(hub, name, replace, json_out, Some(token))
                    .await
            } else if value.starts_with("cmxt1.") {
                let ticket = crate::cli::pairing::join_ticket_text(&value)?;
                let client = connect(true).await?;
                let args = crate::cli::pairing::JoinArgs { ticket, name, peer_name, advertise };
                crate::cli::pairing::join(client, args, json_out).await
            } else {
                Err(crate::cli::errors::AppError::new(
                    crate::cli::errors::Code::Usage,
                    "join.malformed",
                    "join value has an unknown prefix",
                )
                .with_exit(2)
                .into())
            }
        }
        Command::Host(PeerCmd::Consent { cmd }) => {
            let (screen, control, granted) = match cmd {
                crate::cli::command_host::ConsentCmd::Grant { screen, control } => {
                    (screen, control, true)
                }
                crate::cli::command_host::ConsentCmd::Revoke { screen, control } => {
                    (screen, control, false)
                }
            };
            let surface = match (screen, control) {
                (true, false) => "screen",
                (false, true) => "control",
                _ => return Err(anyhow!("use exactly one of --screen or --control")),
            };
            let client = crate::client::Client::connect(&crate::config::socket_path()).await?;
            let value = client
                .request(
                    method::MUX_MACHINE_CONSENT_SET,
                    json!({"surface":surface,"granted":granted}),
                )
                .await?;
            if json_out {
                print_json(&value);
            } else {
                println!("consent updated: {surface}");
            }
            Ok(())
        }
        // A file of this person's: no daemon needed.
        Command::Host(PeerCmd::Hold { name, reason, until, release }) => {
            crate::cli::hosts::hold(name, reason, until, release, json_out)
        }
        // This machine's join: no daemon connection (a daemon that is down is a step).
        Command::Host(PeerCmd::Doctor { here: true, fix, .. }) => {
            let print = if json_out {
                crate::cli::host_join_doctor::Print::Lines
            } else {
                crate::cli::host_join_doctor::Print::Human
            };
            let code = crate::cli::host_join_doctor::run_here(fix, print, &mut std::io::stdout());
            if code != 0 {
                return Err(crate::cli::errors::AppError::new(
                    crate::cli::errors::Code::Runtime,
                    "unhealthy",
                    "this machine's join needs attention",
                )
                .into());
            }
            Ok(())
        }
        Command::Host(cmd) => {
            let client = connect(true).await?;
            let v = match cmd {
                PeerCmd::Add { name, url, token } => {
                    let url = url.unwrap_or_else(|| format!("ssh://{name}"));
                    let has_token = token.is_some();
                    // Save and start reconnecting without waiting for ssh's
                    // connect timeout. `host ls` reports the probe result.
                    let p = peer_add_params(&name, &url, token.as_deref());
                    let reply = client.request("_acpmux/peer_add", p).await?;
                    let connected = reply
                        .get("peers")
                        .and_then(Value::as_array)
                        .and_then(|peers| {
                            peers.iter().find(|peer| {
                                peer.get("name").and_then(Value::as_str) == Some(name.as_str())
                            })
                        })
                        .and_then(|peer| peer.get("connected").and_then(Value::as_bool))
                        .unwrap_or(false);
                    let warning = if !connected {
                        let host = url
                            .strip_prefix("ssh://")
                            .unwrap_or(&url)
                            .split(':')
                            .next()
                            .unwrap_or(&name);
                        let (message, warning) = if url.starts_with("ssh://") && has_token {
                            (
                                format!(
                                    "peer {name} was saved and is probing in the background; verify the SSH alias with `ssh -o BatchMode=yes {host} true`, then run `acpmux host ls` and retry after it shows connected (the saved WebSocket token is retained)"
                                ),
                                json!({
                                    "reason": "peer_probing",
                                    "try": format!("ssh -o BatchMode=yes {host} true"),
                                    "detail": "the peer was saved and is probing in the background"
                                }),
                            )
                        } else if url.starts_with("ssh://") {
                            (
                                format!(
                                    "peer {name} was saved and is probing in the background; verify the SSH alias with `ssh -o BatchMode=yes {host} true`, then run `acpmux host doctor {name} --json`"
                                ),
                                json!({
                                    "reason": "peer_probing",
                                    "try": format!("ssh -o BatchMode=yes {host} true"),
                                    "detail": "the peer was saved and is probing in the background"
                                }),
                            )
                        } else {
                            (
                                format!(
                                    "peer {name} was saved and is probing in the background; run `acpmux host ls` and retry after it shows connected"
                                ),
                                json!({
                                    "reason": "peer_probing",
                                    "try": "acpmux host ls",
                                    "detail": "the peer was saved and is probing in the background"
                                }),
                            )
                        };
                        if !json_out {
                            eprintln!("warning: {message}");
                        }
                        Some(warning)
                    } else {
                        None
                    };
                    let mut reply = reply;
                    if let Some(warning) = warning {
                        reply["warning"] = warning;
                    }
                    reply
                }
                PeerCmd::Ls => client.request("_acpmux/peers", json!({})).await?,
                PeerCmd::Status { name } => {
                    let v = client.request("_acpmux/peer_status", json!({"name": name})).await?;
                    if json_out {
                        print_json(&v);
                    } else {
                        crate::cli::peer_status::print(&v);
                    }
                    return Ok(());
                }
                PeerCmd::Place { build } => {
                    let work = if build { "build" } else { "agent" };
                    let v = client.request("_acpmux/place", json!({"work": work})).await?;
                    if json_out {
                        print_json(&v);
                    } else {
                        crate::cli::place::lines(&v).iter().for_each(|l| println!("{l}"));
                    }
                    return Ok(());
                }
                PeerCmd::VmHost { name, state } => {
                    // `vm-host on` names no peer: the state alone.
                    let (name, state) = match (name, state) {
                        (Some(n), None) if n == "on" || n == "off" => (None, Some(n)),
                        other => other,
                    };
                    let mut p = json!({"on": state.as_deref().map(|s| s == "on")});
                    if let Some(name) = &name {
                        p["name"] = json!(name);
                    }
                    let v = client.request("_acpmux/vm_host", p).await?;
                    if json_out {
                        print_json(&v);
                    } else {
                        println!("{}", crate::cli::peer_status::vm_host_line(name.as_deref(), &v));
                    }
                    return Ok(());
                }
                PeerCmd::Rm { name } => {
                    client.request("_acpmux/peer_remove", json!({"name": name})).await?
                }
                PeerCmd::Setup { host, name, port, no_auto_update } => {
                    let auto = !no_auto_update;
                    return crate::cli::hosts::setup(client, &host, name, port, auto, json_out)
                        .await;
                }
                // Dispatched before the connect (above); kept here so the
                // match stays total without a panic.
                PeerCmd::SelfUpdate { channel } => {
                    return crate::cli::hosts::self_update(&channel, json_out).await;
                }
                PeerCmd::Hold { name, reason, until, release } => {
                    return crate::cli::hosts::hold(name, reason, until, release, json_out);
                }
                PeerCmd::Approvals { cmd } => {
                    return crate::cli::host_approvals::run(cmd, json_out).await;
                }
                PeerCmd::Update { name, all, binary_dir, if_idle, keep_newer } => {
                    // Run from a session, `--if-idle` never waits on that session's own turn.
                    let caller = match std::env::var("ACPMUX_SESSION_ID") {
                        Ok(session) if if_idle && !session.is_empty() => {
                            let status = client.request(method::MUX_STATUS, json!({})).await?;
                            status.get("personInstance").and_then(Value::as_str).map(|d| {
                                crate::cli::hosts::Caller { session, daemon: d.to_owned() }
                            })
                        }
                        _ => None,
                    };
                    let opts = crate::cli::hosts::UpdateOptions {
                        binary_dir,
                        if_idle,
                        keep_newer,
                        caller,
                    };
                    return crate::cli::hosts::update(client, name, all, opts, json_out).await;
                }
                PeerCmd::Enroll { host, name, harnesses, remote_binary, reverse } => {
                    let plan = crate::cli::host_enroll::Plan::enroll(
                        host,
                        name,
                        harnesses,
                        remote_binary,
                        reverse,
                    );
                    return crate::cli::host_enroll::run(client, plan, true, json_out).await;
                }
                PeerCmd::Doctor { target, fix, harnesses, remote_binary, reverse, .. } => {
                    let target = target.unwrap_or_default();
                    let peers = client.request("_acpmux/peers", json!({})).await?;
                    let list =
                        peers.get("peers").and_then(Value::as_array).cloned().unwrap_or_default();
                    let (name, host, port) = crate::cli::host_enroll::pick_target(&list, &target);
                    let plan = crate::cli::host_enroll::Plan {
                        name,
                        host,
                        port,
                        harnesses,
                        remote_binary,
                        reverse,
                        lends_github: false,
                    };
                    return crate::cli::host_enroll::run(client, plan, fix, json_out).await;
                }
                PeerCmd::Candidates { probe } => {
                    return crate::cli::host_candidates::run(&client, probe, json_out).await;
                }
                PeerCmd::Ticket(cmd) => {
                    return crate::cli::pairing::ticket(client, cmd, json_out).await;
                }
                PeerCmd::Join { .. } | PeerCmd::Consent { .. } => {
                    return Err(anyhow!(
                        "host join and consent are handled before daemon connection"
                    ));
                }
            };
            if json_out {
                print_json(&v);
                return Ok(());
            }
            let peers = v.get("peers").and_then(Value::as_array).cloned().unwrap_or_default();
            if peers.is_empty() {
                println!("no peers (add one: acpmux host add HOST)");
            }
            for p in peers {
                let state = crate::peer_link::state_label(&p, crate::store::now_ms());
                let build = p.get("remoteBuild").and_then(Value::as_str).unwrap_or("");
                println!(
                    "{:<16} {:<10} {:>3} sessions  {}  {:<24} {}{}{}{}",
                    p.get("name").and_then(Value::as_str).unwrap_or(""),
                    state,
                    p.get("sessions").and_then(Value::as_u64).unwrap_or(0),
                    crate::cli::peer_status::resources(&p),
                    p.get("url").and_then(Value::as_str).unwrap_or(""),
                    if build.is_empty() { String::new() } else { format!("build {build}") },
                    crate::cli::peer_status::outdated_hint(
                        p.get("name").and_then(Value::as_str).unwrap_or(""),
                        &p,
                    )
                    .unwrap_or_default(),
                    p.get("error")
                        .and_then(Value::as_str)
                        .map(|e| format!("  ({e})"))
                        .unwrap_or_default(),
                    // A user or port: another account's or another daemon on that machine.
                    p.get("canonicalEndpoint")
                        .and_then(Value::as_str)
                        .map(|c| format!("  (not the canonical endpoint {c})"))
                        .unwrap_or_default(),
                );
            }
            Ok(())
        }
        Command::Router(_)
        | Command::DaemonRun { .. }
        | Command::Stdio { .. }
        | Command::CliAgent { .. }
        | Command::UniichatAgent { .. }
        | Command::Daemon(_)
        | Command::Harness(_) => {
            unreachable!()
        }
        _ => Err(anyhow!("command routed to the wrong dispatch family")),
    }
}

/// The `web:` line of `daemon status` and `daemon start`, and what `acpmux web`
/// prints: the Web UI link without its bearer token unless `show_token`
/// (ergo-walk2, 2026-10-25: a terminal, a screen share or a pasted log is no
/// place for it; ergo-walk4, 2026-10-26, for `web --no-open`).
fn web_line(url: Option<&str>, show_token: bool) -> String {
    let Some(url) = url else { return "-".into() };
    if show_token {
        return url.to_owned();
    }
    match url.split_once("?token=") {
        Some((bare, _)) => format!("{bare} (token hidden: add --show-token)"),
        None => url.to_owned(),
    }
}

/// What a hidden token reads as in `daemon config`.
const HIDDEN_TOKEN: &str = "(token hidden: add --show-token)";

/// config.json as `daemon config` prints it: its JSON printed anew (keys
/// sorted) with the bearer tokens in it replaced by [`HIDDEN_TOKEN`]: the
/// listener's `websocket.token`, a peer's `token` and `peerToken`, and the
/// userinfo, query and fragment of a peer's `url` (ergo-walk4, 2026-10-26:
/// "`acpmux daemon config` human output prints websocket.token in full").
/// Never the file's own text: a duplicate key or an escaped spelling keeps a
/// token there that the parsed config no longer shows. A file that is not
/// JSON is named, not printed: it may hold a token all the same.
fn config_text_without_tokens(text: &str) -> String {
    let mut value = match serde_json::from_str::<Value>(text) {
        Ok(value) => value,
        Err(e) => {
            return format!(
                "# (not valid JSON: {e}; it may hold tokens: add --show-token to print it)"
            );
        }
    };
    let hide = |slot: Option<&mut Value>| {
        if let Some(slot) = slot
            && slot.as_str().is_some_and(|s| !s.is_empty())
        {
            *slot = Value::String(HIDDEN_TOKEN.into());
        }
    };
    hide(value.pointer_mut("/websocket/token"));
    if let Some(peers) = value.get_mut("peers").and_then(Value::as_object_mut) {
        for peer in peers.values_mut() {
            hide(peer.get_mut("token"));
            hide(peer.get_mut("peerToken"));
            if let Some(url) = peer.get_mut("url")
                && let Some(text) = url.as_str()
            {
                let bare = crate::server::url_without_secrets(text);
                if bare != text {
                    *url = Value::String(format!("{bare} {HIDDEN_TOKEN}"));
                }
            }
        }
    }
    serde_json::to_string_pretty(&value).unwrap_or_else(|_| HIDDEN_TOKEN.into())
}

#[cfg(test)]
mod tests {
    use super::{peer_add_params, resume_moves_off};
    use serde_json::json;

    #[test]
    fn resume_moves_a_stopped_chat_off_a_machine_a_person_works_at_and_nothing_else() {
        for status in ["closed", "idle", "disconnected"] {
            let info = json!({"status": status, "peer": null, "turn": null, "movedTo": null});
            assert!(resume_moves_off(&info, true), "{status}");
            assert!(!resume_moves_off(&info, false), "{status}: a fleet host resumes in place");
        }
        // A live agent, a turn, a peer's chat, one moving or moved away: resumed where it is.
        for info in [
            json!({"status": "ready"}),
            json!({"status": "running"}),
            json!({"status": "waiting"}),
            json!({"status": "idle", "turn": {"turnId": "t"}}),
            json!({"status": "closed", "peer": "gcp-1"}),
            json!({"status": "closed", "moving": true}),
            json!({"status": "closed", "movedTo": {"host": "gcp-1", "sessionId": "m"}}),
        ] {
            assert!(!resume_moves_off(&info, true), "{info}");
        }
    }

    #[test]
    fn host_add_saves_without_waiting_for_the_first_probe() {
        let params = peer_add_params("blackhole", "ssh://192.0.2.10", None);
        assert_eq!(params["wait"], false);
        assert_eq!(params["name"], "blackhole");
        assert_eq!(params["url"], "ssh://192.0.2.10");
    }

    #[test]
    fn host_add_keeps_a_supplied_peer_token() {
        let params = peer_add_params("peer", "wss://peer.example", Some("secret"));
        assert_eq!(params["token"], "secret");
        assert_eq!(params["wait"], false);
    }
}
