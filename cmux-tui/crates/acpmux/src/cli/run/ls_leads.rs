//! `acpmux ls --leads`: the leaders (Leo, 2026-11-02: "i need to be able to see and talk to the
//! leaders of every respective thing"), the coordinator, its deputies and the area owners. Each
//! starts its lanes from its own chat, and the daemon tags every such lane `lane.reportsTo` with
//! that chat's id (`hub/lane_reports.rs`), so a leader is derived, never listed by hand: a live
//! session that at least one live session reports to. A lane names its leader by bare id on its
//! own machine, so the two match on (peer, id). The app's New Tab derives the same
//! (webviews `acpmux/leads.ts`).

use std::collections::HashMap;

use serde_json::{Value, json};

use super::ls::is_live;
use crate::hub::REPORTS_TO_TAG as TAG;

/// A row's machine (its peer; empty for this one's) and id.
fn key(row: &Value) -> Option<(&str, &str)> {
    let id = row.get("sessionId").and_then(Value::as_str)?;
    Some((row.get("peer").and_then(Value::as_str).unwrap_or(""), id))
}

/// The leader `row` reports to, on its own machine.
fn reports_to(row: &Value) -> Option<(&str, &str)> {
    let (peer, id) = key(row)?;
    let to = row.get("tags").and_then(|t| t.get(TAG)).and_then(Value::as_str)?;
    (!to.is_empty() && to != id).then_some((peer, to))
}

/// Live and on the lists: not archived, and not a side chat or an aside's throwaway copy (as
/// the app's `sessionEntry` reads `side`).
fn listed(row: &Value) -> bool {
    let tagged = |tag: &str| row.get("tags").and_then(|t| t.get(tag)).is_some();
    is_live(row) && !["archived", "side", "aside"].iter().any(|tag| tagged(tag))
}

fn name(row: &Value) -> &str {
    row.get("name").and_then(Value::as_str).unwrap_or("")
}

/// The leaders among `rows`, each once, with `reports` (the names of the live sessions that
/// report to it); the one with the most reports first, then by name.
pub(super) fn leaders(rows: &[Value]) -> Vec<Value> {
    let rows: Vec<&Value> = rows.iter().filter(|r| listed(r)).collect();
    let mut reports: HashMap<(&str, &str), Vec<&str>> = HashMap::new();
    for row in &rows {
        if let Some(to) = reports_to(row) {
            reports.entry(to).or_default().push(name(row));
        }
    }
    let mut out: Vec<(usize, Value)> = Vec::new();
    for row in rows {
        let Some(below) = key(row).and_then(|k| reports.remove(&k)) else { continue };
        let mut lead = row.clone();
        if let Some(obj) = lead.as_object_mut() {
            obj.insert("reports".to_owned(), json!(below));
        }
        out.push((below.len(), lead));
    }
    out.sort_by(|(a, x), (b, y)| b.cmp(a).then_with(|| name(x).cmp(name(y))));
    out.into_iter().map(|(_, lead)| lead).collect()
}

/// The text view: one line a leader, `NAME  HOST  STATE  AREA  REPORTS`.
pub(super) fn render(leads: &[Value]) -> String {
    let cell = |row: &Value, path: &[&str]| -> String {
        let mut at = Some(row);
        for p in path {
            at = at.and_then(|v| v.get(*p));
        }
        at.and_then(Value::as_str).filter(|s| !s.is_empty()).unwrap_or("-").to_owned()
    };
    let lines: Vec<[String; 5]> = leads
        .iter()
        .map(|lead| {
            let state = lead
                .get("lane")
                .and_then(|l| l.get("state"))
                .and_then(Value::as_str)
                .or_else(|| lead.get("status").and_then(Value::as_str))
                .unwrap_or("-")
                .to_owned();
            let names: Vec<&str> = lead
                .get("reports")
                .and_then(Value::as_array)
                .map(|r| r.iter().filter_map(Value::as_str).collect())
                .unwrap_or_default();
            let host = cell(lead, &["peer"]);
            [
                name(lead).to_owned(),
                if host == "-" { "local".to_owned() } else { host },
                state,
                cell(lead, &["tags", "area"]),
                format!("{}: {}", names.len(), names.join(", ")),
            ]
        })
        .collect();
    if lines.is_empty() {
        return "no leaders: no live session has a live session reporting to it\n".to_owned();
    }
    let head = ["NAME", "HOST", "STATE", "AREA", "REPORTS"].map(str::to_owned);
    let mut widths = [0usize; 4];
    for line in std::iter::once(&head).chain(&lines) {
        for (w, c) in widths.iter_mut().zip(line.iter()) {
            *w = (*w).max(c.chars().count());
        }
    }
    let mut out = String::new();
    for line in std::iter::once(&head).chain(&lines) {
        for (c, w) in line.iter().zip(widths) {
            out.push_str(&format!("{c:<w$}  "));
        }
        if let Some(last) = line.last() {
            out.push_str(last);
        }
        out.push('\n');
    }
    out
}

#[cfg(test)]
mod tests;
