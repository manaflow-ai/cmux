//! Claude Code's `hook_callback` control request: a hook its SDK host registered (the
//! `initialize` request's `hooks`, event -> `[{matcher, hookCallbackIds}]`) has fired, and
//! Claude Code waits for that callback's hook output before it goes on. acpmux registers none
//! today (`"hooks": {}` in `outbound.rs`), so any id is one it does not know: it answers with an
//! empty hook output, which Claude Code reads as a hook with no decision, never with an error.
//! Claude Code 2.1.310 given an error for a registered `Stop` callback never sent that turn's
//! result; given the empty output it ended the turn as usual.

use super::*;

impl Translator {
    /// Answers `hook_callback` `rid`: success with an empty hook output (no decision, no
    /// context, nothing stopped), so the hook Claude Code runs is a no-op and the turn goes on.
    pub(super) async fn answer_hook_callback(&self, rid: &str, req: &Value) {
        let id = req.get("callback_id").and_then(Value::as_str).unwrap_or("?");
        tracing::debug!("claude hook_callback {id}: no hook registered, answered with no decision");
        self.stdin_replies.lock().await.push(json!({
            "type": "control_response",
            "response": {"subtype": "success", "request_id": rid, "response": {}}
        }));
    }
}
