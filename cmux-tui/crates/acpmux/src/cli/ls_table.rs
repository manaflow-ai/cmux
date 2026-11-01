//! The text `acpmux ls` prints (`--json` is the daemon's list as it is).
//!
//! By default the list is compact (Leo, 2026-10-30: "acpmux ls should probably not be overly...
//! verbose? i guess"): only the live lanes someone named, one short line each, NAME, HOST (only
//! while some row is on a peer), STATE, TURNS, AGE, WARN (only while some row breaks a usage
//! rule) and STUCK, the short reason a lane needs someone. Closed sessions, reviewer boxes,
//! sub-sessions and sessions with only their harness's generated name are hidden and counted on
//! a last line. `--all` lists those too; `--wide` prints every column (AGENT, STATUS, the usage
//! columns and LAST).
//! A peer whose link is down never drops out: its rows read `unknown`, and a line per such peer
//! says its sessions are last known, not live (hq#4897: unreadable means UNKNOWN).

use super::output::short;
use serde_json::Value;

/// `acpmux ls --help` examples.
pub const HELP: &str = "Examples:
  acpmux ls                       live named lanes: NAME, HOST, STATE, TURNS, AGE, STUCK, WARN
  acpmux ls --all                 also closed, reviewer, sub- and unnamed sessions
  acpmux ls --wide                every column (AGENT, STATUS, usage, LAST)
  acpmux ls --status stuck        only stuck sessions (a filter hides nothing else)
  acpmux ls --live --host cosmic-gray   that host's live sessions (--host local: this machine)
  acpmux --json ls --fields name,state,peer   for scripts: the daemon's rows, unchanged
  acpmux ls 'review-27*' --fields name,turn.activity   name globs (host/glob: one peer's); dotted fields

STUCK is why a lane needs someone: permission, capacity, harness down, failed turn, stalled 12m.
A peer that cannot be reached reads UNKNOWN; its sessions are last known. ls never starts a daemon.
Usage (--wide): LAUNCHER, CAP (autocompact cap, or none), CTX (context now), CMP (compactions),
SUBS (subagents live/started), TOK24H and $24H; ? is a value acpmux could not read, never 0.";

/// Which rows and columns the text list shows.
#[derive(Clone, Copy, Debug, Default)]
pub struct View {
    /// Rows the compact list hides, listed too.
    pub all: bool,
    /// Every column, not the compact few.
    pub wide: bool,
}

/// Why the compact list hides a row; `None` for one it lists.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Hidden {
    Closed,
    Reviewer,
    SubSession,
    Unnamed,
}

const HIDDEN_ORDER: [(Hidden, &str); 4] = [
    (Hidden::Closed, "closed"),
    (Hidden::Reviewer, "reviewers"),
    (Hidden::SubSession, "sub-sessions"),
    (Hidden::Unnamed, "unnamed"),
];

fn text<'a>(row: &'a Value, key: &str) -> &'a str {
    row.get(key).and_then(Value::as_str).unwrap_or("")
}

fn hidden(row: &Value) -> Option<Hidden> {
    if text(row, "status") == "closed" {
        return Some(Hidden::Closed);
    }
    let tags = row
        .get("tags")
        .and_then(Value::as_object)
        .into_iter()
        .flat_map(|tags| tags.keys().map(String::as_str));
    if crate::review_box::is(text(row, "harness"), tags) {
        return Some(Hidden::Reviewer);
    }
    if row.get("parentId").is_some_and(|p| !p.is_null()) {
        return Some(Hidden::SubSession);
    }
    if !named(row) {
        return Some(Hidden::Unnamed);
    }
    None
}

/// Whether someone named the session: not empty, and not the `HARNESS` or `HARNESS-N` name the
/// daemon gives a session started without one (`hub/new_request.rs` `unique_name_among`).
fn named(row: &Value) -> bool {
    let name = text(row, "name");
    if name.trim().is_empty() {
        return false;
    }
    // The daemon says so (`nameGiven`); a session from before it was kept says so by its title
    // source, renamed (`named`) or started under a name and not yet prompted (`launched`).
    if row["nameGiven"] == true || matches!(text(row, "titleSource"), "named" | "launched") {
        return true;
    }
    let harness = text(row, "harness");
    let generated = name.strip_prefix(harness).is_some_and(|rest| {
        rest.is_empty()
            || rest
                .strip_prefix('-')
                .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
    });
    harness.is_empty() || !generated
}

/// The peer a row lives on; `None` for this machine's.
fn host(row: &Value) -> Option<&str> {
    row.get("peer").and_then(Value::as_str).filter(|p| !p.is_empty())
}

/// Whether the row is a peer's last-known copy, its peer unreachable now.
fn unreadable(row: &Value) -> bool {
    row["stale"] == true
        || host(row).is_some()
            && row
                .get("peerState")
                .and_then(Value::as_str)
                .is_some_and(|s| s != "connected" && s != "degraded")
}

