//! Owns the remaining daemon, session maintenance, peer, and output commands.

use super::*;
use anyhow::Context;

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

/// `session pause` and `session wake` need a daemon that serves them (`hub/pause.rs`).
fn unsupported_pause(client: &Client) -> Result<()> {
    if client.daemon_lists(crate::hub::pause::FEATURE) {
        return Ok(());
    }
    Err(crate::cli::errors::AppError::new(
        crate::cli::errors::Code::Runtime,
        "session_pause_unsupported",
        "the running daemon predates `session pause` and `session wake`: restart it on the \
         installed acpmux, then retry",
    )
    .into())
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

/// What `session resume` prints when nothing ran: the hold a daemon start keeps for a person
/// (`personHold` in `MUX_INFO`, `hub/protected_hold.rs`) and how to release it, else that
/// nothing is held. A lane VM's chats run in its home folder and no person opens them there, so
/// "nothing is held" over a queue that never drained sent people looking elsewhere.
pub(super) fn not_resumed_line(info: &Value, session: &str) -> String {
    let Some(hold) = info.get("personHold").filter(|h| h.is_object()) else {
        return "nothing is held".to_owned();
    };
    let reason = hold["reason"].as_str().unwrap_or("its folder is guarded");
    format!(
        "held for a person: {reason}. Its queue runs when someone opens the chat in cmux or sends it a prompt; `acpmux session resume {session} --open` opens it now"
    )
}

/// Opens chat `id` as the cmux app does when a person clicks it (a visible attach, then a
/// detach): the release of a daemon start's hold for a person (`Hub::release_protected_hold`).
async fn open_as_person(client: &Client, id: &str) -> Result<()> {
    client
        .request(method::MUX_ATTACH, json!({"sessionId": id, "visible": true, "limit": 0}))
        .await?;
    client.request(method::MUX_DETACH, json!({"sessionId": id})).await?;
    Ok(())
}

/// What `session resume` prints when it moved the chat first.
fn moved_line(host: &str) -> String {
    format!(
        "moved to {host} (as `session move --machine auto` does): this machine is one a person works at, so a stopped chat resumes on a fleet host"
    )
}

pub(super) async fn run(cmd: Command, json_out: bool, _suppress_reads: bool) -> Result<()> {
    match cmd {
        Command::ClearPeerSnapshots => crate::daemon::clear_peer_snapshots().await,
        Command::Session(control) => crate::cli::mesh_control::run(control, json_out).await,
        Command::Retention(args) => {
            let client = connect(true).await?;
            let archive = args.archive.map(std::path::absolute).transpose()?;
            let v = client
                .request(
                    method::MUX_RETENTION,
                    json!({"dryRun": args.dry_run, "archive": archive, "olderThanDays": args.older_than_days, "only": args.only, "unreadOnly": args.unread_only}),
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
                let read_back = v.get("readBack").and_then(|r| r.as_array());
                for chat in read_back.into_iter().flatten() {
                    let text = |key: &str| chat.get(key).and_then(|x| x.as_str()).unwrap_or("?");
                    let num = |key: &str| chat.get(key).and_then(|x| x.as_u64()).unwrap_or(0);
                    println!(
                        "{}: {} -> {} bytes, reads back the same {} rows (digest {})",
                        text("sessionId"),
                        num("bytesBefore"),
                        num("bytesAfter"),
                        num("rows"),
                        text("digest")
                    );
                }
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
        Command::Kill { session, purge, condition, close } => {
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
            // Recorded with the close (`close_why.rs`); an older daemon ignores them.
            if let Some(reason) = close.reason {
                cmux_json::JsonSet::set(&mut params, "reason", json!(reason));
            }
            if let Some(outcome) = close.outcome {
                cmux_json::JsonSet::set(&mut params, "outcome", json!(outcome));
            }
            let v = client.request(method::MUX_KILL, params).await?;
            if json_out {
                print_json(&v)
            } else {
                println!("{}", if purge { "purged" } else { "closed" })
            }
            Ok(())
        }
        Command::PauseAgent { session } => {
            let client = connect(true).await?;
            unsupported_pause(&client)?;
            let id = resolve_id(&client, &session).await?;
            let v = client.request(method::MUX_PAUSE, json!({"sessionId": id})).await?;
            if json_out {
                print_json(&v);
            } else if v["paused"] == true {
                println!(
                    "paused: its agent exited in {} ms; its next prompt or `acpmux session wake {session}` resumes the same conversation",
                    v["exitMs"]
                );
            } else if v["reason"] == "paused" {
                println!("already paused");
            } else {
                println!("not running: it is stopped, and its next prompt resumes it");
            }
            Ok(())
        }
        Command::WakeAgent { session } => {
            let client = connect(true).await?;
            unsupported_pause(&client)?;
            let id = resolve_id(&client, &session).await?;
            let v = client.request(method::MUX_WAKE, json!({"sessionId": id})).await?;
            if json_out {
                print_json(&v);
            } else if v["woke"] == true {
                println!("resumed its conversation in {} ms", v["tookMs"]);
            } else if v["reason"] == "running" {
                println!("not paused: its agent is running");
            } else {
                println!("not paused: it is stopped, and its next prompt resumes it");
            }
            Ok(())
        }
        Command::SessionHold {
            session,
            held,
            fleet,
            allow,
            set_allow,
            reason,
            status,
            hold_for,
        } => {
            let client = connect(true).await?;
            if !client.daemon_lists(crate::hub::session_hold::FEATURE) {
                return Err(crate::cli::errors::AppError::new(
                    crate::cli::errors::Code::Runtime,
                    "session_hold_unsupported",
                    "the running daemon predates `session hold`: restart it on the installed \
                     acpmux, then retry",
                )
                .into());
            }
            if fleet {
                fn allow_of(v: &Value) -> Vec<String> {
                    v.pointer("/fleetHold/allow")
                        .and_then(Value::as_array)
                        .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect())
                        .unwrap_or_default()
                }
                fn shown(a: &[String]) -> String {
                    if a.is_empty() { "none".to_owned() } else { a.join(", ") }
                }
                // Read first: `--allow` adds to what is there, and the change is printed.
                let before = client.request(method::MUX_FLEET_HOLD, json!({})).await?;
                let hold_now = serde_json::from_value::<crate::hub::session_hold::FleetHold>(
                    before.get("fleetHold").cloned().unwrap_or_default(),
                )
                .unwrap_or_default();
                let active = hold_now.active(crate::store::now_ms());
                if status {
                    if json_out {
                        print_json(&before);
                    } else if active {
                        println!("{}", crate::cli::hold_line::fleet_hold_line(&hold_now, None));
                        println!("allowed: {}", shown(&allow_of(&before)));
                    } else {
                        println!("fleet hold off");
                    }
                    return Ok(());
                }
                // `--allow` adds to a hold that is on; with none on it is no order to start one
                // (2026-11-25: `hold --fleet --allow X` meant to admit X started a hold that idled
                // every other chat on the host). `--set-allow`, or `hold --fleet` alone, starts one.
                if held && !active && !allow.is_empty() && set_allow.is_none() {
                    if json_out {
                        print_json(&json!({"fleetHold": hold_now, "changed": false,
                            "reason": "no_fleet_hold"}));
                    } else {
                        println!(
                            "fleet hold off: --allow only adds to a hold that is on, so nothing \
                             changed. To start a hold that lets only these run: `acpmux session \
                             hold --fleet --set-allow {}`",
                            allow.join(",")
                        );
                    }
                    return Ok(());
                }
                let was = if active { allow_of(&before) } else { Vec::new() };
                let next = crate::hub::session_hold::next_allow(&was, set_allow.as_deref(), &allow);
                let mut p = json!({"on": held, "allow": next});
                if held {
                    let for_ms = match hold_for.as_deref().map(str::trim) {
                        None => crate::hub::session_hold::DEFAULT_FOR_MS,
                        Some("never" | "0") => 0,
                        Some(text) => crate::cli::run::ls::parse_duration_ms(text)?,
                    };
                    cmux_json::JsonSet::set(&mut p, "forMs", json!(for_ms));
                    let by = std::env::var("ACPMUX_SESSION_NAME")
                        .ok()
                        .or_else(|| std::env::var("ACPMUX_SESSION_ID").ok())
                        .filter(|v| !v.trim().is_empty())
                        .unwrap_or_else(|| "person".to_owned());
                    cmux_json::JsonSet::set(&mut p, "by", json!(by));
                }
                let reason = reason.or_else(|| {
                    held.then(|| before.pointer("/fleetHold/reason").and_then(Value::as_str))
                        .flatten()
                        .map(str::to_owned)
                });
                if let Some(reason) = reason {
                    cmux_json::JsonSet::set(&mut p, "reason", json!(reason));
                }
                let v = client.request(method::MUX_FLEET_HOLD, p).await?;
                if json_out {
                    print_json(&v);
                } else if v.pointer("/fleetHold/on").and_then(Value::as_bool) == Some(true) {
                    let now = allow_of(&v);
                    let set: crate::hub::session_hold::FleetHold =
                        serde_json::from_value(v["fleetHold"].clone()).unwrap_or_default();
                    println!(
                        "{}",
                        crate::cli::hold_line::fleet_hold_line(
                            &set,
                            v.get("held").and_then(Value::as_u64)
                        )
                    );
                    println!("allowed before: {}", shown(&was));
                    println!("allowed now:    {}", shown(&now));
                    let dropped: Vec<_> =
                        was.iter().filter(|a| !now.contains(a)).cloned().collect();
                    if !dropped.is_empty() {
                        println!("dropped (--set-allow): {}", dropped.join(", "));
                    }
                } else {
                    println!("fleet hold off");
                }
                return Ok(());
            }
            let Some(session) = session else {
                anyhow::bail!("name a session, or pass --fleet");
            };
            let id = resolve_id(&client, &session).await?;
            let v = client
                .request(method::MUX_SESSION_HOLD, json!({"sessionId": id, "held": held}))
                .await?;
            if json_out {
                print_json(&v);
            } else if held {
                println!(
                    "held{}: messages wait in its inbox; its person's prompt, opening it, or `acpmux session release {session}` lets it run",
                    if v.get("paused").and_then(Value::as_bool) == Some(true) {
                        ", its agent paused"
                    } else {
                        ""
                    }
                );
            } else {
                println!("released: it runs its next prompt");
            }
            Ok(())
        }
        Command::RouteDeath { facts } => {
            let text = if facts.as_os_str() == "-" {
                let mut buf = String::new();
                std::io::Read::read_to_string(&mut std::io::stdin(), &mut buf)?;
                buf
            } else {
                std::fs::read_to_string(&facts)
                    .with_context(|| format!("reading {}", facts.display()))?
            };
            let f: crate::death_route::Facts =
                serde_json::from_str(&text).context("facts are not the death-route JSON")?;
            print_json(&serde_json::to_value(crate::death_route::route(&f))?);
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
            search,
            before,
            subscribe,
            unsubscribe,
            subscriptions,
            thread,
            unread,
        }) => {
            let client = connect(true).await?;
            crate::cli::session_inbox::run(
                &client,
                &session,
                thread.as_deref(),
                unread,
                search.as_deref(),
                before,
                subscribe.as_deref(),
                unsubscribe.as_deref(),
                subscriptions,
                json_out,
            )
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
        Command::ResumeQueue { session, open } => {
            let client = connect(true).await?;
            let mut id = crate::cli::resolve::control_id(&client, &session).await?;
            let mut info = client.request(method::MUX_INFO, json!({"sessionId": id})).await?;
            // Released as a person's open: its restored queue starts by itself (`start_restored`).
            let mut opened = false;
            if open && info.get("personHold").is_some_and(Value::is_object) {
                open_as_person(&client, &id).await?;
                opened = true;
                info = client.request(method::MUX_INFO, json!({"sessionId": id})).await?;
            }
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
                None => resume_held(&client, &id, &info).await? || opened,
            };
            if json_out {
                print_json(&json!({
                    "sessionId": id,
                    "resumed": resumed,
                    "movedTo": moved_to,
                    "opened": opened,
                    "personHold": info.get("personHold").cloned().unwrap_or(Value::Null),
                }));
            } else if opened {
                println!("opened: what waited for a person runs now");
            } else if resumed {
                println!("resumed");
            } else {
                println!("{}", not_resumed_line(&info, &session));
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
        Command::Register { renew: true, .. } => {
            // A hook's step: bounded, silent, and never a failure the session sees.
            let v = crate::cli::reply_address::renew().await;
            if json_out {
                print_json(&v);
            }
            Ok(())
        }
        Command::Register { name, code, renew: false } => {
            let name = name.unwrap_or_default();
            let client = connect(true).await?;
            let env = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
            // Claude Code exports both to its Bash commands and hooks (its documented inbox).
            let socket = env("CLAUDE_CODE_MESSAGING_SOCKET");
            let token = socket.as_ref().and(env("CLAUDE_CODE_MESSAGING_TOKEN"));
            let params = json!({"name": name, "socket": socket, "token": token, "code": code});
            let v = client.request(method::MUX_REGISTER, params).await?;
            if json_out {
                print_json(&v)
            } else if v.get("pending").and_then(Value::as_bool) == Some(true) {
                println!(
                    "sent a one-time code into this session's inbox: it arrives as a message from acpmux; run the `{} register {name} --code ...` it gives to finish",
                    crate::cli::entry::program()
                );
            } else {
                let field =
                    |k: &str| v.get(k).and_then(Value::as_str).unwrap_or_default().to_owned();
                let how = match field("token").as_str() {
                    "registered" => "delivered with its own messaging token",
                    _ => "reached over ACP",
                };
                println!(
                    "registered {} ({} session {}): {how}",
                    field("name"),
                    field("family"),
                    field("agentSessionId")
                );
            }
            Ok(())
        }
        Command::Succeed { session, names } => {
            let client = connect(true).await?;
            let id = crate::cli::resolve::control_id(&client, &session).await?;
            let v = client
                .request(method::MUX_SUCCEED, json!({"sessionId": id, "names": names}))
                .await?;
            if json_out {
                print_json(&v);
            } else {
                let added: Vec<&str> =
                    v["added"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
                println!("{id} answers to {}", added.join(", "));
            }
            Ok(())
        }
        Command::Role { cmd } => {
            let client = connect(true).await?;
            let (op, params) = match cmd {
                RoleCmd::Ls => ("ls", json!({"op": "ls"})),
                RoleCmd::Claim { address, session } => {
                    let id = crate::cli::resolve::control_id(&client, &session).await?;
                    ("claim", json!({"op": "claim", "sessionId": id, "address": address}))
                }
                RoleCmd::Release { address, session } => {
                    let id = crate::cli::resolve::control_id(&client, &session).await?;
                    ("release", json!({"op": "release", "sessionId": id, "address": address}))
                }
            };
            let v = client.request(method::MUX_ROLE, params).await?;
            if json_out {
                print_json(&v);
                return Ok(());
            }
            match op {
                "ls" => {
                    for row in v["sessions"].as_array().into_iter().flatten() {
                        let roles: Vec<&str> = row["roles"]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .filter_map(|r| r["address"].as_str())
                            .collect();
                        let succeeds: Vec<&str> = row["succeeds"]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .filter_map(Value::as_str)
                            .collect();
                        println!(
                            "{}\troles: {}\tsucceeds: {}",
                            row["name"].as_str().unwrap_or_default(),
                            if roles.is_empty() { "-".into() } else { roles.join(", ") },
                            if succeeds.is_empty() { "-".into() } else { succeeds.join(", ") },
                        );
                    }
                }
                "claim" => println!(
                    "{} holds {}",
                    v["sessionId"].as_str().unwrap_or_default(),
                    v["address"].as_str().unwrap_or_default()
                ),
                _ => println!(
                    "{} gave up {}",
                    v["sessionId"].as_str().unwrap_or_default(),
                    v["address"].as_str().unwrap_or_default()
                ),
            }
            Ok(())
        }
        Command::Icon { session, icon } => {
            let client = connect(true).await?;
            let id = crate::cli::resolve::control_id(&client, &session).await?;
            let Some(icon) = icon else {
                let v = client.request(method::MUX_INFO, json!({"sessionId": id})).await?;
                if json_out {
                    print_json(&v.get("icon").cloned().unwrap_or_default());
                    return Ok(());
                }
                match serde_json::from_value::<crate::session_icon::SessionIcon>(
                    v.get("icon").cloned().unwrap_or_default(),
                ) {
                    Ok(icon) => println!("{}", icon.describe()),
                    Err(_) => println!("none (its harness mark)"),
                }
                return Ok(());
            };
            let wire = crate::cli::icon_input::wire(&icon).await?;
            let v = client
                .request(method::MUX_RENAME, json!({"sessionId": id, "newIcon": wire}))
                .await?;
            if json_out {
                print_json(&v);
            } else {
                match serde_json::from_value::<crate::session_icon::SessionIcon>(
                    v.get("icon").cloned().unwrap_or_default(),
                ) {
                    Ok(icon) => println!("{}", icon.describe()),
                    Err(_) => println!("cleared"),
                }
            }
            Ok(())
        }
        Command::Rename { session, new_name, handle, icon } => {
            let client = connect(true).await?;
            let id = if handle {
                crate::cli::resolve::control_id(&client, &session).await?
            } else {
                resolve_id(&client, &session).await?
            };
            let mut params = if handle {
                json!({"sessionId": id, "newHandle": new_name})
            } else {
                json!({"sessionId": id, "newName": new_name})
            };
            if let (Some(icon), Some(fields)) = (icon, params.as_object_mut()) {
                fields.insert("newIcon".into(), json!(crate::cli::icon_input::wire(&icon).await?));
            }
            let v = client.request(method::MUX_RENAME, params).await?;
            if json_out {
                print_json(&v)
            } else if handle {
                println!(
                    "{}",
                    v["handle"].as_str().ok_or_else(|| anyhow!("rename returned no handle"))?
                );
            } else {
                println!("renamed")
            }
            Ok(())
        }
        Command::Fork { session, name, cwd, force_admit, harness, model } => {
            let client = connect(true).await?;
            let id = resolve_id(&client, &session).await?;
            let mut acpmux = serde_json::Map::new();
            if let Some(n) = name {
                acpmux.insert("name".into(), json!(n));
            }
            if force_admit {
                acpmux.insert("forceAdmit".into(), json!(true));
            }
            if let Some(h) = harness {
                acpmux.insert("harness".into(), json!(h));
            }
            if let Some(m) = model {
                acpmux.insert("model".into(), json!(m));
            }
            // One id for this fork, sent again on the retry after a daemon restart: the daemon
            // answers the fork the first request made instead of a second one (cmux#50084).
            acpmux.insert("requestId".into(), json!(uuid::Uuid::now_v7().to_string()));
            let mut p = json!({"sessionId": id, "mcpServers": [], "_meta": {"acpmux": acpmux}});
            if let Some(c) = cwd {
                p["cwd"] = json!(c);
            }
            let v = match client.request(method::SESSION_FORK, p.clone()).await {
                Err(e) if crate::cli::output::daemon_closed_error(&e) => {
                    let client = crate::cli::output::reconnect_after_update().await?;
                    client.request(method::SESSION_FORK, p).await?
                }
                answer => answer?,
            };
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
                    let v = client
                        .request(
                            method::SESSION_SET_MODEL,
                            json!({"sessionId": id, "modelId": val}),
                        )
                        .await?;
                    // The daemon read the name as its catalog id (`hub/model_alias.rs`).
                    if let (Some(from), Some(to)) = (
                        v.pointer("/modelRewrite/from").and_then(Value::as_str),
                        v.pointer("/modelRewrite/to").and_then(Value::as_str),
                    ) {
                        eprintln!("model {from} -> {to}");
                    }
                    v
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
        Command::Allow { session, option, standing_grant } => {
            let how = if standing_grant { Answer::StandingGrant } else { Answer::Allow };
            answer_permission(&session, option, how, json_out).await
        }
        Command::Deny { session } => {
            answer_permission(&session, None, Answer::Deny, json_out).await
        }
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
                    crate::home_fs::create_dirs(local.parent().unwrap())?;
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
        Command::Rebalance(crate::cli::command::RebalanceArgs {
            dry_run,
            force,
            max_moves,
            timeout,
            undo,
        }) => {
            super::rebalance::run(
                super::rebalance::Args { dry_run, force, max_moves, timeout, undo },
                json_out,
            )
            .await
        }
        Command::MoveSessions(crate::cli::command::MoveSessionsArgs {
            sessions,
            host,
            all_idle,
            interrupt,
            after_turn,
            timeout,
            leave_dirty,
            carry_changes,
            cwd,
            dry_run,
            from,
            slow_ok,
            abort,
            take_back,
            from_snapshot,
            as_harness,
        }) => {
            if abort {
                return super::session_move::end_stale(
                    &sessions,
                    from.as_deref(),
                    take_back,
                    json_out,
                )
                .await;
            }
            let args = super::session_move::MoveArgs {
                sessions,
                host: host.unwrap_or_default(),
                all_idle,
                interrupt,
                after_turn,
                turn_timeout: std::time::Duration::from_secs(timeout),
                leave_dirty,
                carry_changes,
                cwd,
                dry_run,
                resume_there: false,
                from,
                slow_ok,
                from_snapshot,
                as_harness,
            };
            super::session_move::run(args, json_out).await
        }
        Command::Transfer { session, to, cwd, name, interrupt, after_turn } => {
            super::transfer::run(&session, &to, cwd, name, interrupt, after_turn, json_out).await
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
                    let v = crate::cli::slow_notice::noted(
                        "the status request",
                        client.request(method::MUX_STATUS, json!({})),
                    )
                    .await?;
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
                    // A count that missed status's reading budget is null: unknown, not 0.
                    let live = v.get("liveAgents").and_then(Value::as_u64);
                    println!(
                        "sessions: {} ({} live agents)",
                        v.get("sessions").and_then(Value::as_u64).unwrap_or(0),
                        live.map_or_else(|| "unknown".to_owned(), |n| n.to_string())
                    );
                    if let Some(line) = crate::hub::views::other_build_hosts_line(&v) {
                        println!("{line}");
                    }
                    println!(
                        "policy:   {}",
                        v.get("permissionPolicy").and_then(Value::as_str).unwrap_or("")
                    );
                    let url = v.get("webUrl").and_then(Value::as_str);
                    println!("web:      {}", web_line(url, show_token));
                    if let Some(line) = host_pressure_line(&v["host_pressure"]) {
                        println!("host:     {line}");
                    }
                    if let Some(fleet) = v.get("fleetHold").filter(|f| !f.is_null())
                        && let Ok(hold) = serde_json::from_value::<
                            crate::hub::session_hold::FleetHold,
                        >(fleet.clone())
                    {
                        let held = fleet.get("held").and_then(Value::as_u64);
                        println!(
                            "hold:     {}",
                            crate::cli::hold_line::fleet_hold_line(&hold, held)
                        );
                    }
                    if let Some(line) = crate::session_budget::budget_line(&v["sessionBudgets"]) {
                        println!("budget:   {line}");
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
                    // Why a start would fail, when config.json already says (the daemon's start
                    // check): the person sees it here, not only in daemon.log.
                    let refused = crate::daemon::saved_start_refusal().await;
                    if json_out {
                        let out = match &refused {
                            Some(why) => {
                                json!({"running": false, "error": e.to_string(), "refused": why})
                            }
                            None => json!({"running": false, "error": e.to_string()}),
                        };
                        print_json(&out)
                    } else {
                        println!("daemon not running ({e})");
                        if let Some(why) = &refused {
                            println!("refused:  {why}");
                        }
                    }
                }
            }
            Ok(())
        }
        Command::Shutdown { end_agents, keep_agents, restart } => {
            crate::cli::shutdown::run(end_agents, keep_agents, restart, json_out).await
        }
        Command::DaemonRestart => crate::cli::shutdown::restart(json_out).await,
        Command::DaemonFelt => crate::cli::daemon_felt::run(json_out).await,
        Command::DaemonPlacement { message } => crate::cli::daemon_placement::run(&message).await,
        Command::DaemonStats { by, since, top } => {
            crate::cli::daemon_stats::run(by, &since, top, json_out).await
        }
        #[cfg(unix)]
        Command::DaemonPrune { apply } => crate::daemon::prune::run_command(apply, json_out).await,
        #[cfg(not(unix))]
        Command::DaemonPrune { .. } => Err(anyhow!("daemon prune runs on macOS and Linux only")),
        Command::DaemonService { action } => crate::cli::daemon_service::run(action, json_out),
        Command::Config { show_token, set } => {
            let path = Config::path();
            if let Some(assignment) = set {
                let (key, value) =
                    assignment.split_once('=').ok_or_else(|| anyhow!("--set expects KEY=VALUE"))?;
                let mut cfg = Config::load()?;
                cfg.set(key, value)?;
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
            print_start_modes().await;
            Ok(())
        }
        Command::Web { app, no_open, show_token, rotate_token, tailnet } => {
            let app = app || tailnet;
            let client = connect(true).await?;
            let m = if rotate_token { method::MUX_WEB_TOKEN_ROTATE } else { method::MUX_STATUS };
            let v = client.request(m, json!({})).await?;
            let url = v
                .get("webUrl")
                .and_then(Value::as_str)
                .ok_or_else(|| anyhow!("daemon has no web listener"))?
                .to_owned();
            let tailnet_plan = if tailnet {
                let tn = crate::tailnet::Tailnet::locate()?;
                let plan = crate::web_tailnet::plan(&tn.status()?, &url)?;
                // Name the host and origin first, so the proxy never fronts a listener that
                // would refuse its requests; the daemon applies them at its next connection.
                let mut cfg = Config::load()?;
                if let Some(ws) = cfg.websocket.as_mut()
                    && crate::web_tailnet::allow(ws, &plan.fqdn)
                {
                    cfg.save()?;
                    client.request(method::MUX_RELOAD_CONFIG, json!({})).await?;
                }
                tn.serve_https_to_loopback(plan.port)?;
                Some(plan)
            } else {
                None
            };
            let url = if app {
                let mut url = reqwest::Url::parse(&url).context("invalid web listener URL")?;
                let listener_token = url
                    .fragment()
                    .and_then(|fragment| fragment.strip_prefix("token="))
                    .filter(|token| !token.is_empty())
                    .ok_or_else(|| anyhow!("web listener URL has no token fragment"))?;
                let token = crate::ws_auth::browser_app_token(listener_token);
                url.set_path("/app/");
                url.set_query(None);
                url.set_fragment(Some(&format!("token={token}")));
                match &tailnet_plan {
                    Some(plan) => crate::web_tailnet::link(&plan.fqdn, &token),
                    None => url.to_string(),
                }
            } else {
                url
            };
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
        Command::Host(PeerCmd::SelfUpdate { channel, now, allow_downgrade }) => {
            crate::cli::hosts::self_update(&channel, now, allow_downgrade, json_out).await
        }
        // A file of this machine's; the daemon, when it runs, only reloads it.
        Command::Host(PeerCmd::Approvals { cmd }) => {
            crate::cli::host_approvals::run(cmd, json_out).await
        }
        // This machine's own key file or ssh agent; no daemon.
        Command::Host(PeerCmd::Key { create }) => crate::cli::host_ssh_key::run(create, json_out),
        // Its own socket, a fresh daemon connection per client: none held here.
        #[cfg(unix)]
        Command::Host(PeerCmd::BrokerForward { owners, socket }) => {
            crate::cli::host_broker_forward::run(owners, socket).await
        }
        #[cfg(not(unix))]
        Command::Host(PeerCmd::BrokerForward { .. }) => {
            Err(anyhow!("machine broker-forward needs unix sockets"))
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
            // A symlinked home is refused by name; then a process-wide file lock protects the check, redeem
            // and commit as one transaction. A second installer never redeems behind the first one.
            crate::cli::join_input::refuse_symlinked_home()?;
            let _lock = crate::cli::cloud_join::join_lock().map_err(|e| {
                crate::cli::errors::AppError::new(
                    crate::cli::errors::Code::Runtime,
                    "join.store",
                    format!("local machine store is busy or unavailable: {e:#}"),
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
        Command::Host(PeerCmd::LeaveIntent { user_id, signed_out_at }) => {
            let recorded =
                crate::cli::cloud_join::record_leave_intent(&user_id, signed_out_at).await?;
            if json_out {
                print_json(&json!({ "recorded": recorded }));
            } else if recorded {
                println!("recorded");
            } else {
                println!("not recorded: that account signed in again since");
            }
            Ok(())
        }
        Command::Host(PeerCmd::Leave { local_only }) => {
            crate::cli::cloud_join::leave(local_only, json_out).await
        }
        // The enroll runs here; a running daemon starts its relay at its next start.
        Command::Host(PeerCmd::EnrollSelf { access_token_stdin: _, hub, build_tag, user_id }) => {
            let access = crate::cli::join_input::read_stdin_line(false)?
                .ok_or_else(|| anyhow!("the access token must be on stdin"))?;
            let request = crate::cli::cloud_join::EnrollRequest { hub, user_id, build_tag };
            let outcome = crate::cli::cloud_join::enroll_self(request, access).await;
            if json_out {
                print_json(&json!({ "outcome": outcome }));
            } else {
                println!("{}", serde_json::to_value(outcome)?.as_str().unwrap_or_default());
            }
            Ok(())
        }
        Command::Host(PeerCmd::Vault { cmd }) => match cmd {
            crate::cli::command_host::VaultCmd::Pull => {
                crate::cli::host_vault::pull_cmd(json_out).await
            }
            crate::cli::command_host::VaultCmd::Status => {
                crate::cli::host_vault::status_cmd(json_out).await
            }
            crate::cli::command_host::VaultCmd::Forget => {
                crate::cli::host_vault::forget_cmd(json_out).await
            }
            crate::cli::command_host::VaultCmd::Keep { name, hosts, env } => {
                crate::cli::host_vault::keep_cmd(name, hosts, env, json_out).await
            }
            crate::cli::command_host::VaultCmd::Drop { name } => {
                crate::cli::host_vault::drop_cmd(name, json_out).await
            }
            crate::cli::command_host::VaultCmd::Audit => {
                crate::cli::host_vault::audit_cmd(json_out)
            }
        },
        Command::Host(PeerCmd::Deps { cmd }) => crate::cli::machine_deps::run(cmd, json_out).await,
        Command::Host(PeerCmd::Consent { cmd }) => {
            let (screen, control, signed_in_machines, granted) = match cmd {
                crate::cli::command_host::ConsentCmd::Grant {
                    screen,
                    control,
                    signed_in_machines,
                } => (screen, control, signed_in_machines, true),
                crate::cli::command_host::ConsentCmd::Revoke {
                    screen,
                    control,
                    signed_in_machines,
                } => (screen, control, signed_in_machines, false),
            };
            let surface = match (screen, control, signed_in_machines) {
                (true, false, false) => "screen",
                (false, true, false) => "control",
                (false, false, true) => crate::cli::cloud_join::SIGNED_IN_MACHINES,
                _ => {
                    return Err(anyhow!(
                        "use exactly one of --screen, --control or --signed-in-machines"
                    ));
                }
            };
            // Under sudo: this Mac's admin sets it here, with no app (`consent_admin.rs`).
            if let Some(consent) = crate::cli::consent_admin::set_if_admin(surface, granted)? {
                if json_out {
                    print_json(&crate::cli::cloud_join::for_this_account(
                        json!({"consent":consent}),
                    ));
                } else {
                    println!("consent updated as this Mac's admin: {surface}");
                }
                return Ok(());
            }
            let client = crate::client::Client::connect(&crate::config::socket_path()).await?;
            let value = client
                .request(
                    method::MUX_MACHINE_CONSENT_SET,
                    json!({"surface":surface,"granted":granted}),
                )
                .await
                .inspect_err(|error| {
                    // Only the person check's refusal, and only in text mode (--json keeps stderr
                    // to the one error envelope): say how this Mac's admin does it instead.
                    let person = error.downcast_ref::<crate::client::DaemonError>().is_some_and(|e| {
                        e.0.data.as_ref().and_then(|d| d["reason"].as_str())
                            == Some(crate::hub::person::REASON)
                    });
                    if person && cfg!(unix) && !json_out {
                        eprintln!(
                            "as this Mac's admin, run it with sudo instead: sudo acpmux machine consent {} --{}",
                            if granted { "grant" } else { "revoke" },
                            if surface == crate::cli::cloud_join::SIGNED_IN_MACHINES {
                                "signed-in-machines"
                            } else {
                                surface
                            }
                        );
                    }
                })?;
            if json_out {
                print_json(&value);
            } else {
                println!("consent updated: {surface}");
            }
            Ok(())
        }
        Command::Host(PeerCmd::Tunnel { cmd }) => {
            use crate::cli::command_host::TunnelCmd;
            let (m, network) = match cmd {
                TunnelCmd::Attach { network } => (method::MUX_MACHINE_TUNNEL_ATTACH, network),
                TunnelCmd::Detach { network } => (method::MUX_MACHINE_TUNNEL_DETACH, network),
                TunnelCmd::Rekey => (method::MUX_MACHINE_TUNNEL_REKEY, None),
            };
            let token = crate::cli::join_input::read_stdin_line(false)?
                .ok_or_else(|| anyhow!("pass the cmux access token on stdin"))?;
            let mut params = json!({"token": token.as_str()});
            if let Some(network) = network {
                cmux_json::JsonSet::set(&mut params, "networkId", json!(network));
            }
            let client = crate::client::Client::connect(&crate::config::socket_path()).await?;
            let value = client.request(m, params).await?;
            if json_out {
                print_json(&value);
            } else {
                println!("{}", m.trim_start_matches("_acpmux/machine.tunnel."));
            }
            Ok(())
        }
        // Reads the host; asks a running daemon only, never starts one (`host_load.rs`).
        Command::Host(PeerCmd::Load { watch: true, lines }) => {
            crate::host_load_watch::run(lines).await
        }
        Command::Host(PeerCmd::Load { .. }) => {
            let load = crate::host_load::sample().await;
            print_json(&serde_json::to_value(&load)?);
            Ok(())
        }
        // Reads the home directory and writes one file; no daemon (`disk_usage.rs`).
        Command::Host(PeerCmd::DiskWalk) => crate::disk_usage::walk_and_store(),
        // Reads the fleet listing and the registry; changes nothing (`cell_report.rs`).
        Command::Host(PeerCmd::Cells) => super::ls::cells(json_out).await,
        // Pure: judges the readings on stdin, no daemon (`cli/host_budget.rs`).
        Command::Host(PeerCmd::Verdict) => crate::cli::host_budget::verdict_stdin(),
        // Only a running daemon's chats: no daemon, no chats to tell.
        Command::Host(PeerCmd::Notice { text }) => {
            let client = crate::client::Client::connect(&crate::config::socket_path()).await?;
            print_json(&client.request("_acpmux/host_notice", json!({"text": text})).await?);
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
                                    "peer {name} was saved and is probing in the background; verify the SSH alias with `ssh -o BatchMode=yes {host} true`, then run `acpmux machine ls` and retry after it shows connected (the saved WebSocket token is retained)"
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
                                    "peer {name} was saved and is probing in the background; verify the SSH alias with `ssh -o BatchMode=yes {host} true`, then run `acpmux machine doctor {name} --json`"
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
                                    "peer {name} was saved and is probing in the background; run `acpmux machine ls` and retry after it shows connected"
                                ),
                                json!({
                                    "reason": "peer_probing",
                                    "try": "acpmux machine ls",
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
                PeerCmd::Load { .. }
                | PeerCmd::Cells
                | PeerCmd::DiskWalk
                | PeerCmd::Verdict
                | PeerCmd::Notice { .. } => {
                    return Err(anyhow!(
                        "machine load, cells, disk-walk, verdict and notice are handled before connecting"
                    ));
                }
                PeerCmd::Rm { name } => {
                    client.request("_acpmux/peer_remove", json!({"name": name})).await?
                }
                PeerCmd::Setup { host, name, port, no_auto_update, allow_downgrade, now } => {
                    let opts = crate::cli::hosts::SetupOptions {
                        port,
                        auto_update: !no_auto_update,
                        allow_downgrade,
                        now,
                    };
                    return crate::cli::hosts::setup(client, &host, name, opts, json_out).await;
                }
                // Dispatched before the connect (above); kept here so the
                // match stays total without a panic.
                PeerCmd::SelfUpdate { channel, now, allow_downgrade } => {
                    return crate::cli::hosts::self_update(
                        &channel,
                        now,
                        allow_downgrade,
                        json_out,
                    )
                    .await;
                }
                PeerCmd::Hold { name, reason, until, release } => {
                    return crate::cli::hosts::hold(name, reason, until, release, json_out);
                }
                PeerCmd::Approvals { cmd } => {
                    return crate::cli::host_approvals::run(cmd, json_out).await;
                }
                PeerCmd::Update {
                    name,
                    all,
                    binary_dir,
                    if_idle,
                    keep_newer,
                    allow_downgrade,
                    now,
                } => {
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
                        allow_downgrade,
                        caller,
                        now,
                    };
                    return crate::cli::hosts::update(client, name, all, opts, json_out).await;
                }
                PeerCmd::Enroll {
                    host,
                    name,
                    harnesses,
                    remote_binary,
                    reverse,
                    accept_new_host_key,
                } => {
                    let plan = crate::cli::host_enroll::Plan::enroll(
                        host,
                        name,
                        harnesses,
                        remote_binary,
                        reverse,
                        accept_new_host_key,
                    );
                    return crate::cli::host_enroll::run(client, plan, true, json_out).await;
                }
                PeerCmd::Doctor { target, fix, harnesses, remote_binary, reverse, .. } => {
                    let target = target.unwrap_or_default();
                    let peers = client.request("_acpmux/peers", json!({})).await?;
                    let list =
                        peers.get("peers").and_then(Value::as_array).cloned().unwrap_or_default();
                    let (name, host, port) = crate::cli::host_enroll::pick_target(&list, &target);
                    if !json_out
                        && let Some(note) = crate::cli::host_enroll::hub_route_note(&list, &name)
                    {
                        println!("{note}");
                    }
                    let plan = crate::cli::host_enroll::Plan {
                        name,
                        host,
                        port,
                        harnesses,
                        remote_binary,
                        reverse,
                        lends_github: false,
                        accept_new_host_key: false,
                    };
                    return crate::cli::host_enroll::run(client, plan, fix, json_out).await;
                }
                PeerCmd::Candidates { probe } => {
                    return crate::cli::host_candidates::run(&client, probe, json_out).await;
                }
                PeerCmd::Agents { target, install, login } => {
                    let peers = client.request("_acpmux/peers", json!({})).await?;
                    let list =
                        peers.get("peers").and_then(Value::as_array).cloned().unwrap_or_default();
                    let (name, host, _) = crate::cli::host_enroll::pick_target(&list, &target);
                    return crate::cli::host_agents::run(&name, &host, install, login, json_out);
                }
                PeerCmd::Ticket(cmd) => {
                    return crate::cli::pairing::ticket(client, cmd, json_out).await;
                }
                PeerCmd::Join { .. }
                | PeerCmd::Leave { .. }
                | PeerCmd::LeaveIntent { .. }
                | PeerCmd::EnrollSelf { .. }
                | PeerCmd::Consent { .. }
                | PeerCmd::Tunnel { .. }
                | PeerCmd::Vault { .. }
                | PeerCmd::Deps { .. }
                | PeerCmd::Key { .. }
                | PeerCmd::BrokerForward { .. } => {
                    return Err(anyhow!(
                        "host join, leave, consent, vault and deps are handled before daemon connection"
                    ));
                }
            };
            if json_out {
                print_json(&v);
                return Ok(());
            }
            let peers = v.get("peers").and_then(Value::as_array).cloned().unwrap_or_default();
            if peers.is_empty() {
                println!("no peers (add one: acpmux machine add HOST)");
            }
            for p in peers {
                let state = crate::peer_link::state_label(&p, crate::store::now_ms());
                let build = p.get("remoteBuild").and_then(Value::as_str).unwrap_or("");
                println!(
                    "{:<16} {:<10} {:>3} sessions  {}  {:<24} {}{}{}{}{}",
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
                    crate::fleet_elastic::suffix(&p),
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
    // `#token=` from this build; `?token=` from an older daemon still running.
    match url.split_once("#token=").or_else(|| url.split_once("?token=")) {
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

/// `acpmux config`'s last lines: the permission mode a new chat starts in, as the local daemon
/// answers `_acpmux/start_mode` (what the app's mode picker shows), for the default harness and
/// each harness with its own `permissionMode`. Nothing when no daemon runs.
async fn print_start_modes() {
    let Ok(cfg) = Config::load() else { return };
    let Ok(client) = crate::client::Client::connect(&crate::config::socket_path()).await else {
        return;
    };
    let mut names: Vec<Option<String>> = vec![None];
    names.extend(
        cfg.defaults
            .iter()
            .filter(|(_, d)| d.permission_mode.is_some())
            .map(|(k, _)| Some(k.clone())),
    );
    for name in names {
        let Ok(v) = client.request(method::MUX_START_MODE, json!({"harness": name})).await else {
            continue;
        };
        let s = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("-").to_owned();
        println!(
            "# new {} chats start in: {} ({}, from {})",
            s("harness"),
            s("level"),
            s("modeId"),
            s("source")
        );
    }
    println!("# change: acpmux config --set permissions.default=yolo|standard|ask|default");
}

#[cfg(test)]
mod tests {
    use super::{not_resumed_line, peer_add_params, resume_moves_off};
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

    /// A queue a daemon start holds for a person is named, with how to release it, instead of
    /// "nothing is held" (a lane VM's queues sat a day behind that line).
    #[test]
    fn resume_names_a_hold_for_a_person_and_how_to_release_it() {
        let held = json!({"personHold": {"folder": "/Users/p/Downloads/x", "reason": "/Users/p/Downloads/x is in a privacy-protected folder; an agent starts there only when a person picks it"}});
        let line = not_resumed_line(&held, "lane-a");
        assert!(
            line.starts_with(
                "held for a person: /Users/p/Downloads/x is in a privacy-protected folder"
            ),
            "{line}"
        );
        assert!(line.contains("`acpmux session resume lane-a --open`"), "{line}");
        assert_eq!(not_resumed_line(&json!({"queue": []}), "lane-a"), "nothing is held");
        assert_eq!(not_resumed_line(&json!({"personHold": null}), "lane-a"), "nothing is held");
    }
}
