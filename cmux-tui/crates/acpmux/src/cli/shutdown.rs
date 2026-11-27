//! `acpmux daemon shutdown`: stop the daemon. As SIGTERM and the
//! `_acpmux/shutdown` request without endAgents, it leaves the user
//! sessions' hosted agents running for the next daemon (a restart or an
//! update); pooled hosts end (cx-qryd0, hq-6d 2026-10-15: a plain stop ended
//! every agent before). `--end-agents` stops every agent host of this home
//! too: the daemon ends its agents first (`_acpmux/shutdown endAgents`), and
//! once it exited, any host a record of this home still names and that still
//! runs is ended here (`agent_host::sweep`), so the command succeeds only
//! when none is left. `--keep-agents` is accepted and changes nothing.

use crate::agent_host::{self, sweep};
use crate::cli::output::print_json;
use crate::clock::{Clock, TokioClock};
use crate::config::Config;
use crate::daemon::connect;
use crate::rpc::method;
use anyhow::{Result, anyhow};
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::time::Duration;

/// How long a host left after the daemon exited gets between SIGTERM and
/// SIGKILL (and the SIGKILL until its lock drops).
const HOST_GRACE: Duration = Duration::from_secs(3);

pub(crate) async fn run(
    end_agents: bool,
    keep_agents: bool,
    restart: bool,
    json_out: bool,
) -> Result<()> {
    // `--keep-agents` is a compatibility no-op; only the explicit restart
    // command or --restart updater flag requests service-restart signaling.
    let _ = keep_agents;
    let Some(was) = run_on(&*TokioClock::new(), end_agents, json_out, false, restart).await? else {
        return Ok(());
    };
    // With `acpmux.v2` `start` a restart never exits: the installed build runs in its place.
    let Some(status) = back_from_handoff(was).await? else {
        // A stop signal during the restart, or an exec that failed: it exited after all.
        if json_out {
            print_json(&json!({"stopped": true, "restarted": false, "handoff": false}));
        } else {
            println!("stopped; the restart in place gave way to an exit");
        }
        return Ok(());
    };
    let pid = status.get("pid").and_then(Value::as_u64).unwrap_or(0);
    if json_out {
        print_json(&json!({"stopped": false, "restarted": true, "handoff": true, "pid": pid}));
    } else if end_agents {
        println!("restarted in place; daemon pid {pid}");
    } else {
        println!("restarted in place; daemon pid {pid}, its agent hosts untouched");
    }
    Ok(())
}

/// Stop and start the daemon while keeping hosted agents for handoff.
pub(crate) async fn restart(json_out: bool) -> Result<()> {
    // A daemon started with `--listen`/`--token` keeps those values only in
    // memory for that run. Refuse an unsaved token before stopping; save only
    // the bound listener when the configured credential already matches.
    let client = connect(false).await?;
    let before = client.request(method::MUX_STATUS, json!({})).await?;
    preserve_restart_listener(&before)?;
    drop(client);
    // The binary the next daemon should run: this command's own, or a newer install
    // (`daemon/start_exe.rs`), never whatever `acpmux` PATH names.
    let choice = crate::daemon::start_exe::current(&crate::config::home())?;
    let mut status = Value::Null;
    for attempt in 1..=RESTART_ATTEMPTS {
        let handed_off = run_on(&*TokioClock::new(), false, json_out, true, true).await?;
        let back = match handed_off {
            Some(was) => back_from_handoff(was).await.ok().flatten(),
            None => None,
        };
        status = match back {
            Some(status) => status,
            // The daemon exited (also where its exec in place failed): start the next one.
            None => {
                let client = crate::daemon::connect(true).await?;
                client.request(method::MUX_STATUS, json!({})).await?
            }
        };
        let Some(stale) = stale_winner(&choice, &status) else { break };
        // Another client of an older build started its own binary between the old daemon's
        // exit and this start (air-blue, 2026-11-22). Restart again; say so either way.
        if attempt == RESTART_ATTEMPTS {
            return Err(anyhow!(
                "the daemon came back as {stale}, an older build than {} ({}); a client of that \
                 build restarted it first. Update or remove that binary, then run `daemon restart` again",
                choice.this.exe.display(),
                choice.why
            ));
        }
        eprintln!("restart: the daemon came back as {stale}, an older build; restarting it again");
        tracing::warn!("restart: the daemon came back as {stale}, an older build; again");
    }
    anyhow::ensure!(
        before.get("listen") == status.get("listen")
            && before.get("webUrl") == status.get("webUrl"),
        "the daemon started with different listener settings; inspect `daemon status`"
    );
    let exe = status.get("exe").and_then(Value::as_str).unwrap_or("unknown");
    if json_out {
        print_json(&json!({
            "restarted": true,
            "status": status,
            "start": {"exe": choice.this.exe, "why": choice.why},
        }));
    } else {
        println!(
            "restarted; daemon pid {} runs {exe} ({})",
            status.get("pid").and_then(serde_json::Value::as_u64).unwrap_or(0),
            choice.why
        );
    }
    Ok(())
}

