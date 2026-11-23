//! acpmux holds a prompt that names `@computer-use` (CMUX-682) while this Mac's Computer Use is
//! not ready, so no send route gets past the check: the page's own send, the app's prompt journal
//! replaying after a reconnect, a queued prompt that starts or is sent now, a queue edit, a Retry
//! that rebuilds a failed turn's words, and `/btw`.
//!
//! - The app says the state with `_acpmux/computer_use_state {"state": <state>}`, where the state
//!   is one of [`STATES`] or `null` (unknown). Only the verified local app connection
//!   (`Origin::LocalApp` with `ConnAuth::LocalApp`, `server/local_app.rs`) may set it; any other
//!   connection that names `state` is refused. The same method without `state` stays the peer's
//!   read of this machine's state (`server/computer_use_relay.rs` `state`).
//! - acpmux keeps the latest state in memory only. It is unknown at start, and an unknown state
//!   holds nothing: an older app that never sends it keeps today's behavior.
//! - A known state other than `ready` refuses every prompt for a chat on this Mac whose
//!   person-visible text (every text block that is not a context block) names `@computer-use`
//!   ([`crate::tool_mentions::mentioned`]), before its agent sees it. The refusal is
//!   [`refusal`]: data `{"reason": "computer_use.not_ready", "state": <state>}` and a plain
//!   message for the CLI.
//! - A chat on another machine is never held here: its prompt goes to that machine before this
//!   check (`server/peer_forward.rs`), and that machine's daemon has its own state.
//!
//! The checks, in order of arrival:
//!
//! | Route | Where | A refused prompt |
//! | --- | --- | --- |
//! | `session/prompt`, the journal replay too | `server/requests.rs` | answered with the refusal; one the chat already took (a resend of its id) answers as before |
//! | a queue edit (`update`) | `hub/queue_edit.rs` | the edit is refused; the prompt waits with its old words |
//! | Send now, `interrupt` | `hub/queue_edit.rs` | refused; the prompt stays queued |
//! | a queued prompt's start or steer | `hub/turns.rs` `run_prompt_joined` | refused as other dispatch checks are (`prompt_refused`); its `queued` record keeps its words |
//! | a failed turn's Retry | `hub/auto_resume/retry_turn.rs` | refused; the failed turn stays as it was |
//! | `/btw` | `hub/btw.rs` | refused before a side session is made |

use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::sync::RwLock;

/// The `data.reason` of a refusal.
pub const REASON: &str = "computer_use.not_ready";

/// The states the app sends (`computerUse/computerUseState.ts`).
pub const STATES: [&str; 5] = ["ready", "starting", "needs_setup", "unavailable", "disabled"];

/// This Mac's Computer Use state as the app last said it; `None` while unknown.
#[derive(Debug, Default)]
pub struct Gate {
    state: RwLock<Option<&'static str>>,
}

impl Gate {
    pub fn set(&self, state: Option<&'static str>) {
        *self.state.write().unwrap_or_else(|e| e.into_inner()) = state;
    }

    pub fn state(&self) -> Option<&'static str> {
        *self.state.read().unwrap_or_else(|e| e.into_inner())
    }

    /// The refusal for `blocks`, a prompt's content, or `Ok` when it may go.
    pub fn check(&self, blocks: &[Value]) -> Result<(), RpcError> {
        let Some(state) = self.state().filter(|s| *s != "ready") else { return Ok(()) };
        if names_computer_use(blocks) { Err(refusal(state)) } else { Ok(()) }
    }

    /// [`Gate::check`] for a prompt that is one text (`/btw`'s question).
    pub fn check_text(&self, text: &str) -> Result<(), RpcError> {
        self.check(&[json!({"type": "text", "text": text})])
    }
}

/// Whether the person-visible text of `blocks` names `@computer-use`.
pub fn names_computer_use(blocks: &[Value]) -> bool {
    let text = crate::tool_mentions::own_text(blocks);
    crate::tool_mentions::mentioned(&text).contains(&"computer-use")
}

/// The state in `_acpmux/computer_use_state`'s params: one of [`STATES`], or `None` for `null`.
pub fn parse(params: &Value) -> Result<Option<&'static str>, RpcError> {
    match params.get("state") {
        None => Err(RpcError::invalid_params("state is required")),
        Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => {
            STATES.iter().find(|k| **k == s).map(|k| Some(*k)).ok_or_else(|| {
                RpcError::invalid_params(format!(
                    "state must be one of {}, or null",
                    STATES.join(", ")
                ))
            })
        }
        Some(_) => Err(RpcError::invalid_params("state must be a string or null")),
    }
}

/// The refusal of a prompt that names `@computer-use` while the state is `state`.
pub fn refusal(state: &str) -> RpcError {
    let why = match state {
        "starting" => "Computer Use is still starting on this Mac",
        "needs_setup" => "Computer Use needs setup on this Mac (two macOS permissions in cmux)",
        "disabled" => "Computer Use is turned off in cmux settings",
        _ => "Computer Use is not available on this Mac",
    };
    RpcError::new(
        -32000,
        format!("{why}. The message names @computer-use, so it was not sent: send it again when Computer Use is ready, or remove @computer-use."),
    )
    .with_data(json!({"reason": REASON, "state": state}))
}

/// Whether `e` is a [`refusal`].
pub fn is_refusal(e: &RpcError) -> bool {
    e.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str) == Some(REASON)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(t: &str) -> Value {
        json!({"type": "text", "text": t})
    }

    #[test]
    fn computer_use_gate_holds_only_a_known_state_that_is_not_ready() {
        let gate = Gate::default();
        let asks = [text("open Notes with @computer-use")];
        // Unknown: an older app never says it, and nothing is held.
        assert!(gate.check(&asks).is_ok());
        gate.set(Some("ready"));
        assert!(gate.check(&asks).is_ok());
        for state in ["starting", "needs_setup", "unavailable", "disabled"] {
            gate.set(Some(state));
            let e = gate.check(&asks).unwrap_err();
            assert_eq!(e.data, Some(json!({"reason": REASON, "state": state})));
            assert!(e.message.contains("@computer-use"), "{}", e.message);
            assert!(is_refusal(&e));
        }
        gate.set(None);
        assert!(gate.check(&asks).is_ok());
    }

    #[test]
    fn computer_use_gate_reads_the_persons_words_only() {
        let gate = Gate::default();
        gate.set(Some("needs_setup"));
        assert!(gate.check(&[text("open it with @browser-use")]).is_ok());
        assert!(gate.check(&[text("run `@computer-use` literally")]).is_ok());
        // A context block (the tools note itself, a client's) is not the person's words.
        let note = crate::tool_mentions::note(&["computer-use"]).unwrap();
        let hidden = json!({"type": "text", "text": note, "_meta": {"acpmux": {"context": true}}});
        assert!(gate.check(&[text("plain words"), hidden]).is_ok());
        assert!(gate.check_text("now @computer-use").is_err());
    }

    #[test]
    fn computer_use_gate_params_name_a_known_state_or_null() {
        assert_eq!(parse(&json!({"state": "ready"})).unwrap(), Some("ready"));
        assert_eq!(parse(&json!({"state": null})).unwrap(), None);
        assert!(parse(&json!({})).is_err());
        assert!(parse(&json!({"state": "on"})).is_err());
        assert!(parse(&json!({"state": 1})).is_err());
    }
}
