//! `acpmux session limits SESSION [--max N | --clear]`: how many of a session's sub-sessions run
//! at once (`hub/subsession_runs.rs`), how many run and wait now, and its other sub-session
//! limits, each with where it comes from. `--max` and `--clear` set or clear the session's own
//! `maxRunning` through `_acpmux/subsession/limits`, which takes the person (the app) or a
//! session above it in its family; a session never raises its own.

use crate::cli::output::print_json;
use crate::cli::run::resolve_id;
use crate::client::Client;
use crate::rpc::method;
use anyhow::Result;
use serde_json::{Value, json};

pub async fn run(
    client: &Client,
    session: &str,
    max: Option<u32>,
    clear: bool,
    json_out: bool,
) -> Result<()> {
    let id = resolve_id(client, session).await?;
    let reply = if max.is_some() || clear {
        let value = if clear { Value::Null } else { json!(max) };
        let params = json!({"sessionId": id, "maxRunning": value});
        client.request(method::MUX_SUBSESSION_LIMITS, params).await?
    } else {
        // Only what the session list holds: no wait for the chat logs after a restart.
        let params = json!({"sessionId": id, "waitLogs": false});
        client.request(method::MUX_INFO, params).await?
    };
    let limits = reply.get("subsessionLimits").cloned().unwrap_or(Value::Null);
    if json_out {
        print_json(&json!({"sessionId": id, "subsessionLimits": limits}));
    } else {
        print!("{}", describe(&limits));
    }
    Ok(())
}

/// The limits as lines a person reads.
pub fn describe(l: &Value) -> String {
    let n = |k: &str| l[k].as_u64().map_or_else(|| "?".to_owned(), |n| n.to_string());
    let from = |k: &str| l[k].as_str().unwrap_or("unknown").to_owned();
    format!(
        "running {} of {} at once ({}), {} queued\nopen at most {} ({})\nnesting at most {} deep ({})\n",
        n("running"),
        n("maxRunning"),
        from("maxRunningSource"),
        n("queued"),
        n("maxChildren"),
        from("maxChildrenSource"),
        n("maxDepth"),
        from("maxDepthSource"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn describe_names_each_limit_and_its_source() {
        let l = json!({
            "maxRunning": 16, "maxRunningSource": "default", "running": 3, "queued": 2,
            "maxChildren": 50, "maxChildrenSource": "settings",
            "maxDepth": 3, "maxDepthSource": "inherited",
        });
        assert_eq!(
            describe(&l),
            "running 3 of 16 at once (default), 2 queued\nopen at most 50 (settings)\nnesting at most 3 deep (inherited)\n"
        );
    }

    #[test]
    fn describe_from_an_older_daemon_marks_what_it_lacks() {
        let l = json!({"maxChildren": 50, "maxChildrenSource": "default", "maxDepth": 3, "maxDepthSource": "default"});
        assert!(describe(&l).starts_with("running ? of ? at once (unknown), ? queued\n"));
    }
}
