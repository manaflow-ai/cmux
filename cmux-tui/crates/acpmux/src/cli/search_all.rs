//! `acpmux search TEXT…`: search the indexed turns of every session the daemon lists.
//!
//! The per-session index is owned by acpmux (`session_search.rs`). This command only
//! enumerates the daemon's session rows, asks that existing RPC for each row, and formats
//! the combined result. Peer rows use the same RPC through the mesh read transport.

use crate::cli::list_read::{self, Via};
use crate::cli::output::print_json;
pub use crate::cli::session_search::HistoryQuery as SearchArgs;
use crate::client::Client;
use crate::no_panic::LockExt as _;
use crate::rpc::method;
use anyhow::Result;
use futures_util::stream::{self, StreamExt};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::sync::{Arc, Mutex};

/// A search asks the daemon for one session's already-indexed text. Keep the
/// fanout bounded because peer reads hold a mesh receipt while the remote
/// daemon opens its index.
const MAX_CONCURRENT_SEARCHES: usize = 16;

pub async fn run(client: Arc<Client>, args: SearchArgs, json_out: bool) -> Result<()> {
    let mut params = args.params()?;
    params["withTurnTime"] = json!(true);
    let limit =
        crate::session_search::Query::from_params(&params).map_err(anyhow::Error::msg)?.limit;
    let status = client.request(method::MUX_STATUS, json!({})).await.ok();
    let source = if list_read::closed_remote_listed(status.as_ref()) {
        None
    } else {
        let peers = status.as_ref().and_then(|status| status["peers"].as_array());
        Via::daemon().open_knowing(&client, peers.map(Vec::as_slice)).await?
    };
    let rows = match source {
        Some(mut source) => source.rows(acpmux_client::wire::ListView::All, &|_| true).await?,
        None => {
            let listed = client.whole_list(method::MUX_SESSIONS, json!({})).await?;
            listed.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default()
        }
    };
    let session_count = rows.len();
    let local_host = crate::pairing::machine_name();
    let offline_peers = Mutex::new(HashSet::<String>::new());
    let searches = rows.into_iter().filter_map(|row| {
        let session = crate::session_identity::routed_id(&row).ok()?;
        let name = row["name"].as_str().unwrap_or(&session).to_owned();
        let host = row
            .get("peer")
            .and_then(Value::as_str)
            .filter(|host| !host.is_empty())
            .map(str::to_owned)
            .unwrap_or_else(|| local_host.clone());
        let client = client.clone();
        let is_peer = row["peer"].is_string();
        let offline_peers = &offline_peers;
        let mut params = params.clone();
        params["sessionId"] = json!(session);
        Some(async move {
            let result = if is_peer && offline_peers.lock_or_recover().contains(&host) {
                Err("peer_unreachable".to_owned())
            } else {
                client.request(method::MUX_SESSION_SEARCH, params).await.map_err(|error| {
                    // Retain only a stable reason. A refusal on one session, or a slow
                    // index, says nothing about another session on the same host.
                    let reason = error
                        .downcast_ref::<crate::client::DaemonError>()
                        .and_then(|daemon| daemon.0.data.as_ref())
                        .and_then(|data| data["reason"].as_str())
                        .unwrap_or("search_unavailable");
                    if is_peer && reason == "peer_unreachable" {
                        offline_peers.lock_or_recover().insert(host.clone());
                    }
                    reason.to_owned()
                })
            };
            (session, name, host, result)
        })
    });
    let mut results = stream::iter(searches).buffer_unordered(MAX_CONCURRENT_SEARCHES);
    let mut hits = Vec::new();
    let mut unreached = Vec::new();
    while let Some((session, name, host, result)) = results.next().await {
        match result {
            Ok(answer) => {
                for mut hit in
                    answer.get("hits").and_then(Value::as_array).cloned().unwrap_or_default()
                {
                    hit["session"] = json!(name);
                    hit["sessionId"] = json!(session);
                    hit["host"] = json!(host);
                    hits.push(hit);
                }
                hits.sort_by_key(|hit| std::cmp::Reverse(hit["at"].as_u64().unwrap_or(0)));
                hits.truncate(limit);
            }
            Err(error) => unreached.push(json!({
                "session": session,
                "host": host,
                "error": error,
            })),
        }
    }
    for hit in &mut hits {
        hit["time"] = json!(utc_time(hit));
    }
    let answer = json!({"query": params["query"], "hits": hits, "unreached": unreached, "sessions": session_count});
    if json_out {
        print_json(&answer);
    } else {
        print!("{}", text(&answer));
    }
    Ok(())
}

fn utc_time(hit: &Value) -> Option<String> {
    // Older peer daemons return only the timestamp of the matching message.
    let millis = hit.get("turnStartedAt").or_else(|| hit.get("at"))?.as_i64()?;
    chrono::DateTime::from_timestamp_millis(millis)
        .map(|time| time.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
}

fn text(answer: &Value) -> String {
    let mut out = String::new();
    for hit in answer.get("hits").and_then(Value::as_array).into_iter().flatten() {
        let timestamp = hit["time"].as_str().unwrap_or("unknown");
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
    for row in answer.get("unreached").and_then(Value::as_array).into_iter().flatten() {
        out.push_str(&format!(
            "unavailable {} {}: {}\n",
            row.get("session").and_then(Value::as_str).unwrap_or("?"),
            row.get("host").and_then(Value::as_str).unwrap_or("?"),
            row.get("error").and_then(Value::as_str).unwrap_or("search_unavailable"),
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
        let mut answer = json!({"hits": [{
            "session": "peer/s-1", "host": "peer", "at": 1_735_689_605_000_i64,
            "turnStartedAt": 1_735_689_600_000_i64,
            "role": "assistant", "snippet": "first line\nsecond line"
        }]});
        answer["hits"][0]["time"] = json!(utc_time(&answer["hits"][0]));
        assert_eq!(
            text(&answer),
            "peer/s-1 peer 2025-01-01T00:00:00Z assistant first line second line\n"
        );
        assert_eq!(utc_time(&json!({"at": 0})).as_deref(), Some("1970-01-01T00:00:00Z"));
    }

    #[test]
    fn text_reports_unavailable_sessions_without_remote_error_details() {
        let answer = json!({
            "hits": [],
            "unreached": [{"session": "peer/s-1", "host": "peer", "error": "mesh.read_unanswered"}]
        });
        assert_eq!(text(&answer), "unavailable peer/s-1 peer: mesh.read_unanswered\n");
    }
}