fn state(row: &Value) -> String {
    if unreadable(row) {
        return "unknown".into();
    }
    if pending(row) > 0 {
        return "waiting".into();
    }
    row["state"].as_str().map_or_else(|| text(row, "status").to_owned(), str::to_owned)
}

fn pending(row: &Value) -> u64 {
    row.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0)
}

/// The short reason a lane needs someone, or empty: a permission it waits on, the daemon's stuck
/// reason (capacity, the harness down), a failed or lost turn, or a stalled turn.
fn stuck(row: &Value, now: u64) -> String {
    if unreadable(row) {
        return format!("peer {}", row.get("peerState").and_then(Value::as_str).unwrap_or("down"));
    }
    match pending(row) {
        0 => {}
        1 => return "permission".into(),
        n => return format!("{n} permissions"),
    }
    match text(row, "stuckReason") {
        "" => {}
        "capacity" => return "capacity".into(),
        "harness_unavailable" => return "harness down".into(),
        other => return other.replace('_', " "),
    }
    let lane = &row["lane"];
    if let Some(since) = lane["stalledSince"].as_u64() {
        return format!("stalled {}", ago(now, since));
    }
    match lane["state"].as_str() {
        Some("failed") => "failed turn".into(),
        Some("lost") => "lost turn".into(),
        Some("input") => "question".into(),
        _ => String::new(),
    }
}

/// The WARN cell: `warn` when the row breaks a usage rule (`usageWarnings`, `hub/usage_warnings.rs`),
/// one word so the default listing stays compact (Leo 2026-10-30: "acpmux ls should probably not
/// be overly... verbose?"); wide names each rule with its number and the command that answers it
/// (`ctx 412k: acpmux send lane-1 /compact | lane-place rotate lane-1`). A respawn that waits
/// for the turn to end (`respawnPending`, `hub/profile_respawn.rs`) comes first, in full in both:
/// `respawn pending: profile changed`.
fn warn(row: &Value, wide: bool) -> String {
    let respawn = row
        .get("respawnPending")
        .and_then(Value::as_str)
        .map(|why| format!("respawn pending: {why}"));
    let usage = row.get("usageWarnings").and_then(Value::as_array).filter(|w| !w.is_empty()).map(
        |warnings| {
            if !wide {
                return "warn".to_owned();
            }
            warnings
                .iter()
                .map(crate::hub::usage_warnings::with_command)
                .collect::<Vec<_>>()
                .join("; ")
        },
    );
    respawn.into_iter().chain(usage).collect::<Vec<_>>().join("; ")
}

/// The wide view's usage columns, read from `usageStats` (`hub/usage_view.rs`).
const USAGE_HEADER: [&str; 7] = ["LAUNCHER", "CAP", "CTX", "CMP", "SUBS", "TOK24H", "$24H"];

/// A row's usage cells: its launcher, autocompact cap (its tokens; `capped` when a cap is set
/// but its value could not be read; `none` when nothing caps it), the last
/// call's context, compactions, subagents live/started, and the last day's tokens and cost. A
/// value acpmux could not read is `?`, never 0; a row without `usageStats` (a harness it does not
/// read, records not found yet) is all `?`.
fn usage(row: &Value) -> [String; 7] {
    let stats = &row["usageStats"];
    let tokens = |n: u64| match n {
        n if n >= 999_500 => format!("{:.1}M", n as f64 / 1e6),
        n if n >= 1_000 => format!("{}k", n.saturating_add(500) / 1000),
        n => n.to_string(),
    };
    let unknown = || "?".to_owned();
    let count = |k: &str| stats[k].as_u64().map_or_else(unknown, |n| n.to_string());
    let cap = match (stats["autocompact"].as_str(), stats["autocompactCap"].as_u64()) {
        (Some("capped"), Some(n)) => tokens(n),
        (Some("capped"), None) => "capped".to_owned(),
        (Some("none"), _) => "none".to_owned(),
        _ => unknown(),
    };
    let cost = match stats["costUsd24h"].as_f64() {
        Some(c) if c >= 10.0 => format!("${c:.0}"),
        Some(c) => format!("${c:.2}"),
        None => unknown(),
    };
    [
        short(stats["launcher"].as_str().unwrap_or("?"), 10),
        cap,
        stats["contextTokens"].as_u64().map_or_else(unknown, tokens),
        count("compactions24h"),
        format!("{}/{}", count("subagentsLive"), count("subagents24h")),
        stats["tokens24h"].as_u64().map_or_else(unknown, tokens),
        cost,
    ]
}

/// How long ago `at` was, from `now` (both in ms): `12s`, `4m`, `3h`, `2d`.
fn ago(now: u64, at: u64) -> String {
    let s = now.saturating_sub(at) / 1000;
    match s {
        0..60 => format!("{s}s"),
        60..3600 => format!("{}m", s / 60),
        3600..86_400 => format!("{}h", s / 3600),
        _ => format!("{}d", s / 86_400),
    }
}

