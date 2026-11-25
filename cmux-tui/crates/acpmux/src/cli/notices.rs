//! Read notice records through the daemon's paged history store.

use std::collections::HashSet;

use anyhow::Result;
use clap::Args;
use serde_json::{Value, json};

use crate::cli::output::{page_events, print_json};
use crate::rpc::method;

#[derive(Args)]
pub struct NoticesArgs {
    /// The session name, id, or host/name (default this chat).
    #[arg(default_value = "@")]
    pub session: String,
    /// At most this many notices, newest first.
    #[arg(long, short = 'n', default_value_t = 20, value_parser = clap::value_parser!(u64).range(1..=200))]
    pub limit: u64,
}

fn is_notice(event: &Value) -> bool {
    event["kind"] == "host_notice"
        || matches!(
            event.pointer("/msg/_meta/provenance/kind").and_then(Value::as_str),
            Some("notice" | "inbox_notice")
        )
}

pub async fn run(args: NoticesArgs, json_out: bool) -> Result<()> {
    let client = crate::daemon::connect(false).await?;
    let id = crate::cli::run::resolve_id(&client, &args.session).await?;
    let mut before = u64::MAX;
    let mut notices = Vec::new();
    let mut prompts = HashSet::new();
    loop {
        let page = client
            .request(
                method::MUX_EVENTS,
                json!({"sessionId": id, "beforeSeq": before, "limit": 200,
                    "kinds": ["user_message", "inbox", "host_notice"]}),
            )
            .await?;
        let (events, more) = page_events(&page);
        let oldest = events.first().and_then(|event| event["seq"].as_u64());
        for event in events.into_iter().rev().filter(is_notice) {
            let prompt = event.pointer("/msg/promptId").and_then(Value::as_str);
            if prompt.is_some_and(|prompt| !prompts.insert(prompt.to_owned())) {
                continue;
            }
            notices.push(event);
            if notices.len() as u64 >= args.limit {
                break;
            }
        }
        if notices.len() as u64 >= args.limit || !more {
            break;
        }
        match oldest {
            Some(oldest) if oldest < before => before = oldest,
            _ => break,
        }
    }
    if json_out {
        print_json(&json!({"sessionId": id, "notices": notices}));
    } else if notices.is_empty() {
        println!("no notices");
    } else {
        for event in notices {
            let text = event.pointer("/msg/text").and_then(Value::as_str).unwrap_or_default();
            println!("{}  {}", event.get("seq").unwrap_or(&Value::Null), text);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn notices_include_tool_inbox_and_host_records() {
        for kind in ["notice", "inbox_notice"] {
            assert!(is_notice(&json!({"kind": "user_message", "msg": {
                "_meta": {"provenance": {"kind": kind}}, "text": "build finished"}})));
        }
        assert!(is_notice(&json!({"kind": "host_notice", "msg": {"text": "resized"}})));
        assert!(!is_notice(&json!({"kind": "user_message", "msg": {"text": "hello"}})));
        assert!(!is_notice(&json!({"kind": "permission_request", "msg": {}})));
    }
}
