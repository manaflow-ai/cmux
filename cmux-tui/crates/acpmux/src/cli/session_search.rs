//! `acpmux session search SESSION TEXT…` (`_acpmux/session_search`, HQ#6365): the session's
//! prompts, replies and tool titles that hold every word of TEXT, newest first, from the index the
//! daemon keeps beside the log, instead of a grep over the harness's transcript.

use crate::cli::orchestrate::expand_session_key;
use crate::cli::output::{age, print_json};
use crate::cli::run::resolve_id;
use crate::client::Client;
use crate::rpc::method;
use anyhow::Result;
use clap::Args;
use serde_json::{Value, json};
use std::sync::Arc;

/// Search every session on this daemon and its peers in the engine, returning one row per
/// matching prompt or reply. The engine reports peers it could not search beside its hits.
pub async fn all(client: Arc<Client>, query: String, limit: u32, json_out: bool) -> Result<()> {
    let result = client
        .request(method::MUX_SESSION_SEARCH, json!({"allSessions": true, "query": query, "limit": limit}))
        .await
        .map_err(|e| {
            if e.downcast_ref::<crate::client::DaemonError>()
                .is_some_and(|err| err.0.message == "sessionId or session is required")
            {
                anyhow::anyhow!("this daemon predates cross-session search; update the agent engine on this machine")
            } else {
                e
            }
        })?;
    if json_out {
        print_json(&result);
    } else {
        let answer: crate::hub::history_search::Answer = serde_json::from_value(result)?;
        if answer.hits.is_empty() {
            println!("No matching prompts or replies.");
        } else {
            println!("SESSION\tHOST\tTURN TIME\tPREVIEW");
            for hit in answer.hits {
                println!("{}\t{}\t{}\t{}", hit.session, hit.host, hit.turn_time, hit.preview);
            }
        }
        for why in answer.incomplete {
            eprintln!("Search incomplete: {why}");
        }
    }
    Ok(())
}

#[derive(Args)]
pub struct SearchArgs {
    /// The session: name, id, or host/name for a peer's.
    pub session: String,
    #[command(flatten)]
    pub query: HistoryQuery,
}

#[derive(Args)]
pub struct HistoryQuery {
    /// The words to find, in any case and order, within one message.
    #[arg(required = true)]
    pub text: Vec<String>,
    /// Only messages from this side: user (prompts), assistant (replies) or tool (tool titles).
    #[arg(long, value_parser = ["user", "assistant", "tool"])]
    pub role: Option<String>,
    /// Only messages from this long ago or later: 30m, 24h, 7d.
    #[arg(long, value_name = "DURATION")]
    pub since: Option<String>,
    /// At most this many hits (most 200).
    #[arg(long, short = 'n', default_value_t = 20)]
    pub limit: usize,
}

impl HistoryQuery {
    pub(super) fn params(&self) -> Result<Value> {
        let since_ms = self
            .since
            .as_deref()
            .map(crate::cli::run::ls::parse_duration_ms)
            .transpose()?
            .map(|ago| crate::store::now_ms().saturating_sub(ago));
        Ok(json!({
            "query": self.text.join(" "),
            "role": self.role,
            "sinceMs": since_ms,
            "limit": self.limit,
        }))
    }
}

pub async fn run(client: Arc<Client>, args: SearchArgs, json_out: bool) -> Result<()> {
    let id = resolve_id(&client, &expand_session_key(&args.session)?).await?;
    let mut params = args.query.params()?;
    if let Some(fields) = params.as_object_mut() {
        fields.insert("sessionId".to_owned(), json!(id));
    }
    let v = client.request(method::MUX_SESSION_SEARCH, params).await?;
    if json_out {
        print_json(&v);
        return Ok(());
    }
    let hits = v.get("hits").and_then(Value::as_array).cloned().unwrap_or_default();
    if hits.is_empty() {
        println!("no message holds every word");
        return Ok(());
    }
    println!("{:<8} {:<5} {:<9} TEXT", "SEQ", "AGE", "ROLE");
    for h in hits {
        println!(
            "{:<8} {:<5} {:<9} {}",
            h.get("seq").and_then(Value::as_u64).unwrap_or(0),
            age(h.get("at").and_then(Value::as_u64).unwrap_or(0)),
            h.get("role").and_then(Value::as_str).unwrap_or(""),
            h.get("snippet").and_then(Value::as_str).unwrap_or(""),
        );
    }
    Ok(())
}
