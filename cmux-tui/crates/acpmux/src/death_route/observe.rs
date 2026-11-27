//! Part of `death_route.rs`: the facts this machine's hub already holds about a dead session, so
//! a caller (the fleet's `lane_deaths.py`, a coordinator, a person) names the session and no longer
//! reads them itself (cmuxterm-hq `docs/design/fleet-dogfoods-remote.md` move 2: the product owns
//! death routing, `lane_deaths.py` keeps no decision and ever fewer reads).
//!
//! From `_acpmux/peers`, the row of the session's host:
//! - `host_down`: its link is not up (`downSince` set, or not connected);
//! - `dead_seconds`: how long it has been down, from `downSince`;
//! - `hosts.answering`: every peer whose link is up.
//!
//! From `_acpmux/peer_snapshot`, this machine's copy of the session:
//! - `has_row`: the hub knows its row;
//! - `snapshot_records`: the records of its chat the copy keeps (at least; a page past the read's
//!   bound reads as its own length), so a dead host's session moves from the copy.
//!
//! The caller's facts lie over these ([`merge`]): what it says wins, field by field, so a caller
//! that knows better (a VM it stopped itself, a first-seen time of its own) keeps its word. A fact
//! the hub cannot know (capacity, holders, the tried record, admission) comes only from the caller.

use serde_json::{Map, Value, json};

/// The host part of `HOST/NAME`, or empty for a bare name.
pub fn host_of(key: &str) -> &str {
    key.split_once('/').map_or("", |(h, _)| h)
}

/// The facts `peers` (an `_acpmux/peers` reply) and `snapshot` (an `_acpmux/peer_snapshot`
/// reply, when read) give of session `key`, at `now_ms`. Only what they say: a host this machine
/// has no peer row for (this machine itself, a host it never linked) gets no host facts.
pub fn observe(key: &str, peers: &Value, snapshot: Option<&Value>, now_ms: u64) -> Value {
    let host = host_of(key);
    let mut facts = Map::new();
    facts.insert("key".into(), json!(key));
    if !host.is_empty() {
        facts.insert("host".into(), json!(host));
    }
    let rows = peers.get("peers").and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[]);
    let up = |p: &Value| {
        p.get("connected").and_then(Value::as_bool) == Some(true)
            && p.get("downSince").is_none_or(Value::is_null)
    };
    let mut hosts = Map::new();
    let answering: Vec<&str> =
        rows.iter().filter(|p| up(p)).filter_map(|p| p.get("name")?.as_str()).collect();
    if !rows.is_empty() {
        hosts.insert("answering".into(), json!(answering));
    }
    if let Some(row) = rows.iter().find(|p| p.get("name").and_then(Value::as_str) == Some(host)) {
        facts.insert("host_down".into(), json!(!up(row)));
        if let Some(since) = row.get("downSince").and_then(Value::as_u64) {
            facts
                .insert("dead_seconds".into(), json!(now_ms.saturating_sub(since) as f64 / 1000.0));
        }
    }
    if let Some(snap) = snapshot {
        facts.insert("has_row".into(), json!(snap.get("summary").is_some_and(|s| !s.is_null())));
        let records = snap.get("events").and_then(Value::as_array).map_or(0, Vec::len);
        if records > 0 {
            facts.insert("snapshot_records".into(), json!(records));
        }
    }
    if !hosts.is_empty() {
        facts.insert("hosts".into(), Value::Object(hosts));
    }
    Value::Object(facts)
}

/// `over` laid on `base`: objects merge key by key, anything else in `over` replaces `base`'s.
pub fn merge(base: Value, over: Value) -> Value {
    match (base, over) {
        (Value::Object(mut b), Value::Object(o)) => {
            for (k, v) in o {
                let merged = match b.remove(&k) {
                    Some(old) => merge(old, v),
                    None => v,
                };
                b.insert(k, merged);
            }
            Value::Object(b)
        }
        (_, over) => over,
    }
}

#[cfg(test)]
#[path = "observe_tests.rs"]
mod tests;
