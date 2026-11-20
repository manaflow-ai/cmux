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

#[derive(Args)]
pub struct SearchArgs {
    /// The session: name, id, or host/name for a peer's.
    pub session: String,
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

pub async fn run(client: Arc<Client>, args: SearchArgs, json_out: bool) -> Result<()> {
    let id = resolve_id(&client, &expand_session_key(&args.session)?).await?;
    let since_ms = args
        .since
        .as_deref()
        .map(crate::cli::run::ls::parse_duration_ms)
        .transpose()?
        .map(|ago| crate::store::now_ms().saturating_sub(ago));
    let params = json!({
        "sessionId": id,
        "query": args.text.join(" "),
        "role": args.role,
        "sinceMs": since_ms,
        "limit": args.limit,
    });
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
