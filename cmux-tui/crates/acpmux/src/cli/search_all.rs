//! `acpmux search TEXT…`: search the indexed turns of every session the daemon lists.
//!
//! The per-session index is owned by acpmux (`session_search.rs`). This command only
//! enumerates the daemon's session rows, asks that existing RPC for each row, and formats
//! the combined result. Peer rows use the same RPC through the mesh read transport.

use crate::cli::output::print_json;
use crate::client::Client;
use crate::rpc::method;
use anyhow::Result;
use clap::Args;
use serde_json::{Value, json};
use std::sync::Arc;

#[derive(Args, Debug, Clone)]
pub struct SearchArgs {
    /// The words to find, in any case and order, within one indexed message.
    #[arg(required = true)]
    pub text: Vec<String>,
    /// Only messages from this side: user, assistant or tool.
    #[arg(long, value_parser = ["user", "assistant", "tool"])]
    pub role: Option<String>,
    /// Only messages from this long ago or later: 30m, 24h, 7d.
    #[arg(long, value_name = "DURATION")]
    pub since: Option<String>,
    /// At most this many hits across all sessions.
    #[arg(long, short = 'n', default_value_t = 20)]
    pub limit: usize,
}

pub async fn run(client: Arc<Client>, args: SearchArgs, json_out: bool) -> Result<()> {
    let since_ms = args
        .since
        .as_deref()
        .map(crate::cli::run::ls::parse_duration_ms)
        .transpose()?
        .map(|ago| crate::store::now_ms().saturating_sub(ago));
    let limit = args.limit.clamp(1, 200);
    let query = args.text.join(" ");
    let listed = client.whole_list(method::MUX_SESSIONS, json!({})).await?;
    let rows = listed.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default();
    let session_count = rows.len();
    let role = args.role.clone();
    let mut hits = Vec::new();
    let mut unreached = Vec::new();
    for row in rows {
        let id = row.get("sessionId").and_then(Value::as_str).unwrap_or_default();
        if id.is_empty() {
            continue;
        }
        let host = row
            .get("peer")
            .and_then(Value::as_str)
            .filter(|host| !host.is_empty())
            .map(str::to_owned)
            .unwrap_or_else(|| crate::pairing::machine_name());
        let session = row
            .get("qualifiedSessionId")
            .and_then(Value::as_str)
            .filter(|key| !key.is_empty())
            .map(str::to_owned)
            .unwrap_or_else(|| id.to_owned());
        let params = json!({
            "sessionId": session.clone(),
            "query": query.clone(),
            "role": role.clone(),
            "sinceMs": since_ms,
            "limit": limit,
        });
        match client.request(method::MUX_SESSION_SEARCH, params).await {
            Ok(answer) => {
                for mut hit in
                    answer.get("hits").and_then(Value::as_array).cloned().unwrap_or_default()
                {
                    hit["session"] = json!(session.clone());
                    hit["host"] = json!(host.clone());
                    hits.push(hit);
                }
            }
            Err(error) => unreached
                .push(json!({"session": session, "host": host, "error": error.to_string()})),
        }
    }
    hits.sort_by_key(|hit| std::cmp::Reverse(hit.get("at").and_then(Value::as_u64).unwrap_or(0)));
    hits.truncate(limit);
    let answer =
        json!({"query": query, "hits": hits, "unreached": unreached, "sessions": session_count});
    if json_out {
        print_json(&answer);
    } else {
        print!("{}", text(&answer));
    }
    Ok(())
}

fn text(answer: &Value) -> String {
    let mut out = String::new();
    for hit in answer.get("hits").and_then(Value::as_array).into_iter().flatten() {
        let at = hit.get("at").and_then(Value::as_i64).unwrap_or_default();
        let timestamp = chrono::DateTime::from_timestamp_millis(at)
            .map(|time| time.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
            .unwrap_or_else(|| "unknown".to_owned());
        let preview = hit
            .get("snippet")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        out.push_str(&format!(
            "{} {} {} {} {}\n",
            hit.get("session").and_then(Value::as_str).unwrap_or("?"),
            hit.get("host").and_then(Value::as_str).unwrap_or("?"),
            timestamp,
            hit.get("role").and_then(Value::as_str).unwrap_or("?"),
            preview,
        ));
    }
    if out.is_empty() {
        out.push_str("no message holds every word\n");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_has_session_host_utc_time_role_and_one_line_preview() {
        let answer = json!({"hits": [{
            "session": "peer/s-1", "host": "peer", "at": 1_735_689_600_000,
            "role": "assistant", "snippet": "first line\nsecond line"
        }]});
        assert_eq!(
            text(&answer),
            "peer/s-1 peer 2025-01-01T00:00:00Z assistant first line second line\n"
        );
    }
}
