//! `acpmux session stop --purge`'s line, `acpmux session undelete SESSION` and `acpmux session
//! deleted`: a deleted chat is kept 7 days, restorable (`hub/soft_delete.rs`). A daemon older
//! than that deletes at once; the line says which happened from the daemon's own reply.

use anyhow::Result;
use serde_json::{Value, json};

use crate::cli::output::print_json;
use crate::client::Client;
use crate::rpc::method;

/// Unix ms as this machine's local date and time, `Nov 24 18:03`.
fn local_time(ms: u64) -> String {
    i64::try_from(ms)
        .ok()
        .and_then(chrono::DateTime::from_timestamp_millis)
        .map(|t| t.with_timezone(&chrono::Local).format("%b %-d %H:%M").to_string())
        .unwrap_or_else(|| ms.to_string())
}

/// What `session stop` prints for the daemon's reply `v`.
pub(crate) fn kill_line(purge: bool, now: bool, v: &Value) -> String {
    if !purge {
        return "closed".into();
    }
    if v.get("deleted").and_then(Value::as_bool) == Some(true) {
        let id = v.get("sessionId").and_then(Value::as_str).unwrap_or("");
        let until = v.get("restorableUntil").and_then(Value::as_u64);
        return match until {
            Some(until) => format!(
                "deleted; restorable until {} with `acpmux session undelete {id}`",
                local_time(until)
            ),
            None => format!("deleted; restorable with `acpmux session undelete {id}`"),
        };
    }
    if now {
        "purged".into()
    } else {
        // Asked for the grace, and the daemon did not keep it: it predates the grace.
        "purged (the running daemon predates restorable deletes: it deleted the chat at once)"
            .into()
    }
}

/// Whether the daemon keeps deleted chats, or an error that says it predates them.
fn require(client: &Client) -> Result<()> {
    if client.daemon_lists(crate::hub::soft_delete::FEATURE) {
        return Ok(());
    }
    Err(crate::cli::errors::AppError::new(
        crate::cli::errors::Code::Runtime,
        "soft_delete_unsupported",
        "the running daemon predates restorable deletes: it keeps no deleted chat; restart it on \
         the installed acpmux",
    )
    .into())
}

/// `acpmux session undelete SESSION`.
pub(crate) async fn undelete(client: &Client, session: &str, json_out: bool) -> Result<()> {
    require(client)?;
    let v = client.request(method::MUX_UNDELETE, json!({"sessionId": session})).await?;
    if json_out {
        print_json(&v);
    } else {
        let name = v.get("name").and_then(Value::as_str).unwrap_or(session);
        println!("restored {name}");
    }
    Ok(())
}

/// `acpmux session deleted`.
pub(crate) async fn deleted(client: &Client, json_out: bool) -> Result<()> {
    require(client)?;
    let v = client.request(method::MUX_DELETED, json!({})).await?;
    if json_out {
        print_json(&v);
    } else {
        print!("{}", render(&v));
    }
    Ok(())
}

/// One line per deleted chat: its name, its id, and until when it may be restored.
fn render(v: &Value) -> String {
    let rows = v.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default();
    if rows.is_empty() {
        return "no deleted chats\n".into();
    }
    rows.iter()
        .map(|r| {
            let until = r.get("restorableUntil").and_then(Value::as_u64).map(local_time);
            format!(
                "{}\t{}\trestorable until {}\n",
                r.get("name").and_then(Value::as_str).unwrap_or(""),
                r.get("sessionId").and_then(Value::as_str).unwrap_or(""),
                until.as_deref().unwrap_or("?"),
            )
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_new_daemon_says_until_when_it_may_be_restored() {
        let v =
            json!({"sessionId": "abc", "purged": false, "deleted": true, "restorableUntil": 1_000});
        let line = kill_line(true, false, &v);
        assert!(line.starts_with("deleted; restorable until "), "{line}");
        assert!(line.contains("acpmux session undelete abc"), "{line}");
    }

    #[test]
    fn an_older_daemon_deleted_at_once_and_the_line_says_so() {
        // An older daemon's reply to `{purge: true, grace: true}`: it ignored `grace`.
        let v = json!({"sessionId": "abc", "purged": true});
        assert!(kill_line(true, false, &v).contains("deleted the chat at once"));
        assert_eq!(kill_line(true, true, &v), "purged");
        assert_eq!(kill_line(false, false, &json!({"purged": false})), "closed");
    }

    #[test]
    fn the_list_names_each_deleted_chat() {
        let v = json!({"sessions": [{"sessionId": "abc", "name": "lane", "restorableUntil": 5}]});
        let text = render(&v);
        assert!(text.starts_with("lane\tabc\trestorable until "), "{text}");
        assert_eq!(render(&json!({"sessions": []})), "no deleted chats\n");
    }
}
