//! A Mac that is already locked tells the agent and the person; it does not pretend.
//!
//! Design L2 (cmuxterm-hq `docs/design/locked-screen-computer-use.md`): the worker's own lock
//! refusal stays (`mac_locked`; the older driver's `screen_locked`), and this bridge maps it to one
//! typed result instead of a generic tool error: a stable `code` `mac_locked`, `state` `locked`,
//! plain text, and the routes that work (unlock it, or run the call on a Cloud or remote machine).
//! Whatever else the worker said (its message, a `whileLocked` detail) is kept beside it.
//!
//! The result stays `isError` for the agent (the call did not run) and carries
//! `_meta["cmux/state"] = "mac_locked"` so a chat can draw it as a state rather than a failure.
//! [`super::awake`] keeps a Mac from dimming into the lock in the first place (L1); nothing here
//! unlocks anything. [`to_mcp_routed`] names the person's own machines that can take the call now
//! (L3, the remote route), so the agent moves the call there instead of waiting on the lock.

use cmux_computer_use::ToolOutput;
use serde_json::{Value, json};

use super::client::Outcome;

/// The one code an agent and a chat see for a locked Mac.
pub const CODE: &str = "mac_locked";
/// The worker codes that mean the Mac is locked (`screen_locked`: the older driver's).
pub const WORKER_CODES: &[&str] = &[CODE, "screen_locked"];
/// The MCP result `_meta` key a chat reads to show the call as a state.
pub const STATE_META: &str = "cmux/state";
/// What the agent and the person read.
pub const MESSAGE: &str = "This Mac is locked, so Computer Use cannot act on it. Unlock it, or run this on a Cloud or remote machine (list_machines, then pass machine).";

/// Whether a worker code means the Mac is locked.
pub fn is_locked_code(code: &str) -> bool {
    WORKER_CODES.contains(&code)
}

/// The worker's code for a locked Mac in `outcome`, if it is one.
fn locked_code(outcome: &Outcome) -> Option<String> {
    match outcome {
        Outcome::Output(out) if out.is_error => {
            out.code.as_deref().filter(|c| is_locked_code(c)).map(str::to_owned)
        }
        Outcome::Failed { code, .. } if is_locked_code(code) => Some(code.clone()),
        // A worker that answers the request itself with an error sends `code: reason`.
        Outcome::Failed { code, message } if code == "worker_error" => WORKER_CODES
            .iter()
            .find(|c| message == *c || message.starts_with(&format!("{c}:")))
            .map(|c| (*c).to_owned()),
        _ => None,
    }
}

/// The typed locked result for `outcome` when the worker said the Mac is locked; any other
/// outcome unchanged.
pub fn map(outcome: Outcome) -> Outcome {
    let Some(worker_code) = locked_code(&outcome) else { return outcome };
    let (body, detail, png) = match outcome {
        Outcome::Output(out) => {
            let detail = out.body.get("error").and_then(Value::as_str).map(str::to_owned);
            (out.body, detail, out.png_base64)
        }
        Outcome::Failed { message, .. } => (json!({}), Some(message), None),
        // Never locked (`locked_code` is None for it).
        off @ Outcome::Off(_) => return off,
    };
    // The worker's own fields (a `whileLocked` detail) stay beside the typed ones.
    let mut map = match body {
        Value::Object(map) => map,
        other => serde_json::Map::from_iter([("worker".to_owned(), other)]),
    };
    map.insert("error".into(), MESSAGE.into());
    map.insert("code".into(), CODE.into());
    map.insert("state".into(), "locked".into());
    if worker_code != CODE {
        map.insert("worker_code".into(), worker_code.into());
    }
    if let Some(detail) = detail.filter(|d| d != MESSAGE) {
        map.insert("detail".into(), detail.into());
    }
    map.insert(
        "routes".into(),
        json!([
            {"route": "unlock", "text": "The person unlocks this Mac, then the call can run again."},
            {"route": "remote", "text": "Run it on another machine: list_machines, then pass machine."},
            {"route": "cloud", "text": "Run it on a cmux Cloud machine, which never locks."},
        ]),
    );
    let body = Value::Object(map);
    Outcome::Output(ToolOutput { is_error: true, code: Some(CODE.into()), body, png_base64: png })
}

/// Names `machines` (the person's machines that can take the call now, design L3's "remote"
/// route) in a locked result's body: `machines`, the remote route's text and the error line.
/// Nothing changes when there are none; the generic routes stay.
fn route_to(body: &mut Value, machines: &[String]) {
    let Some(first) = machines.first() else { return };
    let names = machines.join(", ");
    body["machines"] = json!(machines);
    body["error"] = format!("{MESSAGE} Ready to take it now: {names}.").into();
    if let Some(routes) = body["routes"].as_array_mut() {
        for route in routes.iter_mut().filter(|r| r["route"] == "remote") {
            route["text"] =
                format!("Run it on {names}: call the same tool again with machine \"{first}\".")
                    .into();
            route["machines"] = json!(machines);
        }
    }
}

/// [`to_mcp`], with the machines that can take the call instead named in a locked result.
/// `machines` runs only when the call was locked (it asks the daemon, which asks each peer).
pub fn to_mcp_routed(outcome: Outcome, machines: impl FnOnce() -> Vec<String>) -> Value {
    let mut outcome = map(outcome);
    if let Outcome::Output(out) = &mut outcome
        && out.code.as_deref() == Some(CODE)
    {
        route_to(&mut out.body, &machines());
    }
    mark(outcome)
}

