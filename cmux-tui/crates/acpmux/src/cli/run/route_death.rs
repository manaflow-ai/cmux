//! `acpmux session route [HOST/NAME] [--facts FILE] [--show-facts]`: one death-routing step
//! (`death_route.rs`). Named, the session's facts start from what this machine's hub knows
//! (`death_route::observe`); the caller's FACTS lie over them.

use super::*;
use anyhow::Context;
use std::future::Future;
use std::path::PathBuf;
use std::time::Duration;
use tokio::time::{Instant, timeout_at};

const HUB_READ_BUDGET: Duration = Duration::from_secs(3);

/// Optional observations share one deadline, including the connection handshake. A silent
/// hub must not keep the caller from deciding recovery from the facts it already has.
async fn hub_read<T>(
    deadline: Instant,
    operation: &str,
    read: impl Future<Output = Result<T>>,
) -> Option<T> {
    match timeout_at(deadline, read).await {
        Ok(Ok(value)) => Some(value),
        Ok(Err(error)) => {
            eprintln!("session route: {operation} failed ({error:#}); using the available facts");
            None
        }
        Err(_) => {
            eprintln!(
                "session route: {operation} exceeded the hub read budget; using the available facts"
            );
            None
        }
    }
}

/// The caller's facts as JSON: FILE, `-` for stdin, or none.
fn caller_facts(facts: Option<&PathBuf>) -> Result<Value> {
    let Some(path) = facts else { return Ok(json!({})) };
    let text = if path.as_os_str() == "-" {
        let mut buf = String::new();
        std::io::Read::read_to_string(&mut std::io::stdin(), &mut buf)?;
        buf
    } else {
        std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?
    };
    serde_json::from_str(&text).context("facts are not the death-route JSON")
}

/// What the hub here knows of `key`; with no daemon to ask, nothing (said on stderr), so the
/// caller's facts decide alone as before.
async fn hub_facts(key: &str) -> Value {
    let deadline = Instant::now() + HUB_READ_BUDGET;
    let Some(client) = hub_read(deadline, "connecting to acpmux", connect(false)).await else {
        return json!({"key": key});
    };
    let peers = hub_read(deadline, "reading peers", client.request("_acpmux/peers", json!({})))
        .await
        .unwrap_or_else(|| json!({}));
    let snapshot = if crate::death_route::observe::host_of(key).is_empty() {
        None
    } else {
        hub_read(
            deadline,
            "reading the peer snapshot",
            client.request("_acpmux/peer_snapshot", json!({"sessionId": key})),
        )
        .await
    };
    crate::death_route::observe::observe(key, &peers, snapshot.as_ref(), crate::store::now_ms())
}

pub(super) async fn run(
    session: Option<String>,
    facts: Option<PathBuf>,
    show_facts: bool,
) -> Result<()> {
    if session.is_none() && facts.is_none() {
        return Err(anyhow!("name the dead session (HOST/NAME) or give --facts FILE"));
    }
    let given = caller_facts(facts.as_ref())?;
    let key = session.or_else(|| given.get("key").and_then(Value::as_str).map(str::to_owned));
    let seen = match key.as_deref().filter(|k| k.contains('/')) {
        Some(k) => hub_facts(k).await,
        None => json!({}),
    };
    let merged = crate::death_route::observe::merge(seen, given);
    let f: crate::death_route::Facts =
        serde_json::from_value(merged.clone()).context("facts are not the death-route JSON")?;
    let step = serde_json::to_value(crate::death_route::route(&f))?;
    if show_facts {
        print_json(&json!({"facts": merged, "step": step}));
    } else {
        print_json(&step);
    }
    Ok(())
}

#[cfg(test)]
#[path = "route_death_tests.rs"]
mod tests;
