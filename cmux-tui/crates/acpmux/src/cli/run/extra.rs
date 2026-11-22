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
        which @ (Command::Status | Command::DaemonStart) => {
            match connect(matches!(which, Command::DaemonStart)).await {
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
                // `daemon start` promised a running daemon: failing to start
                // one is an error, so callers such as `host setup` see it.
                Err(e) if matches!(which, Command::DaemonStart) => return Err(e),
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
        Command::Shutdown { keep_agents } => crate::cli::shutdown::run(keep_agents, json_out).await,
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
        Command::Peer(cmd) => {
            let client = connect(true).await?;
            let v = match cmd {
                PeerCmd::Add { name, url, token } => {
                    let mut p = json!({"name": name, "url": url});
                    if let Some(t) = token {
                        p["token"] = json!(t);
                    }
                    // `wait`: the daemon answers after the first connect attempt
                    // settled, so the listing shows the real state.
                    p["wait"] = json!(true);
                    client.request("_acpmux/peer_add", p).await?
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
        Command::Router(_)
        | Command::DaemonRun { .. }
        | Command::Stdio { .. }
        | Command::Session(_)
        | Command::Daemon(_)
        | Command::Harness(_)
        | Command::Host(_) => {
            unreachable!()
        }
        _ => Err(anyhow!("command routed to the wrong dispatch family")),
    }
}
