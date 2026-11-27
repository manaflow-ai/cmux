//! `acpmux archive SESSION...` and `acpmux unarchive SESSION...`: the chat menu's Archive and
//! Unarchive from the command line, through `_acpmux/archive` (`hub/inactive_archive.rs`). Every
//! session is resolved first, so a name that matches nothing changes none of them. An unarchive
//! of a chat that is not archived succeeds and changes nothing; so does an archive of one that is.
//! `acpmux ls --archived` lists the archived ones.

use std::sync::Arc;

use anyhow::Result;
use serde_json::{Value, json};

use crate::cli::orchestrate::expand_session_key;
use crate::cli::output::print_json;
use crate::cli::run::resolve_id;
use crate::client::Client;
use crate::rpc::method;

/// Archive (`archived`) or unarchive each of `sessions` (names, ids, `host/name`).
pub(crate) async fn run(
    client: Arc<Client>,
    sessions: Vec<String>,
    archived: bool,
    json_out: bool,
) -> Result<()> {
    let mut ids = Vec::with_capacity(sessions.len());
    for key in &sessions {
        ids.push(resolve_id(&client, &expand_session_key(key)?).await?);
    }
    let mut rows = Vec::with_capacity(ids.len());
    for id in ids {
        let summary = client
            .request(method::MUX_ARCHIVE, json!({"sessionId": id, "archived": archived}))
            .await?;
        rows.push(row(&id, &summary, archived));
    }
    if json_out {
        print_json(&json!({"sessions": rows}));
    } else {
        print!("{}", render(&rows));
    }
    Ok(())
}

/// One session's outcome from its summary after the change: `changed` is null from a daemon
/// that does not say.
pub(crate) fn row(id: &str, summary: &Value, archived: bool) -> Value {
    let tags = summary.get("tags");
    let archived_at = tags
        .and_then(|t| t.get("archived"))
        .and_then(Value::as_str)
        .and_then(|v| v.parse::<u64>().ok());
    json!({
        "sessionId": id,
        "name": summary.get("name").and_then(Value::as_str).unwrap_or(""),
        "archived": archived,
        "archivedAt": archived_at,
        "changed": summary.get("changed").and_then(Value::as_bool),
    })
}

/// One line a session: `archived NAME`, `unarchived NAME`, or what was already so.
pub(crate) fn render(rows: &[Value]) -> String {
    let mut out = String::new();
    for row in rows {
        let name = row["name"].as_str().filter(|n| !n.is_empty());
        let label = name.or(row["sessionId"].as_str()).unwrap_or("?");
        let archived = row["archived"] == true;
        let line = match (archived, row["changed"].as_bool()) {
            (true, Some(false)) => format!("{label} was already archived"),
            (false, Some(false)) => format!("{label} was not archived"),
            (true, _) => format!("archived {label}"),
            (false, _) => format!("unarchived {label}"),
        };
        out.push_str(&line);
        out.push('\n');
    }
    out
}

#[cfg(test)]
#[path = "archive_tests.rs"]
mod tests;
