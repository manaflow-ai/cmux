//! Owns the remaining daemon, session maintenance, peer, and output commands.

use super::*;

pub(super) async fn run(cmd: Command, json_out: bool, _suppress_reads: bool) -> Result<()> {
    match cmd {
        Command::Cancel { session } => {
            let client = connect(true).await?;
            let id = resolve_id(&client, &session).await?;
            // As a request, the reply says the daemon handled the cancel.
            client.request(method::SESSION_CANCEL, json!({"sessionId": id})).await?;
            if json_out {
                print_json(&json!({"sessionId": id, "cancelSent": true}));
            } else {
                println!("cancel sent");
            }
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
        Command::ResumeQueue { session } => {
            let client = connect(true).await?;
            let id = resolve_id(&client, &session).await?;
            let info = client.request(method::MUX_INFO, json!({"sessionId": id})).await?;
            // `_acpmux/queue_edit` `resume` names the queue by any of its prompts: a held one.
            let held = info["queue"]
                .as_array()
                .into_iter()
                .flatten()
                .find(|q| q["held"] == true)
                .and_then(|q| q["promptId"].as_str())
                .map(str::to_owned);
            let resumed = match held {
                Some(prompt_id) => {
                    let v = client
                        .request(
                            method::MUX_QUEUE_EDIT,
                            json!({"sessionId": id, "promptId": prompt_id, "op": "resume"}),
                        )
                        .await?;
                    v["ok"] == true
                }
                None => false,
            };
            if json_out {
                print_json(&json!({"sessionId": id, "resumed": resumed}));
            } else if resumed {
                println!("resumed");
            } else {
                println!("nothing is held");
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
        Command::Answer { session, answer } => answer_question(&session, &answer).await,
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
        Command::Shutdown { end_agents, .. } => {
            crate::cli::shutdown::run(end_agents, json_out).await
        }
        Command::Config => {
            let path = Config::path();
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
        Command::Web { no_open, rotate_token } => {
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
        // No daemon connection: the update must work while the daemon does not.
        Command::Host(PeerCmd::SelfUpdate { channel }) => {
            crate::cli::hosts::self_update(&channel, json_out).await
        }
        Command::Host(cmd) => {
            let client = connect(true).await?;
            let v = match cmd {
                PeerCmd::Add { name, url, token } => {
                    let url = url.unwrap_or_else(|| format!("ssh://{name}"));
                    let has_token = token.is_some();
                    let mut p = json!({"name": name, "url": url});
                    if let Some(t) = token {
                        p["token"] = json!(t);
                    }
                    // `wait`: the daemon answers after the first connect attempt
                    // settled, so the listing shows the real state.
                    p["wait"] = json!(true);
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
                                    "peer {name} was saved and will keep reconnecting; verify the SSH alias with `ssh -o BatchMode=yes {host} true`, then run `acpmux host ls` and retry after it shows connected (the saved WebSocket token is retained)"
                                ),
                                json!({
                                    "reason": "peer_unreachable",
                                    "try": format!("ssh -o BatchMode=yes {host} true"),
                                    "detail": "the peer was saved and will keep reconnecting"
                                }),
                            )
                        } else if url.starts_with("ssh://") {
                            (
                                format!(
                                    "peer {name} was saved and will keep reconnecting; verify the SSH alias with `ssh -o BatchMode=yes {host} true`, then run `acpmux host doctor {name} --json`"
                                ),
                                json!({
                                    "reason": "peer_unreachable",
                                    "try": format!("ssh -o BatchMode=yes {host} true"),
                                    "detail": "the peer was saved and will keep reconnecting"
                                }),
                            )
                        } else {
                            (
                                format!(
                                    "peer {name} was saved and will keep reconnecting; run `acpmux host ls` and retry after it shows connected"
                                ),
                                json!({
                                    "reason": "peer_unreachable",
                                    "try": "acpmux host ls",
                                    "detail": "the peer was saved and will keep reconnecting"
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
                PeerCmd::Doctor { target, fix, harnesses, remote_binary, reverse } => {
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
                    };
                    return crate::cli::host_enroll::run(client, plan, fix, json_out).await;
                }
                PeerCmd::Candidates { probe } => {
                    return crate::cli::host_candidates::run(&client, probe, json_out).await;
                }
                PeerCmd::Ticket(cmd) => {
                    return crate::cli::pairing::ticket(client, cmd, json_out).await;
                }
                PeerCmd::Join { ticket, name, peer_name, advertise } => {
                    let args = crate::cli::pairing::JoinArgs { ticket, name, peer_name, advertise };
                    return crate::cli::pairing::join(client, args, json_out).await;
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
                let outdated = p.get("outdated").and_then(Value::as_bool).unwrap_or(false);
                println!(
                    "{:<16} {:<10} {:>3} sessions  {}  {:<24} {}{}{}{}",
                    p.get("name").and_then(Value::as_str).unwrap_or(""),
                    state,
                    p.get("sessions").and_then(Value::as_u64).unwrap_or(0),
                    crate::cli::peer_status::resources(&p),
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
        | Command::Session(_)
        | Command::Daemon(_)
        | Command::Harness(_) => {
            unreachable!()
        }
        _ => Err(anyhow!("command routed to the wrong dispatch family")),
    }
}

/// The `web:` line of `daemon status` and `daemon start`: the Web UI link
/// without its bearer token unless `show_token` (ergo-walk2, 2026-10-25: a
/// terminal, a screen share or a pasted log is no place for it).
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