/// The daemon's status once its exec in place serves again (`daemon/handoff.rs`): the same pid,
/// whose `handoffs` grew past `was` (the count its shutdown answer named). The old image may
/// still accept for a moment and then end the connection, so it dials again until the new one
/// answers, within the budget a stop has to exit ([`crate::daemon::EXIT_BUDGET`]). None when the
/// daemon exited instead (a stop signal during the restart, or an exec that failed): only an exit
/// removes the socket, which a restart in place keeps throughout.
async fn back_from_handoff(was: u64) -> Result<Option<Value>> {
    // timeout: the same bound as the wait for an old daemon's exit; past it the restart failed.
    let deadline = tokio::time::Instant::now() + crate::daemon::EXIT_BUDGET;
    loop {
        // A dial that waits in the kept socket's backlog is answered once the new image serves.
        let dial = async {
            let client = connect(false).await.ok()?;
            client.request(method::MUX_STATUS, json!({})).await.ok()
        };
        if let Ok(Some(status)) = tokio::time::timeout_at(deadline, dial).await
            && status.get("handoffs").and_then(Value::as_u64).is_some_and(|n| n > was)
        {
            return Ok(Some(status));
        }
        if !crate::config::socket_path().exists() {
            return Ok(None);
        }
        if tokio::time::Instant::now() >= deadline {
            return Err(anyhow!(
                "the daemon did not serve again within {:?} of its restart; inspect `daemon status`",
                crate::daemon::EXIT_BUDGET
            ));
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// How many times `restart` stops and starts the daemon when an older build keeps winning.
const RESTART_ATTEMPTS: u32 = 2;

/// The daemon `status` names, as `<exe> (build <b>)`, when it is an older build than `choice`
/// (`start_exe::stale_winner`); None when it runs the chosen build or cannot be told apart.
fn stale_winner(choice: &crate::daemon::start_exe::Choice, status: &Value) -> Option<String> {
    use crate::daemon::start_exe;
    let exe = status
        .get("exe")
        .and_then(Value::as_str)
        .map(|e| crate::self_command::undeleted(std::path::PathBuf::from(e)))?;
    let build = status.get("build").and_then(Value::as_str);
    let stale = start_exe::stale_winner(
        choice,
        crate::hub::build(),
        Some(&exe),
        build,
        start_exe::commit_time_of(&exe),
    );
    stale.then(|| format!("{} (build {})", exe.display(), build.unwrap_or("unknown")))
}

fn preserve_restart_listener(status: &Value) -> Result<()> {
    let Some(listen) = status.get("listen").and_then(Value::as_str) else {
        return Ok(());
    };
    // web_url appends the raw token after this exact prefix (`#token=`; an
    // older daemon wrote `?token=`); do not decode it or split on '&', both
    // of which would change a custom credential.
    let token = status.get("webUrl").and_then(Value::as_str).and_then(|url| {
        url.split_once("#token=").or_else(|| url.split_once("?token=")).map(|(_, token)| token)
    });
    // Tagged/dev homes deliberately cannot claim the shared fixed port. A
    // restart cannot reapply that policy after stopping the explicit daemon,
    // so refuse before shutdown rather than silently moving the listener.
    let shared_home = crate::daemon::uses_shared_home();
    if crate::daemon::first_run_listen(shared_home, Some(listen)) != listen {
        return Err(anyhow!(
            "cannot restart a non-shared daemon on reserved listener {listen}; stop it manually and choose another port"
        ));
    }
    let mut config = Config::load()?;
    let websocket = config.websocket.as_mut().ok_or_else(|| {
        anyhow!("cannot restart without saved listener settings; the daemon is still running")
    })?;
    anyhow::ensure!(
        token.is_some_and(|token| websocket.token.as_deref() == Some(token))
            && websocket.token_rotated >= crate::daemon::TOKEN_ROTATION,
        "cannot restart with an unsaved --token override; the daemon is still running"
    );
    // A network listen opted in with `--insecure-network-listen` lasts one run: the restarted
    // daemon reads only config.json and would refuse the address, leaving no daemon. Refuse
    // before stopping this one unless the saved opt-in covers it.
    let bound: Vec<std::net::SocketAddr> = listen.parse().into_iter().collect();
    crate::server::ws_auth::check_listen(listen, &bound, websocket.allow_insecure_network).map_err(
        |e| e.context("cannot restart: the daemon runs with --insecure-network-listen, which a restart does not keep; the daemon is still running"),
    )?;
    if websocket.listen == listen {
        return Ok(());
    }
    websocket.listen = listen.to_owned();
    config.save().map_err(|e| anyhow!("preserve daemon listener settings for restart: {e:#}"))
}

/// The `_acpmux/shutdown` reason of this command: which command, then the caller's own word
/// when it set `ACPMUX_STOP_REASON` (tools/nightly-update's heal names itself there), so the
/// daemon's log tells a script's restart from a person's.
fn cli_reason(restart: bool, end_agents: bool) -> String {
    let command = match (restart, end_agents) {
        (true, _) => "cli: daemon restart",
        (false, true) => "cli: daemon shutdown --end-agents",
        (false, false) => "cli: daemon shutdown",
    };
    match std::env::var("ACPMUX_STOP_REASON") {
        Ok(why) if !why.trim().is_empty() => format!("{command} ({})", why.trim()),
        _ => command.to_owned(),
    }
}

/// Stop the daemon and wait for its exit. Some when it answered with `handoff` instead: a
/// restart that execs in place, which never exits (`daemon/handoff.rs`); nothing is waited for
/// or swept then. The value is the daemon's `handoffs` before this one.
async fn run_on(
    clock: &dyn Clock,
    end_agents: bool,
    json_out: bool,
    quiet: bool,
    restart: bool,
) -> Result<Option<u64>> {
    let keep_agents = !end_agents;
    let hosts = agent_host::hosts_dir();
    let before = sweep::running_hosts(&hosts).len();
    let client = connect(false).await?;
    let mut params = if keep_agents { json!({}) } else { json!({"endAgents": true}) };
    if restart {
        params.set("restart", json!(true));
    }
    params.set("reason", json!(cli_reason(restart, end_agents)));
    // A refusal (a shutdown already under way hands its agents off) or a
    // closed connection still ends with the daemon's exit, and the sweep
    // below ends whatever it left running.
    let answer = client.request(method::MUX_SHUTDOWN, params).await;
    // A refusal of this client (`exe_path::shutdown_refusal`) leaves the daemon running.
    if let Err(e) = &answer
        && e.to_string().contains("refused to stop the daemon")
    {
        return Err(anyhow!("{e}"));
    }
    // A restart whose installed build failed its check: the daemon serves on, unchanged.
    if let Err(e) = &answer
        && e.downcast_ref::<crate::client::DaemonError>().is_some_and(|e| {
            e.0.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str)
                == Some("restart.handoff_check_failed")
        })
    {
        return Err(anyhow!("{e}; the daemon is still running"));
    }
    // An exec in place: the same pid serves again, its agents and hosts untouched.
    if let Ok(a) = &answer
        && a.get("handoff").and_then(Value::as_bool) == Some(true)
    {
        return Ok(Some(a.get("handoffs").and_then(Value::as_u64).unwrap_or(0)));
    }
    drop(client);
    // The daemon holds its lock until it exits, so a `daemon start` right
    // after this cannot lose the lock to the stopping one.
    if !crate::daemon::wait_for_exit().await {
        // A daemon that still runs still owns its hosts: none is touched.
        return Err(anyhow!(
            "the daemon did not exit after `_acpmux/shutdown`; its agent hosts were not checked"
        ));
    }
    // Pooled hosts are hidden sessions: they never wait for a next daemon.
    let (kept, ending): (Vec<_>, Vec<_>) =
        sweep::running_hosts(&hosts).into_iter().partition(|h| keep_agents && !h.pooled);
    let after_exit = ending.len();
    let left = sweep::end_hosts(clock, ending, HOST_GRACE).await;
    if !left.is_empty() {
        let names: Vec<String> = left
            .iter()
            .map(|h| format!("session {} (host pid {})", h.session_id, h.host_pid))
            .collect();
        return Err(anyhow!(
            "the daemon stopped, but {} agent host(s) still run after SIGKILL: {}",
            left.len(),
            names.join(", ")
        ));
    }
    let ended = before.saturating_sub(kept.len()).max(after_exit);
    if quiet {
        return Ok(None);
    }
    if json_out {
        print_json(&json!({
            "stopped": true,
            "endAgents": end_agents,
            "agentHosts": {
                "before": before,
                "ended": ended,
                "endedAfterExit": after_exit,
                "kept": kept.len(),
                "left": [],
            },
        }));
    } else {
        let mut line = format!("stopped; {ended} agent host(s) ended");
        if after_exit > 0 {
            line += &format!(" ({after_exit} after the daemon exited)");
        }
        if !kept.is_empty() {
            line += &format!(", {} kept for the next daemon", kept.len());
        }
        println!("{line}");
    }
    Ok(None)
}