/// One table: each column's cells padded to its widest, the last column unpadded.
fn table(rows: Vec<Vec<String>>) -> String {
    let columns = rows.first().map_or(0, Vec::len);
    let widths: Vec<usize> = (0..columns)
        .map(|c| {
            rows.iter().filter_map(|r| r.get(c)).map(|cell| cell.chars().count()).max().unwrap_or(0)
        })
        .collect();
    let mut out = String::new();
    for row in rows {
        let mut line = String::new();
        for (c, cell) in row.iter().enumerate() {
            if c + 1 == columns {
                line.push_str(cell);
            } else {
                line.push_str(&format!("{cell:<w$}  ", w = widths.get(c).copied().unwrap_or(0)));
            }
        }
        out.push_str(line.trim_end());
        out.push('\n');
    }
    out
}

/// The text list of `sessions` (the daemon's rows, newest first). `peers` is the daemon's peer
/// list (`_acpmux/status` `peers`), `None` when it could not be read. `filtered`: the caller
/// selected rows itself (`--status`, `--tag`, ...), so none is hidden.
pub fn render(
    sessions: &[Value],
    peers: Option<&[Value]>,
    view: View,
    filtered: bool,
    now: u64,
) -> String {
    let mut hidden_counts = [0usize; HIDDEN_ORDER.len()];
    // The daemon's order (newest first) in every view: `--limit`, `--since` and `--tag` read it.
    let shown: Vec<&Value> = sessions
        .iter()
        .filter(|row| match hidden(row) {
            Some(why) if !view.all && !filtered => {
                let i = HIDDEN_ORDER.iter().position(|(h, _)| *h == why).unwrap_or(0);
                if let Some(count) = hidden_counts.get_mut(i) {
                    *count += 1;
                }
                false
            }
            _ => true,
        })
        .collect();
    let mut out = String::new();
    if shown.is_empty() {
        out.push_str(if filtered {
            "no sessions match these filters\n"
        } else if sessions.is_empty() {
            "no sessions (create one: acpmux new -m codex -n my-task)\n"
        } else {
            "no live named sessions\n"
        });
    } else {
        let with_host = shown.iter().any(|r| host(r).is_some());
        let with_warn = shown.iter().any(|r| !warn(r, false).is_empty());
        let with_stuck = shown.iter().any(|r| !stuck(r, now).is_empty());
        let mut header = vec!["NAME"];
        if with_host {
            header.push("HOST");
        }
        if view.wide {
            header.extend(["AGENT", "STATUS"]);
        } else {
            header.push("STATE");
        }
        header.extend(["TURNS", "AGE"]);
        if with_stuck || view.wide {
            header.push("STUCK");
        }
        if with_warn {
            header.push("WARN");
        }
        if view.wide {
            header.extend(USAGE_HEADER);
            header.push("LAST");
        }
        let mut rows = vec![header.into_iter().map(str::to_owned).collect::<Vec<_>>()];
        for row in &shown {
            let mut cells = vec![short(text(row, "name"), if view.wide { 24 } else { 32 })];
            if with_host {
                cells.push(host(row).unwrap_or("-").to_owned());
            }
            if view.wide {
                cells.push(short(text(row, "harness"), 8));
            }
            cells.push(state(row));
            cells.push(row.get("turnCount").and_then(Value::as_u64).unwrap_or(0).to_string());
            cells.push(ago(now, row.get("updatedAt").and_then(Value::as_u64).unwrap_or(0)));
            if with_stuck || view.wide {
                cells.push(stuck(row, now));
            }
            if with_warn {
                cells.push(warn(row, view.wide));
            }
            if view.wide {
                cells.extend(usage(row));
                cells.push(short(text(row, "lastPrompt"), 50));
            }
            rows.push(cells);
        }
        out.push_str(&table(rows));
    }
    for peer in peers.unwrap_or_default() {
        let state = text(peer, "state");
        if state.is_empty() || state == "connected" || state == "degraded" {
            continue;
        }
        let since = peer["downSince"]
            .as_u64()
            .map(|at| format!(" for {}", ago(now, at)))
            .unwrap_or_default();
        out.push_str(&format!(
            "UNKNOWN {}: peer {state}{since}; its sessions are last known, not live\n",
            text(peer, "name")
        ));
    }
    if peers.is_none() {
        out.push_str("UNKNOWN peers: their link states could not be read\n");
    }
    let hidden_total: usize = hidden_counts.iter().sum();
    if hidden_total > 0 {
        let parts: Vec<String> = HIDDEN_ORDER
            .iter()
            .zip(hidden_counts)
            .filter(|(_, n)| *n > 0)
            .map(|((_, label), n)| format!("{n} {label}"))
            .collect();
        out.push_str(&format!(
            "{hidden_total} more hidden ({}): acpmux ls --all\n",
            parts.join(", ")
        ));
    }
    out
}

#[cfg(test)]
#[path = "ls_table_tests.rs"]
mod tests;
