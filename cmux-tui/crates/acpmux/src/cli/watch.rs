//! `acpmux watch add|ls|rm`: the daemon's durable wake subscriptions (`server/watches.rs`,
//! `hub/watches.rs`) from a shell. A watch wakes its recipient with one ordinary message when a
//! watched session ends a turn, asks for permission or closes, so a coordinator needs no wait
//! loop and no worker polls it. The daemon keeps the watch and any wake it owes across its own
//! restart and the recipient's outage; this command only creates, lists and removes one. Inside an
//! agent session the CLI carries the session's caller token (`client.rs`), so `--to` defaults to
//! that session. The MCP tools of the same names answer with the same text (`acpmux_mcp_watch.rs`).
//!
//! A time watch (`--at`, `--every`, `hub/watch_timers.rs`) wakes its recipient with `--prompt` at
//! a time instead: once, or every period until `--until`. The times are turned into ms since the
//! epoch here, so the daemon keeps numbers and every surface parses them one way (`when_ms`).

use anyhow::Result;
use clap::Subcommand;
use serde_json::{Value, json};

use crate::rpc::method;

#[derive(Subcommand)]
pub enum WatchCmd {
    /// Wake a session once, with one message, when one of these sessions is done or blocked; or,
    /// with --at or --every, at a time, with --prompt.
    Add {
        /// The sessions to watch: names, ids or HOST/name (none for a time watch).
        #[arg(required_unless_present_any = ["at", "every"])]
        sessions: Vec<String>,
        /// The session to wake. Default: the session this command runs in.
        #[arg(long)]
        to: Option<String>,
        /// States that wake it: ready, permission, done, closed. Default: ready or permission.
        /// With --every: the time after which it fires no more (RFC 3339 or +DURATION).
        #[arg(long = "until", value_delimiter = ',')]
        until: Vec<String>,
        /// Only a turn whose transcript contains this text wakes it.
        #[arg(long = "match")]
        match_text: Option<String>,
        /// A time watch: wake once at this time, RFC 3339 (2026-11-26T09:00:00Z) or +DURATION
        /// (+30m, +1h30m). With --every, the first fire.
        #[arg(long)]
        at: Option<String>,
        /// A time watch: wake every DURATION (30m, 1d). A fire missed while the host slept is
        /// sent once, not once per missed period.
        #[arg(long)]
        every: Option<String>,
        /// The message a time watch sends when it falls due.
        #[arg(long)]
        prompt: Option<String>,
    },
    /// The watches and the wakes they still owe (not yet accepted by the recipient).
    Ls,
    /// Remove a watch. Wakes it already owes are still delivered.
    Rm { id: String },
}

/// The `watch_add` params from the shared arguments of the CLI and the MCP tool.
pub(crate) fn add_params(
    sessions: Vec<String>,
    to: Option<String>,
    until: Vec<String>,
    match_text: Option<String>,
) -> Value {
    let mut p = serde_json::Map::new();
    p.insert("sessions".into(), json!(sessions));
    p.insert("once".into(), json!(true));
    if let Some(to) = to {
        p.insert("to".into(), json!(to));
    }
    if !until.is_empty() {
        p.insert("until".into(), json!(until));
    }
    if let Some(m) = match_text {
        p.insert("match".into(), json!(m));
    }
    Value::Object(p)
}

/// The ms since the epoch a time names: RFC 3339, or a duration from `now_ms` (`+30m`; the `+`
/// may be left out).
pub(crate) fn when_ms(text: &str, now_ms: u64) -> Result<u64, String> {
    let t = text.trim();
    if let Ok(at) = chrono::DateTime::parse_from_rfc3339(t) {
        return u64::try_from(at.timestamp_millis()).map_err(|_| format!("{t:?} is before 1970"));
    }
    duration_ms(t.strip_prefix('+').unwrap_or(t)).map(|d| now_ms.saturating_add(d)).map_err(|_| {
        format!("invalid time {t:?}; use RFC 3339 (2026-11-26T09:00:00Z) or +DURATION (+30m)")
    })
}

