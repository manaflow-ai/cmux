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
    run_on(&*TokioClock::new(), end_agents, json_out, false, restart).await
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
        run_on(&*TokioClock::new(), false, json_out, true, true).await?;
        let client = crate::daemon::connect(true).await?;
        status = client.request(method::MUX_STATUS, json!({})).await?;
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

async fn run_on(
    clock: &dyn Clock,
    end_agents: bool,
    json_out: bool,
    quiet: bool,
    restart: bool,
) -> Result<()> {
    let keep_agents = !end_agents;
    let hosts = agent_host::hosts_dir();
    let before = sweep::running_hosts(&hosts).len();
    let client = connect(false).await?;
    let mut params = if keep_agents { json!({}) } else { json!({"endAgents": true}) };
    if restart {
        params.set("restart", json!(true));
        if keep_agents {
            params.set("execUpdate", json!(true));
        }
    }
    params.set("reason", json!(cli_reason(restart, end_agents)));
    // A refusal (a shutdown already under way hands its agents off) or a
    // closed connection still ends with the daemon's exit, and the sweep
    // below ends whatever it left running.
    let answer = client.request(method::MUX_SHUTDOWN, params).await;
    // A refusal of this client (`exe_path::shutdown_refusal`) leaves the daemon running.
    if let Err(e) = &answer
        && (e.to_string().contains("refused to stop the daemon")
            || e.to_string().contains("daemon update deferred"))
    {
        return Err(anyhow!("{e}"));
    }
    drop(client);
    if let Ok(answer) = &answer
        && let Some(receipt) = ExecReceipt::accepted(answer)?
    {
        wait_exec_receipt(&receipt).await?;
        if !quiet {
            if json_out {
                print_json(
                    &json!({"execUpdated": true, "pid": receipt.pid, "updateId": receipt.id, "execImage": receipt.image}),
                );
            } else {
                println!("ACPMUX_EXEC_UPDATED");
            }
        }
        return Ok(());
    }
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
        return Ok(());
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
    Ok(())
}

/// An accepted exec is complete only when the new image serves this receipt at the same PID.
/// It keeps the lock, so the ordinary shutdown's lock-release wait cannot observe it.
struct ExecReceipt {
    id: String,
    pid: u64,
    image: Value,
}

impl ExecReceipt {
    fn accepted(answer: &Value) -> Result<Option<Self>> {
        if answer.get("execUpdate").and_then(Value::as_bool) != Some(true) {
            return Ok(None); // An older daemon completed the ordinary shutdown protocol.
        }
        let id = answer.get("updateId").and_then(Value::as_str).filter(|s| !s.is_empty());
        let pid = answer.get("pid").and_then(Value::as_u64).filter(|p| *p > 0);
        let image = answer
            .get("execImage")
            .filter(|image| image.as_object().is_some_and(|v| !v.is_empty()));
        match (id, pid, image) {
            (Some(id), Some(pid), Some(image)) => {
                Ok(Some(Self { id: id.to_owned(), pid, image: image.clone() }))
            }
            _ => Err(anyhow!(
                "daemon accepted exec update without an identity receipt; no supervisor restart was requested"
            )),
        }
    }

    fn matches(&self, status: &Value) -> bool {
        status.get("lastExecUpdate").and_then(Value::as_str) == Some(self.id.as_str())
            && status.get("pid").and_then(Value::as_u64) == Some(self.pid)
            && status.get("ready").and_then(Value::as_bool) == Some(true)
            && status.get("execImage") == Some(&self.image)
    }
}

async fn wait_exec_receipt(receipt: &ExecReceipt) -> Result<()> {
    // timeout: an accepted exec that never serves its receipt is unconfirmed, never permission
    // to restart the supervisor and interrupt whichever image is currently running.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(90);
    let mut delay = Duration::from_millis(50);
    let mut attempts = 0;
    let wait = async {
        loop {
            attempts += 1;
            let read = async {
                let client = crate::client::Client::connect(&crate::config::socket_path()).await?;
                client.request(method::MUX_STATUS, json!({})).await
            };
            if let Ok(Ok(status)) = tokio::time::timeout(Duration::from_secs(5), read).await
                && receipt.matches(&status)
            {
                return;
            }
            // There is no event subscription across exec; bounded backoff only until the exact
            // receipt is served. Never autostart a daemon while the owner keeps its lock.
            tracing::debug!(attempts, update_id = %receipt.id, "waiting for exec update receipt");
            tokio::time::sleep(delay).await;
            delay = (delay * 2).min(Duration::from_secs(1));
        }
    };
    tokio::time::timeout_at(deadline, wait).await.map_err(|_| {
        anyhow!("daemon exec update {} at pid {} was not confirmed within 90 seconds; no supervisor restart was requested", receipt.id, receipt.pid)
    })
}

#[cfg(test)]
mod exec_receipt_tests {
    use super::*;

    #[test]
    fn only_the_ready_exec_image_at_the_accepted_pid_completes_an_update() {
        let receipt = ExecReceipt::accepted(
            &json!({"execUpdate":true,"updateId":"update-a","pid":42,"execImage":{"inode":123}}),
        )
        .unwrap()
        .unwrap();
        assert!(receipt.matches(
            &json!({"lastExecUpdate":"update-a","pid":42,"ready":true,"execImage":{"inode":123}})
        ));
        for status in [
            json!({"lastExecUpdate":"update-b","pid":42,"ready":true,"execImage":{"inode":123}}),
            json!({"lastExecUpdate":"update-a","pid":43,"ready":true,"execImage":{"inode":123}}),
            json!({"lastExecUpdate":"update-a","pid":42,"ready":false,"execImage":{"inode":123}}),
            json!({"lastExecUpdate":"update-a","pid":42,"ready":true,"execImage":{"inode":124}}),
            json!({"lastExecUpdate":"update-a","pid":42,"ready":true}),
            json!({"pid":42,"ready":true}),
        ] {
            assert!(!receipt.matches(&status), "{status}");
        }
        assert!(ExecReceipt::accepted(&json!({"stopping":true})).unwrap().is_none());
        for answer in [
            json!({"execUpdate":true}),
            json!({"execUpdate":true,"updateId":"","pid":42,"execImage":{"inode":123}}),
            json!({"execUpdate":true,"updateId":"a","pid":0,"execImage":{"inode":123}}),
            json!({"execUpdate":true,"updateId":"a","pid":42}),
            json!({"execUpdate":true,"updateId":"a","pid":42,"execImage":{}}),
            json!({"execUpdate":true,"updateId":"a","pid":42,"execImage":"image-a"}),
        ] {
            assert!(
                ExecReceipt::accepted(&answer).is_err(),
                "malformed exec never falls back to restart: {answer}"
            );
        }
    }
}
