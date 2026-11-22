//! `acpmux watch add|ls|rm`: the daemon's durable wake subscriptions (`server/watches.rs`,
//! `hub/watches.rs`) from a shell. A watch wakes its recipient with one ordinary message when a
//! watched session ends a turn, asks for permission or closes, so a coordinator needs no wait
//! loop and no worker polls it. The daemon keeps the watch and any wake it owes across its own
//! restart and the recipient's outage; this command only creates, lists and removes one. Inside an
//! agent session the CLI carries the session's caller token (`client.rs`), so `--to` defaults to
//! that session. The MCP tools of the same names answer with the same text (`acpmux_mcp_watch.rs`).

use anyhow::Result;
use clap::Subcommand;
use serde_json::{Value, json};

use crate::rpc::method;

#[derive(Subcommand)]
pub enum WatchCmd {
    /// Wake a session once, with one message, when one of these sessions is done or blocked.
    Add {
        /// The sessions to watch: names, ids or HOST/name.
        #[arg(required = true)]
        sessions: Vec<String>,
        /// The session to wake. Default: the session this command runs in.
        #[arg(long)]
        to: Option<String>,
        /// States that wake it: ready, permission, done, closed. Default: ready or permission.
        #[arg(long = "until", value_delimiter = ',')]
        until: Vec<String>,
        /// Only a turn whose transcript contains this text wakes it.
        #[arg(long = "match")]
        match_text: Option<String>,
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

pub async fn run(cmd: WatchCmd, json_out: bool) -> Result<()> {
    let (m, params) = match cmd {
        WatchCmd::Add { sessions, to, until, match_text } => {
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
        let mut line =
            format!("{}  wakes {} when {}", str_of(&w["id"]), str_of(&w["to"]), condition(w));
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
mod tests {
    use super::*;

    #[test]
    fn text_names_the_condition_the_owed_wakes_and_their_outbox_state() {
        let added = json!({"id": "w1", "to": "coord", "sessions": ["a", "b/c"],
            "until": ["ready", "permission"], "match": "BLOCKER", "active": true});
        assert_eq!(
            text(method::MUX_WATCH_ADD, &added),
            "Watch w1: wakes coord once when a or b/c is ready or permission, matching \"BLOCKER\".\n\
             List with acpmux watch ls; remove with acpmux watch rm w1."
        );
        let listed = json!({"watches": [{"id": "w1", "to": "coord", "sessions": ["a"],
            "until": ["ready"], "active": false, "offline": ["b"]}],
            "deliveries": [{"deliveryId": "d1", "target": "coord", "status": "failed",
            "attempts": 2, "error": "peer down"}]});
        assert_eq!(
            text(method::MUX_WATCH_LS, &listed),
            "w1  wakes coord when a is ready  (resolved, wake pending)  (offline: b)\n\
             Wakes owed:\n  d1 to coord: failed (attempt 2): peer down"
        );
        assert_eq!(
            text(method::MUX_WATCH_LS, &json!({"watches": [], "deliveries": []})),
            "No watches."
        );
        assert_eq!(
            text(method::MUX_WATCH_RM, &json!({"removed": "w1", "owed": 1})),
            "Removed watch w1. It still owes 1 wake(s) from before; they are delivered."
        );
    }

    #[test]
    fn add_params_leave_defaults_to_the_daemon() {
        assert_eq!(
            add_params(vec!["a".into()], None, vec![], None),
            json!({"sessions": ["a"], "once": true})
        );
        assert_eq!(
            add_params(vec!["a".into()], Some("c".into()), vec!["done".into()], Some("x".into())),
            json!({"sessions": ["a"], "once": true, "to": "c", "until": ["done"], "match": "x"})
        );
    }
}
