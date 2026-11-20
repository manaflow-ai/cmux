//! `acpmux search TEXT…`: search the indexed turns of every session the daemon lists.
//!
//! The per-session index is owned by acpmux (`session_search.rs`). This command only
//! enumerates the daemon's session rows, asks that existing RPC for each row, and formats
//! the combined result. Peer rows use the same RPC through the mesh read transport.

use crate::cli::output::print_json;
use crate::client::Client;
use crate::rpc::method;
use anyhow::{Context, Result, anyhow, bail};
use clap::Args;
use futures::StreamExt;
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
    let limit = args.limit.clamp(1, crate::session_search::MAX_LIMIT);
    let query = args.text.join(" ");
    let params = json!({"query": query, "role": args.role, "sinceMs": since_ms, "limit": limit,
        "withTurnTime": true});
    crate::session_search::Query::from_params(&params).map_err(|why| anyhow!(why))?;
    let mut listed = client.whole_list(method::MUX_SESSIONS, json!({})).await?;
    let rows = listed
        .get_mut("sessions")
        .and_then(Value::as_array_mut)
        .context("the daemon's session list has no sessions array")?;
    crate::cli::send_relay::merge_rows(rows, crate::cli::send_relay::relay_rows(false).await);
    let own_host = crate::pairing::machine_name();
    let targets: Vec<_> = rows
        .iter()
        .filter_map(|row| {
            let id = row.get("sessionId")?.as_str().filter(|id| !id.is_empty())?;
            let peer = row.get("peer").and_then(Value::as_str).filter(|p| !p.is_empty());
            let key = row
                .get("qualifiedSessionId")
                .and_then(Value::as_str)
                .filter(|k| !k.is_empty())
                .map(str::to_owned)
                .unwrap_or_else(|| match peer {
                    Some(host) => format!("{host}/{id}"),
                    None => id.to_owned(),
                });
            Some((key, peer.unwrap_or(&own_host).to_owned()))
        })
        .collect();
    let session_count = targets.len();
    // Match the concurrency budget of the ls --with-tools peer reads.
    let mut reads = futures::stream::iter(targets.into_iter().map(|(session, host)| {
        let client = &client;
        let mut params = params.clone();
        params["sessionId"] = json!(session);
        async move {
            let reply = client.request(method::MUX_SESSION_SEARCH, params).await;
            (session, host, reply)
        }
    }))
    .buffer_unordered(8);
    let mut hits = Vec::new();
    let mut unreached = Vec::new();
    while let Some((session, host, answer)) = reads.next().await {
        match answer.and_then(|mut reply| {
            reply
                .get_mut("hits")
                .and_then(Value::as_array_mut)
                .map(std::mem::take)
                .context("the search response has no hits array")
        }) {
            Ok(rows) => {
                for mut hit in rows {
                    hit["session"] = json!(session);
                    hit["host"] = json!(host);
                    let at = hit["turnStartedAt"].as_i64().or_else(|| hit["at"].as_i64());
                    hit["time"] = json!(
                        at.and_then(chrono::DateTime::from_timestamp_millis)
                            .map(|t| t.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
                    );
                    hits.push(hit);
                }
                // Only the newest global limit can survive later replies.
                hits.sort_unstable_by(|a, b| {
                    b["at"]
                        .as_u64()
                        .cmp(&a["at"].as_u64())
                        .then_with(|| a["host"].as_str().cmp(&b["host"].as_str()))
                        .then_with(|| a["session"].as_str().cmp(&b["session"].as_str()))
                        .then_with(|| b["seq"].as_u64().cmp(&a["seq"].as_u64()))
                });
                hits.truncate(limit);
            }
            Err(error) => unreached
                .push(json!({"session": session, "host": host, "error": error.to_string()})),
        }
    }
    let failed = unreached.len();
    let answer =
        json!({"query": query, "hits": hits, "unreached": unreached, "sessions": session_count});
    if json_out {
        print_json(&answer);
    } else {
        print!("{}", text(&answer));
        if failed > 0 {
            eprintln!(
                "Could not search {failed} of {session_count} sessions. First failure: {}",
                answer["unreached"][0]["error"].as_str().unwrap_or("unknown error")
            );
        }
    }
    if failed > 0 && failed == session_count {
        bail!("no session history could be searched");
    }
    Ok(())
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
    if out.is_empty() && answer["unreached"].as_array().is_none_or(Vec::is_empty) {
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
            "session": "peer/s-1", "host": "peer", "time": "2025-01-01T00:00:00Z",
            "role": "assistant", "snippet": "first line\nsecond line"
        }]});
        assert_eq!(
            text(&answer),
            "peer/s-1 peer 2025-01-01T00:00:00Z assistant first line second line\n"
        );
    }
}