/// A duration such as `30m`, `1h30m`, `1d` in ms.
pub(crate) fn duration_ms(text: &str) -> Result<u64, String> {
    crate::cli::run::ls::parse_duration_ms(text)
        .map_err(|_| format!("invalid duration {text:?}; use values such as 90s, 30m, 1h30m or 1d"))
}

/// The `watch_add` params of a time watch, from the CLI's or the MCP tool's arguments.
pub(crate) fn time_params(
    to: Option<String>,
    at: Option<&str>,
    every: Option<&str>,
    until: Option<&str>,
    prompt: Option<String>,
    now_ms: u64,
) -> Result<Value, String> {
    let mut p = serde_json::Map::new();
    if let Some(to) = to {
        p.insert("to".into(), json!(to));
    }
    if let Some(at) = at {
        p.insert("atMs".into(), json!(when_ms(at, now_ms)?));
    }
    if let Some(every) = every {
        p.insert("everyMs".into(), json!(duration_ms(every.trim())?));
    }
    if let Some(until) = until {
        if every.is_none() {
            return Err("an end time (--until) needs every (--every)".into());
        }
        p.insert("endMs".into(), json!(when_ms(until, now_ms)?));
    }
    match prompt {
        Some(prompt) if !prompt.trim().is_empty() => {
            p.insert("prompt".into(), json!(prompt));
        }
        _ => {
            return Err(
                "a time watch needs a prompt (--prompt): the message it sends when due".into()
            );
        }
    }
    Ok(Value::Object(p))
}

pub async fn run(cmd: WatchCmd, json_out: bool) -> Result<()> {
    let (m, params) = match cmd {
        WatchCmd::Add { sessions, to, until, match_text, at, every, prompt }
            if at.is_some() || every.is_some() =>
        {
            if !sessions.is_empty() || match_text.is_some() {
                anyhow::bail!("a time watch (--at, --every) takes no sessions and no --match");
            }
            if until.len() > 1 {
                anyhow::bail!("--until takes one time with --every");
            }
            let params = time_params(
                to,
                at.as_deref(),
                every.as_deref(),
                until.first().map(String::as_str),
                prompt,
                crate::store::now_ms(),
            )
            .map_err(anyhow::Error::msg)?;
            (method::MUX_WATCH_ADD, params)
        }
        WatchCmd::Add { sessions, to, until, match_text, prompt, .. } => {
            if prompt.is_some() {
                anyhow::bail!("--prompt is for a time watch: add --at or --every");
            }
            (method::MUX_WATCH_ADD, add_params(sessions, to, until, match_text))
        }
        WatchCmd::Ls => (method::MUX_WATCH_LS, json!({})),
        WatchCmd::Rm { id } => (method::MUX_WATCH_RM, json!({"id": id})),
    };
    let client = crate::daemon::connect(false).await?;
    let reply = client.request(m, params).await?;
    if json_out {
        println!("{}", serde_json::to_string_pretty(&reply)?);
    } else {
        println!("{}", text(m, &reply));
    }
    Ok(())
}

/// A reply as text, for the CLI and the MCP tools alike.
pub(crate) fn text(m: &str, reply: &Value) -> String {
    match m {
        method::MUX_WATCH_ADD if reply["prompt"].is_string() => format!(
            "Watch {}: wakes {} {}.\nList with acpmux watch ls; remove with acpmux watch rm {}.",
            str_of(&reply["id"]),
            str_of(&reply["to"]),
            schedule(reply),
            str_of(&reply["id"]),
        ),
        method::MUX_WATCH_ADD => format!(
            "Watch {}: wakes {} once when {}.\nList with acpmux watch ls; remove with acpmux watch rm {}.",
            str_of(&reply["id"]),
            str_of(&reply["to"]),
            condition(reply),
            str_of(&reply["id"]),
        ),
        method::MUX_WATCH_RM => match reply["owed"].as_u64().unwrap_or(0) {
            0 => format!("Removed watch {}.", str_of(&reply["removed"])),
            n => format!(
                "Removed watch {}. It still owes {n} wake(s) from before; they are delivered.",
                str_of(&reply["removed"])
            ),
        },
        _ => ls_text(reply),
    }
}

