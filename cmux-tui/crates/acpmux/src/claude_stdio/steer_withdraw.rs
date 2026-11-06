//! Taking back a steer Claude Code has not read (`MUX_STEER_WITHDRAW`, the X on a waiting
//! steer's row). A steered line waits in Claude Code's command queue until its current step
//! ends; Claude Code's `cancel_async_message` drops it from there by the line's uuid, and is a
//! no-op once Claude Code took it (`{cancelled: false}`). Dropped, the steer's own prompt answers
//! `STEER_WITHDRAWN`; otherwise it stays and is answered `steered` at its echo, as before.
//!
//! Another session's message in a line of several (`steer_batch.rs`) is taken back too, whatever
//! route sent it (Leo, 2026-11-06: "I can't ... cancel and edit these messages. Why? Is it because
//! the ... codex thing sent them?"): the whole line is dropped, and the line's other messages go
//! in again as one new line, each still answered at that line's echo. Only a message in a line
//! being written again, or held for one, stays: that lasts until Claude Code answers the drop.

use super::*;

impl Translator {
    /// `MUX_STEER_WITHDRAW {sessionId, promptId}`: asks Claude Code to drop the steer of that
    /// prompt (`_meta.promptId` of its `session/prompt`) while it still waits; answers
    /// `{withdrawn: false}` at once when none does.
    pub(super) async fn withdraw_steer(&self, id: &Id, p: &Value) -> Outbound {
        let prompt_id = p.get("promptId").and_then(Value::as_str).unwrap_or_default();
        // Under the steers lock, which `fail_pending` takes before it answers what waits: a steer
        // failed meanwhile is not asked for, and a withdraw registered here is answered by it.
        let batches = self.batches.lock().await;
        let steers = self.steers.lock().await;
        let uuid = self.steer_lines.lock().await.get(prompt_id).cloned();
        let uuid = uuid.filter(|u| steers.iter().any(|(s, _)| s == u));
        // Another session's message in a line being written again, or held for one: it stays,
        // as one Claude Code read first does (`steer_batch.rs`).
        if Self::rewriting(&batches, prompt_id, uuid.as_deref()) {
            return Outbound::Reply(Message::ok(id.clone(), json!({"withdrawn": false})));
        }
        drop(batches);
        let Some(uuid) = uuid else {
            return Outbound::Reply(Message::ok(id.clone(), json!({"withdrawn": false})));
        };
        self.pending.lock().await.insert(id.to_string(), Pending::Withdraw(prompt_id.to_owned()));
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
        let pending = self.pending.lock().await.remove(&id.to_string());
        let waited = pending.is_some();
        let cancelled = ok && inner.get("cancelled").and_then(Value::as_bool) == Some(true);
        let mut out = Vec::new();
        // Withdrawn only while its prompt still waits here: a steer answered meanwhile (the turn
        // ended, the agent's answers failed) has its own answer, and is not taken back.
        let mut withdrawn = false;
        let prompt_id = match pending {
            Some(Pending::Withdraw(prompt_id)) => Some(prompt_id),
            _ => None,
        };
        if cancelled && let Some(steer) = self.unbatch(uuid, prompt_id.as_deref()).await {
            out.push(Message::err(steer, RpcError::internal(STEER_WITHDRAWN)));
            withdrawn = true;
        } else if cancelled {
            let mut steers = self.steers.lock().await;
            if let Some(at) = steers.iter().position(|(u, _)| u == uuid)
                && let Some((_, k)) = steers.remove(at)
            {
                drop(steers);
                self.steer_lines.lock().await.retain(|_, u| u != uuid);
                self.forget_batch(uuid).await;
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

    /// After Claude Code dropped line `uuid` for a withdraw of `prompt_id`: when the line held
    /// other sessions' messages besides it, those go in again as a new line (or lines past
    /// `BATCH_MAX_BYTES`), and the withdrawn message's steer id is returned. `None`
    /// for a line of one message, which `steer_withdrawn` drops as before.
    async fn unbatch(&self, uuid: &str, prompt_id: Option<&str>) -> Option<Id> {
        let prompt_id = prompt_id?;
        let mut batches = self.batches.lock().await;
        let mut steers = self.steers.lock().await;
        let parts = batches.lines.get(uuid).filter(|parts| parts.len() > 1)?;
        // Answered meanwhile (the turn ended): nothing waits here to take back or write again.
        if !steers.iter().any(|(u, _)| u == uuid) {
            return None;
        }
        let at = parts.iter().position(|p| p.prompt_id.as_deref() == Some(prompt_id))?;
        let mut parts = batches.lines.remove(uuid).unwrap_or_default();
        let gone = parts.remove(at);
        steers.retain(|(u, _)| u != uuid);
        let mut written = Vec::new();
        for parts in super::steer_batch::lines_of(parts) {
            let (new, line) = self.steer_line(&mut steers, &parts).await;
            batches.lines.insert(new, parts);
            written.push(line);
        }
        drop(steers);
        drop(batches);
        self.stdin_replies.lock().await.extend(written);
        Some(serde_json::from_str(&gone.id).unwrap_or_else(|_| Value::String(gone.id.clone())))
    }
}
