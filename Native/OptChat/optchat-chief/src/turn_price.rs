//! The price of a Chief turn whose harness reports tokens but no dollars (Hermes, OpenClaw,
//! codex: an ACP `usage` with no `cost_usd`), so every turn's cost is tracked (owner,
//! 2026-11-20). The rates are acpmux's bundled price table (`cmux-tui/crates/acpmux/src/
//! pricing/prices.json`, compiled in): one table for the ledger and the Chief. A model the table
//! does not list stays unpriced, never priced like a sibling. Matching follows acpmux
//! `pricing.rs`: a `vendor/` prefix is dropped, an alias is resolved, and the longest entry id
//! the model starts with wins when what follows is nothing, a `[`/`@`/`:` tag, or `-` and four or
//! more digits (a dated snapshot).

use std::sync::OnceLock;

use serde_json::Value;

const TABLE: &str = include_str!("../../../../cmux-tui/crates/acpmux/src/pricing/prices.json");

/// USD per million tokens.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Rates {
    input: f64,
    output: f64,
    cache_read: f64,
    cache_write: f64,
}

struct Table {
    aliases: Vec<(String, String)>,
    /// Longest id first.
    entries: Vec<(String, Rates)>,
}

fn table() -> &'static Table {
    static T: OnceLock<Table> = OnceLock::new();
    T.get_or_init(|| {
        let doc: Value = serde_json::from_str(TABLE).unwrap_or(Value::Null);
        let aliases = doc
            .get("aliases")
            .and_then(Value::as_object)
            .map(|m| {
                m.iter()
                    .filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_owned())))
                    .collect()
            })
            .unwrap_or_default();
        let mut entries: Vec<(String, Rates)> = doc
            .get("vendors")
            .and_then(Value::as_object)
            .into_iter()
            .flat_map(|v| v.values())
            .filter_map(|vendor| vendor.get("models").and_then(Value::as_array))
            .flatten()
            .filter_map(|e| {
                let f = |k: &str| e.get(k).and_then(Value::as_f64);
                let input = f("input")?;
                Some((
                    e.get("id")?.as_str()?.to_owned(),
                    Rates {
                        input,
                        output: f("output").unwrap_or(0.0),
                        // A missing cache read price bills cache reads as input; a missing cache
                        // write price bills them nothing (acpmux pricing.rs).
                        cache_read: f("cacheRead").unwrap_or(input),
                        cache_write: f("cacheWrite").unwrap_or(0.0),
                    },
                ))
            })
            .collect();
        entries.sort_by_key(|e| std::cmp::Reverse(e.0.len()));
        Table { aliases, entries }
    })
}

fn rates(model: &str) -> Option<Rates> {
    let t = table();
    let bare = model.rsplit_once('/').map_or(model, |(_, m)| m).trim();
    let id = t
        .aliases
        .iter()
        .find(|(alias, _)| alias == bare)
        .map_or(bare, |(_, to)| to.as_str());
    t.entries.iter().find_map(|(entry, r)| {
        let rest = id.strip_prefix(entry.as_str())?;
        let snapshot = rest
            .strip_prefix('-')
            .is_some_and(|d| d.len() >= 4 && d.bytes().all(|b| b.is_ascii_digit()));
        (rest.is_empty() || rest.starts_with(['[', '@', ':']) || snapshot).then_some(*r)
    })
}

/// The dollars `usage` cost on `model`, or None when the table does not list the model.
pub fn price(model: &str, usage: &chief_turn::Usage) -> Option<f64> {
    let r = rates(model)?;
    let m = 1_000_000.0;
    Some(
        usage.input as f64 * r.input / m
            + usage.output as f64 * r.output / m
            + usage.cache_read as f64 * r.cache_read / m
            + usage.cache_write as f64 * r.cache_write / m,
    )
}
