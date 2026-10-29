//! `acpmux session coordinator SESSION [--on | --off] [--flush-minutes N] [--interval-minutes N]`:
//! whether a session is a coordinator (`hub/coordinator.rs`): other agents' messages wait in its
//! inbox and reach it as one digest. With no flag it shows the setting; a write goes through
//! `_acpmux/set_coordinator`, which takes the person (the app or this socket), never an agent.

use crate::cli::output::print_json;
use crate::cli::run::resolve_id;
use crate::client::Client;
use crate::rpc::method;
use anyhow::Result;
use serde_json::{Value, json};

/// What the command asks for: each `None` leaves that part as it is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Change {
    pub on: Option<bool>,
    pub flush_minutes: Option<u64>,
    pub interval_minutes: Option<u64>,
}

/// The request's params for `change`.
pub fn params(id: &str, change: Change) -> Value {
    let mut params = json!({"sessionId": id});
    if let Some(on) = change.on {
        params["coordinator"] = json!(on);
    }
    if let Some(m) = change.flush_minutes {
        params["inboxFlushMs"] = json!(m.saturating_mul(60_000));
    }
    if let Some(m) = change.interval_minutes {
        params["digestIntervalMs"] = json!(m.saturating_mul(60_000));
    }
    params
}

pub async fn run(client: &Client, session: &str, change: Change, json_out: bool) -> Result<()> {
    let id = resolve_id(client, session).await?;
    let reply = client.request(method::MUX_SET_COORDINATOR, params(&id, change)).await?;
    if json_out {
        print_json(&reply);
    } else {
        println!("{}", describe(&reply));
    }
    Ok(())
}

/// The setting as a line a person reads.
pub fn describe(reply: &Value) -> String {
    if reply["coordinator"] != true {
        return "not a coordinator".to_owned();
    }
    let minutes = |key: &str| reply[key].as_u64().unwrap_or(0).div_ceil(60_000);
    let items = reply["inbox"].as_u64().unwrap_or(0);
    format!(
        "coordinator: {items} in its inbox; results and FYIs flush after {} min idle, digests into a running turn at most every {} min",
        minutes("effectiveInboxFlushMs"),
        minutes("effectiveDigestIntervalMs"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_change_is_one_request_shape() {
        assert_eq!(params("s", Change::default()), json!({"sessionId": "s"}));
        let on = Change { on: Some(true), flush_minutes: Some(10), interval_minutes: Some(5) };
        assert_eq!(
            params("s", on),
            json!({"sessionId": "s", "coordinator": true, "inboxFlushMs": 600_000, "digestIntervalMs": 300_000})
        );
        let off = Change { on: Some(false), ..Change::default() };
        assert_eq!(params("s", off), json!({"sessionId": "s", "coordinator": false}));
    }

    #[test]
    fn describe_names_the_inbox_and_its_times() {
        assert_eq!(describe(&json!({"coordinator": false})), "not a coordinator");
        let on = json!({"coordinator": true, "inbox": 3, "effectiveInboxFlushMs": 600_000, "effectiveDigestIntervalMs": 300_000});
        assert_eq!(
            describe(&on),
            "coordinator: 3 in its inbox; results and FYIs flush after 10 min idle, digests into a running turn at most every 5 min"
        );
    }
}