/// The MCP `tools/call` result for `outcome`, the locked state marked for the chat.
pub fn to_mcp(outcome: Outcome) -> Value {
    mark(map(outcome))
}

/// The MCP result for an already mapped `outcome`, `_meta` marked when it is the locked state.
fn mark(outcome: Outcome) -> Value {
    let locked = matches!(&outcome, Outcome::Output(out) if out.code.as_deref() == Some(CODE));
    let mut result = outcome.to_mcp();
    if locked && let Some(map) = result.as_object_mut() {
        map.insert("_meta".into(), json!({STATE_META: CODE}));
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn body(result: &Value) -> Value {
        serde_json::from_str(result["content"][0]["text"].as_str().unwrap()).unwrap()
    }

    #[test]
    fn mac_locked_becomes_the_typed_state_and_keeps_while_locked() {
        let mut out = ToolOutput::error("mac_locked", "the Mac is locked");
        out.body["whileLocked"] = json!({"setting": "computerUse.whileLocked", "value": "off"});
        let result = to_mcp(Outcome::Output(out));
        assert_eq!(result["isError"], true);
        assert_eq!(result["_meta"][STATE_META], CODE);
        let b = body(&result);
        assert_eq!(b["code"], CODE);
        assert_eq!(b["state"], "locked");
        assert_eq!(b["error"], MESSAGE);
        assert_eq!(b["detail"], "the Mac is locked");
        assert!(b.get("worker_code").is_none());
        assert_eq!(b["whileLocked"]["setting"], "computerUse.whileLocked");
        let routes: Vec<_> =
            b["routes"].as_array().unwrap().iter().map(|r| r["route"].as_str().unwrap()).collect();
        assert_eq!(routes, ["unlock", "remote", "cloud"]);
    }

    #[test]
    fn legacy_screen_locked_maps_to_mac_locked() {
        let out = ToolOutput::error("screen_locked", "screen is locked");
        let Outcome::Output(mapped) = map(Outcome::Output(out)) else { panic!("an output") };
        assert_eq!(mapped.code.as_deref(), Some(CODE));
        assert_eq!(mapped.body["worker_code"], "screen_locked");
        assert_eq!(mapped.body["detail"], "screen is locked");
        // A request-level refusal and a remote machine's refusal map the same way.
        for failed in [
            Outcome::Failed {
                code: "worker_error".into(),
                message: "screen_locked: locked".into(),
            },
            Outcome::Failed { code: "mac_locked".into(), message: "locked".into() },
        ] {
            let result = to_mcp(failed);
            assert_eq!(result["_meta"][STATE_META], CODE);
            assert_eq!(body(&result)["state"], "locked");
        }
    }

    #[test]
    fn a_locked_result_names_the_machines_that_can_take_the_call() {
        let asked = std::cell::Cell::new(0);
        let machines = || {
            asked.set(asked.get() + 1);
            vec!["studio".to_owned(), "cloud-1".to_owned()]
        };
        let result =
            to_mcp_routed(Outcome::Output(ToolOutput::error("mac_locked", "locked")), machines);
        assert_eq!(asked.get(), 1);
        assert_eq!(result["_meta"][STATE_META], CODE);
        let b = body(&result);
        assert_eq!(b["machines"], json!(["studio", "cloud-1"]));
        assert!(b["error"].as_str().unwrap().starts_with(MESSAGE));
        assert!(b["error"].as_str().unwrap().ends_with("Ready to take it now: studio, cloud-1."));
        let remote =
            b["routes"].as_array().unwrap().iter().find(|r| r["route"] == "remote").unwrap();
        assert_eq!(remote["machines"], json!(["studio", "cloud-1"]));
        assert!(remote["text"].as_str().unwrap().contains("machine \"studio\""));
        // Unlock and Cloud stay offered.
        assert_eq!(b["routes"].as_array().unwrap().len(), 3);
    }

    #[test]
    fn no_machine_to_route_to_keeps_the_generic_result() {
        let out = || Outcome::Output(ToolOutput::error("mac_locked", "locked"));
        assert_eq!(to_mcp_routed(out(), Vec::new), to_mcp(out()));
    }

    #[test]
    fn an_unlocked_result_never_asks_for_machines() {
        let cases = [
            Outcome::Output(ToolOutput::ok(json!({"ok": true}))),
            Outcome::Output(ToolOutput::error("app_denied", "denied")),
            Outcome::Failed { code: "computer_use_unavailable".into(), message: "away".into() },
        ];
        for outcome in cases {
            let result = to_mcp_routed(outcome.clone(), || panic!("asked for machines"));
            assert_eq!(result, to_mcp(outcome));
        }
    }

    #[test]
    fn other_results_pass_through_unchanged() {
        let cases = [
            Outcome::Output(ToolOutput::error("app_denied", "denied")),
            Outcome::Output(ToolOutput::ok(json!({"code": "mac_locked"}))),
            Outcome::Off(String::new()),
            Outcome::Failed { code: "worker_error".into(), message: "mac_lockedness".into() },
            Outcome::Failed { code: "computer_use_unavailable".into(), message: "away".into() },
        ];
        for outcome in cases {
            assert_eq!(map(outcome.clone()), outcome);
            let result = to_mcp(outcome.clone());
            assert_eq!(result, outcome.to_mcp());
            assert!(result.get("_meta").is_none());
        }
    }
}
