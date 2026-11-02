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
    run_on(&*TokioClock::new(), false, json_out, true, true).await?;
    let client = crate::daemon::connect(true).await?;
    let status = client.request(method::MUX_STATUS, json!({})).await?;
    anyhow::ensure!(
        before.get("listen") == status.get("listen")
            && before.get("webUrl") == status.get("webUrl"),
        "the daemon started with different listener settings; inspect `daemon status`"
    );
    if json_out {
        print_json(&json!({"restarted": true, "status": status}));
    } else {
        println!(
            "restarted; daemon pid {}",
            status.get("pid").and_then(serde_json::Value::as_u64).unwrap_or(0)
        );
    }
    Ok(())
}

fn preserve_restart_listener(status: &Value) -> Result<()> {
    let Some(listen) = status.get("listen").and_then(Value::as_str) else {
        return Ok(());
    };
    // web_url appends the raw token after this exact prefix; do not decode
    // it or split on '&', both of which would change a custom credential.
    let token = status
        .get("webUrl")
        .and_then(Value::as_str)
        .and_then(|url| url.split_once("?token=").map(|(_, token)| token));
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
    if websocket.listen == listen {
        return Ok(());
    }
    websocket.listen = listen.to_owned();
    config.save().map_err(|e| anyhow!("preserve daemon listener settings for restart: {e:#}"))
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
    }
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
