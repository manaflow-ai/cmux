//! `acpmux daemon stats`: the running daemon's busiest callers (or methods) over a recent window,
//! from `_acpmux/callers` (`caller_stats.rs`), each named by client, origin, pid and session so
//! its process can be found. A daemon from before that method answers with its `listReplies`
//! (replies to `_acpmux/watch` and `_acpmux/sessions` since it started) instead.

use anyhow::Result;
use clap::ValueEnum;
use serde_json::{Value, json};
use std::fmt::Write as _;

use crate::rpc::method;

/// What the rows are.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, ValueEnum)]
pub enum By {
    /// One row per caller (client, origin, pid, session) with its busiest methods.
    #[default]
    Caller,
    /// One row per method with how many callers sent it.
    Method,
}

/// `acpmux daemon stats`.
pub async fn run(by: By, since: &str, top: usize, json_out: bool) -> Result<()> {
    let since_secs = crate::cli::run::ls::parse_duration_ms(since)?.div_ceil(1000).max(1);
    let client = crate::daemon::connect(false).await?;
    let params = json!({"sinceSecs": since_secs, "top": top});
    match client.request(method::MUX_CALLERS, params).await {
        Ok(v) => {
            if json_out {
                crate::cli::output::print_json(&v);
            } else {
                print!("{}", render(&v, by));
            }
        }
        Err(e) if method_not_found(&e) => {
            let status = client.request(method::MUX_STATUS, json!({})).await?;
            let list = status.get("listReplies").cloned().unwrap_or(Value::Null);
            if json_out {
                crate::cli::output::print_json(&json!({"listReplies": list, "fallback": true}));
            } else {
                print!("{}", render_list_replies(&list, top));
            }
        }
        Err(e) => return Err(e),
    }
    Ok(())
}

fn method_not_found(e: &anyhow::Error) -> bool {
    e.downcast_ref::<crate::client::DaemonError>().is_some_and(|e| e.0.code == -32601)
}

/// `bytes` as B, KB, MB or GB.
fn human(bytes: u64) -> String {
    const UNITS: [&str; 4] = ["B", "KB", "MB", "GB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit + 1 < UNITS.len() {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} B")
    } else {
        format!("{value:.1} {}", UNITS.get(unit).copied().unwrap_or("GB"))
    }
}

fn u(v: &Value, key: &str) -> u64 {
    v.get(key).and_then(Value::as_u64).unwrap_or(0)
}

/// The `_acpmux/callers` answer `v` as a table.
pub(crate) fn render(v: &Value, by: By) -> String {
    let rows = v.get(if by == By::Caller { "callers" } else { "methods" });
    let rows = rows.and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default();
    let count = u(v, if by == By::Caller { "callerCount" } else { "methodCount" });
    let mut out = String::new();
    let _ = writeln!(
        out,
        "last {}s: {} {} ({} shown), daemon counting for {}s, {} of {} slots, {} evicted",
        u(v, "windowSecs"),
        count,
        if by == By::Caller { "callers" } else { "methods" },
        rows.len(),
        u(v, "uptimeSecs"),
        u(v, "entries"),
        u(v, "maxEntries"),
        u(v, "evicted"),
    );
    if rows.is_empty() {
        out.push_str("no requests in the window\n");
        return out;
    }
    let per_minute = |row: &Value| row.get("perMinute").and_then(Value::as_f64).unwrap_or(0.0);
    match by {
        By::Caller => {
            let _ = writeln!(
                out,
                "{:>8} {:>7} {:>10} {:>10}  {:<6} {:>7}  {:<28} {:<22} TOP METHODS",
                "REQ/MIN", "REQS", "IN", "OUT", "ORIGIN", "PID", "CLIENT", "SESSION"
            );
            for row in rows {
                let pid =
                    row.get("pid").and_then(Value::as_u64).map_or("-".into(), |p| p.to_string());
                let client = row.get("client").and_then(Value::as_str).filter(|c| !c.is_empty());
                let session = row.get("session").and_then(Value::as_str).map_or_else(
                    || "-".to_owned(),
                    |s| {
                        let proven = row.get("sessionProven").and_then(Value::as_bool);
                        if proven == Some(true) { s.to_owned() } else { format!("{s}?") }
                    },
                );
                let methods: Vec<String> = row
                    .get("methods")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .map(|m| {
                        format!(
                            "{} x{}",
                            m.get("method").and_then(Value::as_str).unwrap_or("?"),
                            u(m, "requests")
                        )
                    })
                    .collect();
                let _ = writeln!(
                    out,
                    "{:>8.1} {:>7} {:>10} {:>10}  {:<6} {:>7}  {:<28} {:<22} {}",
                    per_minute(row),
                    u(row, "requests"),
                    human(u(row, "requestBytes")),
                    human(u(row, "replyBytes")),
                    row.get("origin").and_then(Value::as_str).unwrap_or("?"),
                    pid,
                    client.unwrap_or("(unnamed)"),
                    session,
                    methods.join(", "),
                );
            }
        }
        By::Method => {
            let _ = writeln!(
                out,
                "{:>8} {:>7} {:>10} {:>10} {:>7}  METHOD",
                "REQ/MIN", "REQS", "IN", "OUT", "CALLERS"
            );
            for row in rows {
                let _ = writeln!(
                    out,
                    "{:>8.1} {:>7} {:>10} {:>10} {:>7}  {}",
                    per_minute(row),
                    u(row, "requests"),
                    human(u(row, "requestBytes")),
                    human(u(row, "replyBytes")),
                    u(row, "callers"),
                    row.get("method").and_then(Value::as_str).unwrap_or("?"),
                );
            }
        }
    }
    out
}

/// An older daemon's `listReplies` (no `_acpmux/callers`): its list replies since it started, by
/// client, the most replies first.
pub(crate) fn render_list_replies(list: &Value, top: usize) -> String {
    let mut rows: Vec<(&String, &Value)> =
        list.as_object().map(|o| o.iter().collect()).unwrap_or_default();
    rows.sort_by(|a, b| (u(b.1, "replies"), a.0).cmp(&(u(a.1, "replies"), b.0)));
    let mut out = String::from(
        "this daemon has no per-caller stats (_acpmux/callers); its list replies \
         (_acpmux/watch, _acpmux/sessions) since it started, by client. Read again a minute \
         later for a rate:\n",
    );
    if rows.is_empty() {
        out.push_str("no list replies\n");
        return out;
    }
    let _ = writeln!(out, "{:>9} {:>10} {:>10}  CLIENT", "REPLIES", "BYTES", "LARGEST");
    for (client, row) in rows.into_iter().take(top.max(1)) {
        let _ = writeln!(
            out,
            "{:>9} {:>10} {:>10}  {client}",
            u(row, "replies"),
            human(u(row, "bytes")),
            human(u(row, "largest")),
        );
    }
    out
}

#[cfg(test)]
#[path = "daemon_stats_tests.rs"]
mod tests;
