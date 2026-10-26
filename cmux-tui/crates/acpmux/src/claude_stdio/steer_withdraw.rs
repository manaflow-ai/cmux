//! Taking back a steer Claude Code has not read (`MUX_STEER_WITHDRAW`, the X on a waiting
//! steer's row). A steered line waits in Claude Code's command queue until its current step
//! ends; Claude Code's `cancel_async_message` drops it from there by the line's uuid, and is a
//! no-op once Claude Code took it (`{cancelled: false}`). Dropped, the steer's own prompt answers
//! `STEER_WITHDRAWN`; otherwise it stays and is answered `steered` at its echo, as before.

use super::*;

impl Translator {
    /// `MUX_STEER_WITHDRAW {sessionId, promptId}`: asks Claude Code to drop the steer of that
    /// prompt (`_meta.promptId` of its `session/prompt`) while it still waits; answers
    /// `{withdrawn: false}` at once when none does.
    pub(super) async fn withdraw_steer(&self, id: &Id, p: &Value) -> Outbound {
        let prompt_id = p.get("promptId").and_then(Value::as_str).unwrap_or_default();
        // Under the steers lock, which `fail_pending` takes before it answers what waits: a steer
        // failed meanwhile is not asked for, and a withdraw registered here is answered by it.
        let steers = self.steers.lock().await;
        let uuid = self.steer_lines.lock().await.get(prompt_id).cloned();
        let Some(uuid) = uuid.filter(|u| steers.iter().any(|(s, _)| s == u)) else {
            return Outbound::Reply(Message::ok(id.clone(), json!({"withdrawn": false})));
        };
        self.pending.lock().await.insert(id.to_string(), Pending::Withdraw);
        drop(steers);
        // The uuid rides in the request id: its answer names the line it dropped.
        Outbound::Lines(vec![json!({
            "type": "control_request",
            "request_id": format!("unsteer-{uuid}:{id}"),
            "request": {"subtype": "cancel_async_message", "message_uuid": uuid},
        })])
    }

    /// Claude Code's answer to `withdraw_steer` (`rest` is `<uuid>:<ACP id>`): the withdraw's
    /// reply, and the dropped steer's own answer.
    pub(super) async fn steer_withdrawn(
        &self,
        rest: &str,
        ok: bool,
        inner: &Value,
    ) -> Vec<Message> {
        let Some((uuid, acp)) = rest.split_once(':') else { return Vec::new() };
        let id: Id = serde_json::from_str(acp).unwrap_or(Value::String(acp.to_owned()));
        // Answered already (`fail_pending`): no second answer.
        let waited = self.pending.lock().await.remove(&id.to_string()).is_some();
        let cancelled = ok && inner.get("cancelled").and_then(Value::as_bool) == Some(true);
        let mut out = Vec::new();
        // Withdrawn only while its prompt still waits here: a steer answered meanwhile (the turn
        // ended, the agent's answers failed) has its own answer, and is not taken back.
        let mut withdrawn = false;
        if cancelled {
            let mut steers = self.steers.lock().await;
            if let Some(at) = steers.iter().position(|(u, _)| u == uuid)
                && let Some((_, k)) = steers.remove(at)
            {
                drop(steers);
                self.steer_lines.lock().await.retain(|_, u| u != uuid);
                let steer: Id = serde_json::from_str(&k).unwrap_or(Value::String(k));
                out.push(Message::err(steer, RpcError::internal(STEER_WITHDRAWN)));
                withdrawn = true;
            }
        }
        if waited {
            out.push(Message::ok(id, json!({"withdrawn": withdrawn})));
        }
        out
    }
}
