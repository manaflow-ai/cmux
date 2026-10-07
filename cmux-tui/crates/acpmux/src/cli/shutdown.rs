//! `acpmux daemon shutdown`: stop the daemon and every agent host of this
//! home. The daemon ends its agents first (`_acpmux/shutdown endAgents`);
//! once it exited, any host a record of this home still names and that
//! still runs is ended here (`agent_host::sweep`), so the command succeeds
//! only when none is left. `--keep-agents` leaves the user sessions' hosts
//! running for the next daemon (an update or a restart), as SIGTERM does.

use crate::agent_host::{self, sweep};
use crate::cli::output::print_json;
use crate::clock::{Clock, TokioClock};
use crate::daemon::connect;
use crate::rpc::method;
use anyhow::{Result, anyhow};
use serde_json::json;
use std::time::Duration;

/// How long a host left after the daemon exited gets between SIGTERM and
/// SIGKILL (and the SIGKILL until its lock drops).
const HOST_GRACE: Duration = Duration::from_secs(3);

pub(crate) async fn run(keep_agents: bool, json_out: bool) -> Result<()> {
    run_on(&*TokioClock::new(), keep_agents, json_out).await
}

async fn run_on(clock: &dyn Clock, keep_agents: bool, json_out: bool) -> Result<()> {
    let hosts = agent_host::hosts_dir();
    let before = sweep::running_hosts(&hosts).len();
    let client = connect(false).await?;
    let params = if keep_agents { json!({}) } else { json!({"endAgents": true}) };
    // A refusal (a shutdown already under way hands its agents off) or a
    // closed connection still ends with the daemon's exit, and the sweep
    // below ends whatever it left running.
    let _ = client.request(method::MUX_SHUTDOWN, params).await;
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
    if json_out {
        print_json(&json!({
            "stopped": true,
            "endAgents": !keep_agents,
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
