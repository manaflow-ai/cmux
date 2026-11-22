//! `acpmux session turn-cap SESSION [--minutes N | --off | --clear]`: a session's turn cap
//! (`hub/turn_cap.rs`). Past it, the running turn takes no other agent's steer; their messages
//! wait for the next turn. With no flag it shows the cap; a write goes through
//! `_acpmux/set_turn_cap`, which takes the person (the app or this socket), never an agent.

use crate::cli::output::print_json;
use crate::cli::run::resolve_id;
use crate::client::Client;
use crate::rpc::method;
use anyhow::Result;
use serde_json::{Value, json};

/// What the command asks for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Change {
    Show,
    Minutes(u64),
    Off,
    Clear,
}

/// The request's params for `change`.
pub fn params(id: &str, change: Change) -> Value {
    match change {
        Change::Show => json!({"sessionId": id}),
        Change::Minutes(m) => json!({"sessionId": id, "turnCapMs": m.saturating_mul(60_000)}),
        Change::Off => json!({"sessionId": id, "turnCapMs": 0}),
        Change::Clear => json!({"sessionId": id, "turnCapMs": Value::Null}),
    }
}

pub async fn run(client: &Client, session: &str, change: Change, json_out: bool) -> Result<()> {
    let id = resolve_id(client, session).await?;
    let reply = client.request(method::MUX_SET_TURN_CAP, params(&id, change)).await?;
    if json_out {
        print_json(&reply);
    } else {
        println!("{}", describe(&reply));
    }
    Ok(())
}

/// The cap as a line a person reads.
pub fn describe(reply: &Value) -> String {
    let own = reply.get("turnCapMs").and_then(Value::as_u64);
    match reply.get("effectiveTurnCapMs").and_then(Value::as_u64) {
        None if own == Some(0) => "no turn cap (turned off for this session)".to_owned(),
        None => "no turn cap".to_owned(),
        Some(ms) => {
            let from = if own.is_some() { "this session's" } else { "default" };
            format!("turn cap {} min ({from})", ms.div_ceil(60_000))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_change_is_one_request_shape() {
        assert_eq!(params("s", Change::Show), json!({"sessionId": "s"}));
        assert_eq!(params("s", Change::Minutes(20))["turnCapMs"], 1_200_000);
        assert_eq!(params("s", Change::Off)["turnCapMs"], 0);
        assert!(params("s", Change::Clear)["turnCapMs"].is_null());
    }

    #[test]
    fn describe_names_the_cap_and_where_it_comes_from() {
        let r = |own: Value, eff: Value| json!({"turnCapMs": own, "effectiveTurnCapMs": eff});
        assert_eq!(describe(&r(Value::Null, Value::Null)), "no turn cap");
        assert_eq!(
            describe(&r(json!(0), Value::Null)),
            "no turn cap (turned off for this session)"
        );
        assert_eq!(
            describe(&r(json!(600_000), json!(600_000))),
            "turn cap 10 min (this session's)"
        );
        assert_eq!(describe(&r(Value::Null, json!(1_200_000))), "turn cap 20 min (default)");
    }
}