fn ls_text(reply: &Value) -> String {
    let mut lines = Vec::new();
    for w in reply["watches"].as_array().into_iter().flatten() {
        let mut line = if w["prompt"].is_string() {
            format!("{}  wakes {} {}", str_of(&w["id"]), str_of(&w["to"]), schedule(w))
        } else {
            format!("{}  wakes {} when {}", str_of(&w["id"]), str_of(&w["to"]), condition(w))
        };
        if w["active"] == false {
            line.push_str("  (resolved, wake pending)");
        }
        if let Some(offline) = w["offline"].as_array().filter(|o| !o.is_empty()) {
            let names: Vec<&str> = offline.iter().filter_map(Value::as_str).collect();
            line.push_str(&format!("  (offline: {})", names.join(", ")));
        }
        lines.push(line);
    }
    if lines.is_empty() {
        lines.push("No watches.".to_owned());
    }
    let owed: Vec<String> = reply["deliveries"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|d| {
            // The outbox's own state: `queued`, `delivering` or `failed` is not accepted yet.
            let mut line = format!(
                "  {} to {}: {} (attempt {})",
                str_of(&d["deliveryId"]),
                str_of(&d["target"]),
                str_of(&d["status"]),
                d["attempts"].as_u64().unwrap_or(0)
            );
            if let Some(e) = d["error"].as_str() {
                line.push_str(&format!(": {e}"));
            }
            line
        })
        .collect();
    if !owed.is_empty() {
        lines.push("Wakes owed:".to_owned());
        lines.extend(owed);
    }
    lines.join("\n")
}

/// A time watch's schedule: when it is next due, its period and end, and its prompt.
fn schedule(w: &Value) -> String {
    let at = |key: &str| {
        w[key]
            .as_u64()
            .and_then(|ms| chrono::DateTime::from_timestamp_millis(ms as i64))
            .map(|t| t.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
    };
    let mut s = match at("nextDueMs") {
        Some(next) => format!("next at {next}"),
        None => "fired".to_owned(),
    };
    if let Some(every) = w["everyMs"].as_u64() {
        s.push_str(&format!(", every {}", short_duration(every)));
    }
    if let Some(end) = at("endMs") {
        s.push_str(&format!(" until {end}"));
    }
    let prompt = str_of(&w["prompt"]);
    let mut shown: String = prompt.chars().take(60).collect();
    if shown.len() < prompt.len() {
        shown.push('…');
    }
    s.push_str(&format!(": {shown:?}"));
    s
}

fn short_duration(ms: u64) -> String {
    let secs = ms / 1000;
    let units = [(86_400, "d"), (3_600, "h"), (60, "m"), (1, "s")];
    let mut out = String::new();
    let mut rest = secs;
    for (size, unit) in units {
        if rest >= size {
            out.push_str(&format!("{}{unit}", rest / size));
            rest %= size;
        }
    }
    if out.is_empty() { format!("{ms}ms") } else { out }
}

fn condition(w: &Value) -> String {
    let sessions: Vec<&str> =
        w["sessions"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
    let until: Vec<&str> =
        w["until"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
    let mut s = format!("{} is {}", sessions.join(" or "), until.join(" or "));
    if let Some(m) = w["match"].as_str() {
        s.push_str(&format!(", matching {m:?}"));
    }
    s
}

fn str_of(v: &Value) -> &str {
    v.as_str().unwrap_or("?")
}

#[cfg(test)]
#[path = "watch_tests.rs"]
mod tests;
