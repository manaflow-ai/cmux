//! `acpmux session route [HOST/NAME] [--facts FILE] [--show-facts]`: one death-routing step
//! (`death_route.rs`). Named, the session's facts start from what this machine's hub knows
//! (`death_route::observe`); the caller's FACTS lie over them.

use super::*;
use anyhow::Context;
use std::path::PathBuf;

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
    let client = match connect(false).await {
        Ok(c) => c,
        Err(e) => {
            eprintln!(
                "session route: no acpmux here to read {key} from ({e:#}); the facts given decide"
            );
            return json!({"key": key});
        }
    };
    let peers = client.request("_acpmux/peers", json!({})).await.unwrap_or_else(|e| {
        eprintln!("session route: the peer list did not answer ({e:#})");
        json!({})
    });
    let snapshot = if crate::death_route::observe::host_of(key).is_empty() {
        None
    } else {
        client.request("_acpmux/peer_snapshot", json!({"sessionId": key})).await.ok()
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
