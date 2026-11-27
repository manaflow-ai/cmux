//! `acpmux machine cells`: the fleet's lane hosts as one cell, read-only (RFD 0181 B2).
//!
//! Leo, 2026-11-25: "treating a bundle of computers as one defacto big-ass scaling up and down
//! \"computer\" aka... cmux v2". Borg runs a cell from one view of what runs where against each
//! machine's quota. Ours had none. On 2026-11-25, 12 lane hosts ran past their
//! `lanes.max_lanes`, the worst with 25 live sessions on a cap of 6. And 42 live sessions ran on
//! hosts fleet-registry.json called idle-stopped, which placement refuses. No single read said so.
//!
//! [`report`] joins the registry's lane hosts (`placement::lane_hosts_at`: names, aliases, holds)
//! with the fleet session listing (`acpmux ls --json` rows). It returns, per host:
//! - the live sessions (running, ready or waiting);
//! - the cap (`lanes.max_lanes`);
//! - how far past the cap it is;
//! - why the registry keeps work off it (a hold, a reservation or a stopped `status`);
//! - whether the registry and the host disagree: the registry keeps work off it, yet sessions run there.
//!
//! It is pure, so the CLI and the tests judge the same rows. It changes nothing: placement
//! (`placement.rs`) and rebalance (`rebalance.rs`) act; this module only counts.

use serde_json::{Map, Value, json};

/// The report's shape version.
pub const SCHEMA: &str = "acpmux-cells/v1";

/// The statuses a session holds a lane in.
const LIVE: [&str; 3] = ["running", "ready", "waiting"];

/// The host a listing row runs on: its `qualifiedSessionId`'s prefix before `/`, canonical.
fn row_host(row: &Value) -> Option<String> {
    let q = row.get("qualifiedSessionId")?.as_str()?;
    let (host, _) = q.split_once('/')?;
    (!host.is_empty()).then(|| crate::placement::canonical(host))
}

/// Whether a listing row holds a lane now.
fn row_live(row: &Value) -> bool {
    row.get("status").and_then(Value::as_str).is_some_and(|s| LIVE.contains(&s))
}

/// Why the registry keeps new work off the machine named `names[0]`: its hold or reservation
/// (carried in `lanes._held` by `lane_hosts_at`), else a stopped `status`.
fn kept_off(registry: &Value, names: &[String], lanes: &Value) -> Option<String> {
    if let Some(why) = lanes.get("_held").and_then(Value::as_str) {
        return Some(format!("held: {why}"));
    }
    let machine = crate::placement::machine(Some(registry), names.first()?)?;
    crate::placement::stopped(machine)
}

/// The cell report for `sessions` (fleet listing rows) against `registry` at `now_ms`.
///
/// Only lane hosts are listed: registry machines with a `lanes` object. A row whose host is
/// not a lane host is counted in `liveElsewhere`. With no registry there are no lane hosts,
/// and every live row counts there.
pub fn report(registry: Option<&Value>, sessions: &[Value], now_ms: u64) -> Value {
    let mut live_by_host: Map<String, Value> = Map::new();
    for row in sessions.iter().filter(|r| row_live(r)) {
        if let Some(h) = row_host(row) {
            let n = live_by_host.get(&h).and_then(Value::as_u64).unwrap_or(0);
            live_by_host.insert(h, json!(n + 1));
        }
    }
    let total_live: u64 = live_by_host.values().filter_map(Value::as_u64).sum();
    let lane_hosts: Vec<(Vec<String>, Value)> = crate::placement::lane_hosts_at(registry, now_ms)
        .unwrap_or_default()
        .into_iter()
        .filter(|(_, lanes)| lanes.is_object())
        .collect();

    let mut hosts = Vec::new();
    let (mut over_hosts, mut live_over, mut on_kept_off, mut disagree, mut counted) =
        (0u64, 0u64, 0u64, 0u64, 0u64);
    for (names, lanes) in &lane_hosts {
        let live: u64 =
            names.iter().filter_map(|n| live_by_host.get(n).and_then(Value::as_u64)).sum();
        counted += live;
        let cap = lanes.get("max_lanes").and_then(Value::as_u64);
        let over = cap.map(|c| live.saturating_sub(c)).filter(|o| *o > 0);
        let why = registry.and_then(|r| kept_off(r, names, lanes));
        let disagrees = why.is_some() && live > 0;
        if let Some(o) = over {
            over_hosts += 1;
            live_over += o;
        }
        if disagrees {
            disagree += 1;
            on_kept_off += live;
        }
        hosts.push(json!({
            "host": names[0],
            "live": live,
            "cap": cap,
            "over": over,
            "registry": why,
            "disagrees": disagrees,
        }));
    }
    // Worst first: furthest past the cap, then most live.
    hosts.sort_by_key(|h| {
        let over = h["over"].as_u64().unwrap_or(0);
        let live = h["live"].as_u64().unwrap_or(0);
        (std::cmp::Reverse(over), std::cmp::Reverse(live), h["host"].as_str().map(str::to_owned))
    });
    json!({
        "schema": SCHEMA,
        "atMs": now_ms,
        "hosts": hosts,
        "totals": {
            "laneHosts": lane_hosts.len(),
            "live": total_live,
            "overCapHosts": over_hosts,
            "liveOverCap": live_over,
            "disagreeingHosts": disagree,
            "liveOnStopped": on_kept_off,
            "liveElsewhere": total_live - counted,
        },
    })
}

/// The text view: one line per host past its cap or disagreeing with the registry, then the totals.
pub fn lines(report: &Value) -> Vec<String> {
    let mut out = Vec::new();
    for h in report["hosts"].as_array().into_iter().flatten() {
        let over = h["over"].as_u64();
        let disagrees = h["disagrees"].as_bool() == Some(true);
        if over.is_none() && !disagrees {
            continue;
        }
        let host = h["host"].as_str().unwrap_or("?");
        let live = h["live"].as_u64().unwrap_or(0);
        let cap = h["cap"].as_u64().map_or("no cap".to_owned(), |c| format!("cap {c}"));
        let mut line = format!("{host}: {live} live, {cap}");
        if let Some(o) = over {
            line.push_str(&format!(", {o} over"));
        }
        if disagrees {
            let why = h["registry"].as_str().unwrap_or("kept off");
            line.push_str(&format!(
                "; the registry keeps work off it ({why}) yet sessions run there"
            ));
        }
        out.push(line);
    }
    let t = &report["totals"];
    let n = |k: &str| t[k].as_u64().unwrap_or(0);
    out.push(format!(
        "{} lane hosts, {} live sessions: {} hosts past their cap by {} sessions; {} hosts the \
         registry keeps work off run {} sessions; {} live on machines that are not lane hosts",
        n("laneHosts"),
        n("live"),
        n("overCapHosts"),
        n("liveOverCap"),
        n("disagreeingHosts"),
        n("liveOnStopped"),
        n("liveElsewhere"),
    ));
    out
}

#[cfg(test)]
#[path = "cell_report_tests.rs"]
mod tests;
